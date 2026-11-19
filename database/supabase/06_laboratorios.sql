-- =====================================================================
-- Supabase: laboratorios (ver database/azure-sql/12_laboratorios.sql).
-- Ejecutar ANTES que el script de Azure SQL.
-- =====================================================================
SET search_path TO lab;

CREATE TABLE IF NOT EXISTS laboratorio (
    laboratorio_id  integer PRIMARY KEY,
    nombre          varchar(150) NOT NULL UNIQUE,
    direccion       varchar(250),
    telefono        varchar(20),
    email           varchar(150),
    propio          boolean      NOT NULL,
    activo          boolean      NOT NULL,
    updated_at      timestamp    NOT NULL
);
ALTER TABLE solicitud_examen ADD COLUMN IF NOT EXISTS laboratorio_id integer REFERENCES laboratorio DEFERRABLE INITIALLY DEFERRED;

GRANT SELECT, INSERT, UPDATE, DELETE ON laboratorio TO lab_sync;
GRANT SELECT ON laboratorio TO lab_lectura;
ALTER TABLE laboratorio ENABLE ROW LEVEL SECURITY;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'lab' AND tablename = 'laboratorio' AND policyname = 'sync_total') THEN
        CREATE POLICY sync_total ON lab.laboratorio FOR ALL TO lab_sync USING (true) WITH CHECK (true);
        CREATE POLICY api_lectura ON lab.laboratorio FOR SELECT TO lab_lectura USING (true);
    END IF;
END $$;
