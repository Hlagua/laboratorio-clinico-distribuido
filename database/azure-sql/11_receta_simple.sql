/* =====================================================================
   11_receta_simple.sql  -  Receta: nombre a la izquierda, indicaciones a la derecha
   ---------------------------------------------------------------------
   Revisión del equipo (18-11): la dosis, la frecuencia y la duración se
   escriben en las indicaciones de cada medicamento ("cómo tomarlo"), así
   que dejan de ser obligatorias. Se guardan vacías si no se envían.
   Ejecutar después de 10_control_gratis.sql.
   ===================================================================== */

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

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
    DECLARE @paciente_id BIGINT, @estado VARCHAR(20);
    SELECT @paciente_id = paciente_id, @estado = estado FROM dbo.solicitud_examen WHERE solicitud_id = @solicitud_id;
    IF @paciente_id IS NULL THROW 50093, 'La solicitud no existe.', 1;
    IF @estado NOT IN ('EN_PROCESO', 'COMPLETADA') THROW 50094, 'La solicitud aún no tiene resultados.', 1;
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
