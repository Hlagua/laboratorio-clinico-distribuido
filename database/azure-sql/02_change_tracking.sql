/* =====================================================================
   02_change_tracking.sql
   Habilita Change Tracking (CT) para la replicación incremental hacia
   Supabase y MongoDB Atlas.

   Por qué CT y no CDC / triggers:
   - Disponible en TODOS los niveles de Azure SQL Database (CDC exige
     S3+ o vCore).
   - Registra INSERT / UPDATE / DELETE con una versión global creciente.
   - El sincronizador guarda la última versión aplicada en cada destino;
     si se apaga, al volver pide "cambios desde la versión X" y se pone
     al día solo (incluidos los borrados), siempre que no hayan pasado
     más días que CHANGE_RETENTION. Si pasaron, hace carga completa.
   - Alternativa evaluada: triggers + tabla outbox. Da orden causal
     exacto pero exige mantener un trigger por tabla; CT no toca el
     código de la aplicación.
   ===================================================================== */

-- El sincronizador lee la versión actual y todas las tablas dentro de
-- UNA transacción SNAPSHOT, para obtener una foto consistente aunque
-- haya escrituras concurrentes (en Azure SQL ya viene activado).
ALTER DATABASE CURRENT SET ALLOW_SNAPSHOT_ISOLATION ON;
GO

-- 14 días de retención: el sincronizador puede estar apagado hasta dos
-- semanas y aún ponerse al día de forma incremental.
ALTER DATABASE CURRENT
    SET CHANGE_TRACKING = ON (CHANGE_RETENTION = 14 DAYS, AUTO_CLEANUP = ON);
GO

-- Tablas replicadas. TRACK_COLUMNS_UPDATED no se usa: siempre se
-- reenvía la fila completa (upsert), más simple e idempotente.
ALTER TABLE dbo.persona            ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.usuario            ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.rol                ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.permiso            ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.rol_permiso        ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.usuario_rol        ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.paciente           ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.medico             ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.laboratorista      ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.categoria_examen   ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.tipo_examen        ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.parametro_examen   ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.franja_horaria     ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.cita               ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.solicitud_examen   ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.solicitud_detalle  ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.resultado          ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.resultado_valor    ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.observacion_medica ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.tratamiento        ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.pago               ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.reembolso          ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.notificacion       ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.auditoria          ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.stripe_evento      ENABLE CHANGE_TRACKING;
GO

/* Consulta de verificación:
SELECT t.name AS tabla, ct.min_valid_version, CHANGE_TRACKING_CURRENT_VERSION() AS version_actual
FROM sys.change_tracking_tables ct JOIN sys.tables t ON t.object_id = ct.object_id
ORDER BY t.name;
*/
