"""Qué se replica y hacia dónde.

TABLAS_SUPABASE va en orden padre -> hijo (se usa en la carga completa;
en Supabase las FK son diferidas, así que el orden incremental no importa).
"""

TABLAS_SUPABASE = [
    "persona", "usuario", "rol", "permiso", "rol_permiso", "usuario_rol",
    "paciente", "medico", "laboratorista",
    "categoria_examen", "tipo_examen", "parametro_examen",
    "franja_horaria", "cita",
    "laboratorio",          # 12_laboratorios.sql (antes de solicitud_examen, que la referencia)
    "solicitud_examen", "solicitud_detalle", "resultado", "resultado_valor",
    "observacion_medica", "tratamiento",
    "pago", "reembolso",
    # Base de conocimientos para diagnósticos (07_base_conocimiento.sql)
    "diagnostico", "protocolo", "regla_diagnostica", "regla_condicion", "sugerencia_diagnostica",
    # Medicamentos y recetas (08_recetas.sql)
    "medicamento", "diagnostico_medicamento", "receta", "receta_item",
]

# Tablas copiadas 1:1 a MongoDB (tabla -> colección).
COLECCIONES_DIRECTAS = {
    "auditoria": "auditoria",
    "notificacion": "notificaciones",
    "stripe_evento": "stripe_eventos",
}

# Tablas cuyos cambios reconstruyen documentos desnormalizados en Mongo.
TABLAS_RESULTADOS = ["resultado", "resultado_valor", "observacion_medica", "solicitud_examen"]
TABLAS_PAGOS = ["pago", "reembolso"]

TABLAS_MONGO = list(COLECCIONES_DIRECTAS) + TABLAS_RESULTADOS + TABLAS_PAGOS
