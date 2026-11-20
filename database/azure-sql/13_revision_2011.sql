/* =====================================================================
   13_revision_2011.sql  -  Revisión del equipo del 20-11
   ---------------------------------------------------------------------
   - Sucursales: los laboratorios propios son sucursales de la empresa,
     con su ubicación (para "Cómo llegar"). Cada laboratorista pertenece a
     una sucursal y cada turno de toma de muestras es de una sucursal.
   - La cita de control que agenda el médico SÍ se cobra (como consulta).
     Se paga hasta 2 horas antes; si no, se cancela sola.
   - Nota de la consulta: motivo, molestias, examen físico y diagnóstico.
     La receta puede ir sobre la propia consulta (sin ordenar exámenes).
   - Exámenes ordenados en una consulta: se guarda en qué consulta.
   - Descuentos por sucursal, examen y fechas (o para todo).
   - Nombre del titular de la tarjeta, validado antes de ir a Stripe.
   Ejecutar después de 12_laboratorios.sql y DESPUÉS de
   07_revision_2011.sql en Supabase.
   ===================================================================== */

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ---------------------------------------------------------------------
   1. SUCURSALES
   ------------------------------------------------------------------- */
IF COL_LENGTH('dbo.laboratorio', 'latitud') IS NULL
    ALTER TABLE dbo.laboratorio ADD latitud DECIMAL(9,6) NULL, longitud DECIMAL(9,6) NULL;
GO
UPDATE dbo.laboratorio SET nombre = N'Laboratorio Clínico UTA - Matriz Huachi', latitud = -1.268630, longitud = -78.624240,
       updated_at = SYSUTCDATETIME()
WHERE laboratorio_id = 1 AND latitud IS NULL;
IF NOT EXISTS (SELECT 1 FROM dbo.laboratorio WHERE nombre = N'Laboratorio Clínico UTA - Sucursal Centro')
    INSERT INTO dbo.laboratorio (nombre, direccion, telefono, propio, latitud, longitud)
    VALUES (N'Laboratorio Clínico UTA - Sucursal Centro', N'Calle Sucre y Castillo, Ambato', '032000001', 1, -1.241670, -78.619720);
GO

IF COL_LENGTH('dbo.laboratorista', 'laboratorio_id') IS NULL
    ALTER TABLE dbo.laboratorista ADD laboratorio_id INT NULL
        CONSTRAINT fk_laboratorista_sucursal FOREIGN KEY REFERENCES dbo.laboratorio(laboratorio_id);
GO
UPDATE dbo.laboratorista SET laboratorio_id = (SELECT MIN(laboratorio_id) FROM dbo.laboratorio WHERE propio = 1),
       updated_at = SYSUTCDATETIME()
WHERE laboratorio_id IS NULL;
GO

IF COL_LENGTH('dbo.franja_horaria', 'laboratorio_id') IS NULL
    ALTER TABLE dbo.franja_horaria ADD laboratorio_id INT NULL
        CONSTRAINT fk_franja_sucursal FOREIGN KEY REFERENCES dbo.laboratorio(laboratorio_id);
GO
UPDATE dbo.franja_horaria SET laboratorio_id = (SELECT MIN(laboratorio_id) FROM dbo.laboratorio WHERE propio = 1),
       updated_at = SYSUTCDATETIME()
WHERE medico_id IS NULL AND laboratorio_id IS NULL;
GO
-- El mismo horario puede existir en cada sucursal y en la agenda de cada médico.
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uq_franja_medico' AND object_id = OBJECT_ID('dbo.franja_horaria'))
BEGIN
    IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'uq_franja_medico')
        ALTER TABLE dbo.franja_horaria DROP CONSTRAINT uq_franja_medico;
    ELSE
        DROP INDEX uq_franja_medico ON dbo.franja_horaria;
END;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'uq_franja_agenda' AND object_id = OBJECT_ID('dbo.franja_horaria'))
    CREATE UNIQUE INDEX uq_franja_agenda ON dbo.franja_horaria (fecha, hora_inicio, medico_id, laboratorio_id);
GO

/* ---------------------------------------------------------------------
   2. CONSULTA: de qué consulta sale cada control y cada orden de exámenes
   ------------------------------------------------------------------- */
IF COL_LENGTH('dbo.cita', 'cita_origen_id') IS NULL
    ALTER TABLE dbo.cita ADD cita_origen_id BIGINT NULL
        CONSTRAINT fk_cita_origen FOREIGN KEY REFERENCES dbo.cita(cita_id);
GO
IF COL_LENGTH('dbo.solicitud_examen', 'consulta_cita_id') IS NULL
    ALTER TABLE dbo.solicitud_examen ADD consulta_cita_id BIGINT NULL
        CONSTRAINT fk_sol_consulta FOREIGN KEY REFERENCES dbo.cita(cita_id);
GO

/* Lo que anota el médico en la consulta (dato clínico: solo médico y paciente). */
IF OBJECT_ID('dbo.consulta_nota') IS NULL
CREATE TABLE dbo.consulta_nota (
    cita_id        BIGINT          NOT NULL,
    medico_id      BIGINT          NOT NULL,
    motivo         NVARCHAR(500)   NULL,     -- motivo de la consulta
    sintomas       NVARCHAR(2000)  NULL,     -- molestias principales
    examen_fisico  NVARCHAR(2000)  NULL,     -- observaciones de la consulta
    diagnostico    NVARCHAR(500)   NULL,
    created_at     DATETIME2(3)    NOT NULL CONSTRAINT df_cnota_created DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3)    NOT NULL CONSTRAINT df_cnota_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_consulta_nota PRIMARY KEY (cita_id),
    CONSTRAINT fk_cnota_cita FOREIGN KEY (cita_id) REFERENCES dbo.cita(cita_id),
    CONSTRAINT fk_cnota_medico FOREIGN KEY (medico_id) REFERENCES dbo.medico(medico_id)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID('dbo.consulta_nota'))
    ALTER TABLE dbo.consulta_nota ENABLE CHANGE_TRACKING;
GO

/* ---------------------------------------------------------------------
   3. DESCUENTOS
   ------------------------------------------------------------------- */
IF OBJECT_ID('dbo.descuento') IS NULL
CREATE TABLE dbo.descuento (
    descuento_id    INT IDENTITY(1,1) NOT NULL,
    nombre          NVARCHAR(120)  NOT NULL,
    porcentaje      DECIMAL(5,2)   NOT NULL,
    laboratorio_id  INT            NULL,     -- NULL = todas las sucursales
    tipo_examen_id  INT            NULL,     -- NULL = todos los exámenes
    desde           DATE           NOT NULL,
    hasta           DATE           NOT NULL,
    activo          BIT            NOT NULL CONSTRAINT df_descuento_activo DEFAULT 1,
    updated_at      DATETIME2(3)   NOT NULL CONSTRAINT df_descuento_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_descuento PRIMARY KEY (descuento_id),
    CONSTRAINT ck_descuento_porcentaje CHECK (porcentaje > 0 AND porcentaje <= 90),
    CONSTRAINT ck_descuento_fechas CHECK (hasta >= desde),
    CONSTRAINT fk_descuento_laboratorio FOREIGN KEY (laboratorio_id) REFERENCES dbo.laboratorio(laboratorio_id),
    CONSTRAINT fk_descuento_examen FOREIGN KEY (tipo_examen_id) REFERENCES dbo.tipo_examen(tipo_examen_id)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID('dbo.descuento'))
    ALTER TABLE dbo.descuento ENABLE CHANGE_TRACKING;
GO
IF COL_LENGTH('dbo.solicitud_detalle', 'precio_lista') IS NULL
    ALTER TABLE dbo.solicitud_detalle ADD precio_lista DECIMAL(10,2) NULL, descuento_id INT NULL
        CONSTRAINT fk_detalle_descuento FOREIGN KEY REFERENCES dbo.descuento(descuento_id);
GO

/* ---------------------------------------------------------------------
   4. TITULAR DE LA TARJETA
   ------------------------------------------------------------------- */
IF COL_LENGTH('dbo.pago', 'titular_tarjeta') IS NULL
    ALTER TABLE dbo.pago ADD titular_tarjeta NVARCHAR(100) NULL;
GO

IF USER_ID('app_api') IS NOT NULL
BEGIN
    GRANT SELECT, INSERT, UPDATE ON dbo.consulta_nota TO app_api;
    GRANT SELECT, INSERT, UPDATE ON dbo.descuento TO app_api;
END;
GO

/* ---------------------------------------------------------------------
   5. PROCEDIMIENTOS
   ------------------------------------------------------------------- */

/* La consulta (y ahora también el control) se cobra. El control guarda de qué consulta sale. */
CREATE OR ALTER PROCEDURE dbo.sp_reservar_consulta
    @paciente_id     BIGINT,
    @franja_id       BIGINT,
    @motivo          NVARCHAR(300) = NULL,
    @origen          VARCHAR(10) = 'PACIENTE',
    @medico_agenda   BIGINT = NULL,           -- con origen MEDICO: solo en sus propias franjas
    @cita_origen_id  BIGINT = NULL,           -- consulta de la que sale el control
    @usuario_id      BIGINT = NULL,
    @instancia_api   VARCHAR(30) = NULL,
    @cita_id         BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @cita_id = NULL;
    DECLARE @capacidad TINYINT, @ocupados TINYINT, @activa BIT, @fecha DATE, @hora TIME(0), @medico_id BIGINT,
            @tipo_consulta INT, @precio DECIMAL(10,2), @solicitud_id BIGINT;
    IF @origen NOT IN ('PACIENTE', 'MEDICO') THROW 50100, 'Origen de la cita no válido.', 1;
    SELECT @tipo_consulta = tipo_examen_id, @precio = precio FROM dbo.tipo_examen WHERE codigo = 'CONS-MED';
    IF @tipo_consulta IS NULL THROW 50101, 'No está configurado el precio de la consulta (CONS-MED).', 1;
    IF @cita_origen_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.cita WHERE cita_id = @cita_origen_id AND paciente_id = @paciente_id)
        THROW 50120, 'La consulta de origen no es de este paciente.', 1;

    BEGIN TRY
    BEGIN TRAN;
        SELECT @capacidad = capacidad, @ocupados = ocupados, @activa = activa, @fecha = fecha, @hora = hora_inicio,
               @medico_id = medico_id
        FROM dbo.franja_horaria WITH (UPDLOCK, HOLDLOCK, ROWLOCK)
        WHERE franja_id = @franja_id;

        IF @capacidad IS NULL THROW 50010, 'La franja no existe.', 1;
        IF @medico_id IS NULL THROW 50102, 'La franja es de toma de muestras, no de consulta.', 1;
        IF @origen = 'MEDICO' AND @medico_agenda <> @medico_id THROW 50103, 'Solo puede agendar en su propia agenda.', 1;
        IF @activa = 0 OR DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @hora), CAST(@fecha AS DATETIME2(0))) < DATEADD(HOUR, -5, SYSUTCDATETIME())
            THROW 50011, 'La franja no está disponible.', 1;
        IF @ocupados >= @capacidad THROW 50012, 'La franja ya no tiene cupos disponibles.', 1;
        IF EXISTS (SELECT 1 FROM dbo.paciente pa JOIN dbo.medico m ON m.persona_id = pa.persona_id
                   WHERE pa.paciente_id = @paciente_id AND m.medico_id = @medico_id)
            THROW 50104, 'Un médico no puede agendarse una consulta consigo mismo.', 1;

        UPDATE dbo.franja_horaria SET ocupados = ocupados + 1, updated_at = SYSUTCDATETIME() WHERE franja_id = @franja_id;

        INSERT INTO dbo.cita (paciente_id, franja_id, motivo, canal, tipo, medico_id, origen, estado, cita_origen_id)
        VALUES (@paciente_id, @franja_id, @motivo, 'PORTAL', 'CONSULTA', @medico_id, @origen, 'PENDIENTE_PAGO', @cita_origen_id);
        SET @cita_id = SCOPE_IDENTITY();

        INSERT INTO dbo.solicitud_examen (codigo, paciente_id, medico_id, cita_id, tipo, observaciones)
        VALUES (CONCAT('TMP-', LEFT(REPLACE(CAST(NEWID() AS CHAR(36)), '-', ''), 16)), @paciente_id, @medico_id, @cita_id,
                'CONSULTA', @motivo);
        SET @solicitud_id = SCOPE_IDENTITY();
        INSERT INTO dbo.solicitud_detalle (solicitud_id, tipo_examen_id, precio_unitario, precio_lista)
        VALUES (@solicitud_id, @tipo_consulta, @precio, @precio);
        UPDATE dbo.solicitud_examen
        SET codigo = CONCAT('SOL-', YEAR(SYSUTCDATETIME()), '-', RIGHT(CONCAT('000000', @solicitud_id), 6)), total = @precio
        WHERE solicitud_id = @solicitud_id;

        DECLARE @det NVARCHAR(300) = CONCAT(N'{"franja_id":', @franja_id, N',"medico_id":', @medico_id,
                                             N',"origen":"', @origen, N'","solicitud_id":', @solicitud_id, N'}');
        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @accion = 'RESERVAR_CONSULTA', @entidad = 'cita',
             @entidad_id = @cita_id, @detalle = @det, @instancia_api = @instancia_api;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* Cancelar: libera el cupo y anula el cobro de la cita. Si ya estaba pagada (la API
   devolvió una parte del dinero antes de llamar aquí), también se anula lo pagado
   que aún no se procesa. */
CREATE OR ALTER PROCEDURE dbo.sp_cancelar_cita
    @cita_id     BIGINT,
    @usuario_id  BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @franja_id BIGINT, @estado VARCHAR(20);

    BEGIN TRY
    BEGIN TRAN;
        SELECT @franja_id = franja_id, @estado = estado
        FROM dbo.cita WITH (UPDLOCK, HOLDLOCK)
        WHERE cita_id = @cita_id;

        IF @franja_id IS NULL THROW 50013, 'La cita no existe.', 1;
        IF @estado NOT IN ('PENDIENTE_PAGO', 'CONFIRMADA') THROW 50014, 'La cita no se puede cancelar en su estado actual.', 1;

        UPDATE dbo.cita SET estado = 'CANCELADA', cancelada_at = SYSUTCDATETIME(), updated_at = SYSUTCDATETIME()
        WHERE cita_id = @cita_id;

        UPDATE dbo.franja_horaria SET ocupados = ocupados - 1, updated_at = SYSUTCDATETIME()
        WHERE franja_id = @franja_id AND ocupados > 0;

        UPDATE dbo.solicitud_examen SET estado = 'ANULADA', updated_at = SYSUTCDATETIME()
        WHERE cita_id = @cita_id AND ((tipo = 'CONSULTA' AND estado IN ('REGISTRADA', 'PAGADA')) OR estado = 'PAGADA');

        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @accion = 'CANCELAR_CITA', @entidad = 'cita', @entidad_id = @cita_id;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* Precio de cada examen con el mejor descuento vigente de la sucursal (o general).
   Solo antes de pagar y solo en nuestras sucursales (en un laboratorio externo se paga allá). */
CREATE OR ALTER PROCEDURE dbo.sp_aplicar_descuentos
    @solicitud_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @estado VARCHAR(20), @tipo VARCHAR(10), @lab INT, @propio BIT, @hoy DATE = CAST(DATEADD(HOUR, -5, SYSUTCDATETIME()) AS DATE);
    SELECT @estado = s.estado, @tipo = s.tipo, @lab = s.laboratorio_id, @propio = ISNULL(l.propio, 1)
    FROM dbo.solicitud_examen s LEFT JOIN dbo.laboratorio l ON l.laboratorio_id = s.laboratorio_id
    WHERE s.solicitud_id = @solicitud_id;
    IF @estado IS NULL OR @estado <> 'REGISTRADA' OR @tipo <> 'EXAMENES' RETURN;
    IF EXISTS (SELECT 1 FROM dbo.pago WHERE solicitud_id = @solicitud_id AND estado IN ('PENDIENTE', 'APROBADO')) RETURN;

    BEGIN TRAN;
        UPDATE d
        SET precio_lista = t.precio,
            descuento_id = IIF(@propio = 1, x.descuento_id, NULL),
            precio_unitario = IIF(@propio = 1 AND x.descuento_id IS NOT NULL,
                                  ROUND(t.precio * (100 - x.porcentaje) / 100, 2), t.precio)
        FROM dbo.solicitud_detalle d
        JOIN dbo.tipo_examen t ON t.tipo_examen_id = d.tipo_examen_id
        OUTER APPLY (SELECT TOP 1 ds.descuento_id, ds.porcentaje FROM dbo.descuento ds
                     WHERE ds.activo = 1 AND @hoy BETWEEN ds.desde AND ds.hasta
                       AND (ds.laboratorio_id IS NULL OR ds.laboratorio_id = @lab
                            OR (@lab IS NULL AND ds.laboratorio_id = (SELECT MIN(laboratorio_id) FROM dbo.laboratorio WHERE propio = 1)))
                       AND (ds.tipo_examen_id IS NULL OR ds.tipo_examen_id = d.tipo_examen_id)
                     ORDER BY ds.porcentaje DESC, ds.descuento_id) x
        WHERE d.solicitud_id = @solicitud_id AND d.estado <> 'ANULADO';

        UPDATE dbo.solicitud_examen
        SET total = (SELECT SUM(precio_unitario) FROM dbo.solicitud_detalle WHERE solicitud_id = @solicitud_id AND estado <> 'ANULADO'),
            updated_at = SYSUTCDATETIME()
        WHERE solicitud_id = @solicitud_id;
    COMMIT;
END;
GO

/* Receta: sobre una solicitud de exámenes con resultados o sobre la propia consulta (pagada),
   para recetar sin ordenar exámenes (por ejemplo, una gripe). */
CREATE OR ALTER PROCEDURE dbo.sp_guardar_receta
    @solicitud_id            BIGINT,
    @medico_id               BIGINT,
    @diagnostico             NVARCHAR(500) = NULL,
    @indicaciones_generales  NVARCHAR(2000) = NULL,
    @items                   NVARCHAR(MAX),
    @usuario_id              BIGINT = NULL,
    @receta_id               BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @receta_id = NULL;
    IF ISJSON(@items) = 0 THROW 50090, 'Los medicamentos no son un JSON válido.', 1;
    IF NOT EXISTS (SELECT 1 FROM OPENJSON(@items)) THROW 50091, 'La receta necesita al menos un medicamento.', 1;
    IF EXISTS (SELECT 1 FROM OPENJSON(@items) WITH (nombre NVARCHAR(120))
               WHERE NULLIF(LTRIM(RTRIM(nombre)), N'') IS NULL)
        THROW 50092, 'Cada medicamento necesita su nombre.', 1;
    DECLARE @paciente_id BIGINT, @estado VARCHAR(20), @tipo VARCHAR(10);
    SELECT @paciente_id = paciente_id, @estado = estado, @tipo = tipo FROM dbo.solicitud_examen WHERE solicitud_id = @solicitud_id;
    IF @paciente_id IS NULL THROW 50093, 'La solicitud no existe.', 1;
    IF @tipo = 'CONSULTA' AND @estado NOT IN ('PAGADA', 'COMPLETADA')
        THROW 50121, 'La consulta aún no está pagada.', 1;
    IF @tipo = 'EXAMENES' AND @estado NOT IN ('EN_PROCESO', 'COMPLETADA') THROW 50094, 'La solicitud aún no tiene resultados.', 1;
    IF EXISTS (SELECT 1 FROM dbo.paciente pa JOIN dbo.medico m ON m.persona_id = pa.persona_id
               WHERE pa.paciente_id = @paciente_id AND m.medico_id = @medico_id)
        THROW 50095, 'Un médico no puede recetarse a sí mismo.', 1;
    BEGIN TRY
    BEGIN TRAN;
        SELECT @receta_id = receta_id FROM dbo.receta WITH (UPDLOCK, HOLDLOCK)
        WHERE solicitud_id = @solicitud_id AND medico_id = @medico_id;
        IF @receta_id IS NULL
        BEGIN
            INSERT INTO dbo.receta (solicitud_id, paciente_id, medico_id, diagnostico, indicaciones_generales)
            VALUES (@solicitud_id, @paciente_id, @medico_id, @diagnostico, @indicaciones_generales);
            SET @receta_id = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            UPDATE dbo.receta SET diagnostico = @diagnostico, indicaciones_generales = @indicaciones_generales,
                   updated_at = SYSUTCDATETIME()
            WHERE receta_id = @receta_id;
            DELETE FROM dbo.receta_item WHERE receta_id = @receta_id;
        END;
        INSERT INTO dbo.receta_item (receta_id, orden, medicamento_id, nombre, presentacion, via, dosis, frecuencia,
                                     duracion_dias, cantidad, indicaciones, modificado)
        SELECT @receta_id, CAST(j.[key] AS INT) + 1,
               (SELECT m.medicamento_id FROM dbo.medicamento m WHERE m.medicamento_id = v.medicamento_id),
               LTRIM(RTRIM(v.nombre)), v.presentacion, v.via, ISNULL(LTRIM(RTRIM(v.dosis)), N''), ISNULL(LTRIM(RTRIM(v.frecuencia)), N''),
               NULLIF(v.duracion_dias, 0), v.cantidad, v.indicaciones, ISNULL(v.modificado, 0)
        FROM OPENJSON(@items) j
        CROSS APPLY OPENJSON(j.[value]) WITH (
            medicamento_id INT, nombre NVARCHAR(120), presentacion NVARCHAR(120), via NVARCHAR(30),
            dosis NVARCHAR(60), frecuencia NVARCHAR(60), duracion_dias SMALLINT, cantidad NVARCHAR(40),
            indicaciones NVARCHAR(1000), modificado BIT) v;

        DECLARE @det NVARCHAR(200) = CONCAT(N'{"solicitud_id":', @solicitud_id, N',"medicamentos":',
                                             (SELECT COUNT(*) FROM OPENJSON(@items)), N'}');
        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @rol_actuante = 'MEDICO', @accion = 'GUARDAR_RECETA',
             @entidad = 'receta', @entidad_id = @receta_id, @detalle = @det;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* Descuento creado por el administrador (queda en la auditoría). */
CREATE OR ALTER PROCEDURE dbo.sp_crear_descuento
    @nombre          NVARCHAR(120),
    @porcentaje      DECIMAL(5,2),
    @laboratorio_id  INT = NULL,
    @tipo_examen_id  INT = NULL,
    @desde           DATE,
    @hasta           DATE,
    @usuario_id      BIGINT = NULL,
    @descuento_id    BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF @porcentaje <= 0 OR @porcentaje > 90 THROW 50122, 'El descuento debe estar entre 1 % y 90 %.', 1;
    IF @hasta < @desde THROW 50123, 'La fecha final no puede ser anterior a la inicial.', 1;
    IF @tipo_examen_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.tipo_examen WHERE tipo_examen_id = @tipo_examen_id)
        THROW 50124, 'El examen no existe.', 1;
    BEGIN TRAN;
        INSERT INTO dbo.descuento (nombre, porcentaje, laboratorio_id, tipo_examen_id, desde, hasta)
        VALUES (@nombre, @porcentaje, @laboratorio_id, @tipo_examen_id, @desde, @hasta);
        SET @descuento_id = SCOPE_IDENTITY();
        DECLARE @det NVARCHAR(200) = CONCAT(N'{"porcentaje":', @porcentaje, N',"laboratorio_id":',
                                             ISNULL(CAST(@laboratorio_id AS VARCHAR(10)), 'null'), N'}');
        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @rol_actuante = 'ADMIN', @accion = 'CREAR_DESCUENTO',
             @entidad = 'descuento', @entidad_id = @descuento_id, @detalle = @det;
    COMMIT;
END;
GO

/* Escrituras puntuales de la revisión, por procedimiento (app_api no tiene UPDATE directo en estas tablas). */

/* Turno de toma de muestras elegido para la solicitud: queda en esa sucursal; si ya estaba pagada, confirmado. */
CREATE OR ALTER PROCEDURE dbo.sp_vincular_turno
    @solicitud_id    BIGINT,
    @cita_id         BIGINT,
    @laboratorio_id  INT,
    @usuario_id      BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @estado VARCHAR(20), @paciente BIGINT;
    SELECT @estado = estado, @paciente = paciente_id FROM dbo.solicitud_examen WHERE solicitud_id = @solicitud_id;
    IF @estado IS NULL THROW 50110, 'La solicitud no existe.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.cita WHERE cita_id = @cita_id AND paciente_id = @paciente AND tipo = 'MUESTRA')
        THROW 50125, 'El turno no es de este paciente.', 1;
    BEGIN TRAN;
        UPDATE dbo.solicitud_examen SET cita_id = @cita_id, laboratorio_id = @laboratorio_id, updated_at = SYSUTCDATETIME()
        WHERE solicitud_id = @solicitud_id;
        IF @estado = 'PAGADA'
            UPDATE dbo.cita SET estado = 'CONFIRMADA', updated_at = SYSUTCDATETIME()
            WHERE cita_id = @cita_id AND estado = 'PENDIENTE_PAGO';
        DECLARE @det NVARCHAR(100) = CONCAT(N'{"cita_id":', @cita_id, N',"laboratorio_id":', @laboratorio_id, N'}');
        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @accion = 'ELEGIR_TURNO', @entidad = 'solicitud_examen',
             @entidad_id = @solicitud_id, @detalle = @det;
    COMMIT;
END;
GO

/* Exámenes ordenados en una consulta: se guarda cuál (para mostrarlos en esa consulta y en su control). */
CREATE OR ALTER PROCEDURE dbo.sp_marcar_consulta_solicitud
    @solicitud_id      BIGINT,
    @consulta_cita_id  BIGINT,
    @medico_id         BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE s SET consulta_cita_id = @consulta_cita_id, updated_at = SYSUTCDATETIME()
    FROM dbo.solicitud_examen s JOIN dbo.cita c ON c.cita_id = @consulta_cita_id
    WHERE s.solicitud_id = @solicitud_id AND c.paciente_id = s.paciente_id AND c.medico_id = @medico_id;
END;
GO

/* Nombre del titular de la tarjeta (validado en la API antes de ir a Stripe). */
CREATE OR ALTER PROCEDURE dbo.sp_titular_pago
    @pago_id  BIGINT,
    @titular  NVARCHAR(100)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.pago SET titular_tarjeta = @titular, updated_at = SYSUTCDATETIME() WHERE pago_id = @pago_id AND estado = 'PENDIENTE';
END;
GO

/* Sucursal en la que trabaja un laboratorista. */
CREATE OR ALTER PROCEDURE dbo.sp_asignar_sucursal
    @usuario_id      BIGINT,
    @laboratorio_id  INT,
    @admin_id        BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.laboratorio WHERE laboratorio_id = @laboratorio_id AND propio = 1 AND activo = 1)
        THROW 50126, 'Elija una sucursal activa de la empresa.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.laboratorista l JOIN dbo.usuario u ON u.persona_id = l.persona_id WHERE u.usuario_id = @usuario_id)
        THROW 50127, 'El usuario no es laboratorista.', 1;
    BEGIN TRAN;
        UPDATE l SET laboratorio_id = @laboratorio_id, updated_at = SYSUTCDATETIME()
        FROM dbo.laboratorista l JOIN dbo.usuario u ON u.persona_id = l.persona_id WHERE u.usuario_id = @usuario_id;
        DECLARE @det NVARCHAR(60) = CONCAT(N'{"laboratorio_id":', @laboratorio_id, N'}');
        EXEC dbo.sp_auditar @usuario_id = @admin_id, @rol_actuante = 'ADMIN', @accion = 'ASIGNAR_SUCURSAL',
             @entidad = 'usuario', @entidad_id = @usuario_id, @detalle = @det;
    COMMIT;
END;
GO
