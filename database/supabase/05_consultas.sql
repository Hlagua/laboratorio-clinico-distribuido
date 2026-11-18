-- =====================================================================
-- Supabase: columnas de la consulta médica y del cobro en ventanilla
-- (ver database/azure-sql/09_consultas.sql). Ejecutar ANTES que el script
-- de Azure SQL: el sincronizador copia solo las columnas que existen aquí.
-- =====================================================================
SET search_path TO lab;

ALTER TABLE franja_horaria   ADD COLUMN IF NOT EXISTS medico_id bigint REFERENCES medico DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE cita             ADD COLUMN IF NOT EXISTS tipo      varchar(10) NOT NULL DEFAULT 'MUESTRA';
ALTER TABLE cita             ADD COLUMN IF NOT EXISTS medico_id bigint REFERENCES medico DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE cita             ADD COLUMN IF NOT EXISTS origen    varchar(10) NOT NULL DEFAULT 'PACIENTE';
ALTER TABLE solicitud_examen ADD COLUMN IF NOT EXISTS tipo      varchar(10) NOT NULL DEFAULT 'EXAMENES';
ALTER TABLE pago             ADD COLUMN IF NOT EXISTS factura_identificacion varchar(13);
ALTER TABLE pago             ADD COLUMN IF NOT EXISTS factura_nombre         varchar(200);
ALTER TABLE pago             ADD COLUMN IF NOT EXISTS factura_direccion      varchar(250);
ALTER TABLE pago             ADD COLUMN IF NOT EXISTS factura_email          varchar(150);
CREATE INDEX IF NOT EXISTS ix_cita_medico ON cita (medico_id);
