"""Ejecuta scripts .sql (separados por GO) en Azure SQL con la identidad Entra ID de 'az login'.

No usa la contraseña del administrador SQL: pide un token a Azure CLI.
Los marcadores <CONTRASEÑA_API> y <CONTRASEÑA_SYNC> de 06_seguridad.sql se
reemplazan en memoria con los valores de secretos/credenciales.env.

Uso:  python database/ejecutar_azure_sql.py 01_esquema.sql 02_change_tracking.sql ...
"""
import re
import struct
import subprocess
import sys
from pathlib import Path

import pyodbc

RAIZ = Path(__file__).resolve().parent.parent
AZ = r"C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd"
SQL_COPT_SS_ACCESS_TOKEN = 1256


def credenciales() -> dict:
    datos = {}
    for linea in (RAIZ / "secretos" / "credenciales.env").read_text(encoding="utf-8").splitlines():
        if linea and not linea.startswith("#") and "=" in linea:
            k, v = linea.split("=", 1)
            datos[k] = v
    return datos


def conectar(c: dict) -> pyodbc.Connection:
    token = subprocess.run([AZ, "account", "get-access-token", "--resource", "https://database.windows.net/",
                            "--query", "accessToken", "-o", "tsv"], capture_output=True, text=True, check=True).stdout.strip()
    token_bytes = token.encode("utf-16-le")
    estructura = struct.pack(f"<I{len(token_bytes)}s", len(token_bytes), token_bytes)
    cadena = (f"Driver={{ODBC Driver 18 for SQL Server}};Server=tcp:{c['AZURE_SQL_SERVIDOR']},1433;"
              f"Database={c['AZURE_SQL_BASE']};Encrypt=yes;TrustServerCertificate=no;Connection Timeout=60;")
    return pyodbc.connect(cadena, attrs_before={SQL_COPT_SS_ACCESS_TOKEN: estructura}, autocommit=True)


def lotes(texto: str) -> list[str]:
    return [b.strip() for b in re.split(r"^\s*GO\s*$", texto, flags=re.M | re.I) if b.strip()]


def main():
    c = credenciales()
    cn = conectar(c)
    print("Conectado a", c["AZURE_SQL_SERVIDOR"], "/", c["AZURE_SQL_BASE"], "como",
          cn.execute("SELECT SUSER_SNAME()").fetchval())
    for nombre in sys.argv[1:]:
        ruta = RAIZ / "database" / "azure-sql" / nombre
        texto = ruta.read_text(encoding="utf-8")
        texto = (texto.replace("<CONTRASEÑA_API>", c["AZURE_SQL_APP_API_PASSWORD"])
                      .replace("<CONTRASEÑA_SYNC>", c["AZURE_SQL_APP_SYNC_PASSWORD"]))
        partes = lotes(texto)
        for i, lote in enumerate(partes, 1):
            try:
                cur = cn.cursor()
                cur.execute(lote)
                while cur.nextset():
                    pass
            except pyodbc.Error as e:
                print(f"  ERROR en {nombre}, lote {i}/{len(partes)}: {e}")
                sys.exit(1)
        print(f"  OK {nombre} ({len(partes)} lotes)")


if __name__ == "__main__":
    main()
