/* =====================================================================
   09_consultas.sql  -  Consulta médica y cobro en ventanilla
   ---------------------------------------------------------------------
   Flujo nuevo (observación del equipo, 18-11):
   1. El paciente reserva una CONSULTA con un médico (sin elegir exámenes)
      y la paga por la pasarela (Stripe). La consulta se cobra como una
      solicitud de tipo CONSULTA con una sola línea: "Consulta médica".
   2. El médico atiende, ordena los exámenes y agenda la cita de CONTROL
      (origen MEDICO: el paciente la paga hasta 2 horas antes).
   3. Los resultados le llegan al médico; el paciente solo asiste al control.
   Además:
   - franja_horaria.medico_id: NULL = turnos del laboratorio (toma de
     muestras); con valor = agenda de ese médico.
   - pago.factura_*: datos de facturación que toma el laboratorista en
     ventanilla; el cobro igual pasa por Stripe (QR o en la pantalla).
   - La cita pasa a ATENDIDA al tomar la muestra o al cerrar la consulta.
   Ejecutar después de 08_recetas.sql y DESPUÉS de 05_consultas.sql en
   Supabase (las columnas nuevas deben existir antes en la réplica).
   ===================================================================== */

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ---------------------------------------------------------------------
   1. COLUMNAS NUEVAS
   ------------------------------------------------------------------- */
IF COL_LENGTH('dbo.franja_horaria', 'medico_id') IS NULL
    ALTER TABLE dbo.franja_horaria ADD medico_id BIGINT NULL
        CONSTRAINT fk_franja_medico FOREIGN KEY REFERENCES dbo.medico(medico_id);
GO
-- Antes una sola franja por fecha y hora; ahora una por fecha, hora y médico (NULL = laboratorio).
IF EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'uq_franja')
    ALTER TABLE dbo.franja_horaria DROP CONSTRAINT uq_franja;
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints WHERE name = 'uq_franja_medico')
    ALTER TABLE dbo.franja_horaria ADD CONSTRAINT uq_franja_medico UNIQUE (fecha, hora_inicio, medico_id);
GO

IF COL_LENGTH('dbo.cita', 'tipo') IS NULL
    ALTER TABLE dbo.cita ADD
        tipo      VARCHAR(10) NOT NULL CONSTRAINT df_cita_tipo DEFAULT 'MUESTRA'
                  CONSTRAINT ck_cita_tipo CHECK (tipo IN ('MUESTRA', 'CONSULTA')),
        medico_id BIGINT NULL CONSTRAINT fk_cita_medico FOREIGN KEY REFERENCES dbo.medico(medico_id),
        origen    VARCHAR(10) NOT NULL CONSTRAINT df_cita_origen DEFAULT 'PACIENTE'
                  CONSTRAINT ck_cita_origen CHECK (origen IN ('PACIENTE', 'MEDICO'));
GO

IF COL_LENGTH('dbo.solicitud_examen', 'tipo') IS NULL
    ALTER TABLE dbo.solicitud_examen ADD
        tipo VARCHAR(10) NOT NULL CONSTRAINT df_sol_tipo DEFAULT 'EXAMENES'
             CONSTRAINT ck_sol_tipo CHECK (tipo IN ('EXAMENES', 'CONSULTA'));
GO

IF COL_LENGTH('dbo.pago', 'factura_identificacion') IS NULL
    ALTER TABLE dbo.pago ADD
        factura_identificacion VARCHAR(13)   NULL,   -- cédula, RUC o 9999999999999 (consumidor final)
        factura_nombre         NVARCHAR(200) NULL,
        factura_direccion      NVARCHAR(250) NULL,
        factura_email          VARCHAR(150)  NULL;
GO

/* La consulta se cobra como un ítem del catálogo, inactivo para que no aparezca
   entre los exámenes que se pueden pedir. El precio se cambia aquí. */
IF NOT EXISTS (SELECT 1 FROM dbo.categoria_examen WHERE nombre = N'Consulta médica')
    INSERT INTO dbo.categoria_examen (nombre, descripcion) VALUES (N'Consulta médica', N'Atención del médico tratante');
IF NOT EXISTS (SELECT 1 FROM dbo.tipo_examen WHERE codigo = 'CONS-MED')
    INSERT INTO dbo.tipo_examen (categoria_id, codigo, nombre, descripcion, tipo_muestra, precio, activo)
    SELECT categoria_id, 'CONS-MED', N'Consulta médica', N'Consulta con el médico tratante', N'No aplica', 25.00, 0
    FROM dbo.categoria_examen WHERE nombre = N'Consulta médica';
GO

/* ---------------------------------------------------------------------
   2. PROCEDIMIENTOS
   ------------------------------------------------------------------- */
/* Reserva una consulta con el médico dueño de la franja y crea su cobro
   (solicitud CONSULTA con la línea "Consulta médica"), todo en una transacción.
   @origen = PACIENTE (la reserva el paciente, 30 min para pagar)
           = MEDICO   (cita de control que agenda el médico, se paga hasta 2 h antes) */
CREATE OR ALTER PROCEDURE dbo.sp_reservar_consulta
    @paciente_id    BIGINT,
    @franja_id      BIGINT,
    @motivo         NVARCHAR(300) = NULL,
    @origen         VARCHAR(10) = 'PACIENTE',
    @medico_agenda  BIGINT = NULL,            -- con origen MEDICO: solo en sus propias franjas
    @usuario_id     BIGINT = NULL,
    @instancia_api  VARCHAR(30) = NULL,
    @cita_id        BIGINT OUTPUT
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

        INSERT INTO dbo.cita (paciente_id, franja_id, motivo, canal, tipo, medico_id, origen)
        VALUES (@paciente_id, @franja_id, @motivo, 'PORTAL', 'CONSULTA', @medico_id, @origen);
        SET @cita_id = SCOPE_IDENTITY();

        INSERT INTO dbo.solicitud_examen (codigo, paciente_id, medico_id, cita_id, tipo, observaciones)
        VALUES (CONCAT('TMP-', LEFT(REPLACE(CAST(NEWID() AS CHAR(36)), '-', ''), 16)), @paciente_id, @medico_id, @cita_id,
                'CONSULTA', @motivo);
        SET @solicitud_id = SCOPE_IDENTITY();
        INSERT INTO dbo.solicitud_detalle (solicitud_id, tipo_examen_id, precio_unitario)
        VALUES (@solicitud_id, @tipo_consulta, @precio);
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

/* Cancelar: además libera el cupo y anula el cobro de la consulta si aún no se pagó. */
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
        WHERE cita_id = @cita_id AND tipo = 'CONSULTA' AND estado = 'REGISTRADA';

        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @accion = 'CANCELAR_CITA', @entidad = 'cita', @entidad_id = @cita_id;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* Libera cupos de citas que nunca se pagaron (lo ejecuta el sincronizador).
   - Reservadas por el paciente: @minutos después de reservar.
   - Agendadas por el médico (control): 2 horas antes de la hora de la cita. */
CREATE OR ALTER PROCEDURE dbo.sp_expirar_citas_pendientes
    @minutos   INT = 30,
    @expiradas INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @canceladas TABLE (cita_id BIGINT, franja_id BIGINT);

    BEGIN TRY
    BEGIN TRAN;
        UPDATE c
        SET estado = 'CANCELADA', cancelada_at = SYSUTCDATETIME(), updated_at = SYSUTCDATETIME()
        OUTPUT inserted.cita_id, inserted.franja_id INTO @canceladas
        FROM dbo.cita c WITH (UPDLOCK, READPAST)
        JOIN dbo.franja_horaria f ON f.franja_id = c.franja_id
        WHERE c.estado = 'PENDIENTE_PAGO'
          AND ((c.origen = 'PACIENTE' AND c.created_at < DATEADD(MINUTE, -@minutos, SYSUTCDATETIME()))
               OR (c.origen = 'MEDICO'
                   -- hora de la cita en UTC (Ecuador es UTC-5) menos 2 horas
                   AND DATEADD(HOUR, 3, DATEADD(MINUTE, DATEDIFF(MINUTE, 0, f.hora_inicio), CAST(f.fecha AS DATETIME2(0))))
                       < SYSUTCDATETIME()))
          AND NOT EXISTS (SELECT 1 FROM dbo.solicitud_examen s JOIN dbo.pago p ON p.solicitud_id = s.solicitud_id
                          WHERE s.cita_id = c.cita_id AND p.estado = 'PENDIENTE' AND p.expira_at > SYSUTCDATETIME());

        UPDATE f
        SET ocupados = f.ocupados - x.n, updated_at = SYSUTCDATETIME()
        FROM dbo.franja_horaria f
        JOIN (SELECT franja_id, COUNT(*) AS n FROM @canceladas GROUP BY franja_id) x ON x.franja_id = f.franja_id;

        UPDATE s SET estado = 'ANULADA', updated_at = SYSUTCDATETIME()
        FROM dbo.solicitud_examen s JOIN @canceladas x ON x.cita_id = s.cita_id
        WHERE s.tipo = 'CONSULTA' AND s.estado = 'REGISTRADA';

        SET @expiradas = (SELECT COUNT(*) FROM @canceladas);
        IF @expiradas > 0
        BEGIN
            DECLARE @det NVARCHAR(100) = CONCAT(N'{"citas_expiradas":', @expiradas, N'}');
            EXEC dbo.sp_auditar @accion = 'EXPIRAR_CITAS', @entidad = 'cita', @detalle = @det;
        END;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* Marca la cita como ATENDIDA (idempotente). En una consulta solo puede
   cerrarla su médico, y el cobro de la consulta queda COMPLETADO. */
CREATE OR ALTER PROCEDURE dbo.sp_atender_cita
    @cita_id     BIGINT,
    @medico_id   BIGINT = NULL,
    @usuario_id  BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @estado VARCHAR(20), @tipo VARCHAR(10), @medico_cita BIGINT;
    BEGIN TRY
    BEGIN TRAN;
        SELECT @estado = estado, @tipo = tipo, @medico_cita = medico_id
        FROM dbo.cita WITH (UPDLOCK, HOLDLOCK) WHERE cita_id = @cita_id;
        IF @estado IS NULL THROW 50013, 'La cita no existe.', 1;
        IF @tipo = 'CONSULTA' AND (@medico_id IS NULL OR @medico_id <> @medico_cita)
            THROW 50105, 'Solo el médico de la consulta puede cerrarla.', 1;
        IF @estado = 'ATENDIDA'
        BEGIN
            COMMIT;
            RETURN;
        END;
        IF @estado <> 'CONFIRMADA' THROW 50106, 'Solo se atiende una cita confirmada (pagada).', 1;

        UPDATE dbo.cita SET estado = 'ATENDIDA', updated_at = SYSUTCDATETIME() WHERE cita_id = @cita_id;
        UPDATE dbo.solicitud_examen SET estado = 'COMPLETADA', updated_at = SYSUTCDATETIME()
        WHERE cita_id = @cita_id AND tipo = 'CONSULTA' AND estado = 'PAGADA';

        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @accion = 'ATENDER_CITA', @entidad = 'cita', @entidad_id = @cita_id;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* Igual que antes, más los datos de facturación opcionales (cobro en ventanilla). */
CREATE OR ALTER PROCEDURE dbo.sp_crear_pago
    @solicitud_id                BIGINT,
    @metodo                      VARCHAR(20),
    @stripe_checkout_session_id  VARCHAR(100) = NULL,
    @referencia_transferencia    VARCHAR(50) = NULL,
    @usuario_id                  BIGINT = NULL,
    @factura_identificacion      VARCHAR(13) = NULL,
    @factura_nombre              NVARCHAR(200) = NULL,
    @factura_direccion           NVARCHAR(250) = NULL,
    @factura_email               VARCHAR(150) = NULL,
    @pago_id                     BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @total DECIMAL(10,2), @estado VARCHAR(20);

    BEGIN TRY
    BEGIN TRAN;
        SELECT @total = total, @estado = estado
        FROM dbo.solicitud_examen WITH (UPDLOCK, HOLDLOCK)
        WHERE solicitud_id = @solicitud_id;

        IF @total IS NULL THROW 50030, 'La solicitud no existe.', 1;
        IF @estado <> 'REGISTRADA' THROW 50031, 'La solicitud ya fue pagada o anulada.', 1;

        -- Un pago pendiente anterior queda expirado (se reintentó).
        UPDATE dbo.pago SET estado = 'EXPIRADO', updated_at = SYSUTCDATETIME()
        WHERE solicitud_id = @solicitud_id AND estado = 'PENDIENTE';

        INSERT INTO dbo.pago (solicitud_id, monto, metodo, stripe_checkout_session_id, referencia_transferencia, expira_at,
                              factura_identificacion, factura_nombre, factura_direccion, factura_email)
        VALUES (@solicitud_id, @total, @metodo, @stripe_checkout_session_id, @referencia_transferencia,
                DATEADD(MINUTE, 30, SYSUTCDATETIME()),
                @factura_identificacion, @factura_nombre, @factura_direccion, @factura_email);
        SET @pago_id = SCOPE_IDENTITY();

        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @accion = 'CREAR_PAGO', @entidad = 'pago', @entidad_id = @pago_id;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO
