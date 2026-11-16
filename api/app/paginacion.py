"""Paginación y filtros comunes de los listados del sistema transaccional.

Compatibilidad: si la petición NO trae ?pagina, se devuelve la lista como
antes (limitada a `maximo` filas), para no romper al portal ni a las pruebas.
Con ?pagina=N (&por_pagina=M) se devuelve
    {"items": [...], "total": T, "pagina": N, "por_pagina": M, "paginas": P}

La consulta usa OFFSET ... FETCH, que es SQL estándar: funciona igual en
Azure SQL y en Supabase (PostgreSQL) durante la contingencia.
"""
from datetime import date, timedelta

from flask import jsonify, request

from . import db
from .errores import ApiError

POR_PAGINA_DEFECTO = 20
POR_PAGINA_MAXIMO = 100


def listar(sql: str, params: list, orden: str, *, maximo: int = 200, contingencia: bool = True):
    """`sql` sin ORDER BY (lleva {e}); `orden` es la cláusula ORDER BY completa."""
    if not request.args.get("pagina"):
        return jsonify(db.leer(f"{sql} {orden}", *params, contingencia=contingencia)[:maximo])

    pagina = max(request.args.get("pagina", 1, type=int) or 1, 1)
    por_pagina = min(max(request.args.get("por_pagina", POR_PAGINA_DEFECTO, type=int) or POR_PAGINA_DEFECTO, 1),
                     POR_PAGINA_MAXIMO)
    total = db.leer(f"SELECT COUNT(*) AS n FROM ({sql}) x", *params, contingencia=contingencia)[0]["n"]
    paginas = max((total + por_pagina - 1) // por_pagina, 1)
    pagina = min(pagina, paginas)
    items = db.leer(f"{sql} {orden} OFFSET ? ROWS FETCH NEXT ? ROWS ONLY",
                    *params, (pagina - 1) * por_pagina, por_pagina, contingencia=contingencia)
    return jsonify(items=items, total=total, pagina=pagina, por_pagina=por_pagina, paginas=paginas)


def rango_fechas(columna: str, condiciones: list, params: list):
    """Agrega ?desde / ?hasta (AAAA-MM-DD, ambos inclusive) sobre una columna de fecha y hora."""
    for nombre, operador, extra in (("desde", ">=", 0), ("hasta", "<", 1)):
        valor = request.args.get(nombre)
        if not valor:
            continue
        try:
            dia = date.fromisoformat(valor) + timedelta(days=extra)
        except ValueError:
            raise ApiError(f"El parámetro '{nombre}' debe tener formato AAAA-MM-DD.", 422, "TIPO_INVALIDO")
        condiciones.append(f"{columna} {operador} ?")
        params.append(dia)


def donde(condiciones: list) -> str:
    return " WHERE " + " AND ".join(condiciones) if condiciones else ""
