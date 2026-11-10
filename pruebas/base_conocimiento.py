"""Prueba de la base de conocimientos para diagnósticos en la plataforma publicada.

  1. el motor evalúa las solicitudes con resultados y registra sugerencias
     (diagnóstico CIE-10 + explicación + protocolo), sin duplicarlas
  2. el médico consulta reglas (con precisión), diagnósticos y guías (MongoDB)
  3. el médico responde una sugerencia pendiente (la descarta con motivo)
  4. los roles sin permiso reciben 403
  5. las tablas de conocimiento están replicadas en Supabase

Uso:  python pruebas/base_conocimiento.py
"""
import time

import psycopg
import requests

from comun import ahora, azure_sql_admin, credenciales, guardar, url_base

D = url_base()
c = credenciales()
R = []


def ok(cond, msg, **datos):
    R.append({"hora": ahora(), "ok": bool(cond), "prueba": msg, **datos})
    print(f"{ahora()}  [{'OK' if cond else 'FALLA'}] {msg}  {datos if datos else ''}")


def pedir(metodo, ruta, token=None, rol=None, **kw):
    h = {"Authorization": f"Bearer {token}"} if token else {}
    if rol:
        h["X-Rol-Activo"] = rol
    return requests.request(metodo, f"{D}{ruta}", headers=h, timeout=60, **kw)


def login(email):
    return pedir("POST", "/api/auth/login", json={"email": email, "password": "Lab2026*"}).json()["token"]


t_med, t_adm, t_lab = login("jvillacis@labclinico.test"), login("admin@labclinico.test"), login("cmena@labclinico.test")

# ---------- 1. motor ----------
az = azure_sql_admin()
solicitudes = [f[0] for f in az.execute("""
    SELECT DISTINCT d.solicitud_id FROM dbo.resultado r JOIN dbo.solicitud_detalle d ON d.detalle_id = r.detalle_id
    JOIN dbo.resultado_valor v ON v.resultado_id = r.resultado_id ORDER BY d.solicitud_id""").fetchall()]
total = 0
for sid in solicitudes:
    r = pedir("POST", f"/api/conocimiento/evaluar/{sid}", t_med, "MEDICO")
    if r.status_code != 200:
        ok(False, f"evaluar solicitud {sid}", estado=r.status_code, cuerpo=r.text[:200])
        continue
    total += len(r.json()["sugerencias"])
ok(total > 0, "motor de reglas evalúa las solicitudes con resultados", solicitudes=len(solicitudes), sugerencias=total)

again = sum(pedir("POST", f"/api/conocimiento/evaluar/{sid}", t_med, "MEDICO").json()["nuevas"] for sid in solicitudes)
ok(again == 0, "re-evaluar es idempotente (no duplica sugerencias)", nuevas=again)

sugs = []
for sid in solicitudes:
    sugs += pedir("GET", f"/api/conocimiento/sugerencias?solicitud_id={sid}", t_med, "MEDICO").json()
ejemplo = next((s for s in sugs if s.get("codigo_cie10") == "R73.0"), sugs[0] if sugs else None)
if ejemplo:
    ok(bool(ejemplo.get("explicacion")), "la sugerencia explica qué valores la dispararon",
       cie10=ejemplo.get("codigo_cie10"), explicacion=ejemplo.get("explicacion"))

# ---------- 2. consultas ----------
reglas = pedir("GET", "/api/conocimiento/reglas", t_med, "MEDICO").json()
ok(len(reglas) >= 11 and all("precision_pct" in r for r in reglas), "reglas con condiciones y precisión", reglas=len(reglas))
diags = pedir("GET", "/api/conocimiento/diagnosticos", t_med, "MEDICO").json()
ok(len(diags) >= 10 and all(d.get("protocolo") for d in diags), "diagnósticos CIE-10 con protocolo", diagnosticos=len(diags))
g = pedir("GET", "/api/conocimiento/guias/diabetes", t_med, "MEDICO")
ok(g.status_code == 200 and g.json().get("criterios"), "guía clínica desde MongoDB Atlas", titulo=g.json().get("titulo"))
ok(pedir("GET", "/api/conocimiento/guias/no-existe", t_med, "MEDICO").status_code == 404, "guía inexistente -> 404")

# ---------- 3. respuesta del médico ----------
pendiente = next((s for s in sugs if s["estado"] == "PENDIENTE"), None)
if pendiente:
    r = pedir("POST", f"/api/conocimiento/sugerencias/{pendiente['sugerencia_id']}/responder", t_med, "MEDICO",
              json={"aceptar": False, "motivo": "Prueba automatizada: se requiere segunda muestra"})
    ok(r.status_code in (200, 403), "el médico responde la sugerencia (403 si no es su paciente)",
       estado=r.status_code, nuevo_estado=r.json().get("estado") if r.ok else r.json().get("mensaje"))
    if r.ok:
        r2 = pedir("POST", f"/api/conocimiento/sugerencias/{pendiente['sugerencia_id']}/responder", t_med, "MEDICO",
                   json={"aceptar": True})
        ok(r2.status_code == 409, "una sugerencia ya respondida no se vuelve a responder", estado=r2.status_code)

# ---------- 4. permisos ----------
ok(pedir("POST", "/api/conocimiento/reglas", t_med, "MEDICO", json={}).status_code == 403, "médico no crea reglas -> 403")
ok(pedir("GET", "/api/conocimiento/reglas", t_lab, "LABORATORISTA").status_code == 403, "laboratorista no ve reglas -> 403")
ok(pedir("GET", "/api/conocimiento/reglas").status_code == 401, "sin token -> 401")
ok(pedir("POST", "/api/conocimiento/reglas", t_adm, "ADMIN",
         json={"codigo": "X", "diagnostico_id": 1, "logica": "TODAS", "confianza": "ALTA", "recomendacion": "x",
               "condiciones": [{"parametro_id": 1, "operador": "ENTRE", "valor": 1}]}).status_code == 422,
   "regla inválida (ENTRE sin valor2) -> 422")

# ---------- 5. réplica en Supabase ----------
time.sleep(15)
tablas = ["diagnostico", "protocolo", "regla_diagnostica", "regla_condicion", "sugerencia_diagnostica"]
with psycopg.connect(host=c["SUPABASE_POOLER_HOST"], port=5432, dbname="postgres", user=f"postgres.{c['SUPABASE_PROJECT_REF']}",
                     password=c["SUPABASE_POSTGRES_PASSWORD"], sslmode="require") as pg:
    for t in tablas:
        origen = az.execute(f"SELECT COUNT(*) FROM dbo.{t}").fetchone()[0]
        replica = pg.execute(f"SELECT COUNT(*) FROM lab.{t}").fetchone()[0]
        ok(origen == replica, f"réplica Supabase {t}", azure=origen, supabase=replica)

fallas = [p for p in R if not p["ok"]]
print(f"\n{len(R) - len(fallas)}/{len(R)} pruebas correctas")
print("Resultados:", guardar("base_conocimiento.json", R))
raise SystemExit(1 if fallas else 0)
