-- =====================================================================
-- Supabase: réplica de la base de conocimientos para diagnósticos
-- (ver database/azure-sql/07_base_conocimiento.sql). Ejecutar después de
-- 01_esquema_replica.sql y 02_roles.sql.
-- =====================================================================
SET search_path TO lab;

CREATE TABLE diagnostico (
    diagnostico_id  integer PRIMARY KEY,
    codigo_cie10    varchar(10)  NOT NULL UNIQUE,
    nombre          varchar(150) NOT NULL,
    descripcion     varchar(500),
    updated_at      timestamp    NOT NULL
);

CREATE TABLE protocolo (
    protocolo_id    integer PRIMARY KEY,
    diagnostico_id  integer       NOT NULL UNIQUE REFERENCES diagnostico DEFERRABLE INITIALLY DEFERRED,
    indicaciones    varchar(2000) NOT NULL,
    duracion_dias   smallint,
    updated_at      timestamp     NOT NULL
);

CREATE TABLE regla_diagnostica (
    regla_id        integer PRIMARY KEY,
    codigo          varchar(30)  NOT NULL UNIQUE,
    diagnostico_id  integer      NOT NULL REFERENCES diagnostico DEFERRABLE INITIALLY DEFERRED,
    logica          varchar(10)  NOT NULL,
    sexo            char(1),
    edad_min        smallint,
    edad_max        smallint,
    confianza       varchar(10)  NOT NULL,
    recomendacion   varchar(500) NOT NULL,
    fuente          varchar(200),
    guia_clave      varchar(50),
    activa          boolean      NOT NULL,
    updated_at      timestamp    NOT NULL
);

CREATE TABLE regla_condicion (
    condicion_id  integer PRIMARY KEY,
    regla_id      integer       NOT NULL REFERENCES regla_diagnostica DEFERRABLE INITIALLY DEFERRED,
    parametro_id  integer       NOT NULL REFERENCES parametro_examen DEFERRABLE INITIALLY DEFERRED,
    operador      varchar(6)    NOT NULL,
    valor         numeric(12,3) NOT NULL,
    valor2        numeric(12,3),
    updated_at    timestamp     NOT NULL
);

CREATE TABLE sugerencia_diagnostica (
    sugerencia_id   bigint PRIMARY KEY,
    solicitud_id    bigint        NOT NULL REFERENCES solicitud_examen DEFERRABLE INITIALLY DEFERRED,
    paciente_id     bigint        NOT NULL REFERENCES paciente DEFERRABLE INITIALLY DEFERRED,
    regla_id        integer       NOT NULL REFERENCES regla_diagnostica DEFERRABLE INITIALLY DEFERRED,
    diagnostico_id  integer       NOT NULL REFERENCES diagnostico DEFERRABLE INITIALLY DEFERRED,
    explicacion     varchar(1000) NOT NULL,
    confianza       varchar(10)   NOT NULL,
    estado          varchar(12)   NOT NULL,
    motivo          varchar(300),
    medico_id       bigint        REFERENCES medico DEFERRABLE INITIALLY DEFERRED,
    tratamiento_id  bigint        REFERENCES tratamiento DEFERRABLE INITIALLY DEFERRED,
    respondida_at   timestamp,
    created_at      timestamp     NOT NULL,
    updated_at      timestamp     NOT NULL
);
CREATE INDEX ix_sug_solicitud ON sugerencia_diagnostica (solicitud_id);

-- Mismo esquema de seguridad que el resto de la réplica (ver 02_roles.sql).
GRANT SELECT, INSERT, UPDATE, DELETE ON diagnostico, protocolo, regla_diagnostica, regla_condicion, sugerencia_diagnostica TO lab_sync;
GRANT SELECT ON diagnostico, protocolo, regla_diagnostica, regla_condicion, sugerencia_diagnostica TO lab_lectura;
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['diagnostico', 'protocolo', 'regla_diagnostica', 'regla_condicion', 'sugerencia_diagnostica'] LOOP
        EXECUTE format('ALTER TABLE lab.%I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('CREATE POLICY sync_total ON lab.%I FOR ALL TO lab_sync USING (true) WITH CHECK (true)', t);
        EXECUTE format('CREATE POLICY api_lectura ON lab.%I FOR SELECT TO lab_lectura USING (true)', t);
    END LOOP;
END $$;
