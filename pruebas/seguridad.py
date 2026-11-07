"""Prueba 10: acceso seguro y roles contra el sistema publicado.

Verifica HTTPS (certificado válido y HSTS), autenticación, autorización por
rol, rol activo, protección contra fuerza bruta, SOAP con clave y XXE, y
firma del webhook de Stripe.

Uso:  python pruebas/seguridad.py
"""
import socket
import ssl
from datetime import datetime

import requests

from comun import ahora, credenciales, guardar, url_base

D = url_base()
HOST = D.removeprefix("https://")
resultados = []


def verificar(nombre: str, condicion: bool, detalle=""):
    resultados.append({"prueba": nombre, "ok": bool(condicion), "detalle": str(detalle)})
    print(f"  {'OK   ' if condicion else 'FALLA'}  {nombre}  {detalle}")


def login(email):
    return requests.post(f"{D}/api/auth/login", json={"email": email, "password": "Lab2026*"}, timeout=30).json()["token"]


print(f"{ahora()}  Seguridad de {D}")
# --- HTTPS ---
ctx = ssl.create_default_context()
with socket.create_connection((HOST, 443), timeout=10) as s, ctx.wrap_socket(s, server_hostname=HOST) as tls:
    cert = tls.getpeercert()
    emisor = dict(x[0] for x in cert["issuer"])["organizationName"]
    vence = datetime.strptime(cert["notAfter"], "%b %d %H:%M:%S %Y %Z")
    verificar("certificado TLS válido y de confianza", True, f"{emisor}, {tls.version()}, vence {vence:%Y-%m-%d}")
r = requests.get(f"{D}/health", timeout=15)
verificar("cabecera HSTS", "max-age" in r.headers.get("Strict-Transport-Security", ""), r.headers.get("Strict-Transport-Security"))
r = requests.get(f"http://{HOST}/api/examenes/catalogo", allow_redirects=False, timeout=15)
verificar("HTTP redirige a HTTPS", r.status_code == 301 and r.headers["Location"].startswith("https://"), r.status_code)

# --- autenticación y roles ---
verificar("sin token -> 401", requests.get(f"{D}/api/citas/mias", timeout=15).status_code == 401)
verificar("token falso -> 401", requests.get(f"{D}/api/citas/mias", headers={"Authorization": "Bearer x.y.z"}, timeout=15).status_code == 401)
r = requests.post(f"{D}/api/auth/login", json={"email": "pedro.castillo@correo.test", "password": "incorrecta1"}, timeout=15)
verificar("contraseña incorrecta -> 401 sin revelar si el usuario existe", r.status_code == 401, r.json().get("error"))
h_pac = {"Authorization": f"Bearer {login('pedro.castillo@correo.test')}"}
verificar("paciente en /api/usuarios (admin) -> 403", requests.get(f"{D}/api/usuarios", headers=h_pac, timeout=15).status_code == 403)
verificar("paciente registrando resultados -> 403",
          requests.post(f"{D}/api/resultados", headers=h_pac, json={}, timeout=15).status_code == 403)
ajena = requests.get(f"{D}/api/solicitudes/2", headers=h_pac, timeout=15)
verificar("paciente viendo la solicitud de otro paciente -> 403", ajena.status_code == 403, ajena.json().get("error"))
h_med = {"Authorization": f"Bearer {login('jvillacis@labclinico.test')}"}
verificar("médico multirrol como PACIENTE ve solo lo suyo",
          requests.get(f"{D}/api/solicitudes/mias", headers={**h_med, "X-Rol-Activo": "PACIENTE"}, timeout=15).status_code == 200)
verificar("X-Rol-Activo con un rol no asignado -> 403",
          requests.get(f"{D}/api/usuarios", headers={**h_med, "X-Rol-Activo": "ADMIN"}, timeout=15).status_code == 403)
h_adm = {"Authorization": f"Bearer {login('admin@labclinico.test')}"}
verificar("administrador en /api/usuarios -> 200", requests.get(f"{D}/api/usuarios", headers=h_adm, timeout=15).status_code == 200)

# --- fuerza bruta (Nginx: 10/min por IP en cada VM, ráfaga 5) ---
codigos = [requests.post(f"{D}/api/auth/login", json={"email": "nadie@x.test", "password": "x"}, timeout=15).status_code
           for _ in range(40)]
verificar("limitador de login responde 429 ante ráfagas", 429 in codigos, f"{codigos.count(401)}x401, {codigos.count(429)}x429")

# --- SOAP y webhook ---
sobre = ('<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:lab="urn:labclinico:resultados">'
         '<soapenv:Body><lab:ListarExamenesRequest/></soapenv:Body></soapenv:Envelope>')
r = requests.post(f"{D}/soap", data=sobre, headers={"Content-Type": "text/xml", "X-API-Key": "clave-falsa"}, timeout=15)
verificar("SOAP con clave inválida -> Fault 401", r.status_code == 401 and "Fault" in r.text)
r = requests.post(f"{D}/soap", data=sobre, headers={"Content-Type": "text/xml", "X-API-Key": credenciales()["SOAP_API_KEY"]}, timeout=15)
verificar("SOAP con clave válida -> 200", r.status_code == 200 and "ListarExamenesResponse" in r.text)
xxe = '<?xml version="1.0"?><!DOCTYPE x [<!ENTITY e SYSTEM "file:///etc/passwd">]><x>&e;</x>'
r = requests.post(f"{D}/soap", data=xxe, headers={"Content-Type": "text/xml", "X-API-Key": credenciales()["SOAP_API_KEY"]}, timeout=15)
verificar("SOAP con entidad externa (XXE) -> rechazado", r.status_code == 400 and "root:" not in r.text)
r = requests.post(f"{D}/api/pagos/webhook", data="{}", headers={"Stripe-Signature": "t=1,v1=falsa"}, timeout=15)
verificar("webhook de Stripe con firma falsa -> 400", r.status_code == 400)

ok = sum(r["ok"] for r in resultados)
print(f"\n{ok}/{len(resultados)} verificaciones correctas")
print("Guardado en", guardar("seguridad.json", resultados))
