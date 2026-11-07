/* =====================================================================
   04_datos_prueba.sql  -  Datos FICTICIOS para simular el laboratorio.
   Usa los procedimientos almacenados siempre que es posible, así la
   auditoría y Change Tracking registran las operaciones igual que en
   producción.
   Contraseña de todos los usuarios de prueba: Lab2026*
   ===================================================================== */

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET XACT_ABORT ON;
GO

DECLARE @hash VARCHAR(255) = '$2b$12$kIoBv27ABwFFvJrrIPMuruQwTnWHgH/QTXUYDBApHRrhYWRV4cBaq';

/* ---------------- Roles y permisos ---------------- */
INSERT INTO dbo.rol (codigo, nombre, descripcion) VALUES
 ('PACIENTE',      N'Paciente',        N'Reserva citas, paga y consulta sus resultados'),
 ('LABORATORISTA', N'Laboratorista',   N'Registra muestras y resultados'),
 ('MEDICO',        N'Médico tratante', N'Revisa resultados, registra observaciones y tratamientos'),
 ('ADMIN',         N'Administrador',   N'Gestiona usuarios, catálogo, reembolsos y reportes');

INSERT INTO dbo.permiso (codigo, descripcion) VALUES
 ('cita:reservar',          N'Reservar y cancelar citas propias'),
 ('cita:gestionar',         N'Ver y gestionar todas las citas'),
 ('resultado:ver_propio',   N'Ver resultados propios'),
 ('resultado:ver_todos',    N'Ver resultados de cualquier paciente'),
 ('resultado:registrar',    N'Registrar resultados de exámenes'),
 ('solicitud:crear',        N'Crear solicitudes de exámenes'),
 ('pago:realizar',          N'Pagar solicitudes propias'),
 ('pago:reembolsar',        N'Emitir reembolsos'),
 ('tratamiento:gestionar',  N'Registrar observaciones y tratamientos'),
 ('catalogo:gestionar',     N'Administrar tipos de examen y franjas'),
 ('usuario:gestionar',      N'Administrar usuarios y roles'),
 ('reporte:ver',            N'Ver y descargar reportes');

INSERT INTO dbo.rol_permiso (rol_id, permiso_id)
SELECT r.rol_id, p.permiso_id
FROM (VALUES
  ('PACIENTE','cita:reservar'), ('PACIENTE','resultado:ver_propio'), ('PACIENTE','pago:realizar'), ('PACIENTE','solicitud:crear'),
  ('LABORATORISTA','cita:gestionar'), ('LABORATORISTA','resultado:ver_todos'), ('LABORATORISTA','resultado:registrar'), ('LABORATORISTA','solicitud:crear'),
  ('MEDICO','resultado:ver_todos'), ('MEDICO','solicitud:crear'), ('MEDICO','tratamiento:gestionar'), ('MEDICO','reporte:ver'),
  ('ADMIN','cita:gestionar'), ('ADMIN','resultado:ver_todos'), ('ADMIN','pago:reembolsar'), ('ADMIN','catalogo:gestionar'),
  ('ADMIN','usuario:gestionar'), ('ADMIN','reporte:ver')
) x(rol, permiso)
JOIN dbo.rol r ON r.codigo = x.rol
JOIN dbo.permiso p ON p.codigo = x.permiso;

/* ---------------- Personal (admin, laboratoristas, médicos) ---------------- */
INSERT INTO dbo.persona (cedula, nombres, apellidos, fecha_nacimiento, sexo, telefono, email, direccion) VALUES
 ('1800000001', N'Ana',     N'Torres Ruiz',      '1985-03-12', 'F', '0990000001', 'admin@labclinico.test',      N'Ambato, Av. Cevallos'),
 ('1800000002', N'Carlos',  N'Mena Salazar',     '1990-07-25', 'M', '0990000002', 'cmena@labclinico.test',      N'Ambato, Ficoa'),
 ('1800000003', N'Lucía',   N'Paredes Gómez',    '1993-11-02', 'F', '0990000003', 'lparedes@labclinico.test',   N'Ambato, Huachi'),
 ('1800000004', N'Jorge',   N'Villacís Andrade', '1978-01-30', 'M', '0990000004', 'jvillacis@labclinico.test',  N'Ambato, Atocha'),
 ('1800000005', N'María',   N'Sánchez Lara',     '1982-09-14', 'F', '0990000005', 'msanchez@labclinico.test',   N'Ambato, Izamba');

INSERT INTO dbo.usuario (persona_id, email, password_hash)
SELECT persona_id, email, @hash FROM dbo.persona WHERE cedula IN ('1800000001','1800000002','1800000003','1800000004','1800000005');

DECLARE @u_admin BIGINT = (SELECT u.usuario_id FROM dbo.usuario u JOIN dbo.persona p ON p.persona_id = u.persona_id WHERE p.cedula = '1800000001');
DECLARE @u_lab1  BIGINT = (SELECT u.usuario_id FROM dbo.usuario u JOIN dbo.persona p ON p.persona_id = u.persona_id WHERE p.cedula = '1800000002');
DECLARE @u_lab2  BIGINT = (SELECT u.usuario_id FROM dbo.usuario u JOIN dbo.persona p ON p.persona_id = u.persona_id WHERE p.cedula = '1800000003');
DECLARE @u_med1  BIGINT = (SELECT u.usuario_id FROM dbo.usuario u JOIN dbo.persona p ON p.persona_id = u.persona_id WHERE p.cedula = '1800000004');
DECLARE @u_med2  BIGINT = (SELECT u.usuario_id FROM dbo.usuario u JOIN dbo.persona p ON p.persona_id = u.persona_id WHERE p.cedula = '1800000005');

EXEC dbo.sp_asignar_rol @usuario_id = @u_admin, @rol_codigo = 'ADMIN';
EXEC dbo.sp_asignar_rol @usuario_id = @u_lab1, @rol_codigo = 'LABORATORISTA', @registro_profesional = 'LAB-1001', @especialidad_o_area = N'Hematología', @admin_id = @u_admin;
EXEC dbo.sp_asignar_rol @usuario_id = @u_lab2, @rol_codigo = 'LABORATORISTA', @registro_profesional = 'LAB-1002', @especialidad_o_area = N'Química clínica', @admin_id = @u_admin;
EXEC dbo.sp_asignar_rol @usuario_id = @u_med1, @rol_codigo = 'MEDICO', @registro_profesional = 'MED-2001', @especialidad_o_area = N'Medicina interna', @admin_id = @u_admin;
EXEC dbo.sp_asignar_rol @usuario_id = @u_med2, @rol_codigo = 'MEDICO', @registro_profesional = 'MED-2002', @especialidad_o_area = N'Endocrinología', @admin_id = @u_admin;
-- Caso multirol: el Dr. Villacís también se atiende como PACIENTE.
EXEC dbo.sp_asignar_rol @usuario_id = @u_med1, @rol_codigo = 'PACIENTE', @admin_id = @u_admin;

/* ---------------- Pacientes (con cuenta en el portal) ---------------- */
DECLARE @pid BIGINT;
EXEC dbo.sp_registrar_paciente '1800000011', N'Pedro',   N'Castillo Vega',   '1995-04-18', 'M', '0990000011', 'pedro.castillo@correo.test',  N'Ambato', @hash, 'O+',  NULL,                 @pid OUTPUT;
EXEC dbo.sp_registrar_paciente '1800000012', N'Sofía',   N'Navarrete Cruz',  '2000-12-05', 'F', '0990000012', 'sofia.navarrete@correo.test', N'Ambato', @hash, 'A+',  N'Penicilina',        @pid OUTPUT;
EXEC dbo.sp_registrar_paciente '1800000013', N'Luis',    N'Chávez Ortiz',    '1968-06-21', 'M', '0990000013', 'luis.chavez@correo.test',     N'Pelileo', @hash, 'B+', NULL,                 @pid OUTPUT;
EXEC dbo.sp_registrar_paciente '1800000014', N'Gabriela',N'Ríos Medina',     '1988-02-27', 'F', '0990000014', 'gabriela.rios@correo.test',   N'Baños',  @hash, 'O-',  N'Ibuprofeno',        @pid OUTPUT;
EXEC dbo.sp_registrar_paciente '1800000015', N'Andrés',  N'Pazmiño León',    '1975-10-09', 'M', '0990000015', 'andres.pazmino@correo.test',  N'Ambato', @hash, 'AB+', NULL,                 @pid OUTPUT;
-- Paciente registrado en ventanilla, sin cuenta en el portal.
EXEC dbo.sp_registrar_paciente '1800000016', N'Rosa',    N'Guamán Pilla',    '1955-08-03', 'F', '0990000016', 'rosa.guaman@correo.test',     N'Quero',  NULL,  NULL,  NULL,                 @pid OUTPUT;

/* ---------------- Catálogo de exámenes ---------------- */
INSERT INTO dbo.categoria_examen (nombre, descripcion) VALUES
 (N'Hematología',       N'Estudio de la sangre y sus componentes'),
 (N'Química sanguínea', N'Metabolitos y función de órganos'),
 (N'Uroanálisis',       N'Examen de orina'),
 (N'Inmunología',       N'Hormonas y marcadores inflamatorios');

INSERT INTO dbo.tipo_examen (categoria_id, codigo, nombre, descripcion, tipo_muestra, precio, requiere_ayuno, indicaciones, tiempo_entrega_horas)
SELECT c.categoria_id, x.codigo, x.nombre, x.descripcion, x.muestra, x.precio, x.ayuno, x.indicaciones, x.horas
FROM (VALUES
 (N'Hematología',       'HEM-BH',  N'Biometría hemática',  N'Conteo completo de células sanguíneas', N'Sangre', 8.00,  0, NULL,                                  12),
 (N'Química sanguínea', 'QS-GLU',  N'Glucosa en ayunas',   N'Nivel de glucosa en sangre',            N'Sangre', 3.50,  1, N'Ayuno de 8 a 12 horas',               6),
 (N'Química sanguínea', 'QS-LIP',  N'Perfil lipídico',     N'Colesterol y triglicéridos',            N'Sangre', 15.00, 1, N'Ayuno de 12 horas',                   24),
 (N'Química sanguínea', 'QS-CRE',  N'Creatinina',          N'Función renal',                         N'Sangre', 4.00,  0, NULL,                                  12),
 (N'Química sanguínea', 'QS-URE',  N'Urea',                N'Función renal',                         N'Sangre', 4.00,  0, NULL,                                  12),
 (N'Uroanálisis',       'UR-EMO',  N'Examen de orina (EMO)', N'Análisis físico-químico de orina',    N'Orina',  5.00,  0, N'Primera orina de la mañana',          12),
 (N'Inmunología',       'IN-TSH',  N'TSH',                 N'Hormona estimulante de tiroides',       N'Sangre', 12.00, 0, NULL,                                  48),
 (N'Inmunología',       'IN-PCR',  N'Proteína C reactiva', N'Marcador de inflamación',               N'Sangre', 9.00,  0, NULL,                                  24)
) x(categoria, codigo, nombre, descripcion, muestra, precio, ayuno, indicaciones, horas)
JOIN dbo.categoria_examen c ON c.nombre = x.categoria;

INSERT INTO dbo.parametro_examen (tipo_examen_id, nombre, unidad, valor_ref_min, valor_ref_max, valor_ref_texto, orden)
SELECT t.tipo_examen_id, x.nombre, x.unidad, x.vmin, x.vmax, x.vtexto, x.orden
FROM (VALUES
 ('HEM-BH', N'Hemoglobina',         N'g/dL',       12.0,  17.5,  NULL,          1),
 ('HEM-BH', N'Hematocrito',         N'%',          36.0,  52.0,  NULL,          2),
 ('HEM-BH', N'Leucocitos',          N'x10^3/uL',   4.5,   11.0,  NULL,          3),
 ('HEM-BH', N'Plaquetas',           N'x10^3/uL',   150.0, 450.0, NULL,          4),
 ('QS-GLU', N'Glucosa',             N'mg/dL',      70.0,  100.0, NULL,          1),
 ('QS-LIP', N'Colesterol total',    N'mg/dL',      0.0,   200.0, NULL,          1),
 ('QS-LIP', N'HDL',                 N'mg/dL',      40.0,  60.0,  NULL,          2),
 ('QS-LIP', N'LDL',                 N'mg/dL',      0.0,   130.0, NULL,          3),
 ('QS-LIP', N'Triglicéridos',       N'mg/dL',      0.0,   150.0, NULL,          4),
 ('QS-CRE', N'Creatinina',          N'mg/dL',      0.6,   1.3,   NULL,          1),
 ('QS-URE', N'Urea',                N'mg/dL',      15.0,  45.0,  NULL,          1),
 ('UR-EMO', N'Color',               NULL,          NULL,  NULL,  N'Amarillo',   1),
 ('UR-EMO', N'pH',                  NULL,          5.0,   8.0,   NULL,          2),
 ('UR-EMO', N'Densidad',            NULL,          1.005, 1.030, NULL,          3),
 ('UR-EMO', N'Proteínas',           NULL,          NULL,  NULL,  N'Negativo',   4),
 ('IN-TSH', N'TSH',                 N'mUI/L',      0.4,   4.0,   NULL,          1),
 ('IN-PCR', N'PCR',                 N'mg/L',       0.0,   5.0,   NULL,          1)
) x(codigo, nombre, unidad, vmin, vmax, vtexto, orden)
JOIN dbo.tipo_examen t ON t.codigo = x.codigo;

/* ---------------- Franjas: próximos 14 días (lun-sáb, 07:00-11:00 cada 30 min) ---------------- */
DECLARE @hoy DATE = CAST(DATEADD(HOUR, -5, SYSUTCDATETIME()) AS DATE);   -- hora de Ecuador
;WITH dias AS (
    SELECT TOP (14) DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY (SELECT NULL)), @hoy) AS fecha
    FROM sys.all_objects
), horas AS (
    SELECT TOP (8) DATEADD(MINUTE, 30 * (ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1), CAST('07:00' AS TIME(0))) AS hora
    FROM sys.all_objects
)
INSERT INTO dbo.franja_horaria (fecha, hora_inicio, hora_fin, capacidad)
SELECT d.fecha, h.hora, DATEADD(MINUTE, 30, h.hora), 3
FROM dias d CROSS JOIN horas h
WHERE DATEDIFF(DAY, '19000101', d.fecha) % 7 <> 6;   -- 1900-01-01 fue lunes: excluye domingos

/* ---------------- Flujo completo de ejemplo ---------------- */
DECLARE @pac_pedro BIGINT = (SELECT pa.paciente_id FROM dbo.paciente pa JOIN dbo.persona p ON p.persona_id = pa.persona_id WHERE p.cedula = '1800000011');
DECLARE @pac_sofia BIGINT = (SELECT pa.paciente_id FROM dbo.paciente pa JOIN dbo.persona p ON p.persona_id = pa.persona_id WHERE p.cedula = '1800000012');
DECLARE @pac_luis  BIGINT = (SELECT pa.paciente_id FROM dbo.paciente pa JOIN dbo.persona p ON p.persona_id = pa.persona_id WHERE p.cedula = '1800000013');
DECLARE @pac_gaby  BIGINT = (SELECT pa.paciente_id FROM dbo.paciente pa JOIN dbo.persona p ON p.persona_id = pa.persona_id WHERE p.cedula = '1800000014');
DECLARE @pac_rosa  BIGINT = (SELECT pa.paciente_id FROM dbo.paciente pa JOIN dbo.persona p ON p.persona_id = pa.persona_id WHERE p.cedula = '1800000016');
DECLARE @pac_jorge BIGINT = (SELECT pa.paciente_id FROM dbo.paciente pa JOIN dbo.persona p ON p.persona_id = pa.persona_id WHERE p.cedula = '1800000004');
DECLARE @med_jorge BIGINT = (SELECT m.medico_id FROM dbo.medico m JOIN dbo.persona p ON p.persona_id = m.persona_id WHERE p.cedula = '1800000004');
DECLARE @med_maria BIGINT = (SELECT m.medico_id FROM dbo.medico m JOIN dbo.persona p ON p.persona_id = m.persona_id WHERE p.cedula = '1800000005');
DECLARE @lab_carlos BIGINT = (SELECT l.laboratorista_id FROM dbo.laboratorista l JOIN dbo.persona p ON p.persona_id = l.persona_id WHERE p.cedula = '1800000002');
DECLARE @lab_lucia  BIGINT = (SELECT l.laboratorista_id FROM dbo.laboratorista l JOIN dbo.persona p ON p.persona_id = l.persona_id WHERE p.cedula = '1800000003');

DECLARE @t_bh INT  = (SELECT tipo_examen_id FROM dbo.tipo_examen WHERE codigo = 'HEM-BH');
DECLARE @t_glu INT = (SELECT tipo_examen_id FROM dbo.tipo_examen WHERE codigo = 'QS-GLU');
DECLARE @t_lip INT = (SELECT tipo_examen_id FROM dbo.tipo_examen WHERE codigo = 'QS-LIP');
DECLARE @t_tsh INT = (SELECT tipo_examen_id FROM dbo.tipo_examen WHERE codigo = 'IN-TSH');
DECLARE @t_emo INT = (SELECT tipo_examen_id FROM dbo.tipo_examen WHERE codigo = 'UR-EMO');

DECLARE @franja1 BIGINT = (SELECT MIN(franja_id) FROM dbo.franja_horaria);
DECLARE @franja2 BIGINT = @franja1 + 1;

DECLARE @cita BIGINT, @sol BIGINT, @pago BIGINT, @det BIGINT, @res BIGINT, @reemb BIGINT, @vals NVARCHAR(MAX), @exs NVARCHAR(100);

-- 1) Pedro: cita + biometría + glucosa, pago aprobado, resultados completos.
EXEC dbo.sp_reservar_cita @paciente_id = @pac_pedro, @franja_id = @franja1, @motivo = N'Chequeo anual', @cita_id = @cita OUTPUT;
SET @exs = CONCAT('[', @t_bh, ',', @t_glu, ']');
EXEC dbo.sp_crear_solicitud @paciente_id = @pac_pedro, @examenes = @exs, @medico_id = @med_jorge, @cita_id = @cita, @solicitud_id = @sol OUTPUT;
EXEC dbo.sp_crear_pago @solicitud_id = @sol, @metodo = 'STRIPE', @stripe_checkout_session_id = 'cs_test_seed_0001', @pago_id = @pago OUTPUT;
EXEC dbo.sp_confirmar_pago @pago_id = @pago, @aprobado = 1, @stripe_payment_intent_id = 'pi_test_seed_0001';

SET @det = (SELECT detalle_id FROM dbo.solicitud_detalle WHERE solicitud_id = @sol AND tipo_examen_id = @t_bh);
SET @vals = (SELECT p.parametro_id, v.valor FROM (VALUES (N'Hemoglobina',14.8),(N'Hematocrito',44.0),(N'Leucocitos',7.2),(N'Plaquetas',260.0)) v(nombre, valor)
             JOIN dbo.parametro_examen p ON p.nombre = v.nombre AND p.tipo_examen_id = @t_bh FOR JSON PATH);
EXEC dbo.sp_registrar_resultado @detalle_id = @det, @laboratorista_id = @lab_carlos, @valores = @vals, @resultado_id = @res OUTPUT;

SET @det = (SELECT detalle_id FROM dbo.solicitud_detalle WHERE solicitud_id = @sol AND tipo_examen_id = @t_glu);
SET @vals = (SELECT p.parametro_id, v.valor FROM (VALUES (N'Glucosa',118.0)) v(nombre, valor)
             JOIN dbo.parametro_examen p ON p.nombre = v.nombre AND p.tipo_examen_id = @t_glu FOR JSON PATH);
EXEC dbo.sp_registrar_resultado @detalle_id = @det, @laboratorista_id = @lab_lucia, @valores = @vals,
     @observaciones = N'Glucosa elevada, se sugiere control.', @resultado_id = @res OUTPUT;

DECLARE @obs BIGINT, @trat BIGINT, @fin DATE = DATEADD(MONTH, 3, @hoy);
EXEC dbo.sp_registrar_observacion @resultado_id = @res, @medico_id = @med_jorge, @usuario_id = @u_med1,
     @texto = N'Glucosa en ayunas sobre el rango. Solicitar hemoglobina glicosilada y control en 3 meses.', @observacion_id = @obs OUTPUT;
EXEC dbo.sp_registrar_tratamiento @paciente_id = @pac_pedro, @medico_id = @med_jorge, @solicitud_id = @sol, @usuario_id = @u_med1,
     @diagnostico = N'Glucosa alterada en ayunas', @indicaciones = N'Dieta baja en azúcares, actividad física 30 min diarios, control en 3 meses.',
     @fecha_inicio = @hoy, @fecha_fin = @fin, @tratamiento_id = @trat OUTPUT;

-- 2) Dr. Villacís como PACIENTE: perfil lipídico ordenado por la Dra. Sánchez.
SET @exs = CONCAT('[', @t_lip, ']');
EXEC dbo.sp_crear_solicitud @paciente_id = @pac_jorge, @examenes = @exs, @medico_id = @med_maria, @solicitud_id = @sol OUTPUT;
EXEC dbo.sp_crear_pago @solicitud_id = @sol, @metodo = 'STRIPE', @stripe_checkout_session_id = 'cs_test_seed_0002', @pago_id = @pago OUTPUT;
EXEC dbo.sp_confirmar_pago @pago_id = @pago, @aprobado = 1, @stripe_payment_intent_id = 'pi_test_seed_0002';
SET @det = (SELECT detalle_id FROM dbo.solicitud_detalle WHERE solicitud_id = @sol);
SET @vals = (SELECT p.parametro_id, v.valor FROM (VALUES (N'Colesterol total',228.0),(N'HDL',38.0),(N'LDL',152.0),(N'Triglicéridos',190.0)) v(nombre, valor)
             JOIN dbo.parametro_examen p ON p.nombre = v.nombre AND p.tipo_examen_id = @t_lip FOR JSON PATH);
EXEC dbo.sp_registrar_resultado @detalle_id = @det, @laboratorista_id = @lab_lucia, @valores = @vals, @resultado_id = @res OUTPUT;
EXEC dbo.sp_registrar_tratamiento @paciente_id = @pac_jorge, @medico_id = @med_maria, @solicitud_id = @sol, @usuario_id = @u_med2,
     @diagnostico = N'Dislipidemia mixta', @indicaciones = N'Atorvastatina 20 mg cada noche. Repetir perfil lipídico en 8 semanas.',
     @fecha_inicio = @hoy, @tratamiento_id = @trat OUTPUT;

-- 3) Sofía: pago rechazado (tarjeta declinada en Stripe), luego reintento aprobado, resultados en proceso.
EXEC dbo.sp_reservar_cita @paciente_id = @pac_sofia, @franja_id = @franja1, @motivo = N'Control tiroideo', @cita_id = @cita OUTPUT;
SET @exs = CONCAT('[', @t_tsh, ',', @t_bh, ']');
EXEC dbo.sp_crear_solicitud @paciente_id = @pac_sofia, @examenes = @exs, @medico_id = @med_maria, @cita_id = @cita, @solicitud_id = @sol OUTPUT;
EXEC dbo.sp_crear_pago @solicitud_id = @sol, @metodo = 'STRIPE', @stripe_checkout_session_id = 'cs_test_seed_0003', @pago_id = @pago OUTPUT;
EXEC dbo.sp_confirmar_pago @pago_id = @pago, @aprobado = 0, @stripe_payment_intent_id = 'pi_test_seed_0003', @motivo_rechazo = N'card_declined: fondos insuficientes';
EXEC dbo.sp_crear_pago @solicitud_id = @sol, @metodo = 'STRIPE', @stripe_checkout_session_id = 'cs_test_seed_0004', @pago_id = @pago OUTPUT;
EXEC dbo.sp_confirmar_pago @pago_id = @pago, @aprobado = 1, @stripe_payment_intent_id = 'pi_test_seed_0004';
SET @det = (SELECT detalle_id FROM dbo.solicitud_detalle WHERE solicitud_id = @sol AND tipo_examen_id = @t_bh);
SET @vals = (SELECT p.parametro_id, v.valor FROM (VALUES (N'Hemoglobina',11.4),(N'Hematocrito',35.0),(N'Leucocitos',6.1),(N'Plaquetas',310.0)) v(nombre, valor)
             JOIN dbo.parametro_examen p ON p.nombre = v.nombre AND p.tipo_examen_id = @t_bh FOR JSON PATH);
EXEC dbo.sp_registrar_resultado @detalle_id = @det, @laboratorista_id = @lab_carlos, @valores = @vals, @resultado_id = @res OUTPUT;

-- 4) Luis: pago aprobado y luego reembolso parcial (examen no realizado).
SET @exs = CONCAT('[', @t_glu, ',', @t_tsh, ']');
EXEC dbo.sp_crear_solicitud @paciente_id = @pac_luis, @examenes = @exs, @solicitud_id = @sol OUTPUT;
EXEC dbo.sp_crear_pago @solicitud_id = @sol, @metodo = 'STRIPE', @stripe_checkout_session_id = 'cs_test_seed_0005', @pago_id = @pago OUTPUT;
EXEC dbo.sp_confirmar_pago @pago_id = @pago, @aprobado = 1, @stripe_payment_intent_id = 'pi_test_seed_0005';
UPDATE dbo.solicitud_detalle SET estado = 'ANULADO', updated_at = SYSUTCDATETIME() WHERE solicitud_id = @sol AND tipo_examen_id = @t_tsh;
EXEC dbo.sp_registrar_reembolso @pago_id = @pago, @monto = 12.00, @motivo = N'Reactivo de TSH agotado', @stripe_refund_id = 're_test_seed_0001',
     @admin_id = @u_admin, @reembolso_id = @reemb OUTPUT;

-- 5) Rosa (ventanilla, transferencia con QR) y Gabriela (solicitud registrada, pendiente de pago).
SET @exs = CONCAT('[', @t_emo, ']');
EXEC dbo.sp_crear_solicitud @paciente_id = @pac_rosa, @examenes = @exs, @solicitud_id = @sol OUTPUT;
EXEC dbo.sp_crear_pago @solicitud_id = @sol, @metodo = 'TRANSFERENCIA_QR', @referencia_transferencia = 'TRX-000123', @pago_id = @pago OUTPUT;
EXEC dbo.sp_confirmar_pago @pago_id = @pago, @aprobado = 1;
EXEC dbo.sp_reservar_cita @paciente_id = @pac_gaby, @franja_id = @franja2, @motivo = N'Chequeo general', @cita_id = @cita OUTPUT;
SET @exs = CONCAT('[', @t_bh, ',', @t_lip, ']');
EXEC dbo.sp_crear_solicitud @paciente_id = @pac_gaby, @examenes = @exs, @cita_id = @cita, @solicitud_id = @sol OUTPUT;

-- Las notificaciones de la semilla se marcan como enviadas para no disparar correos reales.
UPDATE dbo.notificacion SET estado = 'ENVIADA', enviada_at = SYSUTCDATETIME(), proveedor_msg_id = 'seed', updated_at = SYSUTCDATETIME();
GO
