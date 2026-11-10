"""Base de conocimientos para diagnósticos: motor de inferencia por reglas.

Las reglas (tabla regla_diagnostica + regla_condicion) relacionan
condiciones sobre los parámetros de laboratorio con un diagnóstico CIE-10.
El motor evalúa las reglas activas sobre los resultados de una solicitud y
registra SUGERENCIAS explicadas; el médico las acepta o las descarta.
El sistema sugiere: el diagnóstico lo decide siempre el médico.
"""
import json
import logging
from datetime import date
from decimal import Decimal

from flask import Blueprint, jsonify, request

from .. import config, db
from ..errores import ApiError, no_encontrado
from ..seguridad import perfil, requiere, usuario_actual
from ..validacion import cuerpo, entero, texto

bp = Blueprint("conocimiento", __name__, url_prefix="/api/conocimiento")
log = logging.getLogger("api")

OPERADORES = {
    "<": lambda v, a, b: v < a,
    "<=": lambda v, a, b: v <= a,
    ">": lambda v, a, b: v > a,
    ">=": lambda v, a, b: v >= a,
    "ENTRE": lambda v, a, b: a <= v <= b,
}
SIMBOLO = {"<": "<", "<=": "≤", ">": ">", ">=": "≥"}


def _num(x) -> str:
    return f"{float(x):g}"


def evaluar_reglas(reglas: list[dict], condiciones: list[dict], valores: dict[int, dict],
                   sexo: str | None, edad: int | None) -> list[dict]:
    """Función pura: devuelve [{regla_id, explicacion}] para las reglas que se cumplen.

    valores: {parametro_id: {"nombre", "valor", "unidad"}} de la solicitud.
    Una condición sobre un parámetro sin resultado no se cumple (no se asume nada).
    """
    por_regla: dict[int, list[dict]] = {}
    for c in condiciones:
        por_regla.setdefault(c["regla_id"], []).append(c)

    sugerencias = []
    for r in reglas:
        if r["sexo"] and sexo != r["sexo"]:
            continue
        if edad is not None and ((r["edad_min"] is not None and edad < r["edad_min"]) or
                                 (r["edad_max"] is not None and edad > r["edad_max"])):
            continue
        conds = por_regla.get(r["regla_id"], [])
        cumplidas = []
        for c in conds:
            v = valores.get(c["parametro_id"])
            if v is None:
                continue
            valor = Decimal(str(v["valor"]))
            if OPERADORES[c["operador"]](valor, Decimal(str(c["valor"])), Decimal(str(c.get("valor2") or 0))):
                umbral = (f"entre {_num(c['valor'])} y {_num(c.get('valor2') or 0)}" if c["operador"] == "ENTRE"
                          else f"{SIMBOLO[c['operador']]} {_num(c['valor'])}")
                cumplidas.append(f"{v['nombre']} {_num(valor)} {v['unidad'] or ''}".strip() + f" ({umbral})")
        cumple = (len(cumplidas) == len(conds) and conds) if r["logica"] == "TODAS" else bool(cumplidas)
        if cumple:
            extra = {"F": " · regla para mujeres", "M": " · regla para hombres"}.get(r["sexo"] or "", "")
            sugerencias.append({"regla_id": r["regla_id"],
                                "explicacion": ("; ".join(cumplidas) + extra)[:1000]})
    return sugerencias


def _edad(nacimiento) -> int | None:
    if not nacimiento:
        return None
    hoy = date.today()
    n = nacimiento if isinstance(nacimiento, date) else date.fromisoformat(str(nacimiento)[:10])
    return hoy.year - n.year - ((hoy.month, hoy.day) < (n.month, n.day))


def calcular(solicitud_id: int) -> list[dict]:
    """Lee la solicitud, sus resultados y las reglas activas; aplica el motor."""
    s = db.leer_uno("""
        SELECT s.solicitud_id, p.sexo, p.fecha_nacimiento
        FROM {e}.solicitud_examen s
        JOIN {e}.paciente pa ON pa.paciente_id = s.paciente_id
        JOIN {e}.persona p ON p.persona_id = pa.persona_id
        WHERE s.solicitud_id = ?""", solicitud_id)
    if not s:
        raise no_encontrado("La solicitud")
    filas = db.leer("""
        SELECT rv.parametro_id, pm.nombre, rv.valor_numerico AS valor, rv.unidad
        FROM {e}.resultado_valor rv
        JOIN {e}.parametro_examen pm ON pm.parametro_id = rv.parametro_id
        JOIN {e}.resultado r ON r.resultado_id = rv.resultado_id
        JOIN {e}.solicitud_detalle d ON d.detalle_id = r.detalle_id
        WHERE d.solicitud_id = ? AND rv.valor_numerico IS NOT NULL""", solicitud_id)
    valores = {f["parametro_id"]: f for f in filas}
    reglas = db.leer("SELECT regla_id, logica, sexo, edad_min, edad_max FROM {e}.regla_diagnostica WHERE activa = ?", True)
    condiciones = db.leer("SELECT regla_id, parametro_id, operador, valor, valor2 FROM {e}.regla_condicion")
    return evaluar_reglas(reglas, condiciones, valores, s["sexo"], _edad(s["fecha_nacimiento"]))


def evaluar_y_registrar(solicitud_id: int) -> int:
    """Calcula y guarda las sugerencias nuevas; devuelve cuántas se agregaron."""
    sugerencias = calcular(solicitud_id)
    if not sugerencias:
        return 0
    return db.ejecutar_sp("sp_registrar_sugerencias", "nuevas", solicitud_id=solicitud_id,
                          sugerencias=json.dumps(sugerencias, ensure_ascii=False),
                          usuario_id=usuario_actual()["usuario_id"]) or 0


SQL_SUGERENCIAS = """
SELECT sg.sugerencia_id, sg.solicitud_id, sg.paciente_id, sg.estado, sg.confianza, sg.explicacion, sg.motivo,
       sg.tratamiento_id, sg.created_at, sg.respondida_at,
       d.diagnostico_id, d.codigo_cie10, d.nombre AS diagnostico,
       r.codigo AS regla, r.recomendacion, r.fuente, r.guia_clave,
       pr.indicaciones AS protocolo, pr.duracion_dias,
       CONCAT(pm.nombres, ' ', pm.apellidos) AS respondida_por
FROM {e}.sugerencia_diagnostica sg
JOIN {e}.diagnostico d ON d.diagnostico_id = sg.diagnostico_id
JOIN {e}.regla_diagnostica r ON r.regla_id = sg.regla_id
LEFT JOIN {e}.protocolo pr ON pr.diagnostico_id = sg.diagnostico_id
LEFT JOIN {e}.medico m ON m.medico_id = sg.medico_id
LEFT JOIN {e}.persona pm ON pm.persona_id = m.persona_id
"""
ORDEN_CONFIANZA = "CASE sg.confianza WHEN 'ALTA' THEN 1 WHEN 'MEDIA' THEN 2 ELSE 3 END"


# ------------------------------ sugerencias ------------------------------
@bp.get("/sugerencias")
@requiere("MEDICO", "LABORATORISTA", "ADMIN")
def sugerencias():
    if request.args.get("solicitud_id"):
        filas = db.leer(SQL_SUGERENCIAS + f" WHERE sg.solicitud_id = ? ORDER BY {ORDEN_CONFIANZA}, sg.sugerencia_id",
                        request.args.get("solicitud_id", type=int))
    elif request.args.get("paciente_id"):
        filas = db.leer(SQL_SUGERENCIAS + " WHERE sg.paciente_id = ? ORDER BY sg.sugerencia_id DESC",
                        request.args.get("paciente_id", type=int))
    else:
        raise ApiError("Indique solicitud_id o paciente_id.", 422, "CAMPO_REQUERIDO")
    return jsonify(filas)


@bp.post("/evaluar/<int:solicitud_id>")
@requiere("MEDICO", "LABORATORISTA", "ADMIN")
def evaluar(solicitud_id: int):
    nuevas = evaluar_y_registrar(solicitud_id)
    return jsonify(nuevas=nuevas, sugerencias=db.leer(
        SQL_SUGERENCIAS + f" WHERE sg.solicitud_id = ? ORDER BY {ORDEN_CONFIANZA}, sg.sugerencia_id", solicitud_id))


@bp.post("/sugerencias/<int:sugerencia_id>/responder")
@requiere("MEDICO")
def responder(sugerencia_id: int):
    d = cuerpo()
    aceptar = d.get("aceptar")
    if not isinstance(aceptar, bool):
        raise ApiError("Envíe 'aceptar': true | false.", 422, "TIPO_INVALIDO")
    db.ejecutar_sp("sp_responder_sugerencia", sugerencia_id=sugerencia_id, medico_id=perfil("medico_id"), aceptar=aceptar,
                   motivo=texto(d, "motivo", False, 300), tratamiento_id=entero(d, "tratamiento_id", False),
                   usuario_id=usuario_actual()["usuario_id"])
    return jsonify(db.leer_uno(SQL_SUGERENCIAS + " WHERE sg.sugerencia_id = ?", sugerencia_id))


# ------------------------------ reglas ------------------------------
@bp.get("/reglas")
@requiere("MEDICO", "ADMIN")
def reglas():
    filas = db.leer("""
        SELECT r.regla_id, r.codigo, r.logica, r.sexo, r.edad_min, r.edad_max, r.confianza, r.recomendacion, r.fuente,
               r.guia_clave, r.activa, d.diagnostico_id, d.codigo_cie10, d.nombre AS diagnostico,
               (SELECT COUNT(*) FROM {e}.sugerencia_diagnostica s WHERE s.regla_id = r.regla_id) AS sugerencias,
               (SELECT COUNT(*) FROM {e}.sugerencia_diagnostica s WHERE s.regla_id = r.regla_id AND s.estado = 'ACEPTADA') AS aceptadas,
               (SELECT COUNT(*) FROM {e}.sugerencia_diagnostica s WHERE s.regla_id = r.regla_id AND s.estado = 'DESCARTADA') AS descartadas
        FROM {e}.regla_diagnostica r JOIN {e}.diagnostico d ON d.diagnostico_id = r.diagnostico_id
        ORDER BY d.codigo_cie10, r.codigo""")
    conds = db.leer("""
        SELECT c.regla_id, c.parametro_id, pm.nombre AS parametro, pm.unidad, c.operador, c.valor, c.valor2
        FROM {e}.regla_condicion c JOIN {e}.parametro_examen pm ON pm.parametro_id = c.parametro_id
        ORDER BY c.condicion_id""")
    for r in filas:
        r["condiciones"] = [{k: v for k, v in c.items() if k != "regla_id"} for c in conds if c["regla_id"] == r["regla_id"]]
        respondidas = r["aceptadas"] + r["descartadas"]
        r["precision_pct"] = round(100 * r["aceptadas"] / respondidas, 1) if respondidas else None
    return jsonify(filas)


@bp.post("/reglas")
@requiere("ADMIN")
def guardar_regla():
    d = cuerpo()
    condiciones = d.get("condiciones")
    if not isinstance(condiciones, list) or not condiciones:
        raise ApiError("La regla necesita al menos una condición.", 422, "CAMPO_REQUERIDO")
    for c in condiciones:
        if (not isinstance(c, dict) or not isinstance(c.get("parametro_id"), int) or c.get("operador") not in OPERADORES
                or not isinstance(c.get("valor"), (int, float))
                or (c["operador"] == "ENTRE") != isinstance(c.get("valor2"), (int, float))):
            raise ApiError("Cada condición requiere parametro_id, operador (<, <=, >, >=, ENTRE), valor y, para ENTRE, valor2.",
                           422, "TIPO_INVALIDO")
    logica = texto(d, "logica", maximo=10).upper()
    confianza = texto(d, "confianza", maximo=10).upper()
    if logica not in ("TODAS", "ALGUNA") or confianza not in ("BAJA", "MEDIA", "ALTA"):
        raise ApiError("logica: TODAS | ALGUNA; confianza: BAJA | MEDIA | ALTA.", 422, "TIPO_INVALIDO")
    sexo = (texto(d, "sexo", False, 1) or "").upper() or None
    regla_id = db.ejecutar_sp(
        "sp_guardar_regla", "regla_id", codigo=texto(d, "codigo", maximo=30).upper(), diagnostico_id=entero(d, "diagnostico_id"),
        logica=logica, confianza=confianza, recomendacion=texto(d, "recomendacion", maximo=500),
        condiciones=json.dumps(condiciones), sexo=sexo, edad_min=d.get("edad_min"), edad_max=d.get("edad_max"),
        fuente=texto(d, "fuente", False, 200), guia_clave=texto(d, "guia_clave", False, 50),
        usuario_id=usuario_actual()["usuario_id"])
    return jsonify(regla_id=regla_id), 201


@bp.patch("/reglas/<int:regla_id>")
@requiere("ADMIN")
def activar_regla(regla_id: int):
    activa = cuerpo().get("activa")
    if not isinstance(activa, bool):
        raise ApiError("Envíe 'activa': true | false.", 422, "TIPO_INVALIDO")
    if not db.ejecutar("UPDATE dbo.regla_diagnostica SET activa = ?, updated_at = SYSUTCDATETIME() WHERE regla_id = ?",
                       activa, regla_id):
        raise no_encontrado("La regla")
    db.ejecutar_sp("sp_auditar", usuario_id=usuario_actual()["usuario_id"], rol_actuante="ADMIN",
                   accion="ACTIVAR_REGLA" if activa else "DESACTIVAR_REGLA", entidad="regla_diagnostica", entidad_id=str(regla_id))
    return jsonify(regla_id=regla_id, activa=activa)


@bp.get("/diagnosticos")
@requiere("MEDICO", "ADMIN", "LABORATORISTA")
def diagnosticos():
    return jsonify(db.leer("""
        SELECT d.diagnostico_id, d.codigo_cie10, d.nombre, d.descripcion, p.indicaciones AS protocolo, p.duracion_dias
        FROM {e}.diagnostico d LEFT JOIN {e}.protocolo p ON p.diagnostico_id = d.diagnostico_id
        ORDER BY d.codigo_cie10"""))


# ------------------------------ guías clínicas (MongoDB) ------------------------------
_mongo = None


def _guias():
    global _mongo
    if not config.MONGO_URI:
        raise ApiError("Las guías clínicas no están configuradas.", 503, "GUIAS_NO_CONFIGURADAS")
    if _mongo is None:
        from pymongo import MongoClient
        _mongo = MongoClient(config.MONGO_URI, serverSelectionTimeoutMS=5000)
    return _mongo[config.MONGO_DB].guias_clinicas


@bp.get("/guias/<clave>")
@requiere("MEDICO", "ADMIN", "LABORATORISTA")
def guia(clave: str):
    try:
        documento = _guias().find_one({"_id": clave}, {"actualizado": 0})
    except ApiError:
        raise
    except Exception as e:
        log.warning('{"evento":"guias_no_disponibles","error":"%s"}', str(e).replace('"', "'")[:200])
        raise ApiError("No se pudo consultar la guía clínica.", 503, "GUIAS_NO_DISPONIBLES")
    if not documento:
        raise no_encontrado("La guía clínica")
    return jsonify(documento)
