/* =====================================================================
   06_seguridad.sql  -  Usuarios de base de datos con mínimo privilegio.
   Ejecutar en Azure SQL (base del laboratorio) como administrador.
   Las contraseñas reales NO se guardan aquí: reemplazar <...> al
   ejecutar y guardarlas en el .env de cada VM (nunca en el código).
   ===================================================================== */

-- Usuario de las APIs Flask: solo ejecuta procedimientos y lee tablas.
CREATE USER app_api WITH PASSWORD = '<CONTRASEÑA_API>';
ALTER ROLE db_datareader ADD MEMBER app_api;
GRANT EXECUTE ON SCHEMA::dbo TO app_api;
-- Escrituras directas puntuales que no pasan por procedimientos.
GRANT INSERT, UPDATE ON dbo.stripe_evento TO app_api;
GRANT INSERT, UPDATE ON dbo.notificacion TO app_api;     -- bandeja de salida de correos
GRANT UPDATE ON dbo.solicitud_detalle TO app_api;        -- registro de toma de muestra
GRANT UPDATE ON dbo.tratamiento TO app_api;              -- cambio de estado del tratamiento
GRANT UPDATE ON dbo.usuario TO app_api;            -- último login, intentos fallidos
GRANT INSERT, UPDATE ON dbo.franja_horaria TO app_api;
GO

-- Usuario del sincronizador: lectura + Change Tracking.
CREATE USER app_sync WITH PASSWORD = '<CONTRASEÑA_SYNC>';
ALTER ROLE db_datareader ADD MEMBER app_sync;
GRANT VIEW CHANGE TRACKING ON SCHEMA::dbo TO app_sync;
GRANT EXECUTE ON dbo.sp_expirar_citas_pendientes TO app_sync;
GO

/* Firewall del servidor Azure SQL (portal o CLI): permitir SOLO las IP
   públicas de VM1 y VM2 (y temporalmente la IP del equipo de desarrollo).
   Desactivar "Allow Azure services and resources to access this server". */
