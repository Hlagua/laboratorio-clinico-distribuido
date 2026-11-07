# Diccionario de datos — Azure SQL Database

_Generado automáticamente con `database/generar_diccionario.py` a partir de la base real._

## persona

Datos personales únicos por cédula. Base de todos los perfiles.

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| persona_id | bigint | No | PK IDENTITY |  |
| cedula | varchar(13) | No |  |  |
| nombres | nvarchar(100) | No |  |  |
| apellidos | nvarchar(100) | No |  |  |
| fecha_nacimiento | date | No |  |  |
| sexo | char(1) | No |  |  |
| telefono | varchar(20) | Sí |  |  |
| email | varchar(150) | Sí |  |  |
| direccion | nvarchar(250) | Sí |  |  |
| created_at | datetime2 | No |  | sysutcdatetime |
| updated_at | datetime2 | No |  | sysutcdatetime |

**Restricciones:**

- `ck_persona_cedula`: `CHECK ((len([cedula])=(13) OR len([cedula])=(10)) AND NOT [cedula] like '%[^0-9]%')`
- `ck_persona_sexo`: `CHECK ([sexo]='O' OR [sexo]='F' OR [sexo]='M')`
- `ck_persona_nacimiento`: `CHECK ([fecha_nacimiento]>'1900-01-01')`
- `uq_persona_cedula`: `UNIQUE (cedula)`

## usuario

Credenciales de acceso (0..1 por persona). Contraseña con bcrypt.

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| usuario_id | bigint | No | PK IDENTITY |  |
| persona_id | bigint | No | FK → persona |  |
| email | varchar(150) | No |  |  |
| password_hash | varchar(255) | No |  |  |
| activo | bit | No |  | 1 |
| intentos_fallidos | tinyint | No |  | 0 |
| bloqueado_hasta | datetime2 | Sí |  |  |
| ultimo_login | datetime2 | Sí |  |  |
| created_at | datetime2 | No |  | sysutcdatetime |
| updated_at | datetime2 | No |  | sysutcdatetime |

**Restricciones:**

- `uq_usuario_email`: `UNIQUE (email)`
- `uq_usuario_persona`: `UNIQUE (persona_id)`

## permiso

Permisos atómicos que se agrupan en roles.

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| permiso_id | smallint | No | PK IDENTITY |  |
| codigo | varchar(60) | No |  |  |
| descripcion | nvarchar(200) | Sí |  |  |

**Restricciones:**

- `uq_permiso_codigo`: `UNIQUE (codigo)`

## rol

Roles del sistema: PACIENTE, LABORATORISTA, MEDICO, ADMIN.

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| rol_id | smallint | No | PK IDENTITY |  |
| codigo | varchar(30) | No |  |  |
| nombre | nvarchar(60) | No |  |  |
| descripcion | nvarchar(200) | Sí |  |  |

**Restricciones:**

- `uq_rol_codigo`: `UNIQUE (codigo)`

## rol_permiso

Relación N:M entre roles y permisos.

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| rol_id | smallint | No | PK FK → rol |  |
| permiso_id | smallint | No | PK FK → permiso |  |

## usuario_rol

Relación N:M entre usuarios y roles: una persona puede tener varios roles.

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| usuario_id | bigint | No | PK FK → usuario |  |
| rol_id | smallint | No | PK FK → rol |  |
| asignado_at | datetime2 | No |  | sysutcdatetime |

## medico

Perfil del médico tratante.

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| medico_id | bigint | No | PK IDENTITY |  |
| persona_id | bigint | No | FK → persona |  |
| registro_profesional | varchar(30) | No |  |  |
| especialidad | nvarchar(100) | No |  |  |
| activo | bit | No |  | 1 |
| created_at | datetime2 | No |  | sysutcdatetime |
| updated_at | datetime2 | No |  | sysutcdatetime |

**Restricciones:**

- `uq_medico_persona`: `UNIQUE (persona_id)`
- `uq_medico_registro`: `UNIQUE (registro_profesional)`

## paciente

Perfil clínico de una persona atendida en el laboratorio.

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| paciente_id | bigint | No | PK IDENTITY |  |
| persona_id | bigint | No | FK → persona |  |
| tipo_sangre | varchar(3) | Sí |  |  |
| alergias | nvarchar(500) | Sí |  |  |
| contacto_emergencia | nvarchar(150) | Sí |  |  |
| telefono_emergencia | varchar(20) | Sí |  |  |
| created_at | datetime2 | No |  | sysutcdatetime |
| updated_at | datetime2 | No |  | sysutcdatetime |

**Restricciones:**

- `ck_paciente_sangre`: `CHECK ([tipo_sangre] IS NULL OR ([tipo_sangre]='O-' OR [tipo_sangre]='O+' OR [tipo_sangre]='AB-' OR [tipo_sangre]='AB+' OR [tipo_sangre]='B-' OR [tipo_sangre]='B+' OR [tipo_sangre]='A-' OR [tipo_sangre]='A+'))`
- `uq_paciente_persona`: `UNIQUE (persona_id)`

## laboratorista

Perfil del profesional que procesa muestras y registra resultados.

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| laboratorista_id | bigint | No | PK IDENTITY |  |
| persona_id | bigint | No | FK → persona |  |
| registro_profesional | varchar(30) | No |  |  |
| area | nvarchar(100) | Sí |  |  |
| activo | bit | No |  | 1 |
| created_at | datetime2 | No |  | sysutcdatetime |
| updated_at | datetime2 | No |  | sysutcdatetime |

**Restricciones:**

- `uq_laboratorista_persona`: `UNIQUE (persona_id)`
- `uq_laboratorista_registro`: `UNIQUE (registro_profesional)`

## categoria_examen

Agrupación de exámenes (hematología, química, etc.).

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| categoria_id | int | No | PK IDENTITY |  |
| nombre | nvarchar(80) | No |  |  |
| descripcion | nvarchar(250) | Sí |  |  |
| updated_at | datetime2 | No |  | sysutcdatetime |

**Restricciones:**

- `uq_categoria_nombre`: `UNIQUE (nombre)`

## parametro_examen

Parámetros que mide cada examen con su rango de referencia.

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| parametro_id | int | No | PK IDENTITY |  |
| tipo_examen_id | int | No | FK → tipo_examen |  |
| nombre | nvarchar(100) | No |  |  |
| unidad | nvarchar(30) | Sí |  |  |
| valor_ref_min | decimal(12,3) | Sí |  |  |
| valor_ref_max | decimal(12,3) | Sí |  |  |
| valor_ref_texto | nvarchar(100) | Sí |  |  |
| orden | smallint | No |  | 1 |
| updated_at | datetime2 | No |  | sysutcdatetime |

**Restricciones:**

- `ck_parametro_rango`: `CHECK ([valor_ref_min] IS NULL OR [valor_ref_max] IS NULL OR [valor_ref_min]<=[valor_ref_max])`
- `uq_parametro_nombre`: `UNIQUE (tipo_examen_id, nombre)`

## tipo_examen

Catálogo de exámenes con precio y requisitos.

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| tipo_examen_id | int | No | PK IDENTITY |  |
| categoria_id | int | No | FK → categoria_examen |  |
| codigo | varchar(20) | No |  |  |
| nombre | nvarchar(120) | No |  |  |
| descripcion | nvarchar(500) | Sí |  |  |
| tipo_muestra | nvarchar(50) | No |  |  |
| precio | decimal(10,2) | No |  |  |
| requiere_ayuno | bit | No |  | 0 |
| indicaciones | nvarchar(500) | Sí |  |  |
| tiempo_entrega_horas | smallint | No |  | 24 |
| activo | bit | No |  | 1 |
| updated_at | datetime2 | No |  | sysutcdatetime |

**Restricciones:**

- `ck_tipo_examen_precio`: `CHECK ([precio]>=(0))`
- `ck_tipo_examen_tiempo`: `CHECK ([tiempo_entrega_horas]>(0))`
- `uq_tipo_examen_codigo`: `UNIQUE (codigo)`

## franja_horaria

Bloques de atención con capacidad; el contador de ocupados se protege ante concurrencia.

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| franja_id | bigint | No | PK IDENTITY |  |
| fecha | date | No |  |  |
| hora_inicio | time | No |  |  |
| hora_fin | time | No |  |  |
| capacidad | tinyint | No |  |  |
| ocupados | tinyint | No |  | 0 |
| activa | bit | No |  | 1 |
| updated_at | datetime2 | No |  | sysutcdatetime |

**Restricciones:**

- `ck_franja_horas`: `CHECK ([hora_fin]>[hora_inicio])`
- `ck_franja_capacidad`: `CHECK ([capacidad]>(0))`
- `ck_franja_ocupados`: `CHECK ([ocupados]>=(0) AND [ocupados]<=[capacidad])`
- `uq_franja`: `UNIQUE (fecha, hora_inicio)`

## cita

Reserva de un paciente en una franja.

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| cita_id | bigint | No | PK IDENTITY |  |
| paciente_id | bigint | No | FK → paciente |  |
| franja_id | bigint | No | FK → franja_horaria |  |
| estado | varchar(20) | No |  | 'PENDIENTE_PAGO' |
| motivo | nvarchar(300) | Sí |  |  |
| canal | varchar(20) | No |  | 'PORTAL' |
| cancelada_at | datetime2 | Sí |  |  |
| created_at | datetime2 | No |  | sysutcdatetime |
| updated_at | datetime2 | No |  | sysutcdatetime |
| version_fila | timestamp | No |  |  |

**Restricciones:**

- `ck_cita_estado`: `CHECK ([estado]='NO_ASISTIO' OR [estado]='CANCELADA' OR [estado]='ATENDIDA' OR [estado]='CONFIRMADA' OR [estado]='PENDIENTE_PAGO')`
- `ck_cita_canal`: `CHECK ([canal]='VENTANILLA' OR [canal]='PORTAL')`
- `ux_cita_paciente_franja_activa`: `UNIQUE filtrado ([estado]<>'CANCELADA') (paciente_id, franja_id)`

## solicitud_examen

Orden de exámenes de un paciente (cabecera).

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| solicitud_id | bigint | No | PK IDENTITY |  |
| codigo | varchar(20) | No |  |  |
| paciente_id | bigint | No | FK → paciente |  |
| medico_id | bigint | Sí | FK → medico |  |
| cita_id | bigint | Sí | FK → cita |  |
| estado | varchar(20) | No |  | 'REGISTRADA' |
| total | decimal(10,2) | No |  | 0 |
| observaciones | nvarchar(500) | Sí |  |  |
| created_at | datetime2 | No |  | sysutcdatetime |
| updated_at | datetime2 | No |  | sysutcdatetime |
| version_fila | timestamp | No |  |  |

**Restricciones:**

- `ck_sol_estado`: `CHECK ([estado]='ANULADA' OR [estado]='COMPLETADA' OR [estado]='EN_PROCESO' OR [estado]='PAGADA' OR [estado]='REGISTRADA')`
- `ck_sol_total`: `CHECK ([total]>=(0))`
- `uq_solicitud_codigo`: `UNIQUE (codigo)`

## solicitud_detalle

Cada examen dentro de una solicitud, con su precio congelado.

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| detalle_id | bigint | No | PK IDENTITY |  |
| solicitud_id | bigint | No | FK → solicitud_examen |  |
| tipo_examen_id | int | No | FK → tipo_examen |  |
| precio_unitario | decimal(10,2) | No |  |  |
| estado | varchar(20) | No |  | 'PENDIENTE' |
| laboratorista_id | bigint | Sí | FK → laboratorista |  |
| muestra_tomada_at | datetime2 | Sí |  |  |
| updated_at | datetime2 | No |  | sysutcdatetime |

**Restricciones:**

- `ck_det_estado`: `CHECK ([estado]='ANULADO' OR [estado]='RESULTADO_LISTO' OR [estado]='EN_ANALISIS' OR [estado]='MUESTRA_TOMADA' OR [estado]='PENDIENTE')`
- `ck_det_precio`: `CHECK ([precio_unitario]>=(0))`
- `uq_detalle_examen`: `UNIQUE (solicitud_id, tipo_examen_id)`

## resultado

Resultado emitido para un examen solicitado.

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| resultado_id | bigint | No | PK IDENTITY |  |
| detalle_id | bigint | No | FK → solicitud_detalle |  |
| laboratorista_id | bigint | No | FK → laboratorista |  |
| fecha_resultado | datetime2 | No |  | sysutcdatetime |
| observaciones | nvarchar(1000) | Sí |  |  |
| validado | bit | No |  | 0 |
| validado_at | datetime2 | Sí |  |  |
| updated_at | datetime2 | No |  | sysutcdatetime |
| version_fila | timestamp | No |  |  |

**Restricciones:**

- `uq_resultado_detalle`: `UNIQUE (detalle_id)`

## observacion_medica

Comentarios del médico tratante sobre un resultado.

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| observacion_id | bigint | No | PK IDENTITY |  |
| resultado_id | bigint | No | FK → resultado |  |
| medico_id | bigint | No | FK → medico |  |
| texto | nvarchar(2000) | No |  |  |
| created_at | datetime2 | No |  | sysutcdatetime |
| updated_at | datetime2 | No |  | sysutcdatetime |

## resultado_valor

Valor por parámetro, con copia del rango vigente y marca de fuera de rango.

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| resultado_valor_id | bigint | No | PK IDENTITY |  |
| resultado_id | bigint | No | FK → resultado |  |
| parametro_id | int | No | FK → parametro_examen |  |
| valor_numerico | decimal(12,3) | Sí |  |  |
| valor_texto | nvarchar(200) | Sí |  |  |
| unidad | nvarchar(30) | Sí |  |  |
| valor_ref_min | decimal(12,3) | Sí |  |  |
| valor_ref_max | decimal(12,3) | Sí |  |  |
| valor_ref_texto | nvarchar(100) | Sí |  |  |
| fuera_rango | bit | No |  | 0 |
| updated_at | datetime2 | No |  | sysutcdatetime |

**Restricciones:**

- `ck_rv_valor`: `CHECK ([valor_numerico] IS NOT NULL OR [valor_texto] IS NOT NULL)`
- `uq_resultado_parametro`: `UNIQUE (resultado_id, parametro_id)`

## tratamiento

Diagnóstico e indicaciones del médico para un paciente.

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| tratamiento_id | bigint | No | PK IDENTITY |  |
| paciente_id | bigint | No | FK → paciente |  |
| medico_id | bigint | No | FK → medico |  |
| solicitud_id | bigint | Sí | FK → solicitud_examen |  |
| diagnostico | nvarchar(1000) | No |  |  |
| indicaciones | nvarchar(2000) | No |  |  |
| fecha_inicio | date | No |  |  |
| fecha_fin | date | Sí |  |  |
| estado | varchar(20) | No |  | 'ACTIVO' |
| created_at | datetime2 | No |  | sysutcdatetime |
| updated_at | datetime2 | No |  | sysutcdatetime |

**Restricciones:**

- `ck_trat_estado`: `CHECK ([estado]='SUSPENDIDO' OR [estado]='FINALIZADO' OR [estado]='ACTIVO')`
- `ck_trat_fechas`: `CHECK ([fecha_fin] IS NULL OR [fecha_fin]>=[fecha_inicio])`

## pago

Pago de una solicitud (Stripe en modo prueba o transferencia con QR).

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| pago_id | bigint | No | PK IDENTITY |  |
| solicitud_id | bigint | No | FK → solicitud_examen |  |
| monto | decimal(10,2) | No |  |  |
| moneda | char(3) | No |  | 'USD' |
| metodo | varchar(20) | No |  |  |
| estado | varchar(20) | No |  | 'PENDIENTE' |
| stripe_checkout_session_id | varchar(100) | Sí |  |  |
| stripe_payment_intent_id | varchar(100) | Sí |  |  |
| referencia_transferencia | varchar(50) | Sí |  |  |
| motivo_rechazo | nvarchar(300) | Sí |  |  |
| monto_reembolsado | decimal(10,2) | No |  | 0 |
| expira_at | datetime2 | Sí |  |  |
| confirmado_at | datetime2 | Sí |  |  |
| created_at | datetime2 | No |  | sysutcdatetime |
| updated_at | datetime2 | No |  | sysutcdatetime |
| version_fila | timestamp | No |  |  |

**Restricciones:**

- `ck_pago_monto`: `CHECK ([monto]>(0))`
- `ck_pago_metodo`: `CHECK ([metodo]='TRANSFERENCIA_QR' OR [metodo]='STRIPE')`
- `ck_pago_estado`: `CHECK ([estado]='REEMBOLSO_PARCIAL' OR [estado]='REEMBOLSADO' OR [estado]='EXPIRADO' OR [estado]='RECHAZADO' OR [estado]='APROBADO' OR [estado]='PENDIENTE')`
- `ck_pago_reembolso`: `CHECK ([monto_reembolsado]>=(0) AND [monto_reembolsado]<=[monto])`
- `ux_pago_aprobado_solicitud`: `UNIQUE filtrado ([estado]='APROBADO') (solicitud_id)`
- `ux_pago_checkout`: `UNIQUE filtrado ([stripe_checkout_session_id] IS NOT NULL) (stripe_checkout_session_id)`
- `ux_pago_intent`: `UNIQUE filtrado ([stripe_payment_intent_id] IS NOT NULL) (stripe_payment_intent_id)`

## reembolso

Reembolsos totales o parciales de un pago.

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| reembolso_id | bigint | No | PK IDENTITY |  |
| pago_id | bigint | No | FK → pago |  |
| monto | decimal(10,2) | No |  |  |
| motivo | nvarchar(300) | No |  |  |
| estado | varchar(20) | No |  | 'PENDIENTE' |
| stripe_refund_id | varchar(100) | Sí |  |  |
| solicitado_por | bigint | No | FK → usuario |  |
| created_at | datetime2 | No |  | sysutcdatetime |
| updated_at | datetime2 | No |  | sysutcdatetime |

**Restricciones:**

- `ck_reemb_monto`: `CHECK ([monto]>(0))`
- `ck_reemb_estado`: `CHECK ([estado]='CANCELADO' OR [estado]='FALLIDO' OR [estado]='EXITOSO' OR [estado]='PENDIENTE')`
- `ux_reembolso_stripe`: `UNIQUE filtrado ([stripe_refund_id] IS NOT NULL) (stripe_refund_id)`

## stripe_evento

Eventos recibidos por webhook de Stripe (idempotencia y trazabilidad).

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| stripe_event_id | varchar(100) | No | PK |  |
| tipo | varchar(80) | No |  |  |
| pago_id | bigint | Sí | FK → pago |  |
| procesado | bit | No |  | 0 |
| payload | nvarchar(MAX) | No |  |  |
| recibido_at | datetime2 | No |  | sysutcdatetime |

**Restricciones:**

- `ck_se_payload`: `CHECK (isjson([payload])=(1))`

## notificacion

Bandeja de salida de correos (Mailjet).

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| notificacion_id | bigint | No | PK IDENTITY |  |
| persona_id | bigint | No | FK → persona |  |
| canal | varchar(10) | No |  | 'EMAIL' |
| tipo | varchar(40) | No |  |  |
| destinatario | varchar(150) | No |  |  |
| asunto | nvarchar(200) | No |  |  |
| cuerpo | nvarchar(MAX) | No |  |  |
| estado | varchar(10) | No |  | 'PENDIENTE' |
| intentos | tinyint | No |  | 0 |
| ultimo_error | nvarchar(500) | Sí |  |  |
| proveedor_msg_id | varchar(100) | Sí |  |  |
| created_at | datetime2 | No |  | sysutcdatetime |
| enviada_at | datetime2 | Sí |  |  |
| updated_at | datetime2 | No |  | sysutcdatetime |

**Restricciones:**

- `ck_not_canal`: `CHECK ([canal]='EMAIL')`
- `ck_not_estado`: `CHECK ([estado]='FALLIDA' OR [estado]='ENVIADA' OR [estado]='PENDIENTE')`

## auditoria

Registro de operaciones relevantes; se replica a MongoDB.

| Columna | Tipo | Nulo | Clave | Por defecto |
|---|---|---|---|---|
| auditoria_id | bigint | No | PK IDENTITY |  |
| usuario_id | bigint | Sí | FK → usuario |  |
| rol_actuante | varchar(30) | Sí |  |  |
| accion | varchar(50) | No |  |  |
| entidad | varchar(50) | No |  |  |
| entidad_id | varchar(50) | Sí |  |  |
| detalle | nvarchar(MAX) | Sí |  |  |
| ip_origen | varchar(45) | Sí |  |  |
| instancia_api | varchar(30) | Sí |  |  |
| created_at | datetime2 | No |  | sysutcdatetime |

**Restricciones:**

- `ck_aud_detalle`: `CHECK ([detalle] IS NULL OR isjson([detalle])=(1))`
