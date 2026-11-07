"""Servicio de pagos: Stripe Checkout (modo prueba), transferencia con QR y reembolsos.

Flujo Stripe:
 1. POST /api/pagos/checkout      -> sesión de Checkout + pago PENDIENTE
 2. El paciente paga en la página de Stripe (la tarjeta nunca pasa por aquí)
 3. POST /api/pagos/webhook       -> Stripe confirma: APROBADO / RECHAZADO / EXPIRADO
 4. POST /api/pagos/<id>/reembolso -> reembolso total o parcial
"""
import json
import logging
import secrets
import time
from decimal import Decimal

import segno
import stripe
from flask import Blueprint, jsonify, request

from .. import config, db
from ..errores import ApiError, no_encontrado, prohibido
from ..seguridad import perfil, requiere, rol_actual, usuario_actual
from ..validacion import cuerpo, decimal, entero, texto
from .notificaciones import encolar

bp = Blueprint("pagos", __name__, url_prefix="/api/pagos")
log = logging.getLogger("api")

SQL_PAGOS = """
SELECT pg.pago_id, pg.solicitud_id, s.codigo AS solicitud_codigo, pg.monto, pg.moneda, pg.metodo, pg.estado,
       pg.motivo_rechazo, pg.monto_reembolsado, pg.referencia_transferencia, pg.stripe_payment_intent_id,
       pg.confirmado_at, pg.created_at, s.paciente_id, CONCAT(p.nombres, ' ', p.apellidos) AS paciente
FROM {e}.pago pg
JOIN {e}.solicitud_examen s ON s.solicitud_id = pg.solicitud_id
JOIN {e}.paciente pa ON pa.paciente_id = s.paciente_id
JOIN {e}.persona p ON p.persona_id = pa.persona_id
"""


def _stripe():
    if not config.STRIPE_SECRET_KEY.startswith("sk_test_"):
        raise ApiError("Stripe no está configurado en modo prueba (sk_test_...).", 503, "STRIPE_NO_CONFIGURADO")
    stripe.api_key = config.STRIPE_SECRET_KEY
    return stripe


def _solicitud_a_pagar(solicitud_id: int) -> dict:
    s = db.leer_uno("SELECT s.solicitud_id, s.codigo, s.estado, s.total, s.paciente_id, p.email "
                    "FROM {e}.solicitud_examen s JOIN {e}.paciente pa ON pa.paciente_id = s.paciente_id "
                    "JOIN {e}.persona p ON p.persona_id = pa.persona_id WHERE s.solicitud_id = ?",
                    solicitud_id, contingencia=False)
    if not s:
        raise no_encontrado("La solicitud")
    if rol_actual() == "PACIENTE" and s["paciente_id"] != perfil("paciente_id"):
        raise prohibido("Solo puede pagar sus propias solicitudes.")
    if s["estado"] != "REGISTRADA":
        raise ApiError("La solicitud ya fue pagada o está anulada.", 409, "ESTADO_INVALIDO")
    return s


@bp.post("/checkout")
@requiere("PACIENTE")
def checkout():
    """Registra la solicitud de pago y devuelve la URL de Stripe Checkout."""
    s = _solicitud_a_pagar(entero(cuerpo(), "solicitud_id"))
    examenes = db.leer("SELECT t.nombre, d.precio_unitario FROM {e}.solicitud_detalle d "
                       "JOIN {e}.tipo_examen t ON t.tipo_examen_id = d.tipo_examen_id "
                       "WHERE d.solicitud_id = ? AND d.estado <> 'ANULADO'", s["solicitud_id"])
    sesion = _stripe().checkout.Session.create(
        mode="payment",
        line_items=[{"quantity": 1, "price_data": {
            "currency": "usd", "unit_amount": int(Decimal(e["precio_unitario"]) * 100),
            "product_data": {"name": e["nombre"]}}} for e in examenes],
        customer_email=s["email"],
        client_reference_id=s["codigo"],
        metadata={"solicitud_id": s["solicitud_id"], "codigo": s["codigo"]},
        payment_intent_data={"metadata": {"solicitud_id": s["solicitud_id"], "codigo": s["codigo"]}},
        expires_at=int(time.time()) + 31 * 60,     # mínimo permitido por Stripe: 30 min
        success_url=f"{config.URL_PORTAL}/pagos/resultado?estado=exito&session_id={{CHECKOUT_SESSION_ID}}",
        cancel_url=f"{config.URL_PORTAL}/pagos/resultado?estado=cancelado&solicitud={s['solicitud_id']}",
    )
    pago_id = db.ejecutar_sp("sp_crear_pago", "pago_id", solicitud_id=s["solicitud_id"], metodo="STRIPE",
                             stripe_checkout_session_id=sesion.id, usuario_id=usuario_actual()["usuario_id"])
    return jsonify(pago_id=pago_id, checkout_url=sesion.url, session_id=sesion.id, monto=s["total"]), 201


@bp.post("/transferencia")
@requiere("PACIENTE")
def transferencia():
    """Simulación controlada: genera referencia y QR; el admin confirma la transferencia."""
    s = _solicitud_a_pagar(entero(cuerpo(), "solicitud_id"))
    referencia = f"TRX-{secrets.token_hex(4).upper()}"
    pago_id = db.ejecutar_sp("sp_crear_pago", "pago_id", solicitud_id=s["solicitud_id"], metodo="TRANSFERENCIA_QR",
                             referencia_transferencia=referencia, usuario_id=usuario_actual()["usuario_id"])
    contenido = json.dumps({"cuenta": config.CUENTA_TRANSFERENCIA, "monto": float(s["total"]), "moneda": "USD",
                            "referencia": referencia, "solicitud": s["codigo"]}, ensure_ascii=False)
    qr_png = segno.make(contenido, error="m").png_data_uri(scale=6)
    return jsonify(pago_id=pago_id, referencia=referencia, monto=s["total"], cuenta=config.CUENTA_TRANSFERENCIA,
                   qr=qr_png, mensaje="Realice la transferencia indicando la referencia. El laboratorio la confirmará."), 201


@bp.post("/<int:pago_id>/confirmar-transferencia")
@requiere("ADMIN")
def confirmar_transferencia(pago_id: int):
    d = cuerpo()
    pago = db.leer_uno(SQL_PAGOS + " WHERE pg.pago_id = ?", pago_id, contingencia=False)
    if not pago or pago["metodo"] != "TRANSFERENCIA_QR":
        raise no_encontrado("El pago por transferencia")
    aprobado = bool(d.get("aprobado", True))
    db.ejecutar_sp("sp_confirmar_pago", pago_id=pago_id, aprobado=aprobado,
                   motivo_rechazo=None if aprobado else texto(d, "motivo", maximo=300))
    return jsonify(db.leer_uno(SQL_PAGOS + " WHERE pg.pago_id = ?", pago_id))


@bp.post("/webhook")
def webhook():
    """Eventos de Stripe. Se valida la firma y se procesa cada evento una sola vez."""
    try:
        evento = stripe.Webhook.construct_event(request.get_data(), request.headers.get("Stripe-Signature", ""),
                                                config.STRIPE_WEBHOOK_SECRET)
    except (ValueError, stripe.SignatureVerificationError):
        raise ApiError("Firma de Stripe inválida.", 400, "FIRMA_INVALIDA")

    try:
        db.ejecutar("INSERT INTO dbo.stripe_evento (stripe_event_id, tipo, payload) VALUES (?, ?, ?)",
                    evento["id"], evento["type"], request.get_data(as_text=True))
    except ApiError as e:
        if e.codigo != "DUPLICADO":
            raise
        # Reenvío de Stripe: si ya se procesó no se repite; si quedó a medias
        # (error en el intento anterior) se reprocesa, los SP son idempotentes.
        previo = db.leer_uno("SELECT procesado FROM {e}.stripe_evento WHERE stripe_event_id = ?",
                             evento["id"], contingencia=False)
        if previo and previo["procesado"]:
            return jsonify(recibido=True, duplicado=True)

    objeto = evento.to_dict()["data"]["object"]
    tipo = evento["type"]
    pago = None
    if tipo.startswith("checkout.session."):
        pago = _pago_por_sesion(objeto["id"])
    elif tipo == "payment_intent.payment_failed":
        sesiones = _stripe().checkout.Session.list(payment_intent=objeto["id"], limit=1)
        pago = _pago_por_sesion(sesiones.data[0].id) if sesiones.data else None

    if pago:
        if tipo in ("checkout.session.completed", "checkout.session.async_payment_succeeded"):
            if objeto.get("payment_status") == "paid":
                db.ejecutar_sp("sp_confirmar_pago", pago_id=pago["pago_id"], aprobado=True,
                               stripe_payment_intent_id=objeto.get("payment_intent"))
        elif tipo == "checkout.session.async_payment_failed":
            db.ejecutar_sp("sp_confirmar_pago", pago_id=pago["pago_id"], aprobado=False,
                           stripe_payment_intent_id=objeto.get("payment_intent"), motivo_rechazo="Pago asíncrono fallido")
        elif tipo == "checkout.session.expired":
            db.ejecutar_sp("sp_marcar_pago_expirado", pago_id=pago["pago_id"])
        elif tipo == "payment_intent.payment_failed":
            error = objeto.get("last_payment_error") or {}
            motivo = f"{error.get('decline_code') or error.get('code') or 'rechazado'}: {error.get('message', '')}"[:300]
            db.ejecutar_sp("sp_confirmar_pago", pago_id=pago["pago_id"], aprobado=False,
                           stripe_payment_intent_id=objeto["id"], motivo_rechazo=motivo)

    db.ejecutar("UPDATE dbo.stripe_evento SET procesado = 1, pago_id = ? WHERE stripe_event_id = ?",
                pago["pago_id"] if pago else None, evento["id"])
    log.info('{"evento":"stripe_webhook","tipo":"%s","pago_id":%s,"instancia":"%s"}',
             tipo, pago["pago_id"] if pago else "null", config.INSTANCIA)
    return jsonify(recibido=True, tipo=tipo, pago_id=pago["pago_id"] if pago else None)


def _pago_por_sesion(session_id: str) -> dict | None:
    return db.leer_uno("SELECT pago_id, estado FROM {e}.pago WHERE stripe_checkout_session_id = ?",
                       session_id, contingencia=False)


@bp.get("/mios")
@requiere("PACIENTE")
def mis_pagos():
    return jsonify(db.leer(SQL_PAGOS + " WHERE s.paciente_id = ? ORDER BY pg.pago_id DESC", perfil("paciente_id")))


@bp.get("")
@requiere("ADMIN")
def listar():
    estado = request.args.get("estado")
    if estado:
        return jsonify(db.leer(SQL_PAGOS + " WHERE pg.estado = ? ORDER BY pg.pago_id DESC", estado.upper()))
    return jsonify(db.leer(SQL_PAGOS + " ORDER BY pg.pago_id DESC")[:200])


@bp.get("/<int:pago_id>")
@requiere("PACIENTE", "ADMIN")
def ver(pago_id: int):
    pago = db.leer_uno(SQL_PAGOS + " WHERE pg.pago_id = ?", pago_id)
    if not pago:
        raise no_encontrado("El pago")
    if rol_actual() == "PACIENTE" and pago["paciente_id"] != perfil("paciente_id"):
        raise prohibido()
    pago["reembolsos"] = db.leer("SELECT reembolso_id, monto, motivo, estado, stripe_refund_id, created_at "
                                 "FROM {e}.reembolso WHERE pago_id = ? ORDER BY reembolso_id", pago_id)
    return jsonify(pago)


@bp.post("/<int:pago_id>/reembolso")
@requiere("ADMIN")
def reembolsar(pago_id: int):
    d = cuerpo()
    monto = decimal(d, "monto").quantize(Decimal("0.01"))
    motivo = texto(d, "motivo", maximo=300)
    pago = db.leer_uno(SQL_PAGOS + " WHERE pg.pago_id = ?", pago_id, contingencia=False)
    if not pago:
        raise no_encontrado("El pago")
    if pago["estado"] not in ("APROBADO", "REEMBOLSO_PARCIAL"):
        raise ApiError("Solo se reembolsan pagos aprobados.", 409, "ESTADO_INVALIDO")
    if monto <= 0 or monto + Decimal(pago["monto_reembolsado"]) > Decimal(pago["monto"]):
        raise ApiError("El monto a reembolsar no es válido.", 422, "MONTO_INVALIDO")

    refund_id = None
    if pago["metodo"] == "STRIPE":
        centavos = int(monto * 100)
        # Idempotency-Key: un doble clic no genera dos reembolsos en Stripe.
        clave = f"reembolso-{pago_id}-{pago['monto_reembolsado']}-{centavos}"
        try:
            refund = _stripe().Refund.create(payment_intent=pago["stripe_payment_intent_id"], amount=centavos,
                                             reason="requested_by_customer", metadata={"pago_id": pago_id},
                                             idempotency_key=clave)
        except stripe.StripeError as e:
            raise ApiError(f"Stripe rechazó el reembolso: {e.user_message or e}", 502, "STRIPE_ERROR")
        refund_id = refund.id

    reembolso_id = db.ejecutar_sp("sp_registrar_reembolso", "reembolso_id", pago_id=pago_id, monto=monto, motivo=motivo,
                                  stripe_refund_id=refund_id, admin_id=usuario_actual()["usuario_id"])
    persona = db.leer_uno("SELECT pa.persona_id FROM {e}.paciente pa WHERE pa.paciente_id = ?", pago["paciente_id"])
    encolar(persona["persona_id"], "REEMBOLSO", f"Reembolso registrado - {pago['solicitud_codigo']}",
            f"Se registró un reembolso de USD {monto} para la solicitud {pago['solicitud_codigo']}. Motivo: {motivo}.")
    return jsonify(reembolso_id=reembolso_id, stripe_refund_id=refund_id, pago=db.leer_uno(SQL_PAGOS + " WHERE pg.pago_id = ?", pago_id)), 201
