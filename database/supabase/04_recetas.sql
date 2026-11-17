-- =====================================================================
-- Supabase: réplica de medicamentos y recetas
-- (ver database/azure-sql/08_recetas.sql). Ejecutar después de
-- 03_base_conocimiento.sql y ANTES de cargar los datos en Azure SQL.
-- =====================================================================
SET search_path TO lab;

CREATE TABLE IF NOT EXISTS medicamento (
    medicamento_id  integer PRIMARY KEY,
    nombre          varchar(120)  NOT NULL,
    presentacion    varchar(120)  NOT NULL,
    via             varchar(30)   NOT NULL,
    dosis           varchar(60)   NOT NULL,
    frecuencia      varchar(60)   NOT NULL,
    duracion_dias   smallint,
    indicaciones    varchar(1000) NOT NULL,
    advertencias    varchar(500),
    activo          boolean       NOT NULL,
    updated_at      timestamp     NOT NULL,
    UNIQUE (nombre, presentacion)
);

CREATE TABLE IF NOT EXISTS diagnostico_medicamento (
    diagnostico_medicamento_id integer PRIMARY KEY,
    diagnostico_id  integer      NOT NULL REFERENCES diagnostico DEFERRABLE INITIALLY DEFERRED,
    medicamento_id  integer      NOT NULL REFERENCES medicamento DEFERRABLE INITIALLY DEFERRED,
    nota            varchar(200),
    updated_at      timestamp    NOT NULL
);

CREATE TABLE IF NOT EXISTS receta (
    receta_id               bigint PRIMARY KEY,
    solicitud_id            bigint        NOT NULL REFERENCES solicitud_examen DEFERRABLE INITIALLY DEFERRED,
    paciente_id             bigint        NOT NULL REFERENCES paciente DEFERRABLE INITIALLY DEFERRED,
    medico_id               bigint        NOT NULL REFERENCES medico DEFERRABLE INITIALLY DEFERRED,
    diagnostico             varchar(500),
    indicaciones_generales  varchar(2000),
    created_at              timestamp     NOT NULL,
    updated_at              timestamp     NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_receta_solicitud ON receta (solicitud_id);

CREATE TABLE IF NOT EXISTS receta_item (
    receta_item_id  bigint PRIMARY KEY,
    receta_id       bigint        NOT NULL REFERENCES receta DEFERRABLE INITIALLY DEFERRED,
    orden           smallint      NOT NULL,
    medicamento_id  integer       REFERENCES medicamento DEFERRABLE INITIALLY DEFERRED,
    nombre          varchar(120)  NOT NULL,
    presentacion    varchar(120),
    via             varchar(30),
    dosis           varchar(60)   NOT NULL,
    frecuencia      varchar(60)   NOT NULL,
    duracion_dias   smallint,
    cantidad        varchar(40),
    indicaciones    varchar(1000),
    modificado      boolean       NOT NULL,
    updated_at      timestamp     NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_ritem_receta ON receta_item (receta_id);

-- Mismo esquema de seguridad que el resto de la réplica (ver 02_roles.sql).
GRANT SELECT, INSERT, UPDATE, DELETE ON medicamento, diagnostico_medicamento, receta, receta_item TO lab_sync;
GRANT SELECT ON medicamento, diagnostico_medicamento, receta, receta_item TO lab_lectura;
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['medicamento', 'diagnostico_medicamento', 'receta', 'receta_item'] LOOP
        EXECUTE format('ALTER TABLE lab.%I ENABLE ROW LEVEL SECURITY', t);
        IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'lab' AND tablename = t AND policyname = 'sync_total') THEN
            EXECUTE format('CREATE POLICY sync_total ON lab.%I FOR ALL TO lab_sync USING (true) WITH CHECK (true)', t);
            EXECUTE format('CREATE POLICY api_lectura ON lab.%I FOR SELECT TO lab_lectura USING (true)', t);
        END IF;
    END LOOP;
END $$;
