"""Servicio de exámenes y resultados: catálogo, solicitudes, resultados y PDF."""
import json

from flask import Blueprint, Response, jsonify, request

from .. import config, db
from ..errores import ApiError, no_encontrado, prohibido
from ..pdf import pdf_resultados
from ..seguridad import perfil, requiere, rol_actual, usuario_actual
from ..validacion import cuerpo, entero, lista_enteros, texto

bp = Blueprint("examenes", __name__, url_prefix="/api")

SQL_SOLICITUDES = """
SELECT s.solicitud_id, s.codigo, s.estado, s.total, s.observaciones, s.created_at, s.cita_id,
       pa.paciente_id, p.cedula, CONCAT(p.nombres, ' ', p.apellidos) AS paciente,
       s.medico_id, CONCAT(pm.nombres, ' ', pm.apellidos) AS medico
FROM {e}.solicitud_examen s
JOIN {e}.paciente pa ON pa.paciente_id = s.paciente_id
JOIN {e}.persona p ON p.persona_id = pa.persona_id
LEFT JOIN {e}.medico m ON m.medico_id = s.medico_id
LEFT JOIN {e}.persona pm ON pm.persona_id = m.persona_id
"""


# ------------------------------ catálogo ------------------------------
@bp.get("/examenes/catalogo")
def catalogo():
    """Público: exámenes activos con sus parámetros y rangos de referencia."""
    tipos = db.leer("""
        SELECT t.tipo_examen_id, t.codigo, t.nombre, t.descripcion, t.tipo_muestra, t.precio, t.requiere_ayuno,
               t.indicaciones, t.tiempo_entrega_horas, c.nombre AS categoria
        FROM {e}.tipo_examen t JOIN {e}.categoria_examen c ON c.categoria_id = t.categoria_id
        WHERE t.activo = ? ORDER BY c.nombre, t.nombre""", True)
    parametros = db.leer("SELECT parametro_id, tipo_examen_id, nombre, unidad, valor_ref_min, valor_ref_max, "
                         "valor_ref_texto FROM {e}.parametro_examen ORDER BY tipo_examen_id, orden")
    for t in tipos:
        t["parametros"] = [{k: v for k, v in p.items() if k != "tipo_examen_id"}
                           for p in parametros if p["tipo_examen_id"] == t["tipo_examen_id"]]
    return jsonify(tipos)


@bp.post("/examenes/catalogo")
@requiere("ADMIN")
def crear_tipo_examen():
    """Agrega un examen al catálogo con sus parámetros, en una sola transacción."""
    d = cuerpo()
    parametros = d.get("parametros") or []
    if not isinstance(parametros, list) or not parametros:
        raise ApiError("Envíe al menos un parámetro.", 422, "CAMPO_REQUERIDO")
    tipo_id = db.ejecutar_sp(
        "sp_crear_tipo_examen", "tipo_examen_id",
        categoria=texto(d, "categoria", maximo=80), codigo=texto(d, "codigo", maximo=20).upper(),
        nombre=texto(d, "nombre", maximo=120), descripcion=texto(d, "descripcion", False),
        tipo_muestra=texto(d, "tipo_muestra", maximo=50), precio=d.get("precio"),
        requiere_ayuno=bool(d.get("requiere_ayuno")), indicaciones=texto(d, "indicaciones", False),
        tiempo_entrega_horas=entero(d, "tiempo_entrega_horas", False) or 24,
        parametros=json.dumps(parametros), usuario_id=usuario_actual()["usuario_id"])
    return jsonify(tipo_examen_id=tipo_id), 201


# ------------------------------ solicitudes ------------------------------
@bp.post("/solicitudes")
@requiere("PACIENTE", "MEDICO", "LABORATORISTA")
def crear_solicitud():
    d = cuerpo()
    rol = rol_actual()
    if rol == "PACIENTE":
        paciente_id = perfil("paciente_id")
    else:
        paciente_id = entero(d, "paciente_id")
    medico_id = perfil("medico_id") if rol == "MEDICO" else None
    solicitud_id = db.ejecutar_sp(
        "sp_crear_solicitud", "solicitud_id", paciente_id=paciente_id,
        examenes=json.dumps(lista_enteros(d, "examenes")), medico_id=medico_id,
        cita_id=entero(d, "cita_id", False), observaciones=texto(d, "observaciones", False),
        usuario_id=usuario_actual()["usuario_id"])
    return jsonify(obtener_solicitud(solicitud_id)), 201


@bp.get("/solicitudes/mias")
@requiere("PACIENTE")
def mis_solicitudes():
    return jsonify(db.leer(SQL_SOLICITUDES + " WHERE s.paciente_id = ? ORDER BY s.solicitud_id DESC", perfil("paciente_id")))


@bp.get("/solicitudes")
@requiere("LABORATORISTA", "MEDICO", "ADMIN")
def buscar_solicitudes():
    condiciones, params = [], []
    if request.args.get("estado"):
        condiciones.append("s.estado = ?")
        params.append(request.args["estado"].upper())
    if request.args.get("cedula"):
        condiciones.append("p.cedula = ?")
        params.append(request.args["cedula"])
    if request.args.get("codigo"):
        condiciones.append("s.codigo = ?")
        params.append(request.args["codigo"].upper())
    if rol_actual() == "MEDICO" and request.args.get("propias") == "1":
        condiciones.append("s.medico_id = ?")
        params.append(perfil("medico_id"))
    sql = SQL_SOLICITUDES + (" WHERE " + " AND ".join(condiciones) if condiciones else "")
    return jsonify(db.leer(sql + " ORDER BY s.solicitud_id DESC", *params)[:200])


def obtener_solicitud(solicitud_id: int, codigo: str | None = None) -> dict:
    """Solicitud completa: cabecera, exámenes, resultados, valores y observaciones."""
    s = db.leer_uno(SQL_SOLICITUDES + (" WHERE s.codigo = ?" if codigo else " WHERE s.solicitud_id = ?"),
                    codigo or solicitud_id)
    if not s:
        raise no_encontrado("La solicitud")
    detalles = db.leer("""
        SELECT d.detalle_id, d.estado, d.precio_unitario, t.tipo_examen_id, t.codigo, t.nombre AS examen,
               r.resultado_id, r.fecha_resultado, r.observaciones AS observaciones_laboratorio,
               CONCAT(pl.nombres, ' ', pl.apellidos) AS laboratorista
        FROM {e}.solicitud_detalle d
        JOIN {e}.tipo_examen t ON t.tipo_examen_id = d.tipo_examen_id
        LEFT JOIN {e}.resultado r ON r.detalle_id = d.detalle_id
        LEFT JOIN {e}.laboratorista l ON l.laboratorista_id = r.laboratorista_id
        LEFT JOIN {e}.persona pl ON pl.persona_id = l.persona_id
        WHERE d.solicitud_id = ? ORDER BY d.detalle_id""", s["solicitud_id"])
    valores = db.leer("""
        SELECT rv.resultado_id, pm.parametro_id, pm.nombre AS parametro, rv.valor_numerico, rv.valor_texto, rv.unidad,
               rv.valor_ref_min, rv.valor_ref_max, rv.valor_ref_texto, rv.fuera_rango
        FROM {e}.resultado_valor rv
        JOIN {e}.parametro_examen pm ON pm.parametro_id = rv.parametro_id
        JOIN {e}.resultado r ON r.resultado_id = rv.resultado_id
        JOIN {e}.solicitud_detalle d ON d.detalle_id = r.detalle_id
        WHERE d.solicitud_id = ? ORDER BY pm.orden""", s["solicitud_id"])
    observaciones = db.leer("""
        SELECT o.observacion_id, o.resultado_id, o.texto, o.created_at, CONCAT(pm.nombres, ' ', pm.apellidos) AS medico
        FROM {e}.observacion_medica o
        JOIN {e}.medico m ON m.medico_id = o.medico_id
        JOIN {e}.persona pm ON pm.persona_id = m.persona_id
        JOIN {e}.resultado r ON r.resultado_id = o.resultado_id
        JOIN {e}.solicitud_detalle d ON d.detalle_id = r.detalle_id
        WHERE d.solicitud_id = ? ORDER BY o.created_at""", s["solicitud_id"])
    for d in detalles:
        d["valores"] = [{k: v for k, v in x.items() if k != "resultado_id"}
                        for x in valores if d["resultado_id"] and x["resultado_id"] == d["resultado_id"]]
        d["observaciones_medicas"] = [o for o in observaciones if d["resultado_id"] and o["resultado_id"] == d["resultado_id"]]
    s["examenes"] = detalles
    return s


def _verificar_acceso(solicitud: dict):
    """El paciente solo ve lo suyo; el personal ve todo."""
    if rol_actual() == "PACIENTE" and solicitud["paciente_id"] != perfil("paciente_id"):
        raise prohibido("Solo puede consultar sus propias solicitudes.")


@bp.get("/solicitudes/<int:solicitud_id>")
@requiere("PACIENTE", "LABORATORISTA", "MEDICO", "ADMIN")
def ver_solicitud(solicitud_id: int):
    s = obtener_solicitud(solicitud_id)
    _verificar_acceso(s)
    return jsonify(s)


@bp.get("/solicitudes/<int:solicitud_id>/pdf")
@requiere("PACIENTE", "LABORATORISTA", "MEDICO", "ADMIN")
def pdf_solicitud(solicitud_id: int):
    s = obtener_solicitud(solicitud_id)
    _verificar_acceso(s)
    if not any(d["resultado_id"] for d in s["examenes"]):
        raise ApiError("La solicitud aún no tiene resultados.", 409, "SIN_RESULTADOS")
    return Response(pdf_resultados(s), mimetype="application/pdf",
                    headers={"Content-Disposition": f'attachment; filename="resultados-{s["codigo"]}.pdf"'})


# ------------------------------ resultados ------------------------------
@bp.post("/resultados")
@requiere("LABORATORISTA")
def registrar_resultado():
    d = cuerpo()
    valores = d.get("valores")
    if not isinstance(valores, list) or not valores:
        raise ApiError("Envíe 'valores': [{parametro_id, valor | texto}].", 422, "CAMPO_REQUERIDO")
    for v in valores:
        if not isinstance(v, dict) or not isinstance(v.get("parametro_id"), int) or (v.get("valor") is None and not v.get("texto")):
            raise ApiError("Cada valor requiere parametro_id y 'valor' numérico o 'texto'.", 422, "TIPO_INVALIDO")
    resultado_id = db.ejecutar_sp(
        "sp_registrar_resultado", "resultado_id", detalle_id=entero(d, "detalle_id"),
        laboratorista_id=perfil("laboratorista_id"), valores=json.dumps(valores),
        observaciones=texto(d, "observaciones", False, 1000), usuario_id=usuario_actual()["usuario_id"],
        instancia_api=config.INSTANCIA)
    return jsonify(resultado_id=resultado_id), 201


@bp.post("/solicitudes/detalle/<int:detalle_id>/muestra")
@requiere("LABORATORISTA")
def registrar_muestra(detalle_id: int):
    n = db.ejecutar("""
        UPDATE d SET estado = 'MUESTRA_TOMADA', muestra_tomada_at = SYSUTCDATETIME(), laboratorista_id = ?, updated_at = SYSUTCDATETIME()
        FROM dbo.solicitud_detalle d JOIN dbo.solicitud_examen s ON s.solicitud_id = d.solicitud_id
        WHERE d.detalle_id = ? AND d.estado = 'PENDIENTE' AND s.estado IN ('PAGADA', 'EN_PROCESO')""",
        perfil("laboratorista_id"), detalle_id)
    if not n:
        raise ApiError("El examen no existe, no está pagado o la muestra ya fue registrada.", 409, "ESTADO_INVALIDO")
    return jsonify(mensaje="Toma de muestra registrada.", detalle_id=detalle_id)
