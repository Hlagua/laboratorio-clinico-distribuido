"""Utilidades compartidas por los scripts de prueba (se ejecutan desde el PC del equipo)."""
import json
import struct
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import pyodbc

RAIZ = Path(__file__).resolve().parent.parent
AZ = r"C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
GRUPO = "ad-2026_grupo"
RESULTADOS = RAIZ / "pruebas" / "resultados"


def credenciales() -> dict:
    datos = {}
    for linea in (RAIZ / "secretos" / "credenciales.env").read_text(encoding="utf-8").splitlines():
        if linea and not linea.startswith("#") and "=" in linea:
            k, v = linea.split("=", 1)
            datos[k] = v
    return datos


def url_base() -> str:
    return f"https://{credenciales()['DOMINIO_PRINCIPAL']}"


def az(*args: str) -> str:
    r = subprocess.run([AZ, *args, "--only-show-errors"], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    return r.stdout.strip()


def azure_sql_admin() -> pyodbc.Connection:
    """Conexión a Azure SQL con la identidad Entra de 'az login' (administrador)."""
    c = credenciales()
    token = az("account", "get-access-token", "--resource", "https://database.windows.net/",
               "--query", "accessToken", "-o", "tsv").encode("utf-16-le")
    estructura = struct.pack(f"<I{len(token)}s", len(token), token)
    return pyodbc.connect(
        f"Driver={{ODBC Driver 18 for SQL Server}};Server=tcp:{c['AZURE_SQL_SERVIDOR']},1433;"
        f"Database={c['AZURE_SQL_BASE']};Encrypt=yes;Connection Timeout=60;",
        attrs_before={1256: estructura}, autocommit=True)


def ahora() -> str:
    return datetime.now(timezone.utc).strftime("%H:%M:%S")


def guardar(nombre: str, datos) -> Path:
    RESULTADOS.mkdir(parents=True, exist_ok=True)
    ruta = RESULTADOS / nombre
    ruta.write_text(json.dumps(datos, ensure_ascii=False, indent=2, default=str), encoding="utf-8")
    return ruta
