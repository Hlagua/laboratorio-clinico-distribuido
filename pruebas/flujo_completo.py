"""Prueba del flujo completo (rúbrica 7): cita -> pago -> examen -> tratamiento -> resultados.

Recorre la plataforma publicada con los tres roles, como lo harían las
aplicaciones cliente:
  1. paciente nuevo: registro, login, reserva de cita, solicitud de exámenes
  2. pago: sesión real de Stripe Checkout (modo prueba) y pago por transferencia
     con QR que confirma el administrador
  3. laboratorista: toma de muestra y resultados de cada examen
  4. médico: observación y tratamiento
  5. paciente: resultados, PDF y tratamiento
  6. réplica: el resultado aparece en Supabase y en MongoDB; correos enviados

Los correos del paciente van a un alias del equipo (henrylagua1+...@gmail.com).
Uso:  python pruebas/flujo_completo.py
"""
import random
import time
from urllib.parse import quote

import psycopg
import requests
from pymongo import MongoClient

from comun import RESULTADOS, ahora, credenciales, guardar, url_base

D = url_base()
c = credenciales()
pasos = []


def paso(nombre, **datos):
    pasos.append({"hora": ahora(), "paso": nombre, **datos})
    print(f"{ahora()}  [OK] {nombre}  {datos if datos else ''}")


def pedir(metodo, ruta, token=None, rol=None, **kw):
    # Como las aplicaciones cliente, se indica el rol activo (una persona puede tener varios).
    h = {"Authorization": f"Bearer {token}"} if token else {}
    if rol:
        h["X-Rol-Activo"] = rol
    r = requests.request(metodo, f"{D}{ruta}", headers=h, timeout=60, **kw)
    if r.status_code >= 400:
        raise SystemExit(f"FALLA {metodo} {ruta}: {r.status_code} {r.text[:300]}")
    return r


def login(email, clave="Lab2026*"):
    return pedir("POST", "/api/auth/login", json={"email": email, "password": clave}).json()["token"]


def cedula_valida() -> str:
    base = "17" + random.choice("012345") + "".join(random.choice("0123456789") for _ in range(6))
    s = sum(d - 9 if d > 9 else d for d in (int(x) * k for x, k in zip(base, [2, 1, 2, 1, 2, 1, 2, 1, 2])))
    return base + str((10 - s % 10) % 10)


# ---------------- 1. paciente ----------------
sufijo = random.randint(1000, 9999)
email = f"henrylagua1+paciente{sufijo}@gmail.com"
cedula = cedula_valida()
clave = f"Prueba{sufijo}x"
pedir("POST", "/api/auth/registro", json={"cedula": cedula, "nombres": "Paciente", "apellidos": f"Flujo Completo {sufijo}",
                                          "fecha_nacimiento": "1998-07-15", "sexo": "F", "email": email, "password": clave})
t_pac = login(email, clave)
paso("paciente registrado e inicia sesión", cedula=cedula, email=email)

franja = next(f for f in pedir("GET", "/api/citas/franjas?dias=14").json() if f["cupos_libres"] > 0)
cita = pedir("POST", "/api/citas", t_pac, json={"franja_id": franja["franja_id"], "motivo": "Chequeo (prueba de flujo completo)"}).json()
paso("cita reservada", cita_id=cita["cita_id"], fecha=cita["fecha"], hora=cita["hora_inicio"], estado=cita["estado"])

catalogo = pedir("GET", "/api/examenes/catalogo").json()
examenes = [t["tipo_examen_id"] for t in catalogo if t["codigo"] in ("HEM-BH", "QS-GLU")]
sol = pedir("POST", "/api/solicitudes", t_pac, json={"examenes": examenes, "cita_id": cita["cita_id"]}).json()
paso("solicitud de exámenes creada", codigo=sol["codigo"], total=sol["total"], estado=sol["estado"])

# ---------------- 2. pago ----------------
chk = pedir("POST", "/api/pagos/checkout", t_pac, json={"solicitud_id": sol["solicitud_id"]}).json()
paso("sesión real de Stripe Checkout creada (modo prueba)", session_id=chk["session_id"], url=chk["checkout_url"][:60] + "…")
trf = pedir("POST", "/api/pagos/transferencia", t_pac, json={"solicitud_id": sol["solicitud_id"]}).json()
paso("pago por transferencia registrado (QR generado)", referencia=trf["referencia"], qr_bytes=len(trf["qr"]))
t_adm = login("admin@labclinico.test")
pago = pedir("POST", f"/api/pagos/{trf['pago_id']}/confirmar-transferencia", t_adm, json={"aprobado": True}).json()
paso("administrador confirma la transferencia", pago_id=pago["pago_id"], estado=pago["estado"])
cita_conf = next(x for x in pedir("GET", "/api/citas/mias", t_pac).json() if x["cita_id"] == cita["cita_id"])
paso("la cita queda confirmada", estado=cita_conf["estado"])

# ---------------- 3. laboratorista ----------------
t_lab = login("cmena@labclinico.test")
detalle = pedir("GET", f"/api/solicitudes/{sol['solicitud_id']}", t_lab).json()
for ex in detalle["examenes"]:
    pedir("POST", f"/api/solicitudes/detalle/{ex['detalle_id']}/muestra", t_lab)
    params = next(t for t in catalogo if t["tipo_examen_id"] == ex["tipo_examen_id"])["parametros"]
    valores = [{"parametro_id": p["parametro_id"],
                "valor": (p["valor_ref_max"] + 22) if p["nombre"] == "Glucosa" else round((p["valor_ref_min"] + p["valor_ref_max"]) / 2, 1)}
               for p in params]
    r = pedir("POST", "/api/resultados", t_lab, json={"detalle_id": ex["detalle_id"], "valores": valores}).json()
    paso(f"laboratorista registra {ex['codigo']}", resultado_id=r["resultado_id"])

# ---------------- 4. médico ----------------
t_med = login("jvillacis@labclinico.test")
detalle = pedir("GET", f"/api/solicitudes/{sol['solicitud_id']}", t_med, rol="MEDICO").json()
glucosa = next(e for e in detalle["examenes"] if e["codigo"] == "QS-GLU")
pedir("POST", "/api/observaciones", t_med, rol="MEDICO", json={"resultado_id": glucosa["resultado_id"],
                                                 "texto": "Glucosa elevada. Repetir en ayunas y control en 3 meses."})
trat = pedir("POST", "/api/tratamientos", t_med, rol="MEDICO", json={
    "paciente_id": detalle["paciente_id"], "solicitud_id": sol["solicitud_id"], "diagnostico": "Hiperglucemia en ayunas",
    "indicaciones": "Dieta baja en azúcares, ejercicio 30 min diarios, control en 3 meses.",
    "fecha_inicio": time.strftime("%Y-%m-%d")}).json()
paso("médico registra observación y tratamiento", tratamiento_id=trat["tratamiento_id"])

# ---------------- 5. paciente consulta ----------------
final = pedir("GET", f"/api/solicitudes/{sol['solicitud_id']}", t_pac).json()
fuera = [v["parametro"] for e in final["examenes"] for v in e["valores"] if v["fuera_rango"]]
paso("paciente consulta sus resultados", estado=final["estado"], fuera_de_rango=fuera)
pdf = pedir("GET", f"/api/solicitudes/{sol['solicitud_id']}/pdf", t_pac)
ruta_pdf = RESULTADOS / f"flujo_completo_{final['codigo']}.pdf"
ruta_pdf.write_bytes(pdf.content)
paso("paciente descarga el PDF", bytes=len(pdf.content), archivo=ruta_pdf.name)
paso("paciente ve su tratamiento", tratamientos=len(pedir("GET", "/api/tratamientos/mios", t_pac).json()))

# ---------------- 6. réplica y correos ----------------
pg = psycopg.connect(f"postgresql://lab_lectura.{c['SUPABASE_PROJECT_REF']}:{quote(c['SUPABASE_LAB_LECTURA_PASSWORD'], safe='')}"
                     f"@{c['SUPABASE_POOLER_HOST']}:5432/postgres?sslmode=require", autocommit=True)
mg = MongoClient(c["MONGO_URI"])["laboratorio"]
t0 = time.time()
en_supabase = en_mongo = None
while time.time() - t0 < 90 and not (en_supabase and en_mongo):
    time.sleep(3)
    en_supabase = en_supabase or pg.execute("SELECT estado FROM lab.solicitud_examen WHERE codigo = %s", (final["codigo"],)).fetchone()
    en_mongo = en_mongo or mg.resultados.find_one({"solicitud.codigo": final["codigo"], "observaciones_medicas.0": {"$exists": True}})
paso("réplica comprobada", supabase=en_supabase[0] if en_supabase else None,
     mongo_documento=bool(en_mongo), segundos=round(time.time() - t0))
time.sleep(15)   # el notificador envía cada 10 s
correos = [n for n in pedir("GET", "/api/notificaciones", t_adm).json() if n["destinatario"] == email]
paso("correos al paciente", **{n["tipo"]: n["estado"] for n in correos})

print("\nGuardado en", guardar("flujo_completo.json", {"solicitud": final["codigo"], "pasos": pasos}))
