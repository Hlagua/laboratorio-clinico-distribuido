"""Flujo de consulta médica, control, exámenes ordenados, ventanilla y ajustes (18-11), por el dominio público.

El pago con tarjeta en Stripe lo hace una persona; aquí los pagos se confirman con la
transferencia simulada (paciente + administrador) para poder recorrer todo el flujo.
"""
import random
from datetime import date, timedelta

import requests

D = "https://labclinico-uta.duckdns.org"
R = []


def pedir(metodo, ruta, token, rol, **kw):
    return requests.request(metodo, D + ruta, headers={"Authorization": f"Bearer {token}", "X-Rol-Activo": rol}, timeout=60, **kw)


def ok(cond, msg, extra=""):
    R.append(bool(cond))
    print(("OK    " if cond else "FALLA ") + msg + (f"  {extra}" if extra else ""))


def login(email):
    return requests.post(D + "/api/auth/login", json={"email": email, "password": "Lab2026*"}, timeout=60).json()["token"]


def pagar(token_pac, solicitud_id):
    p = pedir("POST", "/api/pagos/transferencia", token_pac, "PACIENTE", json={"solicitud_id": solicitud_id}).json()
    return pedir("POST", f"/api/pagos/{p['pago_id']}/confirmar-transferencia", adm, "ADMIN", json={"aprobado": True}).json()


def cedula_valida():
    base = [random.randint(1, 2), random.randint(0, 3)] + [random.randint(0, 9) for _ in range(7)]
    base[2] = random.randint(0, 5)
    suma = 0
    for i, c in enumerate(base):
        p = c * (2 if i % 2 == 0 else 1)
        suma += p - 9 if p > 9 else p
    return "".join(map(str, base)) + str((10 - suma % 10) % 10)


pac, med, lab, adm = (login(e) for e in ("sofia.navarrete@correo.test", "jvillacis@labclinico.test",
                                         "lparedes@labclinico.test", "admin@labclinico.test"))

# --- Agenda del médico (la genera el administrador) ---
medicos = requests.get(D + "/api/citas/medicos", timeout=60).json()
vill = next(m for m in medicos if "Villac" in m["nombre"])
desde = date.today() + timedelta(days=1)
r = pedir("POST", "/api/citas/franjas", adm, "ADMIN", json={
    "desde": desde.isoformat(), "hasta": (desde + timedelta(days=10)).isoformat(), "hora_inicio": "08:00", "hora_fin": "10:00",
    "intervalo_minutos": 30, "medico_id": vill["medico_id"]})
ok(r.status_code == 201, "1. el administrador genera la agenda del médico", f"{r.json()}")
vill = next(m for m in requests.get(D + "/api/citas/medicos", timeout=60).json() if m["medico_id"] == vill["medico_id"])
ok(vill["turnos_libres"] > 0 and vill["precio_consulta"], "2. el paciente ve al médico con turnos y precio de consulta",
   f"Dr(a). {vill['nombre']} · {vill['turnos_libres']} turnos · USD {vill['precio_consulta']}")

# --- El paciente reserva y paga la consulta ---
franjas = requests.get(D + "/api/citas/franjas", params={"medico_id": vill["medico_id"], "dias": 14}, timeout=60).json()
lab_franjas = requests.get(D + "/api/citas/franjas", params={"dias": 14}, timeout=60).json()
ok(franjas and all(f["medico_id"] == vill["medico_id"] for f in franjas) and all(f["medico_id"] is None for f in lab_franjas),
   "3. las franjas del médico y las del laboratorio están separadas")
r = pedir("POST", "/api/citas", pac, "PACIENTE", json={"franja_id": franjas[0]["franja_id"], "tipo": "MUESTRA"})
ok(r.status_code == 422, "4. no se puede reservar toma de muestras en la agenda de un médico (422)")
r = pedir("POST", "/api/citas", pac, "PACIENTE", json={"franja_id": franjas[0]["franja_id"], "tipo": "CONSULTA",
                                                       "motivo": "Primera consulta: cansancio y sed"})
cons = r.json()
ok(r.status_code == 201 and cons["tipo"] == "CONSULTA" and cons["estado"] == "PENDIENTE_PAGO" and cons["solicitud_id"]
   and float(cons["solicitud_total"]) == float(vill["precio_consulta"]),
   "5. consulta reservada sin elegir exámenes, con su cobro", f"{cons['fecha']} {cons['hora_inicio']} · {cons['solicitud_codigo']}")
s = pedir("GET", f"/api/solicitudes/{cons['solicitud_id']}", pac, "PACIENTE").json()
ok(s["tipo"] == "CONSULTA" and s["iva"] > 0 and s["examenes"][0]["examen"] == "Consulta médica",
   "6. resumen del pedido de la consulta (con IVA)", f"{s['subtotal']} + {s['iva']} = {s['total']}")
pago = pagar(pac, cons["solicitud_id"])
c = next(x for x in pedir("GET", "/api/citas/mias", pac, "PACIENTE").json() if x["cita_id"] == cons["cita_id"])
ok(pago["estado"] == "APROBADO" and c["estado"] == "CONFIRMADA", "7. al pagar, la consulta queda confirmada")
r = pedir("DELETE", f"/api/citas/{cons['cita_id']}", pac, "PACIENTE")
ok(r.status_code == 409, "8. el paciente no puede cancelar una cita ya pagada (409)", r.json().get("error", ""))

# --- El médico atiende ---
ag = pedir("GET", "/api/citas/agenda", med, "MEDICO", params={"fecha": cons["fecha"]}).json()
ok(any(x["cita_id"] == cons["cita_id"] for x in ag) and all(x["medico_id"] == vill["medico_id"] for x in ag),
   "9. el médico ve la consulta en su agenda (solo las suyas)")
ag_lab = pedir("GET", "/api/citas/agenda", lab, "LABORATORISTA", params={"fecha": cons["fecha"]}).json()
ok(all(x["tipo"] == "MUESTRA" for x in ag_lab), "10. el laboratorista no ve consultas en su agenda")
catalogo = requests.get(D + "/api/examenes/catalogo", timeout=60).json()
ok(not any(t["codigo"] == "CONS-MED" for t in catalogo), "11. la consulta no aparece entre los exámenes del catálogo")
glucosa = next(t for t in catalogo if "Glucosa" in t["nombre"])
r = pedir("POST", "/api/solicitudes", med, "MEDICO", json={"paciente_id": cons["paciente_id"], "examenes": [glucosa["tipo_examen_id"]]})
orden = r.json()
ok(r.status_code == 201 and orden["medico_id"] and orden["tipo"] == "EXAMENES", "12. el médico ordena los exámenes", orden["codigo"])
posteriores = [f for f in requests.get(D + "/api/citas/franjas", params={"medico_id": vill["medico_id"], "dias": 14}, timeout=60).json()
               if f["fecha"] > cons["fecha"]]
r = pedir("POST", "/api/citas/control", med, "MEDICO", json={"paciente_id": cons["paciente_id"],
                                                              "franja_id": posteriores[0]["franja_id"], "motivo": "Control con glucosa"})
control = r.json()
ok(r.status_code == 201 and control["origen"] == "MEDICO" and control["estado"] == "CONFIRMADA" and control["solicitud_id"] is None,
   "13. el médico agenda la cita de control: confirmada y sin cobro (incluida en la consulta)",
   f"{control['fecha']} {control['hora_inicio']}")
otro = next((f for f in requests.get(D + "/api/citas/franjas", params={"dias": 14}, timeout=60).json()), None)
r = pedir("POST", "/api/citas/control", med, "MEDICO", json={"paciente_id": cons["paciente_id"], "franja_id": otro["franja_id"]})
ok(r.status_code in (403, 422), "14. el médico no puede agendar fuera de su agenda", str(r.status_code))
r = pedir("POST", f"/api/citas/{cons['cita_id']}/atender", med, "MEDICO")
cs = pedir("GET", f"/api/solicitudes/{cons['solicitud_id']}", pac, "PACIENTE").json()
ok(r.status_code == 200 and r.json()["estado"] == "ATENDIDA" and cs["estado"] == "COMPLETADA",
   "15. el médico finaliza la consulta: cita ATENDIDA y cobro COMPLETADO")

r = pedir("DELETE", f"/api/citas/{control['cita_id']}", pac, "PACIENTE")
ok(r.status_code == 200, "13b. el paciente sí puede cancelar el control (no tiene cobro)")

# --- El paciente paga los exámenes; el laboratorio los procesa; el médico recibe los resultados ---
ok(pedir("GET", "/api/solicitudes", lab, "LABORATORISTA", params={"codigo": cons["solicitud_codigo"]}).json() == [],
   "16. el laboratorio no ve el cobro de la consulta entre sus solicitudes")
pagar(pac, orden["solicitud_id"])
s = pedir("GET", f"/api/solicitudes/{orden['solicitud_id']}", lab, "LABORATORISTA").json()
ex = s["examenes"][0]
pedir("POST", f"/api/solicitudes/detalle/{ex['detalle_id']}/muestra", lab, "LABORATORISTA")
p = glucosa["parametros"][0]
pedir("POST", "/api/resultados", lab, "LABORATORISTA", json={"detalle_id": ex["detalle_id"],
                                                             "valores": [{"parametro_id": p["parametro_id"], "valor": 135}]})
correos = pedir("GET", "/api/notificaciones", adm, "ADMIN", params={"pagina": 1, "q": orden["codigo"]}).json()["items"]
tipos = {x["tipo"] for x in correos}
ok({"EXAMENES_ORDENADOS", "RESULTADO_LISTO", "RESULTADO_MEDICO"} <= tipos,
   "17. correos: exámenes ordenados al paciente y resultados al paciente y al médico", ", ".join(sorted(tipos)))

# --- Turno de toma de muestras: queda ATENDIDO al registrar la muestra ---
# Una franja del laboratorio donde la paciente no tenga ya una cita activa (las pruebas se repiten).
ocupadas = {x["franja_id"] for x in pedir("GET", "/api/citas/mias", pac, "PACIENTE").json() if x["estado"] != "CANCELADA"}
fl = next(f for f in reversed(requests.get(D + "/api/citas/franjas", params={"dias": 14}, timeout=60).json())
          if f["franja_id"] not in ocupadas)
cm = pedir("POST", "/api/citas", pac, "PACIENTE", json={"franja_id": fl["franja_id"], "tipo": "MUESTRA"}).json()
sm = pedir("POST", "/api/solicitudes", pac, "PACIENTE", json={"examenes": [glucosa["tipo_examen_id"]], "cita_id": cm["cita_id"]}).json()
pagar(pac, sm["solicitud_id"])
pedir("POST", f"/api/solicitudes/detalle/{sm['examenes'][0]['detalle_id']}/muestra", lab, "LABORATORISTA")
c = next(x for x in pedir("GET", "/api/citas/mias", pac, "PACIENTE").json() if x["cita_id"] == cm["cita_id"])
ok(c["estado"] == "ATENDIDA", "18. el turno de toma de muestras queda ATENDIDO al registrar la muestra")

# --- Ventanilla: paciente sin cuenta, cobro por Stripe con datos de factura ---
ced = cedula_valida()
r = pedir("POST", "/api/pacientes", lab, "LABORATORISTA", json={
    "cedula": ced, "nombres": "Paciente", "apellidos": "Ventanilla " + "".join("ABCDEFGHIJ"[int(d)] for d in ced[-4:]), "fecha_nacimiento": "1980-03-15", "sexo": "M"})
walk = r.json()
ok(r.status_code == 201, "19. el laboratorista registra un paciente de ventanilla sin cuenta", f"CI {ced}")
sv = pedir("POST", "/api/solicitudes", lab, "LABORATORISTA", json={"paciente_id": walk["paciente_id"],
                                                                   "examenes": [glucosa["tipo_examen_id"]]}).json()
r = pedir("POST", "/api/pagos/ventanilla", lab, "LABORATORISTA", json={"solicitud_id": sv["solicitud_id"], "factura": {
    "identificacion": "1790012345001", "nombre": "Empresa Ficticia S.A.", "direccion": "Ambato", "email": None}})
v = r.json()
ok(r.status_code == 201 and v["checkout_url"].startswith("https://checkout.stripe.com") and v["qr"].startswith("data:image/png"),
   "20. cobro en ventanilla: URL de Stripe Checkout y su QR")
pg = pedir("GET", f"/api/pagos/{v['pago_id']}", adm, "ADMIN").json()
ok(pg.get("metodo") == "STRIPE", "21. el pago de ventanilla va por la pasarela (Stripe), pendiente de pagar en el QR", pg.get("estado"))
r = pedir("POST", "/api/pagos/ventanilla", lab, "LABORATORISTA", json={"solicitud_id": sv["solicitud_id"],
                                                                        "factura": {"identificacion": "123", "nombre": "X"}})
ok(r.status_code == 422, "22. identificación inválida para la factura (422)")
r = pedir("POST", "/api/pagos/ventanilla", lab, "LABORATORISTA", json={"solicitud_id": sv["solicitud_id"], "factura": {}})
ok(r.status_code == 201, "23. consumidor final (sin datos) también se puede cobrar")

# --- El administrador restablece una clave (se deja la misma de prueba) ---
u = pedir("GET", "/api/usuarios", adm, "ADMIN", params={"pagina": 1, "q": "villac"}).json()["items"][0]
r = pedir("POST", f"/api/usuarios/{u['usuario_id']}/clave", adm, "ADMIN", json={"password": "Lab2026*"})
ok(r.status_code == 200 and login("jvillacis@labclinico.test"), "24. el administrador restablece la clave y el usuario entra")

print(f"\n{sum(R)}/{len(R)} correctas")
