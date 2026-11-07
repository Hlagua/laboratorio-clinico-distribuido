"""Servicio de autenticación: registro de pacientes, login y perfil."""
from datetime import datetime, timedelta, timezone

from flask import Blueprint, jsonify, request

from .. import config, db
from ..errores import ApiError
from ..seguridad import emitir_token, hash_password, requiere, usuario_actual, validar_password, verificar_password
from ..validacion import cedula, cuerpo, fecha, texto

bp = Blueprint("auth", __name__, url_prefix="/api/auth")

SQL_USUARIO = """
SELECT u.usuario_id, u.persona_id, u.email, u.password_hash, u.activo, u.intentos_fallidos, u.bloqueado_hasta,
       CONCAT(p.nombres, ' ', p.apellidos) AS nombre,
       pa.paciente_id, m.medico_id, l.laboratorista_id
FROM {e}.usuario u
JOIN {e}.persona p ON p.persona_id = u.persona_id
LEFT JOIN {e}.paciente pa ON pa.persona_id = u.persona_id
LEFT JOIN {e}.medico m ON m.persona_id = u.persona_id
LEFT JOIN {e}.laboratorista l ON l.persona_id = u.persona_id
WHERE u.email = ?
"""

SQL_ROLES = """
SELECT r.codigo FROM {e}.usuario_rol ur JOIN {e}.rol r ON r.rol_id = ur.rol_id
WHERE ur.usuario_id = ? ORDER BY r.rol_id
"""

SQL_PERMISOS = """
SELECT DISTINCT pe.codigo FROM {e}.usuario_rol ur
JOIN {e}.rol_permiso rp ON rp.rol_id = ur.rol_id
JOIN {e}.permiso pe ON pe.permiso_id = rp.permiso_id
WHERE ur.usuario_id = ? ORDER BY pe.codigo
"""


def _perfil(usuario_id: int, email: str | None = None) -> dict:
    u = db.leer_uno(SQL_USUARIO.replace("u.email = ?", "u.usuario_id = ?"), usuario_id) if email is None \
        else db.leer_uno(SQL_USUARIO, email)
    u["roles"] = [r["codigo"] for r in db.leer(SQL_ROLES, u["usuario_id"])]
    return u


@bp.post("/registro")
def registro():
    """Alta de paciente desde el portal (si la cédula ya existe, solo agrega el rol)."""
    d = cuerpo()
    password = texto(d, "password", maximo=72)
    validar_password(password)
    email = texto(d, "email", maximo=150).lower()
    if "@" not in email:
        raise ApiError("El correo no es válido.", 422, "EMAIL_INVALIDO")
    paciente_id = db.ejecutar_sp(
        "sp_registrar_paciente", "paciente_id",
        cedula=cedula(texto(d, "cedula", maximo=10)), nombres=texto(d, "nombres", maximo=100),
        apellidos=texto(d, "apellidos", maximo=100), fecha_nacimiento=fecha(d, "fecha_nacimiento"),
        sexo=texto(d, "sexo", maximo=1).upper(), telefono=texto(d, "telefono", False, 20), email=email,
        direccion=texto(d, "direccion", False, 250), password_hash=hash_password(password),
        tipo_sangre=texto(d, "tipo_sangre", False, 3), alergias=texto(d, "alergias", False, 500),
    )
    return jsonify(paciente_id=paciente_id, mensaje="Registro exitoso. Ya puede iniciar sesión."), 201


@bp.post("/login")
def login():
    d = cuerpo()
    email = texto(d, "email", maximo=150).lower()
    password = texto(d, "password", maximo=72)
    u = db.leer_uno(SQL_USUARIO, email)            # funciona también en contingencia
    en_azure = db.azure_disponible()
    ahora = datetime.now(timezone.utc).replace(tzinfo=None)

    if not u or not u["activo"]:
        raise ApiError("Correo o contraseña incorrectos.", 401, "CREDENCIALES")
    if u["bloqueado_hasta"] and u["bloqueado_hasta"] > ahora:
        raise ApiError("Cuenta bloqueada temporalmente por intentos fallidos.", 423, "CUENTA_BLOQUEADA")

    if not verificar_password(password, u["password_hash"]):
        if en_azure:
            intentos = u["intentos_fallidos"] + 1
            bloqueo = ahora + timedelta(minutes=config.MINUTOS_BLOQUEO) if intentos >= config.INTENTOS_LOGIN_MAX else None
            db.ejecutar("UPDATE dbo.usuario SET intentos_fallidos = ?, bloqueado_hasta = ?, updated_at = SYSUTCDATETIME() "
                        "WHERE usuario_id = ?", 0 if bloqueo else intentos, bloqueo, u["usuario_id"])
        raise ApiError("Correo o contraseña incorrectos.", 401, "CREDENCIALES")

    u["roles"] = [r["codigo"] for r in db.leer(SQL_ROLES, u["usuario_id"])]
    if not u["roles"]:
        raise ApiError("El usuario no tiene roles asignados.", 403, "SIN_ROLES")

    # En contingencia no se escribe (Supabase es solo lectura).
    if en_azure and db.azure_disponible():
        db.ejecutar("UPDATE dbo.usuario SET ultimo_login = SYSUTCDATETIME(), intentos_fallidos = 0, bloqueado_hasta = NULL "
                    "WHERE usuario_id = ?", u["usuario_id"])
        db.ejecutar_sp("sp_auditar", usuario_id=u["usuario_id"], accion="LOGIN", entidad="usuario",
                       entidad_id=str(u["usuario_id"]), ip_origen=request.headers.get("X-Real-IP", request.remote_addr),
                       instancia_api=config.INSTANCIA)

    return jsonify(token=emitir_token(u), expira_en_horas=config.JWT_HORAS, usuario=_publico(u))


@bp.get("/me")
@requiere()
def me():
    u = _perfil(usuario_actual()["usuario_id"])
    datos = _publico(u)
    datos["permisos"] = [p["codigo"] for p in db.leer(SQL_PERMISOS, u["usuario_id"])]
    return jsonify(datos)


def _publico(u: dict) -> dict:
    return {k: u[k] for k in ("usuario_id", "persona_id", "nombre", "email", "roles",
                              "paciente_id", "medico_id", "laboratorista_id")}
