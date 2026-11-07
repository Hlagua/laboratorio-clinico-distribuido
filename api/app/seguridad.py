"""Autenticación JWT y autorización por roles.

Una persona puede tener varios roles. El token lleva todos; el cliente
indica con qué rol está trabajando con la cabecera X-Rol-Activo. Si no
la envía, se usa el primero de sus roles que el endpoint acepte.
"""
from datetime import datetime, timedelta, timezone
from functools import wraps

import bcrypt
import jwt
from flask import g, request

from . import config
from .errores import ApiError, prohibido

ROLES = ("PACIENTE", "LABORATORISTA", "MEDICO", "ADMIN")
PERSONAL = ("LABORATORISTA", "MEDICO", "ADMIN")


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode(), bcrypt.gensalt(12)).decode()


def verificar_password(password: str, hash_guardado: str) -> bool:
    try:
        return bcrypt.checkpw(password.encode(), hash_guardado.encode())
    except ValueError:
        return False


def validar_password(password: str):
    if (len(password) < 8 or not any(c.isdigit() for c in password)
            or not any(c.isalpha() for c in password)):
        raise ApiError("La contraseña debe tener al menos 8 caracteres, letras y números.", 422, "PASSWORD_DEBIL")
    if len(password.encode()) > 72:    # límite de bcrypt
        raise ApiError("La contraseña es demasiado larga.", 422, "PASSWORD_LARGA")


def emitir_token(usuario: dict) -> str:
    ahora = datetime.now(timezone.utc)
    claims = {
        "sub": str(usuario["usuario_id"]),
        "persona_id": usuario["persona_id"],
        "nombre": usuario["nombre"],
        "email": usuario["email"],
        "roles": usuario["roles"],
        "paciente_id": usuario.get("paciente_id"),
        "medico_id": usuario.get("medico_id"),
        "laboratorista_id": usuario.get("laboratorista_id"),
        "iat": ahora,
        "exp": ahora + timedelta(hours=config.JWT_HORAS),
        "iss": "laboratorio-clinico",
    }
    return jwt.encode(claims, config.JWT_SECRETO, algorithm="HS256")


def _usuario_del_token() -> dict:
    cabecera = request.headers.get("Authorization", "")
    if not cabecera.startswith("Bearer "):
        raise ApiError("Falta el token de acceso.", 401, "NO_AUTENTICADO")
    try:
        claims = jwt.decode(cabecera[7:], config.JWT_SECRETO, algorithms=["HS256"],
                            issuer="laboratorio-clinico", options={"require": ["exp", "sub"]})
    except jwt.ExpiredSignatureError:
        raise ApiError("La sesión expiró, inicie sesión nuevamente.", 401, "TOKEN_EXPIRADO")
    except jwt.InvalidTokenError:
        raise ApiError("Token inválido.", 401, "TOKEN_INVALIDO")
    claims["usuario_id"] = int(claims["sub"])
    return claims


def requiere(*roles_permitidos: str):
    """Exige token válido y (si se indican) alguno de los roles permitidos."""
    def decorador(f):
        @wraps(f)
        def envoltura(*args, **kwargs):
            usuario = _usuario_del_token()
            g.usuario = usuario
            pedido = request.headers.get("X-Rol-Activo")
            if pedido and pedido not in usuario["roles"]:
                raise prohibido("No tiene asignado el rol indicado en X-Rol-Activo.")
            if roles_permitidos:
                candidatos = [pedido] if pedido else usuario["roles"]
                validos = [r for r in candidatos if r in roles_permitidos]
                if not validos:
                    raise prohibido(f"Esta operación requiere uno de estos roles: {', '.join(roles_permitidos)}.")
                g.rol = validos[0]
            else:
                g.rol = pedido or usuario["roles"][0]
            return f(*args, **kwargs)
        return envoltura
    return decorador


def usuario_actual() -> dict:
    return g.usuario


def rol_actual() -> str:
    return g.rol


def perfil(campo: str) -> int:
    """paciente_id / medico_id / laboratorista_id del usuario actual."""
    valor = g.usuario.get(campo)
    if not valor:
        raise prohibido("Su usuario no tiene el perfil requerido para esta operación.")
    return valor
