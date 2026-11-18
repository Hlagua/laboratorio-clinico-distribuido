"""Validación sencilla del cuerpo JSON de las peticiones."""
import re
from datetime import date
from decimal import Decimal, InvalidOperation

from flask import request

from .errores import ApiError


def cuerpo() -> dict:
    datos = request.get_json(silent=True)
    if not isinstance(datos, dict):
        raise ApiError("El cuerpo debe ser un objeto JSON.", 400, "JSON_INVALIDO")
    return datos


def texto(datos: dict, campo: str, requerido: bool = True, maximo: int = 500) -> str | None:
    valor = datos.get(campo)
    if valor is None or (isinstance(valor, str) and not valor.strip()):
        if requerido:
            raise ApiError(f"El campo '{campo}' es obligatorio.", 422, "CAMPO_REQUERIDO")
        return None
    if not isinstance(valor, str):
        raise ApiError(f"El campo '{campo}' debe ser texto.", 422, "TIPO_INVALIDO")
    valor = valor.strip()
    if len(valor) > maximo:
        raise ApiError(f"El campo '{campo}' admite máximo {maximo} caracteres.", 422, "LONGITUD")
    return valor


def entero(datos: dict, campo: str, requerido: bool = True) -> int | None:
    valor = datos.get(campo)
    if valor is None:
        if requerido:
            raise ApiError(f"El campo '{campo}' es obligatorio.", 422, "CAMPO_REQUERIDO")
        return None
    if isinstance(valor, bool) or not isinstance(valor, int) or valor <= 0:
        raise ApiError(f"El campo '{campo}' debe ser un entero positivo.", 422, "TIPO_INVALIDO")
    return valor


def decimal(datos: dict, campo: str, requerido: bool = True) -> Decimal | None:
    valor = datos.get(campo)
    if valor is None:
        if requerido:
            raise ApiError(f"El campo '{campo}' es obligatorio.", 422, "CAMPO_REQUERIDO")
        return None
    try:
        numero = Decimal(str(valor))
    except InvalidOperation:
        raise ApiError(f"El campo '{campo}' debe ser numérico.", 422, "TIPO_INVALIDO")
    return numero


def fecha(datos: dict, campo: str, requerido: bool = True) -> date | None:
    valor = texto(datos, campo, requerido, 10)
    if valor is None:
        return None
    try:
        return date.fromisoformat(valor)
    except ValueError:
        raise ApiError(f"El campo '{campo}' debe tener formato AAAA-MM-DD.", 422, "TIPO_INVALIDO")


def cedula(valor: str) -> str:
    """Valida cédula ecuatoriana (10 dígitos, provincia y dígito verificador)."""
    if not (valor.isdigit() and len(valor) == 10 and 1 <= int(valor[:2]) <= 24 and int(valor[2]) < 6):
        raise ApiError("La cédula no es válida.", 422, "CEDULA_INVALIDA")
    coef = [2, 1, 2, 1, 2, 1, 2, 1, 2]
    suma = sum(d - 9 if d > 9 else d for d in (int(c) * k for c, k in zip(valor[:9], coef)))
    if (10 - suma % 10) % 10 != int(valor[9]):
        raise ApiError("La cédula no es válida (dígito verificador).", 422, "CEDULA_INVALIDA")
    return valor


def lista_enteros(datos: dict, campo: str) -> list[int]:
    valor = datos.get(campo)
    if not isinstance(valor, list) or not valor or not all(isinstance(x, int) and not isinstance(x, bool) and x > 0 for x in valor):
        raise ApiError(f"El campo '{campo}' debe ser una lista de enteros positivos.", 422, "TIPO_INVALIDO")
    return valor


_LETRAS = re.compile(r"^[A-Za-zÁÉÍÓÚÜÑáéíóúüñ' ]+$")


def nombre(datos: dict, campo: str) -> str:
    """Nombres y apellidos: solo letras (con tildes), espacios y apóstrofo; hasta 50 caracteres."""
    valor = " ".join(texto(datos, campo, maximo=50).split())
    if not _LETRAS.match(valor):
        raise ApiError(f"'{campo}' solo puede tener letras.", 422, "TIPO_INVALIDO")
    return valor


def telefono(datos: dict, campo: str = "telefono") -> str | None:
    """Teléfono opcional: 9 o 10 dígitos, empieza con 0 (fijo o celular de Ecuador)."""
    valor = texto(datos, campo, False, 10)
    if valor and not re.fullmatch(r"0\d{8,9}", valor):
        raise ApiError("El teléfono debe tener 9 o 10 dígitos y empezar con 0.", 422, "TELEFONO_INVALIDO")
    return valor
