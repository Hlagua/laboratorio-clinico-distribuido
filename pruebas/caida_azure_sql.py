"""Prueba 6 y 7: interrupción de Azure SQL y consultas desde Supabase.

Simula la caída real de la base principal vista desde las VM:
  1. agrega una regla TEMPORAL de salida en el NSG de cada VM que bloquea el
     tráfico hacia Azure SQL (etiqueta de servicio "Sql", puertos 1433 y
     11000-11999). Efecto inmediato; el firewall de Azure SQL tarda hasta 5 min.
  2. cierra (KILL) las sesiones abiertas de app_api y app_sync
Luego verifica, a través del balanceador, que:
  - el login y las consultas responden desde Supabase (X-Origen-Datos: supabase)
  - las escrituras responden 503 MODO_CONTINGENCIA
y al final restaura las reglas y comprueba la recuperación.

Uso:  python pruebas/caida_azure_sql.py [segundos_de_caida]
"""
import sys
import time

import requests

from comun import GRUPO, ahora, az, azure_sql_admin, credenciales, guardar, url_base

NSGS = ["ad-2026-nsg", "lab-vm2-nsg"]
REGLA = "Prueba-caida-azure-sql"
DURACION = int(sys.argv[1]) if len(sys.argv) > 1 else 60
c = credenciales()
D = url_base()
eventos = []


def registrar(texto, **datos):
    linea = {"hora": ahora(), "evento": texto, **datos}
    eventos.append(linea)
    print(f"{linea['hora']}  {texto}  {datos if datos else ''}")


def sondear(token: str, etiqueta: str) -> dict:
    h = {"Authorization": f"Bearer {token}"}
    r1 = requests.get(f"{D}/api/solicitudes/mias", headers=h, timeout=30)
    r2 = requests.get(f"{D}/api/examenes/catalogo", timeout=30)
    r3 = requests.post(f"{D}/api/citas", headers=h, json={"franja_id": 1}, timeout=30)
    res = {"mis_solicitudes": (r1.status_code, r1.headers.get("X-Origen-Datos"), r1.headers.get("X-Instancia")),
           "catalogo": (r2.status_code, r2.headers.get("X-Origen-Datos"), r2.headers.get("X-Instancia")),
           "escritura_cita": (r3.status_code, r3.json().get("codigo"))}
    registrar(etiqueta, **res)
    return res


def login() -> tuple[int, str, str | None]:
    r = requests.post(f"{D}/api/auth/login", json={"email": "pedro.castillo@correo.test", "password": "Lab2026*"}, timeout=30)
    return r.status_code, r.json().get("token", ""), r.headers.get("X-Instancia")


codigo, token, inst = login()
registrar("login normal", estado=codigo, instancia=inst)
antes = sondear(token, "ANTES de la caída")

# ---------------- caída ----------------
for nsg in NSGS:
    az("network", "nsg", "rule", "create", "-g", GRUPO, "--nsg-name", nsg, "-n", REGLA, "--priority", "100",
       "--direction", "Outbound", "--access", "Deny", "--protocol", "Tcp", "--destination-address-prefixes", "Sql",
       "--destination-port-ranges", "1433", "11000-11999", "--description", "Prueba temporal de caida de Azure SQL", "-o", "none")
registrar("regla temporal: salida hacia Azure SQL BLOQUEADA en ambas VM")
cn = azure_sql_admin()
sesiones = [r[0] for r in cn.execute(
    "SELECT session_id FROM sys.dm_exec_sessions WHERE login_name IN ('app_api','app_sync')").fetchall()]
for s in sesiones:
    try:
        cn.execute(f"KILL {int(s)}")
    except Exception:
        pass
registrar("sesiones de app_api/app_sync cerradas", cantidad=len(sesiones))
inicio_caida = time.time()

time.sleep(5)
codigo_c, token_c, inst_c = login()
registrar("login DURANTE la caída", estado=codigo_c, instancia=inst_c)
durante = [sondear(token_c or token, f"DURANTE la caída ({i + 1})") for i in range(3)]
restante = DURACION - (time.time() - inicio_caida)
if restante > 0:
    time.sleep(restante)

# ---------------- recuperación ----------------
for nsg in NSGS:
    az("network", "nsg", "rule", "delete", "-g", GRUPO, "--nsg-name", nsg, "-n", REGLA)
registrar("regla temporal eliminada: Azure SQL vuelve a estar accesible")
t0 = time.time()
despues = None
while time.time() - t0 < 120:
    time.sleep(5)
    r = requests.get(f"{D}/api/examenes/catalogo", timeout=30)
    if r.headers.get("X-Origen-Datos") == "azure":
        despues = sondear(token, f"DESPUÉS (recuperado en ~{int(time.time() - t0)} s)")
        break

ruta = guardar("caida_azure_sql.json", {"duracion_s": DURACION, "antes": antes, "durante": durante,
                                         "despues": despues, "eventos": eventos})
print("\nResultado guardado en", ruta)
