"""Laboratorios y resultados de laboratorios externos.

- Pueden existir varios laboratorios; el administrador los crea. Uno es el propio.
- Los exámenes se pueden hacer en otro laboratorio: esa solicitud no se cobra aquí.
- El resultado externo se sube en PDF. El archivo se guarda en MongoDB (la parte
  documental del sistema) y se lee su texto para proponer los valores de cada
  parámetro. El laboratorista revisa esa propuesta y la registra como resultado;
  desde ahí el médico la ve igual que un resultado propio.
"""
import base64
import re
import unicodedata
from datetime import datetime, timezone
from io import BytesIO

from bson import ObjectId
from flask import Blueprint, Response, jsonify, request

from .. import config, db
from ..errores import ApiError, no_encontrado, prohibido
from ..seguridad import perfil, requiere, rol_actual, usuario_actual
from ..validacion import correo, cuerpo, entero, telefono, texto

bp = Blueprint("laboratorios", __name__, url_prefix="/api")

MAX_PDF = 5 * 1024 * 1024      # 5 MB por archivo
_mongo = None


def _documentos():
    global _mongo
    if not config.MONGO_URI:
        raise ApiError("El almacenamiento de documentos no está configurado.", 503, "MONGO_NO_CONFIGURADO")
    if _mongo is None:
        from pymongo import MongoClient
        _mongo = MongoClient(config.MONGO_URI, serverSelectionTimeoutMS=5000)
    return _mongo[config.MONGO_DB].resultados_externos


# ------------------------------ laboratorios ------------------------------
@bp.get("/laboratorios")
def laboratorios():
    """Público: laboratorios activos (el propio primero)."""
    todos = request.args.get("todos") == "1"
    sql = "SELECT laboratorio_id, nombre, direccion, telefono, email, propio, activo FROM {e}.laboratorio"
    if todos:
        return jsonify(db.leer(sql + " ORDER BY propio DESC, nombre"))
    return jsonify(db.leer(sql + " WHERE activo = ? ORDER BY propio DESC, nombre", True))


@bp.post("/laboratorios")
@requiere("ADMIN")
def crear_laboratorio():
    d = cuerpo()
    try:
        db.ejecutar("INSERT INTO dbo.laboratorio (nombre, direccion, telefono, email) VALUES (?, ?, ?, ?)",
                    texto(d, "nombre", maximo=150), texto(d, "direccion", False, 250), telefono(d), correo(d, requerido=False))
    except ApiError as e:
        if e.codigo == "DUPLICADO":
            raise ApiError("Ya existe un laboratorio con ese nombre.", 409, "DUPLICADO")
        raise
    db.ejecutar_sp("sp_auditar", usuario_id=usuario_actual()["usuario_id"], rol_actuante="ADMIN",
                   accion="CREAR_LABORATORIO", entidad="laboratorio", entidad_id=d.get("nombre"))
    return jsonify(db.leer_uno("SELECT * FROM {e}.laboratorio WHERE nombre = ?", d["nombre"].strip())), 201


@bp.patch("/laboratorios/<int:laboratorio_id>")
@requiere("ADMIN")
def activar_laboratorio(laboratorio_id: int):
    activo = cuerpo().get("activo")
    if not isinstance(activo, bool):
        raise ApiError("Envíe 'activo': true | false.", 422, "TIPO_INVALIDO")
    if not db.ejecutar("UPDATE dbo.laboratorio SET activo = ?, updated_at = SYSUTCDATETIME() "
                       "WHERE laboratorio_id = ? AND propio = 0", activo, laboratorio_id):
        raise ApiError("El laboratorio no existe o es el propio (no se desactiva).", 409, "OPERACION_INVALIDA")
    return jsonify(laboratorio_id=laboratorio_id, activo=activo)


# ------------------------------ solicitud en otro laboratorio ------------------------------
def _solicitud(solicitud_id: int) -> dict:
    s = db.leer_uno("""
        SELECT s.solicitud_id, s.codigo, s.estado, s.tipo, s.paciente_id, s.laboratorio_id, l.nombre AS laboratorio,
               l.propio
        FROM {e}.solicitud_examen s LEFT JOIN {e}.laboratorio l ON l.laboratorio_id = s.laboratorio_id
        WHERE s.solicitud_id = ?""", solicitud_id)
    if not s:
        raise no_encontrado("La solicitud")
    if rol_actual() == "PACIENTE" and s["paciente_id"] != perfil("paciente_id"):
        raise prohibido("Solo puede gestionar sus propias solicitudes.")
    s["propio"] = s["propio"] is None or bool(s["propio"])     # sin laboratorio = el propio
    return s


@bp.put("/solicitudes/<int:solicitud_id>/laboratorio")
@requiere("PACIENTE", "MEDICO", "LABORATORISTA", "ADMIN")
def cambiar_laboratorio(solicitud_id: int):
    _solicitud(solicitud_id)
    db.ejecutar_sp("sp_cambiar_laboratorio", solicitud_id=solicitud_id, laboratorio_id=entero(cuerpo(), "laboratorio_id"),
                   usuario_id=usuario_actual()["usuario_id"])
    return jsonify(_solicitud(solicitud_id))


def _normalizar(t: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFD", t.lower()) if unicodedata.category(c) != "Mn")


_NUMERO = r"(-?\d+(?:[.,]\d+)?)"


def _base(p: dict) -> dict:
    """Solo lo necesario para registrar el valor (MongoDB no guarda los Decimal de la base)."""
    return {"detalle_id": p["detalle_id"], "parametro_id": p["parametro_id"], "parametro": p["parametro"]}


def leer_valores(texto_pdf: str, parametros: list[dict]) -> list[dict]:
    """Función pura: busca cada parámetro en el texto del PDF y toma el primer valor que le sigue.

    Sirve para informes en línea ("Glucosa 130 mg/dL 70 - 100") y en tabla, donde cada celda
    sale en su propia línea ("Glucosa", "130", "mg/dL"...): se mira una ventana corta después
    del nombre. Si el parámetro es cualitativo, se toma la palabra (Negativo, Positivo...).
    """
    plano = re.sub(r"[ 	]+", " ", _normalizar(texto_pdf))
    propuesta = []
    for p in parametros:
        nombre = _normalizar(p["parametro"])
        for m in re.finditer(r"(?<![a-z])" + re.escape(nombre) + r"(?![a-z])", plano):
            ventana = plano[m.end():m.end() + 60]
            if p["valor_ref_texto"] and p["valor_ref_min"] is None:
                palabra = re.search(r"(no reactivo|positivo|negativo|reactivo|normal|anormal|presente|ausente)", ventana)
                if palabra:
                    propuesta.append({**_base(p), "texto": palabra.group(1).capitalize()})
                    break
                continue
            numero = re.search(_NUMERO, ventana)
            if numero:
                propuesta.append({**_base(p), "valor": float(numero.group(1).replace(",", "."))})
                break
    return propuesta


def _parametros(solicitud_id: int) -> list[dict]:
    return db.leer("""
        SELECT d.detalle_id, t.nombre AS examen, pm.parametro_id, pm.nombre AS parametro, pm.unidad,
               pm.valor_ref_min, pm.valor_ref_max, pm.valor_ref_texto
        FROM {e}.solicitud_detalle d
        JOIN {e}.tipo_examen t ON t.tipo_examen_id = d.tipo_examen_id
        JOIN {e}.parametro_examen pm ON pm.tipo_examen_id = t.tipo_examen_id
        WHERE d.solicitud_id = ? AND d.estado NOT IN ('RESULTADO_LISTO', 'ANULADO') ORDER BY d.detalle_id, pm.orden""",
                   solicitud_id)


@bp.post("/solicitudes/<int:solicitud_id>/resultado-externo")
@requiere("PACIENTE", "MEDICO", "LABORATORISTA", "ADMIN")
def subir_resultado_externo(solicitud_id: int):
    """{nombre, contenido_base64}: guarda el PDF en MongoDB y devuelve los valores que se pudieron leer."""
    s = _solicitud(solicitud_id)
    if s["propio"]:
        raise ApiError("Esta solicitud se procesa en nuestro laboratorio; elija antes el laboratorio externo.",
                       409, "LABORATORIO_PROPIO")
    d = cuerpo()
    nombre = texto(d, "nombre", maximo=150)
    try:
        contenido = base64.b64decode(d.get("contenido_base64") or "", validate=True)
    except (ValueError, TypeError):
        raise ApiError("El archivo no llegó bien (base64 inválido).", 422, "ARCHIVO_INVALIDO")
    if not contenido.startswith(b"%PDF"):
        raise ApiError("El archivo debe ser un PDF.", 422, "ARCHIVO_INVALIDO")
    if len(contenido) > MAX_PDF:
        raise ApiError("El PDF no puede pasar de 5 MB.", 422, "ARCHIVO_GRANDE")
    try:
        from pypdf import PdfReader
        texto_pdf = "\n".join((pg.extract_text() or "") for pg in PdfReader(BytesIO(contenido)).pages)
    except Exception:
        texto_pdf = ""          # PDF escaneado o protegido: se guarda igual, sin valores leídos
    valores = leer_valores(texto_pdf, _parametros(solicitud_id))
    from bson.binary import Binary
    r = _documentos().insert_one({
        "solicitud_id": solicitud_id, "codigo": s["codigo"], "laboratorio": s["laboratorio"], "nombre_archivo": nombre,
        "contenido": Binary(contenido), "tamano": len(contenido), "subido_por": usuario_actual()["usuario_id"],
        "rol": rol_actual(), "fecha": datetime.now(timezone.utc), "valores_leidos": valores,
        "texto_leido": bool(texto_pdf.strip()),
    })
    db.ejecutar_sp("sp_auditar", usuario_id=usuario_actual()["usuario_id"], rol_actuante=rol_actual(),
                   accion="SUBIR_RESULTADO_EXTERNO", entidad="solicitud_examen", entidad_id=str(solicitud_id))
    return jsonify(documento_id=str(r.inserted_id), valores=valores, texto_leido=bool(texto_pdf.strip())), 201


@bp.get("/solicitudes/<int:solicitud_id>/resultado-externo")
@requiere("PACIENTE", "MEDICO", "LABORATORISTA", "ADMIN")
def listar_resultados_externos(solicitud_id: int):
    _solicitud(solicitud_id)
    docs = _documentos().find({"solicitud_id": solicitud_id}, {"contenido": 0}).sort("fecha", -1)
    return jsonify([{**{k: v for k, v in d.items() if k != "_id"}, "documento_id": str(d["_id"]),
                     "fecha": d["fecha"].isoformat()} for d in docs])


@bp.get("/solicitudes/<int:solicitud_id>/resultado-externo/<documento_id>")
@requiere("PACIENTE", "MEDICO", "LABORATORISTA", "ADMIN")
def descargar_resultado_externo(solicitud_id: int, documento_id: str):
    _solicitud(solicitud_id)
    try:
        doc = _documentos().find_one({"_id": ObjectId(documento_id), "solicitud_id": solicitud_id})
    except Exception:
        doc = None
    if not doc:
        raise no_encontrado("El documento")
    return Response(bytes(doc["contenido"]), mimetype="application/pdf",
                    headers={"Content-Disposition": f'inline; filename="{doc["nombre_archivo"]}"'})
