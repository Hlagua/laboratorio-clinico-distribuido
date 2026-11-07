"""Configuración del sincronizador, leída de variables de entorno (.env)."""
import os
import socket

from dotenv import load_dotenv

load_dotenv()


def _requerida(nombre: str) -> str:
    valor = os.getenv(nombre)
    if not valor:
        raise RuntimeError(f"Falta la variable de entorno {nombre}")
    return valor


AZURE_SQL_CONN = _requerida("AZURE_SQL_CONN")
SUPABASE_DSN = _requerida("SUPABASE_DSN")
MONGO_URI = _requerida("MONGO_URI")
MONGO_DB = os.getenv("MONGO_DB", "laboratorio")

INTERVALO_SEGUNDOS = float(os.getenv("SYNC_INTERVALO", "5"))
BACKOFF_MAXIMO = float(os.getenv("SYNC_BACKOFF_MAX", "60"))
MINUTOS_EXPIRAR_CITAS = int(os.getenv("SYNC_MINUTOS_EXPIRAR_CITAS", "30"))
INSTANCIA = os.getenv("SYNC_INSTANCIA", socket.gethostname())
