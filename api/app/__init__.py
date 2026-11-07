"""Fábrica de la aplicación Flask (una por contenedor: api1..api4)."""
import json
import logging
import sys
import time
from datetime import date, datetime, time as hora, timezone
from decimal import Decimal

from flask import Flask, g, jsonify, request
from flask.json.provider import DefaultJSONProvider
from werkzeug.exceptions import HTTPException

from . import config, db
from .errores import ApiError


class ProveedorJSON(DefaultJSONProvider):
    ensure_ascii = False
    sort_keys = False

    @staticmethod
    def default(o):
        if isinstance(o, (datetime, date, hora)):
            return o.isoformat()
        if isinstance(o, Decimal):
            return float(o)
        return DefaultJSONProvider.default(o)


def create_app() -> Flask:
    config.validar()
    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stdout)
    log = logging.getLogger("api")

    app = Flask(__name__)
    app.json = ProveedorJSON(app)
    app.config["MAX_CONTENT_LENGTH"] = 1 * 1024 * 1024

    if config.CORS_ORIGENES:
        from flask_cors import CORS
        CORS(app, origins=config.CORS_ORIGENES, expose_headers=["X-Instancia", "X-Origen-Datos"])

    from .servicios import auth, citas, examenes, notificaciones, pagos, soap, tratamientos, usuarios
    for modulo in (auth, citas, examenes, pagos, tratamientos, notificaciones, usuarios, soap):
        app.register_blueprint(modulo.bp)

    @app.before_request
    def _inicio():
        g.t0 = time.perf_counter()
        g.origen_datos = None

    @app.after_request
    def _cabeceras(resp):
        resp.headers["X-Instancia"] = config.INSTANCIA
        if g.get("origen_datos"):
            resp.headers["X-Origen-Datos"] = g.origen_datos
        if request.path != "/health":
            log.info(json.dumps({
                "ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"), "instancia": config.INSTANCIA,
                "metodo": request.method, "ruta": request.path, "estado": resp.status_code,
                "ms": round((time.perf_counter() - g.t0) * 1000, 1), "origen_datos": g.get("origen_datos"),
                "usuario": (g.get("usuario") or {}).get("usuario_id"), "rol": g.get("rol"),
                "ip": request.headers.get("X-Real-IP", request.remote_addr),
            }, ensure_ascii=False))
        return resp

    app.teardown_appcontext(db.cerrar_conexiones)

    @app.errorhandler(ApiError)
    def _api_error(e: ApiError):
        return jsonify(error=e.mensaje, codigo=e.codigo, instancia=config.INSTANCIA), e.estado

    @app.errorhandler(HTTPException)
    def _http_error(e: HTTPException):
        return jsonify(error=e.description, codigo=e.name.upper().replace(" ", "_"), instancia=config.INSTANCIA), e.code

    @app.errorhandler(Exception)
    def _error_interno(e: Exception):
        log.exception("error no controlado en %s %s", request.method, request.path)
        return jsonify(error="Error interno del servidor.", codigo="ERROR_INTERNO", instancia=config.INSTANCIA), 500

    @app.get("/health")
    def health():
        """Sonda del balanceador: responde 200 mientras la API esté viva,
        aunque Azure SQL esté caído (en ese caso atiende en contingencia)."""
        return jsonify(estado="ok", instancia=config.INSTANCIA,
                       modo="normal" if db.azure_disponible() else "contingencia")

    @app.get("/api/estado")
    def estado():
        azure = supabase = False
        try:
            db.leer("SELECT 1 AS ok", contingencia=False)
            azure = True
        except ApiError:
            pass
        try:
            with db._supabase().cursor() as cur:
                cur.execute("SELECT 1")
            supabase = True
        except ApiError:
            pass
        return jsonify(instancia=config.INSTANCIA, azure_sql=azure, supabase=supabase,
                       modo="normal" if db.azure_disponible() else "contingencia")

    if config.NOTIFICADOR_ACTIVO:
        notificaciones.iniciar_notificador()

    return app
