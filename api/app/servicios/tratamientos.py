"""Servicio de tratamientos y seguimiento médico."""
from flask import Blueprint, jsonify, request

from .. import db
from ..errores import ApiError
from ..seguridad import perfil, requiere, rol_actual, usuario_actual
from ..validacion import cuerpo, entero, fecha, texto

bp = Blueprint("tratamientos", __name__, url_prefix="/api")

SQL_TRATAMIENTOS = """
SELECT t.tratamiento_id, t.paciente_id, CONCAT(pp.nombres, ' ', pp.apellidos) AS paciente, pp.cedula,
       t.medico_id, CONCAT(pm.nombres, ' ', pm.apellidos) AS medico, t.solicitud_id,
       t.diagnostico, t.indicaciones, t.fecha_inicio, t.fecha_fin, t.estado, t.created_at
FROM {e}.tratamiento t
JOIN {e}.paciente pa ON pa.paciente_id = t.paciente_id JOIN {e}.persona pp ON pp.persona_id = pa.persona_id
JOIN {e}.medico m ON m.medico_id = t.medico_id JOIN {e}.persona pm ON pm.persona_id = m.persona_id
"""


@bp.post("/tratamientos")
@requiere("MEDICO")
def crear_tratamiento():
    d = cuerpo()
    tratamiento_id = db.ejecutar_sp(
        "sp_registrar_tratamiento", "tratamiento_id", paciente_id=entero(d, "paciente_id"),
        medico_id=perfil("medico_id"), diagnostico=texto(d, "diagnostico", maximo=1000),
        indicaciones=texto(d, "indicaciones", maximo=2000), fecha_inicio=fecha(d, "fecha_inicio"),
        fecha_fin=fecha(d, "fecha_fin", False), solicitud_id=entero(d, "solicitud_id", False),
        usuario_id=usuario_actual()["usuario_id"])
    return jsonify(db.leer_uno(SQL_TRATAMIENTOS + " WHERE t.tratamiento_id = ?", tratamiento_id)), 201


@bp.get("/tratamientos/mios")
@requiere("PACIENTE")
def mis_tratamientos():
    return jsonify(db.leer(SQL_TRATAMIENTOS + " WHERE t.paciente_id = ? ORDER BY t.fecha_inicio DESC", perfil("paciente_id")))


@bp.get("/tratamientos")
@requiere("MEDICO", "ADMIN")
def buscar_tratamientos():
    if request.args.get("paciente_id"):
        return jsonify(db.leer(SQL_TRATAMIENTOS + " WHERE t.paciente_id = ? ORDER BY t.fecha_inicio DESC",
                               request.args.get("paciente_id", type=int)))
    if rol_actual() == "MEDICO":
        return jsonify(db.leer(SQL_TRATAMIENTOS + " WHERE t.medico_id = ? ORDER BY t.fecha_inicio DESC", perfil("medico_id")))
    return jsonify(db.leer(SQL_TRATAMIENTOS + " ORDER BY t.tratamiento_id DESC")[:200])


@bp.patch("/tratamientos/<int:tratamiento_id>")
@requiere("MEDICO")
def actualizar_estado(tratamiento_id: int):
    d = cuerpo()
    estado = texto(d, "estado", maximo=20).upper()
    if estado not in ("ACTIVO", "FINALIZADO", "SUSPENDIDO"):
        raise ApiError("Estado inválido: ACTIVO, FINALIZADO o SUSPENDIDO.", 422, "TIPO_INVALIDO")
    n = db.ejecutar("UPDATE dbo.tratamiento SET estado = ?, fecha_fin = COALESCE(fecha_fin, CASE WHEN ? <> 'ACTIVO' "
                    "THEN CAST(SYSUTCDATETIME() AS DATE) END), updated_at = SYSUTCDATETIME() "
                    "WHERE tratamiento_id = ? AND medico_id = ?", estado, estado, tratamiento_id, perfil("medico_id"))
    if not n:
        raise ApiError("El tratamiento no existe o no es suyo.", 404, "NO_ENCONTRADO")
    return jsonify(db.leer_uno(SQL_TRATAMIENTOS + " WHERE t.tratamiento_id = ?", tratamiento_id))


@bp.post("/observaciones")
@requiere("MEDICO")
def crear_observacion():
    d = cuerpo()
    observacion_id = db.ejecutar_sp(
        "sp_registrar_observacion", "observacion_id", resultado_id=entero(d, "resultado_id"),
        medico_id=perfil("medico_id"), texto=texto(d, "texto", maximo=2000), usuario_id=usuario_actual()["usuario_id"])
    return jsonify(observacion_id=observacion_id), 201
