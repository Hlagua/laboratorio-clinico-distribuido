"""Revisión del 19-11 por el dominio público: emojis y correo, horario de cada médico, reagendar,
centro de notificaciones, laboratorios externos y resultado en PDF."""
import base64
from datetime import date, timedelta
from io import BytesIO

import requests
from reportlab.pdfgen import canvas

D = "https://labclinico-uta.duckdns.org"
R = []


def pedir(metodo, ruta, token, rol, **kw):
    return requests.request(metodo, D + ruta, headers={"Authorization": f"Bearer {token}", "X-Rol-Activo": rol}, timeout=60, **kw)


def ok(cond, msg, extra=""):
    R.append(bool(cond))
    print(("OK    " if cond else "FALLA ") + msg + (f"  {extra}" if extra else ""))


def login(email):
    return requests.post(D + "/api/auth/login", json={"email": email, "password": "Lab2026*"}, timeout=60).json()["token"]


pac, otro, med, lab, adm = (login(e) for e in ("sofia.navarrete@correo.test", "pedro.castillo@correo.test",
                                               "jvillacis@labclinico.test", "lparedes@labclinico.test", "admin@labclinico.test"))

# --- Emojis y correo ---
base = {"cedula": "1710034065", "nombres": "Ana", "apellidos": "Prueba", "fecha_nacimiento": "1990-01-01", "sexo": "F",
        "password": "abc12345"}
r = requests.post(D + "/api/auth/registro", json={**base, "email": "ana@correo.test\U0001F600"}, timeout=60)
ok(r.status_code == 422, "1. correo con emoji al final: rechazado (422)", r.json().get("error"))
r = pedir("POST", "/api/citas", pac, "PACIENTE", json={"franja_id": 1, "motivo": "dolor \U0001F915"})
ok(r.status_code == 422, "2. motivo con emoji: rechazado (422)", r.json().get("error"))

# --- Horario propio del médico: mañanas cada 30 min y tardes cada hora ---
# Una semana (dentro de los 30 días que permite reagendar) donde el médico aún no tenga turnos.
ini = next((date.today() + timedelta(days=k) for k in range(2, 24)
           if not pedir("GET", "/api/citas/horario", med, "MEDICO",
                        params={"desde": (date.today() + timedelta(days=k)).isoformat(), "dias": 6}).json()), None)
if ini is None:
    raise SystemExit("El médico ya tiene turnos en todas las semanas de los próximos 30 días: libere una semana para repetir la prueba.")
fin = ini + timedelta(days=6)
cuerpo = {"desde": ini.isoformat(), "hasta": fin.isoformat(), "dias": [1, 2, 3, 4, 5],
          "bloques": [{"inicio": "08:00", "fin": "10:00", "minutos": 30}, {"inicio": "15:00", "fin": "17:00", "minutos": 60}]}
r = pedir("POST", "/api/citas/horario", med, "MEDICO", json=cuerpo).json()
ok(r.get("franjas_creadas", 0) > 0, "3. el médico genera su horario (30 min en la mañana, 60 min en la tarde)", str(r))
r2 = pedir("POST", "/api/citas/horario", med, "MEDICO", json=cuerpo).json()
ok(r2.get("franjas_creadas") == 0 and r2.get("omitidas", 0) > 0, "4. repetir no duplica turnos", str(r2))
r = pedir("POST", "/api/citas/horario", med, "MEDICO", json={**cuerpo, "bloques": [
    {"inicio": "08:00", "fin": "10:00", "minutos": 30}, {"inicio": "09:00", "fin": "11:00", "minutos": 30}]})
ok(r.status_code == 422, "5. bloques que se cruzan: rechazado (422)")
turnos = pedir("GET", "/api/citas/horario", med, "MEDICO", params={"desde": ini.isoformat(), "dias": 7}).json()
manana = [t for t in turnos if str(t["hora_inicio"]).startswith("08")]
tarde = [t for t in turnos if str(t["hora_inicio"]).startswith("15")]
ok(manana and tarde and str(manana[0]["hora_fin"]).startswith("08:30") and str(tarde[0]["hora_fin"]).startswith("16:00"),
   "6. cada bloque con su duración", f"{manana[0]['hora_inicio']}-{manana[0]['hora_fin']} y {tarde[0]['hora_inicio']}-{tarde[0]['hora_fin']}")
libre = next(t for t in turnos if not t["ocupados"])
ok(pedir("DELETE", f"/api/citas/franjas/{libre['franja_id']}", med, "MEDICO").status_code == 200, "7. el médico quita un turno libre")

# --- Reagendar ---
vill = next(m for m in requests.get(D + "/api/citas/medicos", timeout=60).json() if "Villac" in m["nombre"])
libres = [f for f in requests.get(D + "/api/citas/franjas", params={"medico_id": vill["medico_id"], "desde": ini.isoformat(), "dias": 7},
                                  timeout=60).json()]
cita = pedir("POST", "/api/citas", pac, "PACIENTE", json={"franja_id": libres[0]["franja_id"], "tipo": "CONSULTA"}).json()
r = pedir("POST", f"/api/citas/{cita['cita_id']}/reprogramar", pac, "PACIENTE", json={"franja_id": libres[1]["franja_id"]})
ok(r.status_code == 200 and r.json()["franja_id"] == libres[1]["franja_id"], "8. el paciente reagenda su consulta a otro horario",
   f"{r.json().get('fecha')} {r.json().get('hora_inicio')}")
lab_f = requests.get(D + "/api/citas/franjas", params={"dias": 14}, timeout=60).json()
if lab_f:
    r = pedir("POST", f"/api/citas/{cita['cita_id']}/reprogramar", pac, "PACIENTE", json={"franja_id": lab_f[0]["franja_id"]})
    ok(r.status_code == 422, "9. no se puede pasar una consulta a un turno de laboratorio (422)")
ok(pedir("POST", f"/api/citas/{cita['cita_id']}/reprogramar", otro, "PACIENTE", json={"franja_id": libres[2]["franja_id"]}).status_code == 403,
   "10. otro paciente no puede reagendarla (403)")

# --- Centro de notificaciones ---
avisos = pedir("GET", "/api/notificaciones/mias", pac, "PACIENTE").json()
ok(any(a["tipo"] == "CITA_REPROGRAMADA" for a in avisos), "11. el centro de notificaciones muestra el aviso de reagendamiento",
   f"{len(avisos)} avisos")
pedir("DELETE", f"/api/citas/{cita['cita_id']}", pac, "PACIENTE")

# --- Laboratorios y resultado externo en PDF ---
labs = requests.get(D + "/api/laboratorios", timeout=60).json()
ok(any(l["propio"] for l in labs) and any(not l["propio"] for l in labs), "12. hay laboratorio propio y externos", ", ".join(l["nombre"] for l in labs))
r = pedir("POST", "/api/laboratorios", adm, "ADMIN", json={"nombre": f"Laboratorio Prueba {date.today():%d%m}", "telefono": "032999999"})
ok(r.status_code in (201, 409), "13. el administrador crea un laboratorio", str(r.status_code))
catalogo = requests.get(D + "/api/examenes/catalogo", timeout=60).json()
glucosa = next(t for t in catalogo if "Glucosa" in t["nombre"])
s = pedir("POST", "/api/solicitudes", pac, "PACIENTE", json={"examenes": [glucosa["tipo_examen_id"]]}).json()
externo = next(l for l in labs if not l["propio"])
r = pedir("PUT", f"/api/solicitudes/{s['solicitud_id']}/laboratorio", pac, "PACIENTE", json={"laboratorio_id": externo["laboratorio_id"]})
ok(r.status_code == 200 and r.json()["propio"] is False, "14. el paciente elige hacerse los exámenes en otro laboratorio", externo["nombre"])
buf = BytesIO()
c = canvas.Canvas(buf)
c.drawString(72, 760, f"{externo['nombre']} - Informe de resultados")
c.drawString(72, 740, "Paciente: Sofia Navarrete")
c.drawString(72, 720, "Glucosa        142   mg/dL    70 - 100")
c.save()
r = pedir("POST", f"/api/solicitudes/{s['solicitud_id']}/resultado-externo", pac, "PACIENTE",
          json={"nombre": "resultado-externo.pdf", "contenido_base64": base64.b64encode(buf.getvalue()).decode()})
v = r.json()
ok(r.status_code == 201 and v["valores"] and v["valores"][0]["valor"] == 142, "15. el paciente sube el PDF y el sistema lee el valor",
   str([(x["parametro"], x.get("valor")) for x in v.get("valores", [])]))
docs = pedir("GET", f"/api/solicitudes/{s['solicitud_id']}/resultado-externo", med, "MEDICO").json()
p = pedir("GET", f"/api/solicitudes/{s['solicitud_id']}/resultado-externo/{docs[0]['documento_id']}", med, "MEDICO")
ok(docs and p.content[:4] == b"%PDF", "16. el médico ve el PDF externo (guardado en MongoDB)")
det = pedir("GET", f"/api/solicitudes/{s['solicitud_id']}", lab, "LABORATORISTA").json()
valores = [{"parametro_id": x["parametro_id"], "valor": x["valor"]} for x in v["valores"]]
r = pedir("POST", "/api/resultados", lab, "LABORATORISTA", json={"detalle_id": det["examenes"][0]["detalle_id"], "valores": valores})
fin_s = pedir("GET", f"/api/solicitudes/{s['solicitud_id']}", med, "MEDICO").json()
ok(r.status_code == 201 and fin_s["estado"] == "COMPLETADA" and fin_s["examenes"][0]["valores"][0]["nivel"] == "ALTO",
   "17. el laboratorista registra los valores leídos y el médico los ve (glucosa ↑ alto), sin cobro en nuestro laboratorio")
propia = pedir("POST", "/api/solicitudes", pac, "PACIENTE", json={"examenes": [glucosa["tipo_examen_id"]]}).json()
r = pedir("POST", f"/api/solicitudes/{propia['solicitud_id']}/resultado-externo", pac, "PACIENTE",
          json={"nombre": "x.pdf", "contenido_base64": base64.b64encode(buf.getvalue()).decode()})
ok(r.status_code == 409, "18. en una solicitud de nuestro laboratorio no se sube PDF externo (409)")

print(f"\n{sum(R)}/{len(R)} correctas")
