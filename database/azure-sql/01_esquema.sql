/* =====================================================================
   PLATAFORMA DISTRIBUIDA - LABORATORIO CLÍNICO
   01_esquema.sql  ->  Base principal (Azure SQL Database)
   ---------------------------------------------------------------------
   Convenciones:
   - PK BIGINT IDENTITY, nombres en snake_case y en español.
   - Fechas de auditoría en UTC (SYSUTCDATETIME()).
   - Toda tabla replicada tiene columna updated_at; la detección de
     cambios la hace Change Tracking (ver 02_change_tracking.sql).
   - Una PERSONA puede tener varios ROLES (ej. médico que también es
     paciente): persona 1-0..1 usuario, usuario N-M rol, y perfiles
     paciente / medico / laboratorista con persona_id UNIQUE.
   Ejecutar conectado a la base (Azure SQL no admite USE).
   ===================================================================== */

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ---------------------------------------------------------------------
   1. IDENTIDAD, USUARIOS Y ROLES
   ------------------------------------------------------------------- */
CREATE TABLE dbo.persona (
    persona_id        BIGINT IDENTITY(1,1) NOT NULL,
    cedula            VARCHAR(13)    NOT NULL,
    nombres           NVARCHAR(100)  NOT NULL,
    apellidos         NVARCHAR(100)  NOT NULL,
    fecha_nacimiento  DATE           NOT NULL,
    sexo              CHAR(1)        NOT NULL,
    telefono          VARCHAR(20)    NULL,
    email             VARCHAR(150)   NULL,
    direccion         NVARCHAR(250)  NULL,
    created_at        DATETIME2(3)   NOT NULL CONSTRAINT df_persona_created DEFAULT SYSUTCDATETIME(),
    updated_at        DATETIME2(3)   NOT NULL CONSTRAINT df_persona_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_persona PRIMARY KEY (persona_id),
    CONSTRAINT uq_persona_cedula UNIQUE (cedula),
    CONSTRAINT ck_persona_cedula CHECK (LEN(cedula) IN (10, 13) AND cedula NOT LIKE '%[^0-9]%'),
    CONSTRAINT ck_persona_sexo CHECK (sexo IN ('M', 'F', 'O')),
    CONSTRAINT ck_persona_nacimiento CHECK (fecha_nacimiento > '1900-01-01')
);
GO

CREATE TABLE dbo.usuario (
    usuario_id         BIGINT IDENTITY(1,1) NOT NULL,
    persona_id         BIGINT        NOT NULL,
    email              VARCHAR(150)  NOT NULL,
    password_hash      VARCHAR(255)  NOT NULL,          -- bcrypt, nunca texto plano
    activo             BIT           NOT NULL CONSTRAINT df_usuario_activo DEFAULT 1,
    intentos_fallidos  TINYINT       NOT NULL CONSTRAINT df_usuario_intentos DEFAULT 0,
    bloqueado_hasta    DATETIME2(3)  NULL,
    ultimo_login       DATETIME2(3)  NULL,
    created_at         DATETIME2(3)  NOT NULL CONSTRAINT df_usuario_created DEFAULT SYSUTCDATETIME(),
    updated_at         DATETIME2(3)  NOT NULL CONSTRAINT df_usuario_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_usuario PRIMARY KEY (usuario_id),
    CONSTRAINT uq_usuario_persona UNIQUE (persona_id),  -- una cuenta por persona
    CONSTRAINT uq_usuario_email UNIQUE (email),
    CONSTRAINT fk_usuario_persona FOREIGN KEY (persona_id) REFERENCES dbo.persona(persona_id)
);
GO

CREATE TABLE dbo.rol (
    rol_id       SMALLINT IDENTITY(1,1) NOT NULL,
    codigo       VARCHAR(30)    NOT NULL,              -- PACIENTE, MEDICO, LABORATORISTA, ADMIN
    nombre       NVARCHAR(60)   NOT NULL,
    descripcion  NVARCHAR(200)  NULL,
    CONSTRAINT pk_rol PRIMARY KEY (rol_id),
    CONSTRAINT uq_rol_codigo UNIQUE (codigo)
);
GO

CREATE TABLE dbo.permiso (
    permiso_id   SMALLINT IDENTITY(1,1) NOT NULL,
    codigo       VARCHAR(60)    NOT NULL,              -- ej. resultado:registrar
    descripcion  NVARCHAR(200)  NULL,
    CONSTRAINT pk_permiso PRIMARY KEY (permiso_id),
    CONSTRAINT uq_permiso_codigo UNIQUE (codigo)
);
GO

CREATE TABLE dbo.rol_permiso (
    rol_id      SMALLINT NOT NULL,
    permiso_id  SMALLINT NOT NULL,
    CONSTRAINT pk_rol_permiso PRIMARY KEY (rol_id, permiso_id),
    CONSTRAINT fk_rp_rol FOREIGN KEY (rol_id) REFERENCES dbo.rol(rol_id),
    CONSTRAINT fk_rp_permiso FOREIGN KEY (permiso_id) REFERENCES dbo.permiso(permiso_id)
);
GO

CREATE TABLE dbo.usuario_rol (
    usuario_id   BIGINT       NOT NULL,
    rol_id       SMALLINT     NOT NULL,
    asignado_at  DATETIME2(3) NOT NULL CONSTRAINT df_usuario_rol_asignado DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_usuario_rol PRIMARY KEY (usuario_id, rol_id),
    CONSTRAINT fk_ur_usuario FOREIGN KEY (usuario_id) REFERENCES dbo.usuario(usuario_id),
    CONSTRAINT fk_ur_rol FOREIGN KEY (rol_id) REFERENCES dbo.rol(rol_id)
);
GO

/* ---------------------------------------------------------------------
   2. PERFILES (una persona puede tener varios a la vez)
   ------------------------------------------------------------------- */
CREATE TABLE dbo.paciente (
    paciente_id          BIGINT IDENTITY(1,1) NOT NULL,
    persona_id           BIGINT        NOT NULL,
    tipo_sangre          VARCHAR(3)    NULL,
    alergias             NVARCHAR(500) NULL,
    contacto_emergencia  NVARCHAR(150) NULL,
    telefono_emergencia  VARCHAR(20)   NULL,
    created_at           DATETIME2(3)  NOT NULL CONSTRAINT df_paciente_created DEFAULT SYSUTCDATETIME(),
    updated_at           DATETIME2(3)  NOT NULL CONSTRAINT df_paciente_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_paciente PRIMARY KEY (paciente_id),
    CONSTRAINT uq_paciente_persona UNIQUE (persona_id),
    CONSTRAINT fk_paciente_persona FOREIGN KEY (persona_id) REFERENCES dbo.persona(persona_id),
    CONSTRAINT ck_paciente_sangre CHECK (tipo_sangre IS NULL OR tipo_sangre IN ('A+','A-','B+','B-','AB+','AB-','O+','O-'))
);
GO

CREATE TABLE dbo.medico (
    medico_id            BIGINT IDENTITY(1,1) NOT NULL,
    persona_id           BIGINT        NOT NULL,
    registro_profesional VARCHAR(30)   NOT NULL,       -- registro SENESCYT / ACESS
    especialidad         NVARCHAR(100) NOT NULL,
    activo               BIT           NOT NULL CONSTRAINT df_medico_activo DEFAULT 1,
    created_at           DATETIME2(3)  NOT NULL CONSTRAINT df_medico_created DEFAULT SYSUTCDATETIME(),
    updated_at           DATETIME2(3)  NOT NULL CONSTRAINT df_medico_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_medico PRIMARY KEY (medico_id),
    CONSTRAINT uq_medico_persona UNIQUE (persona_id),
    CONSTRAINT uq_medico_registro UNIQUE (registro_profesional),
    CONSTRAINT fk_medico_persona FOREIGN KEY (persona_id) REFERENCES dbo.persona(persona_id)
);
GO

CREATE TABLE dbo.laboratorista (
    laboratorista_id     BIGINT IDENTITY(1,1) NOT NULL,
    persona_id           BIGINT        NOT NULL,
    registro_profesional VARCHAR(30)   NOT NULL,
    area                 NVARCHAR(100) NULL,           -- hematología, química, etc.
    activo               BIT           NOT NULL CONSTRAINT df_lab_activo DEFAULT 1,
    created_at           DATETIME2(3)  NOT NULL CONSTRAINT df_lab_created DEFAULT SYSUTCDATETIME(),
    updated_at           DATETIME2(3)  NOT NULL CONSTRAINT df_lab_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_laboratorista PRIMARY KEY (laboratorista_id),
    CONSTRAINT uq_laboratorista_persona UNIQUE (persona_id),
    CONSTRAINT uq_laboratorista_registro UNIQUE (registro_profesional),
    CONSTRAINT fk_laboratorista_persona FOREIGN KEY (persona_id) REFERENCES dbo.persona(persona_id)
);
GO

/* ---------------------------------------------------------------------
   3. CATÁLOGO DE EXÁMENES
   ------------------------------------------------------------------- */
CREATE TABLE dbo.categoria_examen (
    categoria_id  INT IDENTITY(1,1) NOT NULL,
    nombre        NVARCHAR(80)  NOT NULL,
    descripcion   NVARCHAR(250) NULL,
    updated_at    DATETIME2(3)  NOT NULL CONSTRAINT df_cat_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_categoria_examen PRIMARY KEY (categoria_id),
    CONSTRAINT uq_categoria_nombre UNIQUE (nombre)
);
GO

CREATE TABLE dbo.tipo_examen (
    tipo_examen_id        INT IDENTITY(1,1) NOT NULL,
    categoria_id          INT            NOT NULL,
    codigo                VARCHAR(20)    NOT NULL,
    nombre                NVARCHAR(120)  NOT NULL,
    descripcion           NVARCHAR(500)  NULL,
    tipo_muestra          NVARCHAR(50)   NOT NULL,      -- sangre, orina, heces...
    precio                DECIMAL(10,2)  NOT NULL,
    requiere_ayuno        BIT            NOT NULL CONSTRAINT df_tipo_ayuno DEFAULT 0,
    indicaciones          NVARCHAR(500)  NULL,
    tiempo_entrega_horas  SMALLINT       NOT NULL CONSTRAINT df_tipo_tiempo DEFAULT 24,
    activo                BIT            NOT NULL CONSTRAINT df_tipo_activo DEFAULT 1,
    updated_at            DATETIME2(3)   NOT NULL CONSTRAINT df_tipo_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_tipo_examen PRIMARY KEY (tipo_examen_id),
    CONSTRAINT uq_tipo_examen_codigo UNIQUE (codigo),
    CONSTRAINT fk_tipo_examen_categoria FOREIGN KEY (categoria_id) REFERENCES dbo.categoria_examen(categoria_id),
    CONSTRAINT ck_tipo_examen_precio CHECK (precio >= 0),
    CONSTRAINT ck_tipo_examen_tiempo CHECK (tiempo_entrega_horas > 0)
);
GO

CREATE TABLE dbo.parametro_examen (
    parametro_id     INT IDENTITY(1,1) NOT NULL,
    tipo_examen_id   INT             NOT NULL,
    nombre           NVARCHAR(100)   NOT NULL,          -- ej. Hemoglobina
    unidad           NVARCHAR(30)    NULL,              -- ej. g/dL
    valor_ref_min    DECIMAL(12,3)   NULL,
    valor_ref_max    DECIMAL(12,3)   NULL,
    valor_ref_texto  NVARCHAR(100)   NULL,              -- para resultados cualitativos
    orden            SMALLINT        NOT NULL CONSTRAINT df_param_orden DEFAULT 1,
    updated_at       DATETIME2(3)    NOT NULL CONSTRAINT df_param_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_parametro_examen PRIMARY KEY (parametro_id),
    CONSTRAINT uq_parametro_nombre UNIQUE (tipo_examen_id, nombre),
    CONSTRAINT fk_parametro_tipo FOREIGN KEY (tipo_examen_id) REFERENCES dbo.tipo_examen(tipo_examen_id),
    CONSTRAINT ck_parametro_rango CHECK (valor_ref_min IS NULL OR valor_ref_max IS NULL OR valor_ref_min <= valor_ref_max)
);
GO

/* ---------------------------------------------------------------------
   4. AGENDA Y CITAS  (escenario crítico de concurrencia)
   ------------------------------------------------------------------- */
CREATE TABLE dbo.franja_horaria (
    franja_id    BIGINT IDENTITY(1,1) NOT NULL,
    fecha        DATE          NOT NULL,
    hora_inicio  TIME(0)       NOT NULL,
    hora_fin     TIME(0)       NOT NULL,
    capacidad    TINYINT       NOT NULL,                -- pacientes atendibles en la franja
    ocupados     TINYINT       NOT NULL CONSTRAINT df_franja_ocupados DEFAULT 0,
    activa       BIT           NOT NULL CONSTRAINT df_franja_activa DEFAULT 1,
    updated_at   DATETIME2(3)  NOT NULL CONSTRAINT df_franja_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_franja_horaria PRIMARY KEY (franja_id),
    CONSTRAINT uq_franja UNIQUE (fecha, hora_inicio),
    CONSTRAINT ck_franja_horas CHECK (hora_fin > hora_inicio),
    CONSTRAINT ck_franja_capacidad CHECK (capacidad > 0),
    CONSTRAINT ck_franja_ocupados CHECK (ocupados >= 0 AND ocupados <= capacidad)  -- última defensa ante sobre-reserva
);
GO

CREATE TABLE dbo.cita (
    cita_id        BIGINT IDENTITY(1,1) NOT NULL,
    paciente_id    BIGINT         NOT NULL,
    franja_id      BIGINT         NOT NULL,
    estado         VARCHAR(20)    NOT NULL CONSTRAINT df_cita_estado DEFAULT 'PENDIENTE_PAGO',
    motivo         NVARCHAR(300)  NULL,
    canal          VARCHAR(20)    NOT NULL CONSTRAINT df_cita_canal DEFAULT 'PORTAL',
    cancelada_at   DATETIME2(3)   NULL,
    created_at     DATETIME2(3)   NOT NULL CONSTRAINT df_cita_created DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3)   NOT NULL CONSTRAINT df_cita_updated DEFAULT SYSUTCDATETIME(),
    version_fila   ROWVERSION,                          -- concurrencia optimista
    CONSTRAINT pk_cita PRIMARY KEY (cita_id),
    CONSTRAINT fk_cita_paciente FOREIGN KEY (paciente_id) REFERENCES dbo.paciente(paciente_id),
    CONSTRAINT fk_cita_franja FOREIGN KEY (franja_id) REFERENCES dbo.franja_horaria(franja_id),
    CONSTRAINT ck_cita_estado CHECK (estado IN ('PENDIENTE_PAGO','CONFIRMADA','ATENDIDA','CANCELADA','NO_ASISTIO')),
    CONSTRAINT ck_cita_canal CHECK (canal IN ('PORTAL','VENTANILLA'))
);
GO
-- Un paciente no puede tener dos citas activas en la misma franja.
CREATE UNIQUE INDEX ux_cita_paciente_franja_activa
    ON dbo.cita (paciente_id, franja_id)
    WHERE estado <> 'CANCELADA';
GO
CREATE INDEX ix_cita_franja ON dbo.cita (franja_id);
GO

/* ---------------------------------------------------------------------
   5. SOLICITUDES (órdenes) DE EXÁMENES Y RESULTADOS
   ------------------------------------------------------------------- */
CREATE TABLE dbo.solicitud_examen (
    solicitud_id   BIGINT IDENTITY(1,1) NOT NULL,
    codigo         VARCHAR(20)    NOT NULL,             -- ej. SOL-2026-000123
    paciente_id    BIGINT         NOT NULL,
    medico_id      BIGINT         NULL,                 -- médico que ordena (opcional)
    cita_id        BIGINT         NULL,
    estado         VARCHAR(20)    NOT NULL CONSTRAINT df_sol_estado DEFAULT 'REGISTRADA',
    total          DECIMAL(10,2)  NOT NULL CONSTRAINT df_sol_total DEFAULT 0,
    observaciones  NVARCHAR(500)  NULL,
    created_at     DATETIME2(3)   NOT NULL CONSTRAINT df_sol_created DEFAULT SYSUTCDATETIME(),
    updated_at     DATETIME2(3)   NOT NULL CONSTRAINT df_sol_updated DEFAULT SYSUTCDATETIME(),
    version_fila   ROWVERSION,
    CONSTRAINT pk_solicitud_examen PRIMARY KEY (solicitud_id),
    CONSTRAINT uq_solicitud_codigo UNIQUE (codigo),
    CONSTRAINT fk_sol_paciente FOREIGN KEY (paciente_id) REFERENCES dbo.paciente(paciente_id),
    CONSTRAINT fk_sol_medico FOREIGN KEY (medico_id) REFERENCES dbo.medico(medico_id),
    CONSTRAINT fk_sol_cita FOREIGN KEY (cita_id) REFERENCES dbo.cita(cita_id),
    CONSTRAINT ck_sol_estado CHECK (estado IN ('REGISTRADA','PAGADA','EN_PROCESO','COMPLETADA','ANULADA')),
    CONSTRAINT ck_sol_total CHECK (total >= 0)
);
GO
CREATE INDEX ix_solicitud_paciente ON dbo.solicitud_examen (paciente_id);
CREATE INDEX ix_solicitud_medico ON dbo.solicitud_examen (medico_id);
GO

CREATE TABLE dbo.solicitud_detalle (
    detalle_id        BIGINT IDENTITY(1,1) NOT NULL,
    solicitud_id      BIGINT         NOT NULL,
    tipo_examen_id    INT            NOT NULL,
    precio_unitario   DECIMAL(10,2)  NOT NULL,          -- precio congelado al momento de la orden
    estado            VARCHAR(20)    NOT NULL CONSTRAINT df_det_estado DEFAULT 'PENDIENTE',
    laboratorista_id  BIGINT         NULL,
    muestra_tomada_at DATETIME2(3)   NULL,
    updated_at        DATETIME2(3)   NOT NULL CONSTRAINT df_det_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_solicitud_detalle PRIMARY KEY (detalle_id),
    CONSTRAINT uq_detalle_examen UNIQUE (solicitud_id, tipo_examen_id),
    CONSTRAINT fk_det_solicitud FOREIGN KEY (solicitud_id) REFERENCES dbo.solicitud_examen(solicitud_id),
    CONSTRAINT fk_det_tipo FOREIGN KEY (tipo_examen_id) REFERENCES dbo.tipo_examen(tipo_examen_id),
    CONSTRAINT fk_det_laboratorista FOREIGN KEY (laboratorista_id) REFERENCES dbo.laboratorista(laboratorista_id),
    CONSTRAINT ck_det_estado CHECK (estado IN ('PENDIENTE','MUESTRA_TOMADA','EN_ANALISIS','RESULTADO_LISTO','ANULADO')),
    CONSTRAINT ck_det_precio CHECK (precio_unitario >= 0)
);
GO

CREATE TABLE dbo.resultado (
    resultado_id      BIGINT IDENTITY(1,1) NOT NULL,
    detalle_id        BIGINT         NOT NULL,
    laboratorista_id  BIGINT         NOT NULL,
    fecha_resultado   DATETIME2(3)   NOT NULL CONSTRAINT df_res_fecha DEFAULT SYSUTCDATETIME(),
    observaciones     NVARCHAR(1000) NULL,
    validado          BIT            NOT NULL CONSTRAINT df_res_validado DEFAULT 0,
    validado_at       DATETIME2(3)   NULL,
    updated_at        DATETIME2(3)   NOT NULL CONSTRAINT df_res_updated DEFAULT SYSUTCDATETIME(),
    version_fila      ROWVERSION,
    CONSTRAINT pk_resultado PRIMARY KEY (resultado_id),
    CONSTRAINT uq_resultado_detalle UNIQUE (detalle_id),   -- un resultado por examen solicitado
    CONSTRAINT fk_res_detalle FOREIGN KEY (detalle_id) REFERENCES dbo.solicitud_detalle(detalle_id),
    CONSTRAINT fk_res_laboratorista FOREIGN KEY (laboratorista_id) REFERENCES dbo.laboratorista(laboratorista_id)
);
GO

CREATE TABLE dbo.resultado_valor (
    resultado_valor_id BIGINT IDENTITY(1,1) NOT NULL,
    resultado_id       BIGINT         NOT NULL,
    parametro_id       INT            NOT NULL,
    valor_numerico     DECIMAL(12,3)  NULL,
    valor_texto        NVARCHAR(200)  NULL,
    -- Copia del rango vigente al emitir el resultado: si el catálogo
    -- cambia después, el resultado histórico no se altera.
    unidad             NVARCHAR(30)   NULL,
    valor_ref_min      DECIMAL(12,3)  NULL,
    valor_ref_max      DECIMAL(12,3)  NULL,
    valor_ref_texto    NVARCHAR(100)  NULL,
    fuera_rango        BIT            NOT NULL CONSTRAINT df_rv_fuera DEFAULT 0,
    updated_at         DATETIME2(3)   NOT NULL CONSTRAINT df_rv_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_resultado_valor PRIMARY KEY (resultado_valor_id),
    CONSTRAINT uq_resultado_parametro UNIQUE (resultado_id, parametro_id),
    CONSTRAINT fk_rv_resultado FOREIGN KEY (resultado_id) REFERENCES dbo.resultado(resultado_id),
    CONSTRAINT fk_rv_parametro FOREIGN KEY (parametro_id) REFERENCES dbo.parametro_examen(parametro_id),
    CONSTRAINT ck_rv_valor CHECK (valor_numerico IS NOT NULL OR valor_texto IS NOT NULL)
);
GO

/* ---------------------------------------------------------------------
   6. SEGUIMIENTO MÉDICO
   ------------------------------------------------------------------- */
CREATE TABLE dbo.observacion_medica (
    observacion_id  BIGINT IDENTITY(1,1) NOT NULL,
    resultado_id    BIGINT          NOT NULL,
    medico_id       BIGINT          NOT NULL,
    texto           NVARCHAR(2000)  NOT NULL,
    created_at      DATETIME2(3)    NOT NULL CONSTRAINT df_obs_created DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3)    NOT NULL CONSTRAINT df_obs_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_observacion_medica PRIMARY KEY (observacion_id),
    CONSTRAINT fk_obs_resultado FOREIGN KEY (resultado_id) REFERENCES dbo.resultado(resultado_id),
    CONSTRAINT fk_obs_medico FOREIGN KEY (medico_id) REFERENCES dbo.medico(medico_id)
);
GO

CREATE TABLE dbo.tratamiento (
    tratamiento_id  BIGINT IDENTITY(1,1) NOT NULL,
    paciente_id     BIGINT          NOT NULL,
    medico_id       BIGINT          NOT NULL,
    solicitud_id    BIGINT          NULL,               -- exámenes que lo originaron
    diagnostico     NVARCHAR(1000)  NOT NULL,
    indicaciones    NVARCHAR(2000)  NOT NULL,
    fecha_inicio    DATE            NOT NULL,
    fecha_fin       DATE            NULL,
    estado          VARCHAR(20)     NOT NULL CONSTRAINT df_trat_estado DEFAULT 'ACTIVO',
    created_at      DATETIME2(3)    NOT NULL CONSTRAINT df_trat_created DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3)    NOT NULL CONSTRAINT df_trat_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_tratamiento PRIMARY KEY (tratamiento_id),
    CONSTRAINT fk_trat_paciente FOREIGN KEY (paciente_id) REFERENCES dbo.paciente(paciente_id),
    CONSTRAINT fk_trat_medico FOREIGN KEY (medico_id) REFERENCES dbo.medico(medico_id),
    CONSTRAINT fk_trat_solicitud FOREIGN KEY (solicitud_id) REFERENCES dbo.solicitud_examen(solicitud_id),
    CONSTRAINT ck_trat_estado CHECK (estado IN ('ACTIVO','FINALIZADO','SUSPENDIDO')),
    CONSTRAINT ck_trat_fechas CHECK (fecha_fin IS NULL OR fecha_fin >= fecha_inicio)
);
GO
CREATE INDEX ix_tratamiento_paciente ON dbo.tratamiento (paciente_id);
GO

/* ---------------------------------------------------------------------
   7. PAGOS (Stripe en modo prueba / transferencia con QR simulada)
   ------------------------------------------------------------------- */
CREATE TABLE dbo.pago (
    pago_id                     BIGINT IDENTITY(1,1) NOT NULL,
    solicitud_id                BIGINT         NOT NULL,
    monto                       DECIMAL(10,2)  NOT NULL,
    moneda                      CHAR(3)        NOT NULL CONSTRAINT df_pago_moneda DEFAULT 'USD',
    metodo                      VARCHAR(20)    NOT NULL,
    estado                      VARCHAR(20)    NOT NULL CONSTRAINT df_pago_estado DEFAULT 'PENDIENTE',
    stripe_checkout_session_id  VARCHAR(100)   NULL,
    stripe_payment_intent_id    VARCHAR(100)   NULL,
    referencia_transferencia    VARCHAR(50)    NULL,
    motivo_rechazo              NVARCHAR(300)  NULL,
    monto_reembolsado           DECIMAL(10,2)  NOT NULL CONSTRAINT df_pago_reemb DEFAULT 0,
    expira_at                   DATETIME2(3)   NULL,
    confirmado_at               DATETIME2(3)   NULL,
    created_at                  DATETIME2(3)   NOT NULL CONSTRAINT df_pago_created DEFAULT SYSUTCDATETIME(),
    updated_at                  DATETIME2(3)   NOT NULL CONSTRAINT df_pago_updated DEFAULT SYSUTCDATETIME(),
    version_fila                ROWVERSION,
    CONSTRAINT pk_pago PRIMARY KEY (pago_id),
    CONSTRAINT fk_pago_solicitud FOREIGN KEY (solicitud_id) REFERENCES dbo.solicitud_examen(solicitud_id),
    CONSTRAINT ck_pago_monto CHECK (monto > 0),
    CONSTRAINT ck_pago_metodo CHECK (metodo IN ('STRIPE','TRANSFERENCIA_QR')),
    CONSTRAINT ck_pago_estado CHECK (estado IN ('PENDIENTE','APROBADO','RECHAZADO','EXPIRADO','REEMBOLSADO','REEMBOLSO_PARCIAL')),
    CONSTRAINT ck_pago_reembolso CHECK (monto_reembolsado >= 0 AND monto_reembolsado <= monto)
);
GO
CREATE UNIQUE INDEX ux_pago_checkout ON dbo.pago (stripe_checkout_session_id) WHERE stripe_checkout_session_id IS NOT NULL;
CREATE UNIQUE INDEX ux_pago_intent ON dbo.pago (stripe_payment_intent_id) WHERE stripe_payment_intent_id IS NOT NULL;
-- Solo un pago aprobado por solicitud.
CREATE UNIQUE INDEX ux_pago_aprobado_solicitud ON dbo.pago (solicitud_id) WHERE estado = 'APROBADO';
GO

CREATE TABLE dbo.reembolso (
    reembolso_id       BIGINT IDENTITY(1,1) NOT NULL,
    pago_id            BIGINT         NOT NULL,
    monto              DECIMAL(10,2)  NOT NULL,
    motivo             NVARCHAR(300)  NOT NULL,
    estado             VARCHAR(20)    NOT NULL CONSTRAINT df_reemb_estado DEFAULT 'PENDIENTE',
    stripe_refund_id   VARCHAR(100)   NULL,
    solicitado_por     BIGINT         NOT NULL,          -- usuario_id del admin
    created_at         DATETIME2(3)   NOT NULL CONSTRAINT df_reemb_created DEFAULT SYSUTCDATETIME(),
    updated_at         DATETIME2(3)   NOT NULL CONSTRAINT df_reemb_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_reembolso PRIMARY KEY (reembolso_id),
    CONSTRAINT fk_reemb_pago FOREIGN KEY (pago_id) REFERENCES dbo.pago(pago_id),
    CONSTRAINT fk_reemb_usuario FOREIGN KEY (solicitado_por) REFERENCES dbo.usuario(usuario_id),
    CONSTRAINT ck_reemb_monto CHECK (monto > 0),
    CONSTRAINT ck_reemb_estado CHECK (estado IN ('PENDIENTE','EXITOSO','FALLIDO','CANCELADO'))
);
GO
CREATE UNIQUE INDEX ux_reembolso_stripe ON dbo.reembolso (stripe_refund_id) WHERE stripe_refund_id IS NOT NULL;
GO

-- Idempotencia de webhooks: Stripe puede reenviar el mismo evento.
CREATE TABLE dbo.stripe_evento (
    stripe_event_id  VARCHAR(100)   NOT NULL,
    tipo             VARCHAR(80)    NOT NULL,
    pago_id          BIGINT         NULL,
    procesado        BIT            NOT NULL CONSTRAINT df_se_procesado DEFAULT 0,
    payload          NVARCHAR(MAX)  NOT NULL,
    recibido_at      DATETIME2(3)   NOT NULL CONSTRAINT df_se_recibido DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_stripe_evento PRIMARY KEY (stripe_event_id),
    CONSTRAINT fk_se_pago FOREIGN KEY (pago_id) REFERENCES dbo.pago(pago_id),
    CONSTRAINT ck_se_payload CHECK (ISJSON(payload) = 1)
);
GO

/* ---------------------------------------------------------------------
   8. NOTIFICACIONES (bandeja de salida para Mailjet) Y AUDITORÍA
   ------------------------------------------------------------------- */
CREATE TABLE dbo.notificacion (
    notificacion_id    BIGINT IDENTITY(1,1) NOT NULL,
    persona_id         BIGINT          NOT NULL,
    canal              VARCHAR(10)     NOT NULL CONSTRAINT df_not_canal DEFAULT 'EMAIL',
    tipo               VARCHAR(40)     NOT NULL,         -- CITA_CONFIRMADA, PAGO_APROBADO, RESULTADO_LISTO...
    destinatario       VARCHAR(150)    NOT NULL,
    asunto             NVARCHAR(200)   NOT NULL,
    cuerpo             NVARCHAR(MAX)   NOT NULL,
    estado             VARCHAR(10)     NOT NULL CONSTRAINT df_not_estado DEFAULT 'PENDIENTE',
    intentos           TINYINT         NOT NULL CONSTRAINT df_not_intentos DEFAULT 0,
    ultimo_error       NVARCHAR(500)   NULL,
    proveedor_msg_id   VARCHAR(100)    NULL,             -- MessageID devuelto por Mailjet
    created_at         DATETIME2(3)    NOT NULL CONSTRAINT df_not_created DEFAULT SYSUTCDATETIME(),
    enviada_at         DATETIME2(3)    NULL,
    updated_at         DATETIME2(3)    NOT NULL CONSTRAINT df_not_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_notificacion PRIMARY KEY (notificacion_id),
    CONSTRAINT fk_not_persona FOREIGN KEY (persona_id) REFERENCES dbo.persona(persona_id),
    CONSTRAINT ck_not_canal CHECK (canal IN ('EMAIL')),
    CONSTRAINT ck_not_estado CHECK (estado IN ('PENDIENTE','ENVIADA','FALLIDA'))
);
GO
CREATE INDEX ix_notificacion_pendiente ON dbo.notificacion (estado, created_at) WHERE estado = 'PENDIENTE';
GO

CREATE TABLE dbo.auditoria (
    auditoria_id  BIGINT IDENTITY(1,1) NOT NULL,
    usuario_id    BIGINT          NULL,                 -- NULL = sistema / proceso automático
    rol_actuante  VARCHAR(30)     NULL,                 -- con qué rol actuó una persona multirrol
    accion        VARCHAR(50)     NOT NULL,             -- LOGIN, RESERVAR_CITA, REGISTRAR_RESULTADO...
    entidad       VARCHAR(50)     NOT NULL,
    entidad_id    VARCHAR(50)     NULL,
    detalle       NVARCHAR(MAX)   NULL,                 -- JSON
    ip_origen     VARCHAR(45)     NULL,
    instancia_api VARCHAR(30)     NULL,                 -- api1..api4: evidencia del balanceo
    created_at    DATETIME2(3)    NOT NULL CONSTRAINT df_aud_created DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_auditoria PRIMARY KEY (auditoria_id),
    CONSTRAINT fk_aud_usuario FOREIGN KEY (usuario_id) REFERENCES dbo.usuario(usuario_id),
    CONSTRAINT ck_aud_detalle CHECK (detalle IS NULL OR ISJSON(detalle) = 1)
);
GO
CREATE INDEX ix_auditoria_fecha ON dbo.auditoria (created_at);
GO
