"""Configuración de la API, leída de variables de entorno (.env)."""
import os
import socket

from dotenv import load_dotenv

load_dotenv()


def _bool(nombre: str, defecto: bool = False) -> bool:
    return os.getenv(nombre, str(defecto)).strip().lower() in ("1", "true", "si", "sí", "yes")


INSTANCIA = os.getenv("INSTANCIA", socket.gethostname())

# Bases de datos
AZURE_SQL_CONN = os.getenv("AZURE_SQL_CONN", "")
SUPABASE_DSN = os.getenv("SUPABASE_DSN", "")          # rol lab_lectura (solo lectura)
# Guías clínicas de la base de conocimientos (MongoDB Atlas, solo lectura)
MONGO_URI = os.getenv("MONGO_URI", "")
MONGO_DB = os.getenv("MONGO_DB", "laboratorio")

# Circuit breaker hacia Azure SQL
CB_TIMEOUT_CONEXION = int(os.getenv("CB_TIMEOUT_CONEXION", "3"))   # s para conectar
CB_TIMEOUT_CONSULTA = int(os.getenv("CB_TIMEOUT_CONSULTA", "10"))  # s por consulta
CB_SEGUNDOS_ABIERTO = float(os.getenv("CB_SEGUNDOS_ABIERTO", "15"))  # antes de reintentar Azure

# Seguridad
JWT_SECRETO = os.getenv("JWT_SECRETO", "")
JWT_HORAS = float(os.getenv("JWT_HORAS", "8"))
SOAP_API_KEY = os.getenv("SOAP_API_KEY", "")
CORS_ORIGENES = [o for o in os.getenv("CORS_ORIGENES", "").split(",") if o]
INTENTOS_LOGIN_MAX = int(os.getenv("INTENTOS_LOGIN_MAX", "5"))
MINUTOS_BLOQUEO = int(os.getenv("MINUTOS_BLOQUEO", "15"))

# Stripe (modo prueba)
STRIPE_SECRET_KEY = os.getenv("STRIPE_SECRET_KEY", "")
STRIPE_WEBHOOK_SECRET = os.getenv("STRIPE_WEBHOOK_SECRET", "")
URL_PORTAL = os.getenv("URL_PORTAL", "https://localhost")       # retorno desde Stripe Checkout

# Mailjet
MAILJET_API_KEY = os.getenv("MAILJET_API_KEY", "")
MAILJET_API_SECRET = os.getenv("MAILJET_API_SECRET", "")
MAIL_REMITENTE = os.getenv("MAIL_REMITENTE", "")
MAIL_REMITENTE_NOMBRE = os.getenv("MAIL_REMITENTE_NOMBRE", "Laboratorio Clínico")
NOTIFICADOR_ACTIVO = _bool("NOTIFICADOR_ACTIVO")
NOTIFICADOR_INTERVALO = float(os.getenv("NOTIFICADOR_INTERVALO", "10"))

# Fase VI: habilita ?proteccion=0 en la reserva de citas para la prueba comparativa.
PERMITIR_PRUEBA_CONCURRENCIA = _bool("PERMITIR_PRUEBA_CONCURRENCIA")

# Datos ficticios de la cuenta para pagos por transferencia con QR.
CUENTA_TRANSFERENCIA = os.getenv("CUENTA_TRANSFERENCIA", "Banco Ficticio · Cta. Corriente 2200000000 · Laboratorio Clínico S.A.")


def validar():
    faltan = [n for n in ("AZURE_SQL_CONN", "SUPABASE_DSN", "JWT_SECRETO") if not globals()[n]]
    if faltan:
        raise RuntimeError(f"Faltan variables de entorno: {', '.join(faltan)}")
    if len(JWT_SECRETO) < 32:
        raise RuntimeError("JWT_SECRETO debe tener al menos 32 caracteres")
