-- =====================================================================
-- Roles de conexión en Supabase (ejecutar en el SQL Editor después de
-- 01_esquema_replica.sql). Reemplazar <...> por contraseñas fuertes y
-- guardarlas SOLO en los .env de las VM.
-- =====================================================================

-- Sincronizador: escribe la réplica.
CREATE ROLE lab_sync LOGIN PASSWORD '<CONTRASEÑA_SYNC>';
GRANT USAGE ON SCHEMA lab TO lab_sync;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA lab TO lab_sync;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA lab TO lab_sync;

-- APIs Flask en contingencia: SOLO LECTURA (requisito del proyecto).
CREATE ROLE lab_lectura LOGIN PASSWORD '<CONTRASEÑA_LECTURA>';
GRANT USAGE ON SCHEMA lab TO lab_lectura;
GRANT SELECT ON ALL TABLES IN SCHEMA lab TO lab_lectura;
ALTER ROLE lab_lectura SET default_transaction_read_only = on;

-- RLS está activo en todas las tablas: solo estos dos roles tienen
-- política; anon/authenticated (Data API) no ven ninguna fila.
DO $$
DECLARE t record;
BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'lab' LOOP
        EXECUTE format('CREATE POLICY sync_total ON lab.%I FOR ALL TO lab_sync USING (true) WITH CHECK (true)', t.tablename);
        EXECUTE format('CREATE POLICY api_lectura ON lab.%I FOR SELECT TO lab_lectura USING (true)', t.tablename);
    END LOOP;
END $$;

-- Conexión desde las VM: "Session pooler" (IPv4) de Supabase con
-- sslmode=require. En el pooler el usuario va como  lab_lectura.<project-ref>
