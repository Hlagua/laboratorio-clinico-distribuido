"""Revisión del equipo del 20-11 por el dominio público: sucursales y turno al pedir exámenes, descuentos,
control cobrado, nota de la consulta y receta sin exámenes, cancelar con devolución parcial, horario por
fechas sueltas, titular de la tarjeta y notificaciones por rol con enlace."""
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


pac, med, lab, adm = (login(e) for e in ("sofia.navarrete@correo.test", "jvillacis@labclinico.test",
                                         "lparedes@labclinico.test", "admin@labclinico.test"))


def pagar_por_transferencia(solicitud_id):
    """Pago de prueba sin tarjeta: transferencia confirmada por el administrador."""
    p = pedir("POST", "/api/pagos/transferencia", pac, "PACIENTE", json={"solicitud_id": solicitud_id}).json()
    return pedir("POST", f"/api/pagos/{p['pago_id']}/confirmar-transferencia", adm, "ADMIN", json={"aprobado": True}).json()


# --- Sucursales ---
labs = requests.get(D + "/api/laboratorios", timeout=60).json()
sucursales = [l for l in labs if l["propio"]]
ok(len(sucursales) >= 2 and all(l["latitud"] for l in sucursales), "1. hay varias sucursales con su ubicación",
   ", ".join(l["nombre"] for l in sucursales))
centro = next(l for l in sucursales if "Centro" in l["nombre"])
hoy = date.today()
r = pedir("POST", "/api/citas/franjas", adm, "ADMIN", json={"desde": (hoy + timedelta(days=3)).isoformat(),
          "hasta": (hoy + timedelta(days=10)).isoformat(), "laboratorio_id": centro["laboratorio_id"],
          "hora_inicio": "07:00", "hora_fin": "09:00", "intervalo_minutos": 30, "capacidad": 3})
ok(r.status_code == 201, "2. el administrador genera turnos de toma de muestras en la Sucursal Centro", str(r.json()))
dias = requests.get(D + "/api/citas/dias-libres", params={"laboratorio_id": centro["laboratorio_id"]}, timeout=60).json()
ok(dias and all("fecha" in x and x["libres"] > 0 for x in dias), "3. calendario: días con horarios libres de la sucursal",
   f"{len(dias)} días")
dia = dias[0]["fecha"]
turnos = requests.get(D + "/api/citas/franjas", params={"laboratorio_id": centro["laboratorio_id"], "desde": dia, "dias": 0},
                      timeout=60).json()
ok(turnos and all(t["laboratorio_id"] == centro["laboratorio_id"] for t in turnos), "4. horarios de ese día en esa sucursal",
   f"{dia}: {len(turnos)} turnos")

# --- Descuento por sucursal ---
catalogo = requests.get(D + "/api/examenes/catalogo", timeout=60).json()
glucosa = next(t for t in catalogo if "Glucosa" in t["nombre"])
r = pedir("POST", "/api/descuentos", adm, "ADMIN", json={"nombre": "Prueba 20-11 Centro", "porcentaje": 20,
          "laboratorio_id": centro["laboratorio_id"], "tipo_examen_id": glucosa["tipo_examen_id"],
          "desde": hoy.isoformat(), "hasta": (hoy + timedelta(days=30)).isoformat()})
desc = r.json()
ok(r.status_code == 201, "5. el administrador crea un descuento del 20 % en la Sucursal Centro", desc.get("nombre", str(desc)))
ok(pedir("POST", "/api/descuentos", adm, "ADMIN", json={"nombre": "x", "porcentaje": 95, "desde": hoy.isoformat(),
                                                         "hasta": hoy.isoformat()}).status_code == 422,
   "6. un descuento mayor a 90 % se rechaza (422)")

# --- Pedir exámenes eligiendo sucursal, fecha y hora ---
s = pedir("POST", "/api/solicitudes", pac, "PACIENTE", json={"examenes": [glucosa["tipo_examen_id"]],
                                                             "franja_id": turnos[-1]["franja_id"]}).json()
esperado = round(float(glucosa["precio"]) * 0.8, 2)
ok(s.get("cita_id") and s["laboratorio_id"] == centro["laboratorio_id"] and abs(float(s["total"]) - esperado) < 0.01,
   "7. el paciente pide exámenes con turno en la sucursal y se aplica el descuento",
   f"{s.get('codigo')} turno {s.get('cita_fecha')} {str(s.get('cita_hora'))[:5]} total {s.get('total')} (lista {glucosa['precio']})")
r = pedir("POST", "/api/pagos/checkout", pac, "PACIENTE", json={"solicitud_id": s["solicitud_id"], "titular": "Sofia 123"})
ok(r.status_code == 422, "8. titular con números: rechazado (422)", r.json().get("error"))
r = pedir("POST", "/api/pagos/checkout", pac, "PACIENTE", json={"solicitud_id": s["solicitud_id"], "titular": " Sofia  Navarrete"})
ok(r.status_code == 422, "9. titular con espacios de más: rechazado (422)")
r = pedir("POST", "/api/pagos/checkout", pac, "PACIENTE", json={"solicitud_id": s["solicitud_id"], "titular": "Sofía Navarrete"})
ok(r.status_code == 201 and r.json()["checkout_url"].startswith("https://checkout.stripe.com"),
   "10. titular válido: se abre Stripe Checkout")
cita_examenes = s["cita_id"]
agenda_lab = pedir("GET", "/api/citas/agenda", lab, "LABORATORISTA", params={"fecha": dia}).json()
ok(all(c["laboratorio_id"] != centro["laboratorio_id"] for c in agenda_lab),
   "11. la laboratorista de la matriz no ve los turnos de la Sucursal Centro en su agenda")

# --- Consulta: nota, receta sin exámenes y control cobrado ---
vill = next(m for m in requests.get(D + "/api/citas/medicos", timeout=60).json() if "Villac" in m["nombre"])
libres = requests.get(D + "/api/citas/franjas", params={"medico_id": vill["medico_id"], "dias": 60}, timeout=60).json()
consulta = pedir("POST", "/api/citas", pac, "PACIENTE", json={"franja_id": libres[0]["franja_id"], "tipo": "CONSULTA",
                                                              "motivo": "Tos y fiebre desde hace tres días"}).json()
pagar_por_transferencia(consulta["solicitud_id"])
nota = pedir("GET", f"/api/citas/{consulta['cita_id']}/nota", med, "MEDICO").json()
ok(nota["motivo"] == "Tos y fiebre desde hace tres días", "12. la nota parte del motivo que escribió el paciente")
r = pedir("PUT", f"/api/citas/{consulta['cita_id']}/nota", med, "MEDICO", json={
    "motivo": "Tos y fiebre", "sintomas": "Tos seca, fiebre de 38.5, dolor de garganta",
    "examen_fisico": "Faringe eritematosa", "diagnostico": "J06.9 Infección respiratoria aguda"})
ok(r.status_code == 200 and r.json()["diagnostico"].startswith("J06.9"), "13. el médico guarda motivo, molestias y diagnóstico")
r = pedir("PUT", f"/api/recetas/solicitud/{consulta['solicitud_id']}", med, "MEDICO", json={
    "diagnostico": "J06.9 Infección respiratoria aguda",
    "items": [{"nombre": "Paracetamol 500 mg", "indicaciones": "1 tableta cada 8 horas por 3 días"}]})
ok(r.status_code == 200, "14. receta sobre la propia consulta, sin ordenar exámenes", r.json().get("error", ""))
trat = pedir("GET", "/api/tratamientos/mios", pac, "PACIENTE").json()
ok(any("J06.9" in t["diagnostico"] for t in trat), "15. la receta queda como tratamiento del paciente")
control = pedir("POST", "/api/citas/control", med, "MEDICO", json={
    "paciente_id": consulta["paciente_id"], "franja_id": libres[1]["franja_id"], "cita_origen_id": consulta["cita_id"]}).json()
ok(control.get("estado") == "PENDIENTE_PAGO" and control.get("solicitud_id") and float(control["solicitud_total"]) > 0,
   "16. el control que agenda el médico se cobra", f"{control.get('solicitud_codigo')} USD {control.get('solicitud_total')}")
ok(control.get("cita_origen_id") == consulta["cita_id"], "17. el control sabe de qué consulta sale")
orden = pedir("POST", "/api/solicitudes", med, "MEDICO", json={"paciente_id": consulta["paciente_id"],
              "examenes": [glucosa["tipo_examen_id"]], "consulta_cita_id": consulta["cita_id"]}).json()
ok(orden.get("consulta_cita_id") == consulta["cita_id"], "18. los exámenes ordenados guardan su consulta")

# --- Cancelar con devolución parcial ---
lejana = next(f for f in libres if f["fecha"] >= (hoy + timedelta(days=3)).isoformat() and f["franja_id"] not in
              (libres[0]["franja_id"], libres[1]["franja_id"]))
otra = pedir("POST", "/api/citas", pac, "PACIENTE", json={"franja_id": lejana["franja_id"], "tipo": "CONSULTA"}).json()
pagar_por_transferencia(otra["solicitud_id"])
cot = pedir("GET", f"/api/citas/{otra['cita_id']}/cancelacion", pac, "PACIENTE").json()
ok(cot["puede"] and abs(cot["reembolso"] - round(cot["pagado"] * 0.8, 2)) < 0.01,
   "19. con 24 h o más de anticipación se puede cancelar y se devuelve el 80 %", f"{cot['reembolso']} de {cot['pagado']}")
r = pedir("DELETE", f"/api/citas/{otra['cita_id']}", pac, "PACIENTE").json()
ok(abs(r.get("reembolso", 0) - cot["reembolso"]) < 0.01, "20. el paciente cancela y se registra la devolución", r.get("mensaje"))
pagos = pedir("GET", "/api/pagos/mios", pac, "PACIENTE").json()
p = next(x for x in pagos if x["solicitud_id"] == otra["solicitud_id"])
ok(p["estado"] == "REEMBOLSO_PARCIAL", "21. el pago queda con reembolso parcial", f"reembolsado {p['monto_reembolsado']}")
pronto = next((f for f in libres if f["fecha"] <= (hoy + timedelta(days=1)).isoformat()
               and f["franja_id"] not in (libres[0]["franja_id"], libres[1]["franja_id"])), None)
if pronto:
    c2 = pedir("POST", "/api/citas", pac, "PACIENTE", json={"franja_id": pronto["franja_id"], "tipo": "CONSULTA"}).json()
    pagar_por_transferencia(c2["solicitud_id"])
    cot2 = pedir("GET", f"/api/citas/{c2['cita_id']}/cancelacion", pac, "PACIENTE").json()
    ok(not cot2["puede"], "22. con menos de 24 h ya no se cancela: solo reagendar", cot2.get("motivo"))

# --- Horario por fechas sueltas ---
sabado = hoy + timedelta(days=(5 - hoy.weekday()) % 7 + 14)
r = pedir("POST", "/api/citas/horario", med, "MEDICO", json={"fechas": [sabado.isoformat()],
          "bloques": [{"inicio": "08:00", "fin": "11:00", "minutos": 60}]}).json()
ok("franjas_creadas" in r, "23. el médico atiende solo un sábado, tres horas", f"{sabado}: {r}")
q = pedir("POST", "/api/citas/horario/quitar", med, "MEDICO", json={"fechas": [sabado.isoformat()]}).json()
r2 = pedir("POST", "/api/citas/horario", med, "MEDICO", json={"fechas": [sabado.isoformat()],
           "bloques": [{"inicio": "08:00", "fin": "11:00", "minutos": 60}]}).json()
ok(q.get("quitados", 0) >= 1 and r2.get("franjas_creadas", 0) >= 1, "24. puede quitar ese día y volver a generarlo",
   f"quitados {q.get('quitados')}, vueltos a crear {r2.get('franjas_creadas')}")

# --- Notificaciones por rol y con enlace ---
avisos_pac = pedir("GET", "/api/notificaciones/mias", pac, "PACIENTE").json()
ok(avisos_pac and all(a["rol"] == "PACIENTE" for a in avisos_pac), "25. como paciente solo ve avisos de paciente")
ok(any(a["enlace"] and a["enlace"]["tipo"] == "solicitud" and a["enlace"]["solicitud_id"] for a in avisos_pac),
   "26. los avisos traen el enlace a su solicitud")
avisos_med = pedir("GET", "/api/notificaciones/mias", med, "MEDICO").json()
ok(all(a["rol"] == "MEDICO" for a in avisos_med), "27. como médico solo ve avisos de médico", f"{len(avisos_med)} avisos")

# --- Limpieza: se desactiva el descuento de prueba y se liberan las citas creadas ---
pedir("PATCH", f"/api/descuentos/{desc['descuento_id']}", adm, "ADMIN", json={"activo": False})
for cid in (cita_examenes, control.get("cita_id")):
    if cid:
        pedir("DELETE", f"/api/citas/{cid}", adm, "ADMIN")
print(f"\n{sum(R)}/{len(R)} correctas")
