/* =====================================================================
   10_control_gratis.sql  -  La cita de control no se cobra
   ---------------------------------------------------------------------
   Decisión del equipo (18-11): el control que agenda el médico después de
   la consulta está incluido en ella. Queda CONFIRMADO al agendarlo y no se
   crea su cobro. La consulta que reserva el paciente se sigue cobrando por
   Stripe. Ejecutar después de 09_consultas.sql.
   ===================================================================== */

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

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

        -- El control que agenda el médico está incluido en la consulta: queda confirmado y sin cobro.
        INSERT INTO dbo.cita (paciente_id, franja_id, motivo, canal, tipo, medico_id, origen, estado)
        VALUES (@paciente_id, @franja_id, @motivo, 'PORTAL', 'CONSULTA', @medico_id, @origen,
                IIF(@origen = 'MEDICO', 'CONFIRMADA', 'PENDIENTE_PAGO'));
        SET @cita_id = SCOPE_IDENTITY();

        IF @origen = 'PACIENTE'
        BEGIN

        INSERT INTO dbo.solicitud_examen (codigo, paciente_id, medico_id, cita_id, tipo, observaciones)
        VALUES (CONCAT('TMP-', LEFT(REPLACE(CAST(NEWID() AS CHAR(36)), '-', ''), 16)), @paciente_id, @medico_id, @cita_id,
                'CONSULTA', @motivo);
        SET @solicitud_id = SCOPE_IDENTITY();
        INSERT INTO dbo.solicitud_detalle (solicitud_id, tipo_examen_id, precio_unitario)
        VALUES (@solicitud_id, @tipo_consulta, @precio);
        UPDATE dbo.solicitud_examen
        SET codigo = CONCAT('SOL-', YEAR(SYSUTCDATETIME()), '-', RIGHT(CONCAT('000000', @solicitud_id), 6)), total = @precio
        WHERE solicitud_id = @solicitud_id;
        END;

        DECLARE @det NVARCHAR(300) = CONCAT(N'{"franja_id":', @franja_id, N',"medico_id":', @medico_id,
                                             N',"origen":"', @origen, N'","solicitud_id":', ISNULL(CAST(@solicitud_id AS VARCHAR(20)), 'null'), N'}');
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
