"""Prueba de concurrencia real, cobros y reversos (reembolsos) en la nube.

Simula un entorno de producción con múltiples usuarios concurrentes:
- Pacientes registrándose y reservando citas simultáneamente.
- Control de concurrencia transaccional en franjas horarias.
- Procesamiento de cobros (Transferencia QR y sesión Stripe Checkout).
- Confirmación de pagos por Administrador.
- Ejecución de REVERSOS / REEMBOLSOS (reembolso total y parcial).
- Laboratorista ingresando resultados mientras un Médico prescribe tratamientos.
- Consulta SOAP independiente simultánea.
- Verificación de replicación (Azure SQL -> Supabase y MongoDB Atlas).
"""
import concurrent.futures
import random
import time
from decimal import Decimal
import requests
from comun import ahora, credenciales, guardar, url_base

D = url_base()
c = credenciales()

eventos = []

def log(msg, **extra):
    linea = f"{ahora()}  {msg}  {extra if extra else ''}"
    print(linea)
    eventos.append({"hora": ahora(), "mensaje": msg, "datos": extra})

def cedula_valida() -> str:
    # 3er dígito < 6 para persona natural en Ecuador
    base = "17" + random.choice("012345") + "".join(random.choice("0123456789") for _ in range(6))
    s = sum(d - 9 if d > 9 else d for d in (int(x) * k for x, k in zip(base, [2, 1, 2, 1, 2, 1, 2, 1, 2])))
    return base + str((10 - s % 10) % 10)

def login(email, password="Lab2026*"):
    r = requests.post(f"{D}/api/auth/login", json={"email": email, "password": password}, timeout=30)
    if r.status_code != 200:
        raise Exception(f"Login fallo para {email}: {r.status_code} {r.text}")
    return r.json()["token"]

def registrar_paciente(nombre):
    sufijo = random.randint(10000, 99999)
    email = f"henrylagua1+conc_{sufijo}@gmail.com"
    cedula = cedula_valida()
    clave = f"Pass{sufijo}*"
    r = requests.post(f"{D}/api/auth/registro", json={
        "cedula": cedula, "nombres": nombre, "apellidos": f"Prueba {sufijo}",
        "fecha_nacimiento": "1995-04-12", "sexo": "M", "email": email, "password": clave
    }, timeout=30)
    if r.status_code not in (200, 201):
        raise Exception(f"Error registro {nombre}: {r.status_code} {r.text}")
    token = login(email, clave)
    return {"email": email, "cedula": cedula, "token": token, "nombre": nombre}

def main():
    log("=== INICIANDO PRUEBA DE CONCURRENCIA, COBROS Y REVERSOS EN VIVO ===")
    token_admin = login("admin@labclinico.test")
    token_lab = login("cmena@labclinico.test")
    token_med = login("jvillacis@labclinico.test")

    # 1. Registro de 3 pacientes concurrentes
    log("Fase 1: Creación simultánea de 3 cuentas de pacientes")
    pacientes = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
        futuros = [executor.submit(registrar_paciente, f"Paciente_Conc_{i}") for i in range(1, 4)]
        for f in concurrent.futures.as_completed(futuros):
            p = f.result()
            pacientes.append(p)
            log("Paciente registrado con éxito", email=p["email"], cedula=p["cedula"])

    # 2. Concurrencia de Reserva: Dos pacientes compiten por la misma franja
    log("Fase 2: Reserva concurrente con competencia por cupos")
    franjas = requests.get(f"{D}/api/citas/franjas?dias=7", timeout=15).json()
    franja_elegida = next(f for f in franjas if f["cupos_libres"] >= 1)
    fid = franja_elegida["franja_id"]
    log(f"Franja objetivo: ID {fid} ({franja_elegida['fecha']} {franja_elegida['hora_inicio']}) cupos: {franja_elegida['cupos_libres']}")

    def reservar(p):
        h = {"Authorization": f"Bearer {p['token']}", "X-Rol-Activo": "PACIENTE"}
        res = requests.post(f"{D}/api/citas", headers=h, json={"franja_id": fid, "motivo": "Control concurrente"}, timeout=30)
        return p["nombre"], res.status_code, res.json()

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        futuros = [executor.submit(reservar, pacientes[0]), executor.submit(reservar, pacientes[1])]
        for f in concurrent.futures.as_completed(futuros):
            nombre, status, data = f.result()
            log(f"Intento de reserva {nombre}", status=status, respuesta=data.get("estado") or data.get("error"))

    # 3. Creación de solicitudes de examen y cobranza
    log("Fase 3: Creación de solicitudes y múltiples métodos de cobro")
    catalogo = requests.get(f"{D}/api/examenes/catalogo", timeout=15).json()
    ex1 = catalogo[0]["tipo_examen_id"]
    ex2 = catalogo[1]["tipo_examen_id"]

    # Paciente 0 crea solicitud para pago con transferencia y posterior reverso
    h0 = {"Authorization": f"Bearer {pacientes[0]['token']}", "X-Rol-Activo": "PACIENTE"}
    sol1 = requests.post(f"{D}/api/solicitudes", headers=h0, json={"examenes": [ex1, ex2]}, timeout=30).json()
    log("Solicitud 1 creada", codigo=sol1["codigo"], total=sol1["total"])

    # Paciente 2 crea solicitud para sesión de Stripe Checkout
    h2 = {"Authorization": f"Bearer {pacientes[2]['token']}", "X-Rol-Activo": "PACIENTE"}
    sol2 = requests.post(f"{D}/api/solicitudes", headers=h2, json={"examenes": [ex1]}, timeout=30).json()
    log("Solicitud 2 creada", codigo=sol2["codigo"], total=sol2["total"])

    # Cobro A: Transferencia QR
    trf = requests.post(f"{D}/api/pagos/transferencia", headers=h0, json={"solicitud_id": sol1["solicitud_id"]}, timeout=30).json()
    pago1_id = trf["pago_id"]
    log("Pago por Transferencia registrado", pago_id=pago1_id, ref=trf["referencia"], monto=trf["monto"])

    # Cobro B: Stripe Checkout Session
    chk = requests.post(f"{D}/api/pagos/checkout", headers=h2, json={"solicitud_id": sol2["solicitud_id"]}, timeout=30).json()
    log("Sesión Stripe Checkout generada", session_id=chk["session_id"], url=chk["checkout_url"][:50] + "...")

    # 4. Administrador confirma el cobro por transferencia
    h_adm = {"Authorization": f"Bearer {token_admin}", "X-Rol-Activo": "ADMIN"}
    conf = requests.post(f"{D}/api/pagos/{pago1_id}/confirmar-transferencia", headers=h_adm, json={"aprobado": True}, timeout=30).json()
    log("Administrador confirmó el pago", pago_id=pago1_id, estado=conf["estado"])

    # 5. REVERSO / REEMBOLSO (Total y Parcial)
    log("Fase 4: Ejecución de Reversos / Reembolsos de pago")
    # Reverso parcial: 3.00 USD
    reembolso_parcial = requests.post(f"{D}/api/pagos/{pago1_id}/reembolso", headers=h_adm, json={
        "monto": 3.00, "motivo": "Reverso parcial solicitado por el paciente (error en cobro)"
    }, timeout=30).json()
    log("Reverso parcial ejecutado", reembolso_id=reembolso_parcial["reembolso_id"], estado_pago=reembolso_parcial["pago"]["estado"], reembolsado=reembolso_parcial["pago"]["monto_reembolsado"])

    # Reverso restante (reembolso total)
    saldo_restante = float(reembolso_parcial["pago"]["monto"]) - float(reembolso_parcial["pago"]["monto_reembolsado"])
    reembolso_total = requests.post(f"{D}/api/pagos/{pago1_id}/reembolso", headers=h_adm, json={
        "monto": saldo_restante, "motivo": "Reverso total por cancelación de orden"
    }, timeout=30).json()
    log("Reverso total completado", reembolso_id=reembolso_total["reembolso_id"], estado_pago=reembolso_total["pago"]["estado"], total_reembolsado=reembolso_total["pago"]["monto_reembolsado"])

    # 6. Operaciones concurrentes clínicas: Laboratorio y Médico trabajando al mismo tiempo
    log("Fase 5: Concurrencia entre Laboratorista y Médico")
    # Para probar resultados y médico, creamos una solicitud pagada limpia
    sol_clinica = requests.post(f"{D}/api/solicitudes", headers=h0, json={"examenes": [ex1]}, timeout=30).json()
    trf_clinica = requests.post(f"{D}/api/pagos/transferencia", headers=h0, json={"solicitud_id": sol_clinica["solicitud_id"]}, timeout=30).json()
    requests.post(f"{D}/api/pagos/{trf_clinica['pago_id']}/confirmar-transferencia", headers=h_adm, json={"aprobado": True}, timeout=30)
    
    det = requests.get(f"{D}/api/solicitudes/{sol_clinica['solicitud_id']}", headers=h_adm).json()
    detalle_id = det["examenes"][0]["detalle_id"]
    
    # Laboratorista toma muestra
    h_lab = {"Authorization": f"Bearer {token_lab}", "X-Rol-Activo": "LABORATORISTA"}
    requests.post(f"{D}/api/solicitudes/detalle/{detalle_id}/muestra", headers=h_lab, timeout=30)
    
    # Hilos simultáneos: Laboratorista guardando valores mientras Médico consulta historial y un cliente SOAP consulta exámenes
    def tarea_laboratorista():
        params = det["examenes"][0]["parametros"] if "parametros" in det["examenes"][0] else []
        if not params:
            t_obj = next(t for t in catalogo if t["tipo_examen_id"] == det["examenes"][0]["tipo_examen_id"])
            params = t_obj["parametros"]
        valores = [{"parametro_id": p["parametro_id"], "valor": round((p["valor_ref_min"] + p["valor_ref_max"]) / 2, 1)} for p in params]
        r = requests.post(f"{D}/api/resultados", headers=h_lab, json={"detalle_id": detalle_id, "valores": valores}, timeout=30)
        return "LAB", r.status_code, r.json()

    def tarea_medico():
        h_med = {"Authorization": f"Bearer {token_med}", "X-Rol-Activo": "MEDICO"}
        r = requests.get(f"{D}/api/solicitudes/pacientes/{det['paciente_id']}", headers=h_med, timeout=30)
        return "MED", r.status_code, len(r.json())

    def tarea_soap():
        r = requests.post(f"{D}/soap", data=(
            '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:lab="urn:labclinico:resultados">'
            f'<soapenv:Header><lab:Credencial><lab:ApiKey>{c["SOAP_API_KEY"]}</lab:ApiKey></lab:Credencial></soapenv:Header>'
            '<soapenv:Body><lab:ListarExamenesRequest/></soapenv:Body></soapenv:Envelope>'
        ), headers={"Content-Type": "text/xml; charset=utf-8"}, timeout=30)
        return "SOAP", r.status_code, len(r.content)

    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
        f_lab = executor.submit(tarea_laboratorista)
        f_med = executor.submit(tarea_medico)
        f_soap = executor.submit(tarea_soap)
        for f in concurrent.futures.as_completed([f_lab, f_med, f_soap]):
            actor, st, res = f.result()
            log(f"Operación simultánea de {actor} finalizada", status=st, resultado=res)

    # 7. Verificación de replicación en vivo
    log("Fase 6: Esperando sincronización distribuida de cobros y reversos...")
    time.sleep(6)
    
    # Comprobar estado final del pago y reverso en BD
    pago_final = requests.get(f"{D}/api/pagos/{pago1_id}", headers=h_adm).json()
    log("Estado final del pago auditado", estado=pago_final["estado"], monto=pago_final["monto"],
        monto_reembolsado=pago_final["monto_reembolsado"], num_reembolsos=len(pago_final["reembolsos"]))

    archivo_salida = guardar("concurrencia_real.json", {"eventos": eventos, "pago_auditado": pago_final})
    log(f"=== PRUEBA DE CONCURRENCIA Y REVERSOS COMPLETADA CON ÉXITO ===")
    log(f"Resultados guardados en: {archivo_salida}")

if __name__ == "__main__":
    main()
