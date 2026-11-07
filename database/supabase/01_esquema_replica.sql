-- =====================================================================
-- Supabase (PostgreSQL)  -  BASE DE CONTINGENCIA, SOLO LECTURA
-- Réplica de las tablas de Azure SQL que permiten iniciar sesión y
-- consultar citas, resultados, tratamientos y pagos cuando la base
-- principal no está disponible.
--
-- - Esquema "lab" (no "public"): la Data API REST de Supabase solo
--   expone "public", así que estas tablas no quedan publicadas en
--   Internet. Las APIs Flask se conectan directo por PostgreSQL (SSL).
-- - Las PK conservan los mismos valores de Azure SQL (sin IDENTITY).
-- - Las FK son DEFERRABLE INITIALLY DEFERRED: se validan al COMMIT del
--   lote, así el sincronizador puede aplicar cambios en cualquier orden.
-- - Ejecutar en el SQL Editor de Supabase.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS lab;
SET search_path TO lab;

-- ---------- Identidad y roles ----------
CREATE TABLE persona (
    persona_id        bigint PRIMARY KEY,
    cedula            varchar(13)  NOT NULL UNIQUE,
    nombres           varchar(100) NOT NULL,
    apellidos         varchar(100) NOT NULL,
    fecha_nacimiento  date         NOT NULL,
    sexo              char(1)      NOT NULL,
    telefono          varchar(20),
    email             varchar(150),
    direccion         varchar(250),
    created_at        timestamp    NOT NULL,
    updated_at        timestamp    NOT NULL
);

CREATE TABLE usuario (
    usuario_id         bigint PRIMARY KEY,
    persona_id         bigint       NOT NULL UNIQUE REFERENCES persona DEFERRABLE INITIALLY DEFERRED,
    email              varchar(150) NOT NULL UNIQUE,
    password_hash      varchar(255) NOT NULL,
    activo             boolean      NOT NULL,
    intentos_fallidos  smallint     NOT NULL,
    bloqueado_hasta    timestamp,
    ultimo_login       timestamp,
    created_at         timestamp    NOT NULL,
    updated_at         timestamp    NOT NULL
);

CREATE TABLE rol (
    rol_id       smallint PRIMARY KEY,
    codigo       varchar(30)  NOT NULL UNIQUE,
    nombre       varchar(60)  NOT NULL,
    descripcion  varchar(200)
);

CREATE TABLE permiso (
    permiso_id   smallint PRIMARY KEY,
    codigo       varchar(60)  NOT NULL UNIQUE,
    descripcion  varchar(200)
);

CREATE TABLE rol_permiso (
    rol_id      smallint NOT NULL REFERENCES rol DEFERRABLE INITIALLY DEFERRED,
    permiso_id  smallint NOT NULL REFERENCES permiso DEFERRABLE INITIALLY DEFERRED,
    PRIMARY KEY (rol_id, permiso_id)
);

CREATE TABLE usuario_rol (
    usuario_id   bigint    NOT NULL REFERENCES usuario DEFERRABLE INITIALLY DEFERRED,
    rol_id       smallint  NOT NULL REFERENCES rol DEFERRABLE INITIALLY DEFERRED,
    asignado_at  timestamp NOT NULL,
    PRIMARY KEY (usuario_id, rol_id)
);

-- ---------- Perfiles ----------
CREATE TABLE paciente (
    paciente_id          bigint PRIMARY KEY,
    persona_id           bigint NOT NULL UNIQUE REFERENCES persona DEFERRABLE INITIALLY DEFERRED,
    tipo_sangre          varchar(3),
    alergias             varchar(500),
    contacto_emergencia  varchar(150),
    telefono_emergencia  varchar(20),
    created_at           timestamp NOT NULL,
    updated_at           timestamp NOT NULL
);

CREATE TABLE medico (
    medico_id             bigint PRIMARY KEY,
    persona_id            bigint       NOT NULL UNIQUE REFERENCES persona DEFERRABLE INITIALLY DEFERRED,
    registro_profesional  varchar(30)  NOT NULL UNIQUE,
    especialidad          varchar(100) NOT NULL,
    activo                boolean      NOT NULL,
    created_at            timestamp    NOT NULL,
    updated_at            timestamp    NOT NULL
);

CREATE TABLE laboratorista (
    laboratorista_id      bigint PRIMARY KEY,
    persona_id            bigint      NOT NULL UNIQUE REFERENCES persona DEFERRABLE INITIALLY DEFERRED,
    registro_profesional  varchar(30) NOT NULL UNIQUE,
    area                  varchar(100),
    activo                boolean     NOT NULL,
    created_at            timestamp   NOT NULL,
    updated_at            timestamp   NOT NULL
);

-- ---------- Catálogo ----------
CREATE TABLE categoria_examen (
    categoria_id  integer PRIMARY KEY,
    nombre        varchar(80) NOT NULL UNIQUE,
    descripcion   varchar(250),
    updated_at    timestamp   NOT NULL
);

CREATE TABLE tipo_examen (
    tipo_examen_id        integer PRIMARY KEY,
    categoria_id          integer       NOT NULL REFERENCES categoria_examen DEFERRABLE INITIALLY DEFERRED,
    codigo                varchar(20)   NOT NULL UNIQUE,
    nombre                varchar(120)  NOT NULL,
    descripcion           varchar(500),
    tipo_muestra          varchar(50)   NOT NULL,
    precio                numeric(10,2) NOT NULL,
    requiere_ayuno        boolean       NOT NULL,
    indicaciones          varchar(500),
    tiempo_entrega_horas  smallint      NOT NULL,
    activo                boolean       NOT NULL,
    updated_at            timestamp     NOT NULL
);

CREATE TABLE parametro_examen (
    parametro_id     integer PRIMARY KEY,
    tipo_examen_id   integer      NOT NULL REFERENCES tipo_examen DEFERRABLE INITIALLY DEFERRED,
    nombre           varchar(100) NOT NULL,
    unidad           varchar(30),
    valor_ref_min    numeric(12,3),
    valor_ref_max    numeric(12,3),
    valor_ref_texto  varchar(100),
    orden            smallint     NOT NULL,
    updated_at       timestamp    NOT NULL
);

-- ---------- Agenda ----------
CREATE TABLE franja_horaria (
    franja_id    bigint PRIMARY KEY,
    fecha        date      NOT NULL,
    hora_inicio  time(0)   NOT NULL,
    hora_fin     time(0)   NOT NULL,
    capacidad    smallint  NOT NULL,
    ocupados     smallint  NOT NULL,
    activa       boolean   NOT NULL,
    updated_at   timestamp NOT NULL
);

CREATE TABLE cita (
    cita_id       bigint PRIMARY KEY,
    paciente_id   bigint      NOT NULL REFERENCES paciente DEFERRABLE INITIALLY DEFERRED,
    franja_id     bigint      NOT NULL REFERENCES franja_horaria DEFERRABLE INITIALLY DEFERRED,
    estado        varchar(20) NOT NULL,
    motivo        varchar(300),
    canal         varchar(20) NOT NULL,
    cancelada_at  timestamp,
    created_at    timestamp   NOT NULL,
    updated_at    timestamp   NOT NULL
);
CREATE INDEX ix_cita_paciente ON cita (paciente_id);

-- ---------- Solicitudes y resultados ----------
CREATE TABLE solicitud_examen (
    solicitud_id   bigint PRIMARY KEY,
    codigo         varchar(20)   NOT NULL UNIQUE,
    paciente_id    bigint        NOT NULL REFERENCES paciente DEFERRABLE INITIALLY DEFERRED,
    medico_id      bigint        REFERENCES medico DEFERRABLE INITIALLY DEFERRED,
    cita_id        bigint        REFERENCES cita DEFERRABLE INITIALLY DEFERRED,
    estado         varchar(20)   NOT NULL,
    total          numeric(10,2) NOT NULL,
    observaciones  varchar(500),
    created_at     timestamp     NOT NULL,
    updated_at     timestamp     NOT NULL
);
CREATE INDEX ix_solicitud_paciente ON solicitud_examen (paciente_id);

CREATE TABLE solicitud_detalle (
    detalle_id         bigint PRIMARY KEY,
    solicitud_id       bigint        NOT NULL REFERENCES solicitud_examen DEFERRABLE INITIALLY DEFERRED,
    tipo_examen_id     integer       NOT NULL REFERENCES tipo_examen DEFERRABLE INITIALLY DEFERRED,
    precio_unitario    numeric(10,2) NOT NULL,
    estado             varchar(20)   NOT NULL,
    laboratorista_id   bigint        REFERENCES laboratorista DEFERRABLE INITIALLY DEFERRED,
    muestra_tomada_at  timestamp,
    updated_at         timestamp     NOT NULL
);
CREATE INDEX ix_detalle_solicitud ON solicitud_detalle (solicitud_id);

CREATE TABLE resultado (
    resultado_id      bigint PRIMARY KEY,
    detalle_id        bigint    NOT NULL UNIQUE REFERENCES solicitud_detalle DEFERRABLE INITIALLY DEFERRED,
    laboratorista_id  bigint    NOT NULL REFERENCES laboratorista DEFERRABLE INITIALLY DEFERRED,
    fecha_resultado   timestamp NOT NULL,
    observaciones     varchar(1000),
    validado          boolean   NOT NULL,
    validado_at       timestamp,
    updated_at        timestamp NOT NULL
);

CREATE TABLE resultado_valor (
    resultado_valor_id  bigint PRIMARY KEY,
    resultado_id        bigint  NOT NULL REFERENCES resultado DEFERRABLE INITIALLY DEFERRED,
    parametro_id        integer NOT NULL REFERENCES parametro_examen DEFERRABLE INITIALLY DEFERRED,
    valor_numerico      numeric(12,3),
    valor_texto         varchar(200),
    unidad              varchar(30),
    valor_ref_min       numeric(12,3),
    valor_ref_max       numeric(12,3),
    valor_ref_texto     varchar(100),
    fuera_rango         boolean   NOT NULL,
    updated_at          timestamp NOT NULL
);
CREATE INDEX ix_rv_resultado ON resultado_valor (resultado_id);

CREATE TABLE observacion_medica (
    observacion_id  bigint PRIMARY KEY,
    resultado_id    bigint        NOT NULL REFERENCES resultado DEFERRABLE INITIALLY DEFERRED,
    medico_id       bigint        NOT NULL REFERENCES medico DEFERRABLE INITIALLY DEFERRED,
    texto           varchar(2000) NOT NULL,
    created_at      timestamp     NOT NULL,
    updated_at      timestamp     NOT NULL
);

CREATE TABLE tratamiento (
    tratamiento_id  bigint PRIMARY KEY,
    paciente_id     bigint        NOT NULL REFERENCES paciente DEFERRABLE INITIALLY DEFERRED,
    medico_id       bigint        NOT NULL REFERENCES medico DEFERRABLE INITIALLY DEFERRED,
    solicitud_id    bigint        REFERENCES solicitud_examen DEFERRABLE INITIALLY DEFERRED,
    diagnostico     varchar(1000) NOT NULL,
    indicaciones    varchar(2000) NOT NULL,
    fecha_inicio    date          NOT NULL,
    fecha_fin       date,
    estado          varchar(20)   NOT NULL,
    created_at      timestamp     NOT NULL,
    updated_at      timestamp     NOT NULL
);
CREATE INDEX ix_tratamiento_paciente ON tratamiento (paciente_id);

-- ---------- Pagos (solo estado, para que el paciente vea su historial) ----------
CREATE TABLE pago (
    pago_id                     bigint PRIMARY KEY,
    solicitud_id                bigint        NOT NULL REFERENCES solicitud_examen DEFERRABLE INITIALLY DEFERRED,
    monto                       numeric(10,2) NOT NULL,
    moneda                      char(3)       NOT NULL,
    metodo                      varchar(20)   NOT NULL,
    estado                      varchar(20)   NOT NULL,
    stripe_checkout_session_id  varchar(100),
    stripe_payment_intent_id    varchar(100),
    referencia_transferencia    varchar(50),
    motivo_rechazo              varchar(300),
    monto_reembolsado           numeric(10,2) NOT NULL,
    expira_at                   timestamp,
    confirmado_at               timestamp,
    created_at                  timestamp     NOT NULL,
    updated_at                  timestamp     NOT NULL
);

CREATE TABLE reembolso (
    reembolso_id      bigint PRIMARY KEY,
    pago_id           bigint        NOT NULL REFERENCES pago DEFERRABLE INITIALLY DEFERRED,
    monto             numeric(10,2) NOT NULL,
    motivo            varchar(300)  NOT NULL,
    estado            varchar(20)   NOT NULL,
    stripe_refund_id  varchar(100),
    solicitado_por    bigint        NOT NULL REFERENCES usuario DEFERRABLE INITIALLY DEFERRED,
    created_at        timestamp     NOT NULL,
    updated_at        timestamp     NOT NULL
);

-- ---------- Control del sincronizador ----------
-- La versión se actualiza en la MISMA transacción que los datos:
-- o se aplica el lote completo y avanza la versión, o no pasa nada.
CREATE TABLE sync_estado (
    destino          varchar(30) PRIMARY KEY,
    ultima_version   bigint      NOT NULL,
    actualizado_at   timestamp   NOT NULL DEFAULT (now() AT TIME ZONE 'utc')
);

CREATE TABLE sync_log (
    sync_log_id     bigserial PRIMARY KEY,
    inicio          timestamp   NOT NULL,
    fin             timestamp   NOT NULL,
    modo            varchar(15) NOT NULL,          -- INCREMENTAL / COMPLETA
    desde_version   bigint,
    hasta_version   bigint      NOT NULL,
    upserts         integer     NOT NULL,
    deletes         integer     NOT NULL,
    detalle         jsonb,
    instancia       varchar(50)
);

-- RLS activado y sin políticas: ni anon ni authenticated (Data API)
-- pueden leer nada aunque alguien expusiera el esquema por error.
DO $$
DECLARE t record;
BEGIN
    FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'lab' LOOP
        EXECUTE format('ALTER TABLE lab.%I ENABLE ROW LEVEL SECURITY', t.tablename);
    END LOOP;
END $$;
