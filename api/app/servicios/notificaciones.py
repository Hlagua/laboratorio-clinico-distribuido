"""Servicio de notificaciones: bandeja de salida (tabla notificacion) + Mailjet.

Las operaciones de negocio solo ENCOLAN el correo. Un hilo lo envía con
Mailjet y registra el resultado. Puede correr en varias instancias a la
vez: cada una toma filas distintas gracias a UPDLOCK + READPAST.
"""
import html
import logging
import threading
import time

import requests
from flask import Blueprint, jsonify, request

from .. import config, db
from ..errores import ApiError
from ..seguridad import requiere
from ..validacion import cuerpo, texto

bp = Blueprint("notificaciones", __name__, url_prefix="/api/notificaciones")
log = logging.getLogger("api")
MAX_INTENTOS = 5


def encolar(persona_id: int, tipo: str, asunto: str, mensaje: str):
    """Agrega un correo a la bandeja de salida (no bloquea la operación si falla)."""
    try:
        db.ejecutar("""
            INSERT INTO dbo.notificacion (persona_id, tipo, destinatario, asunto, cuerpo)
            SELECT persona_id, ?, email, ?, ? FROM dbo.persona WHERE persona_id = ? AND email IS NOT NULL
        """, tipo, asunto, mensaje, persona_id)
    except ApiError as e:
        log.warning('{"evento":"notificacion_no_encolada","tipo":"%s","error":"%s"}', tipo, e.mensaje)


def enviar_mailjet(destinatario: str, asunto: str, mensaje: str) -> str:
    """Envía un correo con la API v3.1 de Mailjet y devuelve su MessageID."""
    if not (config.MAILJET_API_KEY and config.MAILJET_API_SECRET and config.MAIL_REMITENTE):
        raise RuntimeError("Mailjet no está configurado")
    cuerpo_html = (
        "<div style='font-family:Arial,sans-serif;max-width:560px'>"
        "<h2 style='color:#0b6e4f'>Laboratorio Clínico</h2>"
        f"<p>{html.escape(mensaje)}</p>"
        "<p style='color:#777;font-size:12px'>Mensaje automático, no responda a este correo.</p></div>"
    )
    r = requests.post(
        "https://api.mailjet.com/v3.1/send",
        auth=(config.MAILJET_API_KEY, config.MAILJET_API_SECRET),
        json={"Messages": [{
            "From": {"Email": config.MAIL_REMITENTE, "Name": config.MAIL_REMITENTE_NOMBRE},
            "To": [{"Email": destinatario}],
            "Subject": asunto, "TextPart": mensaje, "HTMLPart": cuerpo_html,
        }]},
        timeout=10,
    )
    datos = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
    mensajes = datos.get("Messages") or [{}]
    if r.status_code != 200 or mensajes[0].get("Status") != "success":
        raise RuntimeError(f"Mailjet HTTP {r.status_code}: {str(datos)[:200]}")
    return str(mensajes[0]["To"][0]["MessageID"])


def procesar_pendientes(limite: int = 10) -> dict:
    """Envía hasta `limite` correos pendientes. Seguro con varias instancias."""
    enviados = fallidos = 0
    cn = db.nueva_conexion_azure()
    try:
        cn.autocommit = False
        cur = cn.cursor()
        filas = cur.execute("""
            SELECT TOP (?) notificacion_id, destinatario, asunto, cuerpo, intentos
            FROM dbo.notificacion WITH (UPDLOCK, READPAST, ROWLOCK)
            WHERE estado = 'PENDIENTE' AND intentos < ?
            ORDER BY notificacion_id
        """, limite, MAX_INTENTOS).fetchall()
        for n_id, destino, asunto, mensaje, intentos in filas:
            try:
                msg_id = enviar_mailjet(destino, asunto, mensaje)
                cur.execute("UPDATE dbo.notificacion SET estado = 'ENVIADA', intentos = intentos + 1, proveedor_msg_id = ?, "
                            "enviada_at = SYSUTCDATETIME(), ultimo_error = NULL, updated_at = SYSUTCDATETIME() "
                            "WHERE notificacion_id = ?", msg_id, n_id)
                enviados += 1
            except Exception as e:
                cur.execute("UPDATE dbo.notificacion SET intentos = intentos + 1, ultimo_error = ?, "
                            "estado = CASE WHEN intentos + 1 >= ? THEN 'FALLIDA' ELSE 'PENDIENTE' END, "
                            "updated_at = SYSUTCDATETIME() WHERE notificacion_id = ?", str(e)[:500], MAX_INTENTOS, n_id)
                fallidos += 1
        cn.commit()
    finally:
        cn.close()
    if enviados or fallidos:
        log.info('{"evento":"notificaciones_procesadas","instancia":"%s","enviadas":%d,"fallidas":%d}',
                 config.INSTANCIA, enviados, fallidos)
    return {"enviadas": enviados, "fallidas": fallidos}


def iniciar_notificador():
    def bucle():
        while True:
            try:
                if db.azure_disponible():
                    procesar_pendientes()
            except Exception as e:
                log.warning('{"evento":"notificador_error","error":"%s"}', str(e).replace('"', "'")[:200])
            time.sleep(config.NOTIFICADOR_INTERVALO)

    threading.Thread(target=bucle, name="notificador", daemon=True).start()


# ------------------------------ endpoints ------------------------------
@bp.get("")
@requiere("ADMIN")
def listar():
    estado = request.args.get("estado")
    sql = ("SELECT notificacion_id, persona_id, tipo, destinatario, asunto, estado, intentos, ultimo_error, "
           "proveedor_msg_id, created_at, enviada_at FROM {e}.notificacion")
    params = []
    if estado:
        sql += " WHERE estado = ?"
        params.append(estado.upper())
    filas = db.leer(sql + " ORDER BY notificacion_id DESC", *params, contingencia=False)
    return jsonify(filas[:200])


@bp.post("/procesar")
@requiere("ADMIN")
def procesar():
    return jsonify(procesar_pendientes(50))


@bp.post("/prueba")
@requiere("ADMIN")
def prueba():
    """Envía de inmediato un correo de prueba (evidencia de integración con Mailjet)."""
    destino = texto(cuerpo(), "email", maximo=150)
    try:
        msg_id = enviar_mailjet(destino, "Prueba de notificación - Laboratorio Clínico",
                                f"Correo de prueba enviado desde la instancia {config.INSTANCIA}.")
    except Exception as e:
        raise ApiError(f"No se pudo enviar el correo: {e}", 502, "MAILJET_ERROR")
    return jsonify(enviado=True, mailjet_message_id=msg_id, instancia=config.INSTANCIA)
