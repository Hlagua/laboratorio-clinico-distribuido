"""Recetas: el médico receta al revisar los resultados, con ayuda de la base de conocimientos.

La base de conocimientos (tablas medicamento y diagnostico_medicamento) solo
SUGIERE:
- los medicamentos habituales para los diagnósticos sugeridos por las reglas
  que el médico no descartó;
- la dosis, la frecuencia, la duración y las indicaciones de cada medicamento
  al escribir su nombre;
- las demás indicaciones (protocolo y recomendación de cada diagnóstico).
El médico puede cambiar o borrar todo. Lo que se guarda es su receta; de cada
medicamento se registra si modificó lo sugerido.
"""
import json

from flask import Blueprint, Response, jsonify, request

from .. import db
from ..errores import ApiError, no_encontrado, prohibido
from ..pdf import pdf_receta
from ..seguridad import perfil, requiere, rol_actual, usuario_actual
from ..validacion import cuerpo, texto

bp = Blueprint("recetas", __name__, url_prefix="/api")

SQL_MEDICAMENTOS = """
SELECT m.medicamento_id, m.nombre, m.presentacion, m.via, m.dosis, m.frecuencia, m.duracion_dias,
       m.indicaciones, m.advertencias,
       (SELECT STRING_AGG(d.codigo_cie10, ', ') FROM {e}.diagnostico_medicamento x
        JOIN {e}.diagnostico d ON d.diagnostico_id = x.diagnostico_id WHERE x.medicamento_id = m.medicamento_id) AS diagnosticos
FROM {e}.medicamento m
"""

SQL_RECETAS = """
SELECT r.receta_id, r.solicitud_id, s.codigo AS solicitud_codigo, r.paciente_id, r.medico_id,
       CONCAT(pm.nombres, ' ', pm.apellidos) AS medico, me.especialidad, me.registro_profesional,
       CONCAT(pp.nombres, ' ', pp.apellidos) AS paciente, pp.cedula, pp.fecha_nacimiento,
       r.diagnostico, r.indicaciones_generales, r.created_at, r.updated_at
FROM {e}.receta r
JOIN {e}.solicitud_examen s ON s.solicitud_id = r.solicitud_id
JOIN {e}.medico me ON me.medico_id = r.medico_id JOIN {e}.persona pm ON pm.persona_id = me.persona_id
JOIN {e}.paciente pa ON pa.paciente_id = r.paciente_id JOIN {e}.persona pp ON pp.persona_id = pa.persona_id
"""

_CAMPOS_ITEM = ("medicamento_id", "nombre", "presentacion", "via", "dosis", "frecuencia", "duracion_dias",
                "cantidad", "indicaciones")


# ------------------------------ base de conocimientos ------------------------------
@bp.get("/medicamentos")
@requiere("MEDICO", "ADMIN")
def medicamentos():
    """Vademécum de la base de conocimientos (?q= busca por nombre o presentación)."""
    q = (request.args.get("q") or "").strip().lower()
    if q:
        return jsonify(db.leer(SQL_MEDICAMENTOS + " WHERE m.activo = ? AND (LOWER(m.nombre) LIKE ? OR LOWER(m.presentacion) LIKE ?) "
                               "ORDER BY m.nombre", True, f"%{q}%", f"%{q}%"))
    return jsonify(db.leer(SQL_MEDICAMENTOS + " WHERE m.activo = ? ORDER BY m.nombre", True))


@bp.post("/medicamentos")
@requiere("ADMIN")
def guardar_medicamento():
    d = cuerpo()
    diagnosticos = d.get("diagnosticos") or []
    if not isinstance(diagnosticos, list) or not all(isinstance(x, int) for x in diagnosticos):
        raise ApiError("'diagnosticos' debe ser una lista de ids.", 422, "TIPO_INVALIDO")
    duracion = d.get("duracion_dias")
    if duracion is not None and (not isinstance(duracion, int) or duracion <= 0):
        raise ApiError("'duracion_dias' debe ser un entero positivo.", 422, "TIPO_INVALIDO")
    medicamento_id = db.ejecutar_sp(
        "sp_guardar_medicamento", "medicamento_id", nombre=texto(d, "nombre", maximo=120),
        presentacion=texto(d, "presentacion", maximo=120), via=texto(d, "via", False, 30) or "Oral",
        dosis=texto(d, "dosis", maximo=60), frecuencia=texto(d, "frecuencia", maximo=60), duracion_dias=duracion,
        indicaciones=texto(d, "indicaciones", maximo=1000), advertencias=texto(d, "advertencias", False, 500),
        diagnosticos=json.dumps(diagnosticos), usuario_id=usuario_actual()["usuario_id"])
    return jsonify(db.leer_uno(SQL_MEDICAMENTOS + " WHERE m.medicamento_id = ?", medicamento_id)), 201


def sugerencia_receta(solicitud_id: int) -> dict:
    """Lo que propone la base de conocimientos para la receta de una solicitud.

    Parte de los diagnósticos sugeridos por las reglas que el médico no descartó.
    """
    diagnosticos = db.leer("""
        SELECT DISTINCT d.diagnostico_id, d.codigo_cie10, d.nombre, pr.indicaciones AS protocolo, r.recomendacion
        FROM {e}.sugerencia_diagnostica sg
        JOIN {e}.diagnostico d ON d.diagnostico_id = sg.diagnostico_id
        JOIN {e}.regla_diagnostica r ON r.regla_id = sg.regla_id
        LEFT JOIN {e}.protocolo pr ON pr.diagnostico_id = d.diagnostico_id
        WHERE sg.solicitud_id = ? AND sg.estado <> 'DESCARTADA'
        ORDER BY d.codigo_cie10""", solicitud_id)
    ids = sorted({d["diagnostico_id"] for d in diagnosticos})
    meds = []
    if ids:
        marcas = ", ".join("?" for _ in ids)
        filas = db.leer(SQL_MEDICAMENTOS.replace("FROM {e}.medicamento m", "FROM {e}.medicamento m "
                        "JOIN {e}.diagnostico_medicamento dm ON dm.medicamento_id = m.medicamento_id "
                        "JOIN {e}.diagnostico dx ON dx.diagnostico_id = dm.diagnostico_id")
                        .replace("SELECT m.medicamento_id", "SELECT dx.codigo_cie10 AS para_cie10, dx.nombre AS para_diagnostico, "
                                 "dm.nota, m.medicamento_id")
                        + f" WHERE m.activo = ? AND dm.diagnostico_id IN ({marcas}) ORDER BY dx.codigo_cie10, m.nombre",
                        True, *ids)
        vistos = set()
        for f in filas:
            if f["medicamento_id"] not in vistos:   # un medicamento sugerido por dos diagnósticos aparece una vez
                vistos.add(f["medicamento_id"])
                meds.append(f)
    # Las "demás cosas que debe seguir": protocolo y recomendación de cada diagnóstico, sin repetir.
    lineas, vistas = [], set()
    for d in diagnosticos:
        for t in (d["protocolo"], d["recomendacion"]):
            if t and t not in vistas:
                vistas.add(t)
                lineas.append(f"• {t}")
    return {
        "diagnosticos": [{k: d[k] for k in ("diagnostico_id", "codigo_cie10", "nombre")} for d in diagnosticos],
        "diagnostico": "; ".join(f"{d['codigo_cie10']} {d['nombre']}" for d in
                                 {d["diagnostico_id"]: d for d in diagnosticos}.values()),
        "medicamentos": meds,
        "indicaciones_generales": "\n".join(lineas),
    }


# ------------------------------ recetas ------------------------------
def _con_items(recetas: list[dict]) -> list[dict]:
    if recetas:
        marcas = ", ".join("?" for _ in recetas)
        items = db.leer(f"SELECT * FROM {{e}}.receta_item WHERE receta_id IN ({marcas}) ORDER BY receta_id, orden",
                        *[r["receta_id"] for r in recetas])
        for r in recetas:
            r["items"] = [i for i in items if i["receta_id"] == r["receta_id"]]
    return recetas


def _solicitud(solicitud_id: int) -> dict:
    s = db.leer_uno("SELECT solicitud_id, paciente_id, estado, codigo FROM {e}.solicitud_examen WHERE solicitud_id = ?", solicitud_id)
    if not s:
        raise no_encontrado("La solicitud")
    if rol_actual() == "PACIENTE" and s["paciente_id"] != perfil("paciente_id"):
        raise prohibido("Solo puede ver sus propias recetas.")
    return s


@bp.get("/recetas/solicitud/<int:solicitud_id>")
@requiere("MEDICO", "PACIENTE")     # la receta es dato clínico: solo médico y paciente
def recetas_de_solicitud(solicitud_id: int):
    """Recetas de la solicitud. Al médico le llega además su receta y la sugerencia de la base de conocimientos."""
    _solicitud(solicitud_id)
    recetas = _con_items(db.leer(SQL_RECETAS + " WHERE r.solicitud_id = ? ORDER BY r.receta_id", solicitud_id))
    datos = {"recetas": recetas}
    if rol_actual() == "MEDICO":
        datos["propia"] = next((r for r in recetas if r["medico_id"] == perfil("medico_id")), None)
        datos["sugerencia"] = sugerencia_receta(solicitud_id)
    return jsonify(datos)


@bp.put("/recetas/solicitud/<int:solicitud_id>")
@requiere("MEDICO")
def guardar_receta(solicitud_id: int):
    d = cuerpo()
    items = d.get("items")
    if not isinstance(items, list) or not items or len(items) > 20:
        raise ApiError("Envíe 'items' con 1 a 20 medicamentos.", 422, "CAMPO_REQUERIDO")
    limpios = []
    for i in items:
        if not isinstance(i, dict):
            raise ApiError("Cada medicamento debe ser un objeto.", 422, "TIPO_INVALIDO")
        x = {k: i.get(k) for k in _CAMPOS_ITEM}
        for k in ("medicamento_id", "duracion_dias"):
            if x[k] is not None and (not isinstance(x[k], int) or x[k] <= 0):
                raise ApiError(f"'{k}' debe ser un entero positivo.", 422, "TIPO_INVALIDO")
        for k, maximo in (("nombre", 120), ("presentacion", 120), ("via", 30), ("dosis", 60), ("frecuencia", 60),
                          ("cantidad", 40), ("indicaciones", 1000)):
            if x[k] is not None:
                if not isinstance(x[k], str) or len(x[k].strip()) > maximo:
                    raise ApiError(f"'{k}' no es válido (máximo {maximo} caracteres).", 422, "TIPO_INVALIDO")
                x[k] = x[k].strip() or None
        x["modificado"] = bool(i.get("modificado"))
        limpios.append(x)
    receta_id = db.ejecutar_sp(
        "sp_guardar_receta", "receta_id", solicitud_id=solicitud_id, medico_id=perfil("medico_id"),
        diagnostico=texto(d, "diagnostico", False, 500), indicaciones_generales=texto(d, "indicaciones_generales", False, 2000),
        items=json.dumps(limpios, ensure_ascii=False), usuario_id=usuario_actual()["usuario_id"])
    return jsonify(_con_items(db.leer(SQL_RECETAS + " WHERE r.receta_id = ?", receta_id))[0])


@bp.get("/recetas/<int:receta_id>/pdf")
@requiere("MEDICO", "PACIENTE")     # la receta es dato clínico: solo médico y paciente
def receta_pdf(receta_id: int):
    r = db.leer_uno(SQL_RECETAS + " WHERE r.receta_id = ?", receta_id)
    if not r:
        raise no_encontrado("La receta")
    if rol_actual() == "PACIENTE" and r["paciente_id"] != perfil("paciente_id"):
        raise prohibido("Solo puede ver sus propias recetas.")
    r = _con_items([r])[0]
    return Response(pdf_receta(r), mimetype="application/pdf",
                    headers={"Content-Disposition": f'attachment; filename="receta-{r["solicitud_codigo"]}.pdf"'})
