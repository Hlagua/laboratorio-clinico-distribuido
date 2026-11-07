/* =====================================================================
   05_consultas.sql  -  Consultas que evidencian el funcionamiento.
   ===================================================================== */

-- 1. Personas con más de un rol (ej. médico que también es paciente)
SELECT p.cedula, CONCAT(p.nombres, ' ', p.apellidos) AS persona,
       STRING_AGG(r.codigo, ', ') WITHIN GROUP (ORDER BY r.codigo) AS roles
FROM dbo.persona p
JOIN dbo.usuario u ON u.persona_id = p.persona_id
JOIN dbo.usuario_rol ur ON ur.usuario_id = u.usuario_id
JOIN dbo.rol r ON r.rol_id = ur.rol_id
GROUP BY p.cedula, p.nombres, p.apellidos
HAVING COUNT(*) > 1;

-- 2. Permisos efectivos de un usuario (unión de todos sus roles)
SELECT DISTINCT u.email, pe.codigo AS permiso
FROM dbo.usuario u
JOIN dbo.usuario_rol ur ON ur.usuario_id = u.usuario_id
JOIN dbo.rol_permiso rp ON rp.rol_id = ur.rol_id
JOIN dbo.permiso pe ON pe.permiso_id = rp.permiso_id
WHERE u.email = 'jvillacis@labclinico.test'
ORDER BY permiso;

-- 3. Franjas disponibles de los próximos 3 días
SELECT franja_id, fecha, hora_inicio, capacidad - ocupados AS cupos_libres
FROM dbo.franja_horaria
WHERE activa = 1 AND ocupados < capacidad
  AND fecha BETWEEN CAST(DATEADD(HOUR, -5, SYSUTCDATETIME()) AS DATE) AND DATEADD(DAY, 3, CAST(DATEADD(HOUR, -5, SYSUTCDATETIME()) AS DATE))
ORDER BY fecha, hora_inicio;

-- 4. Resultados de un paciente con valores fuera de rango
SELECT s.codigo, t.nombre AS examen, pe.nombre AS parametro, rv.valor_numerico, rv.valor_texto, rv.unidad,
       rv.valor_ref_min, rv.valor_ref_max, rv.fuera_rango, r.fecha_resultado
FROM dbo.resultado r
JOIN dbo.resultado_valor rv ON rv.resultado_id = r.resultado_id
JOIN dbo.parametro_examen pe ON pe.parametro_id = rv.parametro_id
JOIN dbo.solicitud_detalle d ON d.detalle_id = r.detalle_id
JOIN dbo.tipo_examen t ON t.tipo_examen_id = d.tipo_examen_id
JOIN dbo.solicitud_examen s ON s.solicitud_id = d.solicitud_id
JOIN dbo.paciente pa ON pa.paciente_id = s.paciente_id
JOIN dbo.persona p ON p.persona_id = pa.persona_id
WHERE p.cedula = '1800000011'
ORDER BY s.codigo, t.nombre, pe.orden;

-- 5. Estado de solicitudes y pagos
SELECT s.codigo, CONCAT(p.nombres, ' ', p.apellidos) AS paciente, s.estado AS estado_solicitud, s.total,
       pg.metodo, pg.estado AS estado_pago, pg.monto_reembolsado
FROM dbo.solicitud_examen s
JOIN dbo.paciente pa ON pa.paciente_id = s.paciente_id
JOIN dbo.persona p ON p.persona_id = pa.persona_id
LEFT JOIN dbo.pago pg ON pg.solicitud_id = s.solicitud_id
ORDER BY s.solicitud_id, pg.pago_id;

-- 6. Ingresos netos por día y método
SELECT CAST(confirmado_at AS DATE) AS dia, metodo, COUNT(*) AS pagos,
       SUM(monto) AS bruto, SUM(monto_reembolsado) AS reembolsado, SUM(monto - monto_reembolsado) AS neto
FROM dbo.pago
WHERE estado IN ('APROBADO', 'REEMBOLSO_PARCIAL', 'REEMBOLSADO')
GROUP BY CAST(confirmado_at AS DATE), metodo;

-- 7. Verificación de consistencia de cupos (debe devolver 0 filas).
--    Tras la prueba SIN protección aparecerán diferencias.
SELECT f.franja_id, f.fecha, f.hora_inicio, f.capacidad, f.ocupados,
       COUNT(c.cita_id) AS citas_activas_reales
FROM dbo.franja_horaria f
LEFT JOIN dbo.cita c ON c.franja_id = f.franja_id AND c.estado <> 'CANCELADA'
GROUP BY f.franja_id, f.fecha, f.hora_inicio, f.capacidad, f.ocupados
HAVING f.ocupados <> COUNT(c.cita_id) OR COUNT(c.cita_id) > f.capacidad;

-- 8. Tratamientos activos con médico tratante
SELECT CONCAT(pp.nombres, ' ', pp.apellidos) AS paciente, CONCAT(pm.nombres, ' ', pm.apellidos) AS medico,
       t.diagnostico, t.fecha_inicio, t.fecha_fin
FROM dbo.tratamiento t
JOIN dbo.paciente pa ON pa.paciente_id = t.paciente_id JOIN dbo.persona pp ON pp.persona_id = pa.persona_id
JOIN dbo.medico m ON m.medico_id = t.medico_id JOIN dbo.persona pm ON pm.persona_id = m.persona_id
WHERE t.estado = 'ACTIVO';

-- 9. Últimos eventos de auditoría (qué instancia de API atendió cada operación)
SELECT TOP (20) a.created_at, u.email, a.rol_actuante, a.accion, a.entidad, a.entidad_id, a.instancia_api
FROM dbo.auditoria a
LEFT JOIN dbo.usuario u ON u.usuario_id = a.usuario_id
ORDER BY a.auditoria_id DESC;

-- 10. Change Tracking: versión actual y cambios pendientes desde la versión 0
SELECT CHANGE_TRACKING_CURRENT_VERSION() AS version_actual;
SELECT ct.SYS_CHANGE_VERSION, ct.SYS_CHANGE_OPERATION, ct.cita_id
FROM CHANGETABLE(CHANGES dbo.cita, 0) AS ct
ORDER BY ct.SYS_CHANGE_VERSION;
