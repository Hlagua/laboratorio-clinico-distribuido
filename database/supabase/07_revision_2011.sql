-- =====================================================================
-- Supabase: revisión del 20-11 (ver database/azure-sql/13_revision_2011.sql).
-- Sucursales con ubicación, sucursal del laboratorista y de cada turno,
-- nota de la consulta, descuentos y titular de la tarjeta.
-- Ejecutar ANTES que el script de Azure SQL.
-- =====================================================================
SET search_path TO lab;

ALTER TABLE laboratorio      ADD COLUMN IF NOT EXISTS latitud  numeric(9,6);
ALTER TABLE laboratorio      ADD COLUMN IF NOT EXISTS longitud numeric(9,6);
ALTER TABLE laboratorista    ADD COLUMN IF NOT EXISTS laboratorio_id integer REFERENCES laboratorio DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE franja_horaria   ADD COLUMN IF NOT EXISTS laboratorio_id integer REFERENCES laboratorio DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE cita             ADD COLUMN IF NOT EXISTS cita_origen_id bigint REFERENCES cita DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE solicitud_examen ADD COLUMN IF NOT EXISTS consulta_cita_id bigint REFERENCES cita DEFERRABLE INITIALLY DEFERRED;
ALTER TABLE pago             ADD COLUMN IF NOT EXISTS titular_tarjeta varchar(100);

CREATE TABLE IF NOT EXISTS consulta_nota (
    cita_id        bigint PRIMARY KEY REFERENCES cita DEFERRABLE INITIALLY DEFERRED,
    medico_id      bigint        NOT NULL REFERENCES medico DEFERRABLE INITIALLY DEFERRED,
    motivo         varchar(500),
    sintomas       varchar(2000),
    examen_fisico  varchar(2000),
    diagnostico    varchar(500),
    created_at     timestamp     NOT NULL,
    updated_at     timestamp     NOT NULL
);

CREATE TABLE IF NOT EXISTS descuento (
    descuento_id    integer PRIMARY KEY,
    nombre          varchar(120)  NOT NULL,
    porcentaje      numeric(5,2)  NOT NULL,
    laboratorio_id  integer REFERENCES laboratorio DEFERRABLE INITIALLY DEFERRED,
    tipo_examen_id  integer REFERENCES tipo_examen DEFERRABLE INITIALLY DEFERRED,
    desde           date          NOT NULL,
    hasta           date          NOT NULL,
    activo          boolean       NOT NULL,
    updated_at      timestamp     NOT NULL
);
ALTER TABLE solicitud_detalle ADD COLUMN IF NOT EXISTS precio_lista numeric(10,2);
ALTER TABLE solicitud_detalle ADD COLUMN IF NOT EXISTS descuento_id integer REFERENCES descuento DEFERRABLE INITIALLY DEFERRED;

GRANT SELECT, INSERT, UPDATE, DELETE ON consulta_nota, descuento TO lab_sync;
GRANT SELECT ON consulta_nota, descuento TO lab_lectura;
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['consulta_nota', 'descuento'] LOOP
        EXECUTE format('ALTER TABLE lab.%I ENABLE ROW LEVEL SECURITY', t);
        IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'lab' AND tablename = t AND policyname = 'sync_total') THEN
            EXECUTE format('CREATE POLICY sync_total ON lab.%I FOR ALL TO lab_sync USING (true) WITH CHECK (true)', t);
            EXECUTE format('CREATE POLICY api_lectura ON lab.%I FOR SELECT TO lab_lectura USING (true)', t);
        END IF;
    END LOOP;
END $$;
