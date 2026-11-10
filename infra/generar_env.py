"""Genera los .env de despliegue a partir de secretos/credenciales.env.

Salida (excluida del repositorio):
  secretos/despliegue/api.env     -> /opt/laboratorio/api/.env          (igual en ambas VM)
  secretos/despliegue/sync.env    -> /opt/laboratorio/sync-worker/.env  (igual en ambas VM)
  secretos/despliegue/vm1.env     -> /opt/laboratorio/infra/.env en VM1
  secretos/despliegue/vm2.env     -> /opt/laboratorio/infra/.env en VM2

Los valores van entre comillas simples: docker compose los toma literales.
"""
from pathlib import Path
from urllib.parse import quote

RAIZ = Path(__file__).resolve().parent.parent
c = {}
for linea in (RAIZ / "secretos" / "credenciales.env").read_text(encoding="utf-8").splitlines():
    if linea and not linea.startswith("#") and "=" in linea:
        k, v = linea.split("=", 1)
        c[k] = v

pendiente = lambda v: (not v) or "<" in v
# DOMINIO_PRINCIPAL: nombre con el que se publica (certificado y URL de retorno de Stripe).
dominio = c.get("DOMINIO_PRINCIPAL") or (f"{c['DUCKDNS_SUBDOMINIO']}.duckdns.org"
                                         if not pendiente(c.get("DUCKDNS_SUBDOMINIO", "")) else "laboratorio.pendiente")


def azure(usuario: str, clave: str) -> str:
    return (f"Driver={{ODBC Driver 18 for SQL Server}};Server=tcp:{c['AZURE_SQL_SERVIDOR']},1433;"
            f"Database={c['AZURE_SQL_BASE']};Uid={usuario};Pwd={{{clave}}};Encrypt=yes;"
            "TrustServerCertificate=no;Connection Timeout=8;")


def supabase(rol: str, clave: str) -> str:
    return (f"postgresql://{rol}.{c['SUPABASE_PROJECT_REF']}:{quote(clave, safe='')}@"
            f"{c['SUPABASE_POOLER_HOST']}:5432/postgres?sslmode=require")


def escribir(nombre: str, valores: dict):
    destino = RAIZ / "secretos" / "despliegue" / nombre
    destino.parent.mkdir(parents=True, exist_ok=True)
    # newline="\n": en Windows, write_text pondría \r\n y Linux leería un "\r" pegado a cada valor.
    destino.write_text("".join(f"{k}='{v}'\n" for k, v in valores.items()), encoding="utf-8", newline="\n")
    print("generado", destino.relative_to(RAIZ))


escribir("api.env", {
    "AZURE_SQL_CONN": azure("app_api", c["AZURE_SQL_APP_API_PASSWORD"]),
    "SUPABASE_DSN": supabase("lab_lectura", c["SUPABASE_LAB_LECTURA_PASSWORD"]),
    "CB_TIMEOUT_CONEXION": "8", "CB_TIMEOUT_CONSULTA": "10", "CB_SEGUNDOS_ABIERTO": "15",
    "JWT_SECRETO": c["JWT_SECRETO"], "JWT_HORAS": "8", "SOAP_API_KEY": c["SOAP_API_KEY"],
    "STRIPE_SECRET_KEY": c["STRIPE_SECRET_KEY"], "STRIPE_WEBHOOK_SECRET": c.get("STRIPE_WEBHOOK_SECRET", ""),
    "URL_PORTAL": f"https://{dominio}",
    "MAILJET_API_KEY": c["MAILJET_API_KEY"], "MAILJET_API_SECRET": c["MAILJET_API_SECRET"],
    "MAIL_REMITENTE": c["MAIL_REMITENTE"], "MAIL_REMITENTE_NOMBRE": "Laboratorio Clinico",
    "NOTIFICADOR_INTERVALO": "10", "PERMITIR_PRUEBA_CONCURRENCIA": "false",
    "MONGO_URI": c["MONGO_URI"], "MONGO_DB": "laboratorio",   # guías clínicas (base de conocimientos)
})
escribir("sync.env", {
    "AZURE_SQL_CONN": azure("app_sync", c["AZURE_SQL_APP_SYNC_PASSWORD"]).replace("Connection Timeout=8", "Connection Timeout=15"),
    "SUPABASE_DSN": supabase("lab_sync", c["SUPABASE_LAB_SYNC_PASSWORD"]),
    "MONGO_URI": c["MONGO_URI"], "MONGO_DB": "laboratorio",
    "SYNC_INTERVALO": "5", "SYNC_BACKOFF_MAX": "60", "SYNC_MINUTOS_EXPIRAR_CITAS": "30",
})
for n, (a, b), otra in ((1, ("api1", "api2"), "172.16.0.5"), (2, ("api3", "api4"), "172.16.0.4")):
    escribir(f"vm{n}.env", {"VM_NOMBRE": f"vm{n}", "API_A": a, "API_B": b, "DOMINIO": dominio, "OTRA_VM_IP": otra})
