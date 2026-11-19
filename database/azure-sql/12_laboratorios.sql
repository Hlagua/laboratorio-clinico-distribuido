/* =====================================================================
   12_laboratorios.sql  -  Varios laboratorios y reprogramación de citas
   ---------------------------------------------------------------------
   Revisión del equipo (19-11):
   - Pueden existir varios laboratorios; el administrador los crea. Uno es
     el propio. El paciente (o el médico) puede elegir hacerse los exámenes
     en otro laboratorio: esos no se cobran aquí y sus resultados se suben
     en PDF (se guarda en MongoDB, la parte documental) y se transcriben.
   - El paciente puede reprogramar su cita a otro horario disponible.
   Ejecutar después de 11_receta_simple.sql y DESPUÉS de
   06_laboratorios.sql en Supabase.
   ===================================================================== */

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF OBJECT_ID('dbo.laboratorio') IS NULL
CREATE TABLE dbo.laboratorio (
    laboratorio_id  INT IDENTITY(1,1) NOT NULL,
    nombre          NVARCHAR(150)  NOT NULL,
    direccion       NVARCHAR(250)  NULL,
    telefono        VARCHAR(20)    NULL,
    email           VARCHAR(150)   NULL,
    propio          BIT            NOT NULL CONSTRAINT df_laboratorio_propio DEFAULT 0,
    activo          BIT            NOT NULL CONSTRAINT df_laboratorio_activo DEFAULT 1,
    updated_at      DATETIME2(3)   NOT NULL CONSTRAINT df_laboratorio_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_laboratorio PRIMARY KEY (laboratorio_id),
    CONSTRAINT uq_laboratorio_nombre UNIQUE (nombre)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID('dbo.laboratorio'))
    ALTER TABLE dbo.laboratorio ENABLE CHANGE_TRACKING;
GO
IF COL_LENGTH('dbo.solicitud_examen', 'laboratorio_id') IS NULL
    ALTER TABLE dbo.solicitud_examen ADD laboratorio_id INT NULL
        CONSTRAINT fk_sol_laboratorio FOREIGN KEY REFERENCES dbo.laboratorio(laboratorio_id);
GO
IF NOT EXISTS (SELECT 1 FROM dbo.laboratorio WHERE propio = 1)
    INSERT INTO dbo.laboratorio (nombre, direccion, telefono, propio)
    VALUES (N'Laboratorio Clínico UTA', N'Av. Los Chasquis y Río Payamino, Ambato', '032000000', 1);
IF NOT EXISTS (SELECT 1 FROM dbo.laboratorio WHERE nombre = N'Laboratorio Externo Ambato (ejemplo)')
    INSERT INTO dbo.laboratorio (nombre, direccion, telefono) VALUES (N'Laboratorio Externo Ambato (ejemplo)', N'Ambato', '032111111');
GO
IF USER_ID('app_api') IS NOT NULL
    GRANT INSERT, UPDATE ON dbo.laboratorio TO app_api;
GO

CREATE OR ALTER PROCEDURE dbo.sp_registrar_resultado
    @detalle_id        BIGINT,
    @laboratorista_id  BIGINT,
    @valores           NVARCHAR(MAX),
    @observaciones     NVARCHAR(1000) = NULL,
    @usuario_id        BIGINT = NULL,
    @instancia_api     VARCHAR(30) = NULL,
    @resultado_id      BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @tipo_examen_id INT, @solicitud_id BIGINT, @estado_det VARCHAR(20), @estado_sol VARCHAR(20);

    IF ISJSON(@valores) = 0 THROW 50050, 'Los valores no son un JSON válido.', 1;

    BEGIN TRY
    BEGIN TRAN;
        SELECT @tipo_examen_id = d.tipo_examen_id, @solicitud_id = d.solicitud_id, @estado_det = d.estado, @estado_sol = s.estado
        FROM dbo.solicitud_detalle d WITH (UPDLOCK, HOLDLOCK)
        JOIN dbo.solicitud_examen s ON s.solicitud_id = d.solicitud_id
        WHERE d.detalle_id = @detalle_id;

        IF @tipo_examen_id IS NULL THROW 50051, 'El examen solicitado no existe.', 1;
        -- Exámenes hechos en un laboratorio externo: no se pagan aquí; sus resultados se transcriben del PDF.
        IF @estado_sol NOT IN ('PAGADA', 'EN_PROCESO')
           AND NOT (@estado_sol = 'REGISTRADA' AND EXISTS (
                SELECT 1 FROM dbo.solicitud_examen s JOIN dbo.laboratorio l ON l.laboratorio_id = s.laboratorio_id
                WHERE s.solicitud_id = @solicitud_id AND l.propio = 0))
            THROW 50052, 'La solicitud no está pagada.', 1;
        IF @estado_det IN ('RESULTADO_LISTO', 'ANULADO') THROW 50053, 'El examen ya tiene resultado o está anulado.', 1;

        -- Conflicto de interés: un laboratorista que también es paciente
        -- no puede registrar sus propios resultados.
        IF EXISTS (SELECT 1
                   FROM dbo.solicitud_examen s
                   JOIN dbo.paciente pa ON pa.paciente_id = s.paciente_id
                   JOIN dbo.laboratorista l ON l.persona_id = pa.persona_id
                   WHERE s.solicitud_id = @solicitud_id AND l.laboratorista_id = @laboratorista_id)
            THROW 50055, 'Un laboratorista no puede registrar sus propios resultados.', 1;

        DECLARE @v TABLE (parametro_id INT PRIMARY KEY, valor DECIMAL(12,3) NULL, texto NVARCHAR(200) NULL);
        INSERT INTO @v (parametro_id, valor, texto)
        SELECT parametro_id, valor, texto
        FROM OPENJSON(@valores) WITH (parametro_id INT, valor DECIMAL(12,3), texto NVARCHAR(200));

        IF EXISTS (SELECT 1 FROM @v v LEFT JOIN dbo.parametro_examen p
                     ON p.parametro_id = v.parametro_id AND p.tipo_examen_id = @tipo_examen_id
                   WHERE p.parametro_id IS NULL)
            THROW 50054, 'Hay parámetros que no pertenecen a este examen.', 1;

        INSERT INTO dbo.resultado (detalle_id, laboratorista_id, observaciones, validado, validado_at)
        VALUES (@detalle_id, @laboratorista_id, @observaciones, 1, SYSUTCDATETIME());
        SET @resultado_id = SCOPE_IDENTITY();

        INSERT INTO dbo.resultado_valor (resultado_id, parametro_id, valor_numerico, valor_texto,
                                         unidad, valor_ref_min, valor_ref_max, valor_ref_texto, fuera_rango)
        SELECT @resultado_id, v.parametro_id, v.valor, v.texto,
               p.unidad, p.valor_ref_min, p.valor_ref_max, p.valor_ref_texto,
               CASE WHEN v.valor IS NOT NULL AND (v.valor < p.valor_ref_min OR v.valor > p.valor_ref_max) THEN 1 ELSE 0 END
        FROM @v v JOIN dbo.parametro_examen p ON p.parametro_id = v.parametro_id;

        UPDATE dbo.solicitud_detalle
        SET estado = 'RESULTADO_LISTO', laboratorista_id = @laboratorista_id,
            muestra_tomada_at = ISNULL(muestra_tomada_at, SYSUTCDATETIME()), updated_at = SYSUTCDATETIME()
        WHERE detalle_id = @detalle_id;

        IF NOT EXISTS (SELECT 1 FROM dbo.solicitud_detalle
                       WHERE solicitud_id = @solicitud_id AND estado NOT IN ('RESULTADO_LISTO', 'ANULADO'))
        BEGIN
            UPDATE dbo.solicitud_examen SET estado = 'COMPLETADA', updated_at = SYSUTCDATETIME()
            WHERE solicitud_id = @solicitud_id;

            INSERT INTO dbo.notificacion (persona_id, tipo, destinatario, asunto, cuerpo)
            SELECT pe.persona_id, 'RESULTADO_LISTO', pe.email,
                   CONCAT(N'Resultados disponibles - ', s.codigo),
                   CONCAT(N'Sus resultados de la solicitud ', s.codigo, N' ya están disponibles en el portal.')
            FROM dbo.solicitud_examen s
            JOIN dbo.paciente pa ON pa.paciente_id = s.paciente_id
            JOIN dbo.persona pe ON pe.persona_id = pa.persona_id
            WHERE s.solicitud_id = @solicitud_id AND pe.email IS NOT NULL;
        END
        ELSE
            UPDATE dbo.solicitud_examen SET estado = 'EN_PROCESO', updated_at = SYSUTCDATETIME()
            WHERE solicitud_id = @solicitud_id AND estado = 'PAGADA';

        DECLARE @det NVARCHAR(200) = CONCAT(N'{"detalle_id":', @detalle_id, N',"solicitud_id":', @solicitud_id, N'}');
        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @accion = 'REGISTRAR_RESULTADO', @entidad = 'resultado',
             @entidad_id = @resultado_id, @detalle = @det, @instancia_api = @instancia_api;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* El paciente o el personal elige en qué laboratorio se hacen los exámenes.
   Solo antes de pagar. Si es externo y tenía un turno de toma de muestras
   pendiente de pago, ese turno se cancela (el cupo queda libre). */
CREATE OR ALTER PROCEDURE dbo.sp_cambiar_laboratorio
    @solicitud_id    BIGINT,
    @laboratorio_id  INT,
    @usuario_id      BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @estado VARCHAR(20), @tipo VARCHAR(10), @cita_id BIGINT, @propio BIT;
    BEGIN TRY
    BEGIN TRAN;
        SELECT @estado = estado, @tipo = tipo, @cita_id = cita_id
        FROM dbo.solicitud_examen WITH (UPDLOCK, HOLDLOCK) WHERE solicitud_id = @solicitud_id;
        IF @estado IS NULL THROW 50110, 'La solicitud no existe.', 1;
        IF @tipo <> 'EXAMENES' THROW 50111, 'Solo los exámenes se pueden hacer en otro laboratorio.', 1;
        IF @estado <> 'REGISTRADA' THROW 50112, 'Solo se cambia de laboratorio antes de pagar.', 1;
        IF EXISTS (SELECT 1 FROM dbo.pago WHERE solicitud_id = @solicitud_id AND estado IN ('PENDIENTE', 'APROBADO'))
            THROW 50113, 'Hay un pago en curso para esta solicitud.', 1;
        SELECT @propio = propio FROM dbo.laboratorio WHERE laboratorio_id = @laboratorio_id AND activo = 1;
        IF @propio IS NULL THROW 50114, 'El laboratorio no existe o está inactivo.', 1;

        UPDATE dbo.solicitud_examen SET laboratorio_id = @laboratorio_id, updated_at = SYSUTCDATETIME()
        WHERE solicitud_id = @solicitud_id;

        IF @propio = 0 AND @cita_id IS NOT NULL
           AND EXISTS (SELECT 1 FROM dbo.cita WHERE cita_id = @cita_id AND tipo = 'MUESTRA' AND estado = 'PENDIENTE_PAGO')
        BEGIN
            UPDATE dbo.solicitud_examen SET cita_id = NULL WHERE solicitud_id = @solicitud_id;
            EXEC dbo.sp_cancelar_cita @cita_id = @cita_id, @usuario_id = @usuario_id;
        END;

        DECLARE @det NVARCHAR(100) = CONCAT(N'{"laboratorio_id":', @laboratorio_id, N'}');
        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @accion = 'CAMBIAR_LABORATORIO', @entidad = 'solicitud_examen',
             @entidad_id = @solicitud_id, @detalle = @det;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* Reprograma una cita a otra franja del mismo tipo (y del mismo médico si es
   consulta). Conserva su estado y su pago: solo cambia el horario. */
CREATE OR ALTER PROCEDURE dbo.sp_reprogramar_cita
    @cita_id      BIGINT,
    @franja_id    BIGINT,
    @usuario_id   BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @estado VARCHAR(20), @tipo VARCHAR(10), @medico BIGINT, @anterior BIGINT, @paciente BIGINT;
    DECLARE @cap TINYINT, @ocu TINYINT, @activa BIT, @fecha DATE, @hora TIME(0), @medico_franja BIGINT;
    BEGIN TRY
    BEGIN TRAN;
        SELECT @estado = estado, @tipo = tipo, @medico = medico_id, @anterior = franja_id, @paciente = paciente_id
        FROM dbo.cita WITH (UPDLOCK, HOLDLOCK) WHERE cita_id = @cita_id;
        IF @estado IS NULL THROW 50013, 'La cita no existe.', 1;
        IF @estado NOT IN ('PENDIENTE_PAGO', 'CONFIRMADA') THROW 50115, 'Solo se reprograma una cita pendiente o confirmada.', 1;
        IF @franja_id = @anterior THROW 50116, 'Elija un horario distinto al actual.', 1;

        SELECT @cap = capacidad, @ocu = ocupados, @activa = activa, @fecha = fecha, @hora = hora_inicio, @medico_franja = medico_id
        FROM dbo.franja_horaria WITH (UPDLOCK, HOLDLOCK, ROWLOCK) WHERE franja_id = @franja_id;
        IF @cap IS NULL THROW 50010, 'La franja no existe.', 1;
        IF @activa = 0 OR DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @hora), CAST(@fecha AS DATETIME2(0))) < DATEADD(HOUR, -5, SYSUTCDATETIME())
            THROW 50011, 'La franja no está disponible.', 1;
        IF @ocu >= @cap THROW 50012, 'La franja ya no tiene cupos disponibles.', 1;
        IF (@tipo = 'CONSULTA' AND (@medico_franja IS NULL OR @medico_franja <> @medico))
           OR (@tipo = 'MUESTRA' AND @medico_franja IS NOT NULL)
            THROW 50117, 'El nuevo horario debe ser del mismo tipo (y del mismo médico).', 1;
        IF EXISTS (SELECT 1 FROM dbo.cita WHERE paciente_id = @paciente AND franja_id = @franja_id AND estado <> 'CANCELADA')
            THROW 50118, 'Ya tiene una cita en ese horario.', 1;

        UPDATE dbo.franja_horaria SET ocupados = ocupados - 1, updated_at = SYSUTCDATETIME() WHERE franja_id = @anterior AND ocupados > 0;
        UPDATE dbo.franja_horaria SET ocupados = ocupados + 1, updated_at = SYSUTCDATETIME() WHERE franja_id = @franja_id;
        UPDATE dbo.cita SET franja_id = @franja_id, updated_at = SYSUTCDATETIME() WHERE cita_id = @cita_id;

        DECLARE @det NVARCHAR(100) = CONCAT(N'{"de":', @anterior, N',"a":', @franja_id, N'}');
        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @accion = 'REPROGRAMAR_CITA', @entidad = 'cita',
             @entidad_id = @cita_id, @detalle = @det;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO
