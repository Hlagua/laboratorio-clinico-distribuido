"""Errores de la API y traducción de los errores de negocio de SQL Server."""
import re

import pyodbc


class ApiError(Exception):
    def __init__(self, mensaje: str, estado: int = 400, codigo: str = "SOLICITUD_INVALIDA"):
        super().__init__(mensaje)
        self.mensaje = mensaje
        self.estado = estado
        self.codigo = codigo


class ModoContingencia(ApiError):
    def __init__(self):
        super().__init__("Sistema en modo contingencia: la base principal no está disponible, solo se permiten consultas.",
                         503, "MODO_CONTINGENCIA")


def no_encontrado(que: str = "El recurso") -> ApiError:
    return ApiError(f"{que} no existe.", 404, "NO_ENCONTRADO")


def prohibido(mensaje: str = "No tiene permiso para esta operación.") -> ApiError:
    return ApiError(mensaje, 403, "PROHIBIDO")


# Códigos THROW de los procedimientos almacenados -> estado HTTP.
_HTTP_POR_CODIGO = {
    50001: 409, 50002: 404, 50003: 404, 50010: 404, 50011: 409, 50012: 409, 50013: 404, 50014: 409,
    50022: 404, 50023: 403, 50030: 404, 50031: 409, 50032: 404, 50040: 404, 50041: 409, 50042: 422,
    50051: 404, 50052: 409, 50053: 409, 50055: 403, 50060: 403, 50061: 403, 50062: 403,
    # base de conocimientos (07_base_conocimiento.sql)
    50080: 422, 50081: 404, 50082: 404, 50083: 409, 50084: 422, 50085: 403, 50086: 403, 50087: 422, 50088: 422,
}
_PATRON_CODIGO = re.compile(r"\((5\d{4})\)")
_PATRON_MENSAJE = re.compile(r"\[SQL Server\](.*?)\s*\(\d+\)\s*\(SQL", re.S)


def desde_sql(e: pyodbc.Error) -> ApiError | None:
    """Convierte un error de negocio (THROW 50xxx) o de integridad en ApiError."""
    texto = str(e)
    m = _PATRON_CODIGO.search(texto)
    if m and 50000 <= int(m.group(1)) < 50100:
        codigo = int(m.group(1))
        mensaje = _PATRON_MENSAJE.search(texto)
        return ApiError(mensaje.group(1).strip() if mensaje else "Operación rechazada.",
                        _HTTP_POR_CODIGO.get(codigo, 400), f"NEGOCIO_{codigo}")
    if isinstance(e, pyodbc.IntegrityError):
        if "2627" in texto or "2601" in texto:
            return ApiError("Ya existe un registro con esos datos.", 409, "DUPLICADO")
        if "547" in texto:
            return ApiError("Los datos no cumplen una restricción de integridad.", 422, "INTEGRIDAD")
    return None
