"""Servicio de citas: franjas disponibles, reservas, cancelaciones y agenda."""
import json
from datetime import date, datetime, time, timedelta
from decimal import Decimal

from flask import Blueprint, g, jsonify, request

from .. import config, db
from ..errores import ApiError, no_encontrado, prohibido
from ..seguridad import perfil, requiere, rol_actual, usuario_actual
from ..validacion import cuerpo, entero, texto
from .notificaciones import encolar

bp = Blueprint("citas", __name__, url_prefix="/api/citas")

# Hay dos tipos de cita:
# - MUESTRA: turno para la toma de muestras en el laboratorio (franjas sin médico).
# - CONSULTA: consulta con un médico (franjas de su agenda). Se cobra por Stripe
#   como una solicitud CONSULTA de una línea ("Consulta médica").
# Una cita se confirma cuando se paga su solicitud (sp_confirmar_pago); si no se
# paga en MINUTOS_PARA_PAGAR, el sincronizador la cancela. La cita de CONTROL que
# agenda el médico también se cobra (revisión del 20-11, 13_revision_2011.sql):
# se paga hasta HORAS_ANTES_CONTROL horas antes de la cita.
MINUTOS_PARA_PAGAR = 30
DIAS_RESERVAR = 90             # el calendario de reservas y de reagendar llega hasta 3 meses
DIAS_REPROGRAMAR = DIAS_RESERVAR
HORAS_ANTES_CONTROL = 2
# Cancelar una cita pagada: con HORAS_CANCELAR o más de anticipación se devuelve PORCENTAJE_REEMBOLSO;
# con menos ya no se cancela, solo se reagenda.
HORAS_CANCELAR = 24
PORCENTAJE_REEMBOLSO = 80

SQL_CITAS = """
SELECT c.cita_id, c.estado, c.motivo, c.canal, c.created_at, c.tipo, c.origen, c.medico_id, c.cita_origen_id,
       CONCAT(pmc.nombres, ' ', pmc.apellidos) AS medico, mc.especialidad,
       f.franja_id, f.fecha, f.hora_inicio, f.hora_fin,
       f.laboratorio_id, lb.nombre AS sucursal, lb.direccion AS sucursal_direccion, lb.latitud, lb.longitud,
       pa.paciente_id, CONCAT(p.nombres, ' ', p.apellidos) AS paciente, p.cedula,
       s.solicitud_id, s.codigo AS solicitud_codigo, s.estado AS solicitud_estado, s.total AS solicitud_total,
       (SELECT STRING_AGG(t.nombre, ', ') FROM {e}.solicitud_detalle sd
        JOIN {e}.tipo_examen t ON t.tipo_examen_id = sd.tipo_examen_id WHERE sd.solicitud_id = s.solicitud_id) AS examenes_resumen
FROM {e}.cita c
JOIN {e}.franja_horaria f ON f.franja_id = c.franja_id
LEFT JOIN {e}.laboratorio lb ON lb.laboratorio_id = f.laboratorio_id
JOIN {e}.paciente pa ON pa.paciente_id = c.paciente_id
JOIN {e}.persona p ON p.persona_id = pa.persona_id
LEFT JOIN {e}.medico mc ON mc.medico_id = c.medico_id
LEFT JOIN {e}.persona pmc ON pmc.persona_id = mc.persona_id
LEFT JOIN (SELECT cita_id, MAX(solicitud_id) AS solicitud_id FROM {e}.solicitud_examen
           WHERE cita_id IS NOT NULL AND estado <> 'ANULADA' GROUP BY cita_id) sx ON sx.cita_id = c.cita_id
LEFT JOIN {e}.solicitud_examen s ON s.solicitud_id = sx.solicitud_id
"""


def _inicio_utc(c: dict) -> datetime:
    """Hora de la cita en UTC (las franjas están en hora de Ecuador, UTC-5)."""
    hora = c["hora_inicio"] if isinstance(c["hora_inicio"], time) else time.fromisoformat(str(c["hora_inicio"]))
    fecha = c["fecha"] if isinstance(c["fecha"], date) else date.fromisoformat(str(c["fecha"]))
    return datetime.combine(fecha, hora) + timedelta(hours=5)


def _con_vencimiento(citas: list[dict]) -> list[dict]:
    """Agrega 'vence_at' (UTC): hasta cuándo se puede pagar una cita pendiente."""
    for c in citas:
        if c["estado"] != "PENDIENTE_PAGO" or not c.get("created_at"):
            c["vence_at"] = None
        elif c.get("origen") == "MEDICO":
            c["vence_at"] = _inicio_utc(c) - timedelta(hours=HORAS_ANTES_CONTROL)
        else:
            c["vence_at"] = c["created_at"] + timedelta(minutes=MINUTOS_PARA_PAGAR)
    return citas


def _fecha_param(nombre: str, defecto: date) -> date:
    valor = request.args.get(nombre)
    if not valor:
        return defecto
    try:
        return date.fromisoformat(valor)
    except ValueError:
        raise ApiError(f"El parámetro '{nombre}' debe tener formato AAAA-MM-DD.", 422, "TIPO_INVALIDO")


def _filtro_agenda() -> tuple[str, list]:
    """?medico_id: su agenda de consultas. Si no, turnos de toma de muestras (de la sucursal ?laboratorio_id)."""
    medico_id = request.args.get("medico_id", type=int)
    if medico_id:
        return "medico_id = ?", [medico_id]
    laboratorio_id = request.args.get("laboratorio_id", type=int)
    if laboratorio_id:
        return "medico_id IS NULL AND laboratorio_id = ?", [laboratorio_id]
    return "medico_id IS NULL", []


@bp.get("/franjas")
def franjas():
    """Público: franjas con cupo entre ?desde y ?desde + ?dias (máx. DIAS_RESERVAR + 2).

    Sin ?medico_id: turnos de toma de muestras (de la sucursal ?laboratorio_id). Con ?medico_id: su agenda de consultas.
    """
    desde = _fecha_param("desde", date.today())
    dias = min(max(request.args.get("dias", 7, type=int), 0), DIAS_RESERVAR + 2)
    filtro, params = _filtro_agenda()
    filas = db.leer(
        "SELECT franja_id, fecha, hora_inicio, hora_fin, capacidad, ocupados, capacidad - ocupados AS cupos_libres, medico_id, "
        f"laboratorio_id FROM {{e}}.franja_horaria WHERE activa = ? AND ocupados < capacidad AND fecha BETWEEN ? AND ? "
        f"AND {filtro} ORDER BY fecha, hora_inicio", True, desde, desde + timedelta(days=dias), *params)
    ahora = datetime.utcnow()
    return jsonify([f for f in filas if _inicio_utc(f) > ahora])


@bp.get("/dias-libres")
def dias_libres():
    """Público: días con horarios libres en los próximos DIAS_RESERVAR días, para marcar el calendario.

    Mismos filtros que /franjas (?medico_id o ?laboratorio_id). Devuelve [{fecha, libres}].
    """
    hoy = date.today()
    filtro, params = _filtro_agenda()
    filas = db.leer(
        "SELECT franja_id, fecha, hora_inicio FROM {e}.franja_horaria "
        f"WHERE activa = ? AND ocupados < capacidad AND fecha BETWEEN ? AND ? AND {filtro}",
        True, hoy, hoy + timedelta(days=DIAS_RESERVAR), *params)
    ahora = datetime.utcnow()
    cuenta: dict[str, int] = {}
    for f in filas:
        if _inicio_utc(f) > ahora:
            clave = str(f["fecha"])[:10]
            cuenta[clave] = cuenta.get(clave, 0) + 1
    return jsonify([{"fecha": k, "libres": v} for k, v in sorted(cuenta.items())])


@bp.get("/medicos")
def medicos():
    """Público: médicos activos con su especialidad, el precio de la consulta y cuántos turnos libres tienen."""
    precio = db.leer_uno("SELECT precio FROM {e}.tipo_examen WHERE codigo = ?", "CONS-MED")
    filas = db.leer("""
        SELECT m.medico_id, CONCAT(p.nombres, ' ', p.apellidos) AS nombre, m.especialidad,
               (SELECT COUNT(*) FROM {e}.franja_horaria f WHERE f.medico_id = m.medico_id AND f.activa = ?
                AND f.ocupados < f.capacidad AND f.fecha >= ?) AS turnos_libres
        FROM {e}.medico m JOIN {e}.persona p ON p.persona_id = m.persona_id
        WHERE m.activo = ? ORDER BY p.apellidos""", True, date.today(), True)
    for f in filas:
        f["precio_consulta"] = precio["precio"] if precio else None
    return jsonify(filas)


@bp.post("")
@requiere("PACIENTE")
def reservar():
    d = cuerpo()
    paciente_id = perfil("paciente_id")
    proteccion, espera_ms = True, 0
    if config.PERMITIR_PRUEBA_CONCURRENCIA:
        proteccion = request.args.get("proteccion", "1") != "0"
        espera_ms = min(request.args.get("espera_ms", 0, type=int), 5000)

    franja_id = entero(d, "franja_id")
    tipo = (d.get("tipo") or "MUESTRA").upper()
    if tipo not in ("MUESTRA", "CONSULTA"):
        raise ApiError("'tipo' debe ser MUESTRA o CONSULTA.", 422, "TIPO_INVALIDO")
    franja = db.leer_uno("SELECT medico_id FROM {e}.franja_horaria WHERE franja_id = ?", franja_id, contingencia=False)
    if not franja:
        raise no_encontrado("La franja")
    if (tipo == "CONSULTA") != (franja["medico_id"] is not None):
        raise ApiError("La franja elegida no corresponde a ese tipo de cita.", 422, "FRANJA_INVALIDA")

    if tipo == "CONSULTA":
        cita_id = db.ejecutar_sp(
            "sp_reservar_consulta", "cita_id", paciente_id=paciente_id, franja_id=franja_id,
            motivo=texto(d, "motivo", False, 300), origen="PACIENTE", usuario_id=usuario_actual()["usuario_id"],
            instancia_api=config.INSTANCIA)
    else:
        cita_id = db.ejecutar_sp(
            "sp_reservar_cita", "cita_id", paciente_id=paciente_id, franja_id=franja_id,
            motivo=texto(d, "motivo", False, 300), canal="PORTAL", usuario_id=usuario_actual()["usuario_id"],
            instancia_api=config.INSTANCIA, protegido=proteccion, espera_ms=espera_ms)

    cita = _con_vencimiento([db.leer_uno(SQL_CITAS + " WHERE c.cita_id = ?", cita_id)])[0]
    cuando = f"el {cita['fecha']} a las {str(cita['hora_inicio'])[:5]}"
    if tipo == "CONSULTA":
        encolar(usuario_actual()["persona_id"], "CITA_RESERVADA", f"Consulta reservada para {cuando}",
                f"Su consulta con Dr(a). {cita['medico']} quedó reservada para {cuando}. Para confirmarla, pague la "
                f"consulta ({cita['solicitud_codigo']}) en los próximos {MINUTOS_PARA_PAGAR} minutos desde 'Mis citas'; "
                "si no, la cita se cancela y el turno se libera.")
    else:
        encolar(usuario_actual()["persona_id"], "CITA_RESERVADA", f"Cita reservada para {cuando}",
                f"Su turno de toma de muestras fue reservado para {cuando}. Para confirmarlo, elija sus exámenes y "
                f"páguelos en los próximos {MINUTOS_PARA_PAGAR} minutos desde 'Mis citas' en el portal; si no, "
                "la cita se cancela y el cupo se libera.")
    return jsonify(cita), 201


@bp.post("/control")
@requiere("MEDICO")
def agendar_control():
    """El médico agenda la cita de control en su propia agenda. Se cobra como una consulta (revisión del 20-11):
    el paciente la paga hasta HORAS_ANTES_CONTROL horas antes; si no, se cancela sola."""
    d = cuerpo()
    paciente_id = entero(d, "paciente_id")
    cita_id = db.ejecutar_sp(
        "sp_reservar_consulta", "cita_id", paciente_id=paciente_id, franja_id=entero(d, "franja_id"),
        motivo=texto(d, "motivo", False, 300) or "Control", origen="MEDICO", medico_agenda=perfil("medico_id"),
        cita_origen_id=entero(d, "cita_origen_id", False),
        usuario_id=usuario_actual()["usuario_id"], instancia_api=config.INSTANCIA)
    cita = _con_vencimiento([db.leer_uno(SQL_CITAS + " WHERE c.cita_id = ?", cita_id)])[0]
    persona = db.leer_uno("SELECT pa.persona_id FROM {e}.paciente pa WHERE pa.paciente_id = ?", paciente_id)
    encolar(persona["persona_id"], "CITA_RESERVADA",
            f"Cita de control el {cita['fecha']} a las {str(cita['hora_inicio'])[:5]} - {cita['solicitud_codigo']}",
            f"Dr(a). {cita['medico']} le agendó una cita de control para el {cita['fecha']} a las "
            f"{str(cita['hora_inicio'])[:5]}. Para confirmarla, pague el control (USD {cita['solicitud_total']:.2f}) "
            f"desde 'Mis citas' en el portal hasta {HORAS_ANTES_CONTROL} horas antes; si no, se cancela y el turno se libera.")
    return jsonify(cita), 201


@bp.get("/<int:cita_id>")
@requiere("MEDICO", "LABORATORISTA", "ADMIN")
def ver_cita(cita_id: int):
    cita = db.leer_uno(SQL_CITAS + " WHERE c.cita_id = ?", cita_id)
    if not cita:
        raise no_encontrado("La cita")
    if rol_actual() == "MEDICO" and cita["medico_id"] != perfil("medico_id"):
        raise prohibido("La cita no es de su agenda.")
    return jsonify(_con_vencimiento([cita])[0])


def _cita_del_medico(cita_id: int) -> dict:
    cita = db.leer_uno("SELECT cita_id, medico_id, paciente_id, motivo, tipo FROM {e}.cita WHERE cita_id = ?", cita_id)
    if not cita or cita["tipo"] != "CONSULTA":
        raise no_encontrado("La consulta")
    if cita["medico_id"] != perfil("medico_id"):
        raise prohibido("La consulta no es de su agenda.")
    return cita


@bp.get("/<int:cita_id>/nota")
@requiere("MEDICO")
def ver_nota(cita_id: int):
    """Lo anotado en la consulta: motivo, molestias, examen físico y diagnóstico (dato clínico: solo su médico)."""
    cita = _cita_del_medico(cita_id)
    nota = db.leer_uno("SELECT motivo, sintomas, examen_fisico, diagnostico, updated_at FROM {e}.consulta_nota "
                       "WHERE cita_id = ?", cita_id)
    # Sin nota todavía: se propone el motivo que escribió el paciente al reservar.
    return jsonify(nota or {"motivo": cita["motivo"], "sintomas": None, "examen_fisico": None, "diagnostico": None,
                            "updated_at": None})


@bp.put("/<int:cita_id>/nota")
@requiere("MEDICO")
def guardar_nota(cita_id: int):
    cita = _cita_del_medico(cita_id)
    d = cuerpo()
    valores = (texto(d, "motivo", False, 500), texto(d, "sintomas", False, 2000), texto(d, "examen_fisico", False, 2000),
               texto(d, "diagnostico", False, 500))
    if not any(valores):
        raise ApiError("Escriba al menos el motivo o las molestias de la consulta.", 422, "CAMPO_REQUERIDO")
    db.ejecutar("""
        MERGE dbo.consulta_nota AS n
        USING (SELECT ? AS cita_id) AS x ON n.cita_id = x.cita_id
        WHEN MATCHED THEN UPDATE SET motivo = ?, sintomas = ?, examen_fisico = ?, diagnostico = ?, updated_at = SYSUTCDATETIME()
        WHEN NOT MATCHED THEN INSERT (cita_id, medico_id, motivo, sintomas, examen_fisico, diagnostico)
             VALUES (?, ?, ?, ?, ?, ?);""", cita_id, *valores, cita_id, cita["medico_id"], *valores)
    db.ejecutar_sp("sp_auditar", usuario_id=usuario_actual()["usuario_id"], rol_actuante="MEDICO",
                   accion="GUARDAR_NOTA_CONSULTA", entidad="cita", entidad_id=str(cita_id))
    return jsonify(db.leer_uno("SELECT motivo, sintomas, examen_fisico, diagnostico, updated_at FROM {e}.consulta_nota "
                               "WHERE cita_id = ?", cita_id))


@bp.post("/<int:cita_id>/atender")
@requiere("MEDICO", "LABORATORISTA", "ADMIN")
def atender(cita_id: int):
    """Marca la cita como ATENDIDA. La consulta solo la cierra su médico."""
    db.ejecutar_sp("sp_atender_cita", cita_id=cita_id,
                   medico_id=perfil("medico_id") if rol_actual() == "MEDICO" else None,
                   usuario_id=usuario_actual()["usuario_id"])
    return jsonify(_con_vencimiento([db.leer_uno(SQL_CITAS + " WHERE c.cita_id = ?", cita_id)])[0])


@bp.get("/mias")
@requiere("PACIENTE")
def mias():
    return jsonify(_con_vencimiento(db.leer(SQL_CITAS + " WHERE c.paciente_id = ? ORDER BY f.fecha DESC, f.hora_inicio DESC",
                                            perfil("paciente_id"))))


def _pagos_de_cita(cita_id: int) -> list[dict]:
    """Pagos aprobados de lo que se cobró por la cita (la consulta o los exámenes aún sin procesar)."""
    return db.leer("""
        SELECT pg.pago_id, pg.monto, pg.monto_reembolsado, s.codigo
        FROM {e}.pago pg JOIN {e}.solicitud_examen s ON s.solicitud_id = pg.solicitud_id
        WHERE s.cita_id = ? AND pg.estado IN ('APROBADO', 'REEMBOLSO_PARCIAL') AND s.estado = 'PAGADA'""",
                   cita_id, contingencia=False)


@bp.get("/<int:cita_id>/cancelacion")
@requiere("PACIENTE", "ADMIN")
def cotizar_cancelacion(cita_id: int):
    """Qué pasa si se cancela: si se puede y cuánto se devuelve (para mostrarlo antes de confirmar)."""
    return jsonify(_politica_cancelacion(cita_id))


def _politica_cancelacion(cita_id: int) -> dict:
    c = db.leer_uno(SQL_CITAS + " WHERE c.cita_id = ?", cita_id, contingencia=False)
    if not c:
        raise no_encontrado("La cita")
    if rol_actual() == "PACIENTE" and c["paciente_id"] != perfil("paciente_id"):
        raise prohibido("Solo puede cancelar sus propias citas.")
    if c["estado"] not in ("PENDIENTE_PAGO", "CONFIRMADA"):
        return {"puede": False, "motivo": "La cita ya no se puede cancelar.", "reembolso": 0, "pagado": 0}
    pagos = _pagos_de_cita(cita_id) if c["estado"] == "CONFIRMADA" else []
    pagado = sum(Decimal(p["monto"]) - Decimal(p["monto_reembolsado"]) for p in pagos)
    if not pagado:
        return {"puede": True, "motivo": None, "reembolso": 0, "pagado": 0}
    horas = (_inicio_utc(c) - datetime.utcnow()).total_seconds() / 3600
    if rol_actual() == "ADMIN":      # la cancela el laboratorio: se devuelve todo
        return {"puede": True, "motivo": None, "reembolso": float(pagado), "pagado": float(pagado), "porcentaje": 100}
    if horas < HORAS_CANCELAR:
        return {"puede": False, "reembolso": 0, "pagado": float(pagado),
                "motivo": f"Faltan menos de {HORAS_CANCELAR} horas para la cita: ya no se puede cancelar, solo reagendar."}
    reembolso = (pagado * PORCENTAJE_REEMBOLSO / 100).quantize(Decimal("0.01"))
    return {"puede": True, "motivo": None, "reembolso": float(reembolso), "pagado": float(pagado),
            "porcentaje": PORCENTAJE_REEMBOLSO}


@bp.delete("/<int:cita_id>")
@requiere("PACIENTE", "ADMIN")
def cancelar(cita_id: int):
    """Cancela la cita. Si estaba pagada: con HORAS_CANCELAR horas o más de anticipación se devuelve el
    PORCENTAJE_REEMBOLSO por Stripe (el administrador devuelve todo); con menos, solo se puede reagendar."""
    politica = _politica_cancelacion(cita_id)
    if not politica["puede"]:
        raise ApiError(politica["motivo"], 409, "CANCELACION_NO_PERMITIDA")
    devuelto = Decimal("0")
    if politica["reembolso"]:
        from .pagos import reembolsar_pago
        porcentaje = Decimal(politica.get("porcentaje", 100))
        for p in _pagos_de_cita(cita_id):
            monto = ((Decimal(p["monto"]) - Decimal(p["monto_reembolsado"])) * porcentaje / 100).quantize(Decimal("0.01"))
            if monto > 0:
                reembolsar_pago(p["pago_id"], monto, f"Cita cancelada con anticipación ({porcentaje}% de devolución)")
                devuelto += monto
    db.ejecutar_sp("sp_cancelar_cita", cita_id=cita_id, usuario_id=usuario_actual()["usuario_id"])
    mensaje = f"Cita cancelada. Se le devolverán USD {devuelto:.2f} a su tarjeta." if devuelto else "Cita cancelada."
    return jsonify(mensaje=mensaje, cita_id=cita_id, reembolso=float(devuelto))


@bp.get("/agenda")
@requiere("LABORATORISTA", "MEDICO", "ADMIN")
def agenda():
    """Citas del día. Laboratorio: tomas de muestras. Médico: sus consultas. Administrador: todo (?tipo=)."""
    dia = _fecha_param("fecha", date.today())
    condiciones, params = ["f.fecha = ?", "c.estado <> 'CANCELADA'"], [dia]
    if rol_actual() == "MEDICO":
        condiciones.append("c.medico_id = ?")
        params.append(perfil("medico_id"))
    elif rol_actual() == "LABORATORISTA":
        # Cada laboratorista ve los turnos de su sucursal.
        condiciones.append("c.tipo = 'MUESTRA'")
        sucursal = sucursal_del_laboratorista()
        if sucursal:
            condiciones.append("f.laboratorio_id = ?")
            params.append(sucursal)
    elif request.args.get("tipo") in ("MUESTRA", "CONSULTA"):
        condiciones.append("c.tipo = ?")
        params.append(request.args["tipo"])
    return jsonify(_con_vencimiento(db.leer(SQL_CITAS + " WHERE " + " AND ".join(condiciones)
                                            + " ORDER BY f.hora_inicio, c.cita_id", *params)))


def sucursal_del_laboratorista() -> int | None:
    lab_id = usuario_actual().get("laboratorista_id")
    if not lab_id:
        return None
    fila = db.leer_uno("SELECT laboratorio_id FROM {e}.laboratorista WHERE laboratorista_id = ?", lab_id)
    return fila["laboratorio_id"] if fila else None


@bp.post("/franjas")
@requiere("ADMIN")
def crear_franjas():
    """Genera franjas para un rango de fechas (lunes a sábado). Las de toma de muestras son de una sucursal."""
    d = cuerpo()
    try:
        desde, hasta = date.fromisoformat(d["desde"]), date.fromisoformat(d["hasta"])
        h_ini, h_fin = d.get("hora_inicio", "07:00"), d.get("hora_fin", "11:00")
    except (KeyError, ValueError, TypeError):
        raise ApiError("Envíe 'desde' y 'hasta' (AAAA-MM-DD).", 422, "TIPO_INVALIDO")
    if hasta < desde or (hasta - desde).days > DIAS_RESERVAR + 2:
        raise ApiError(f"El rango debe ser válido y de máximo {DIAS_RESERVAR + 2} días.", 422, "RANGO_INVALIDO")
    intervalo = entero(d, "intervalo_minutos", False) or 30
    medico_id = entero(d, "medico_id", False)          # None = turnos de toma de muestras de una sucursal
    laboratorio_id = None
    if not medico_id:
        laboratorio_id = entero(d, "laboratorio_id", False) or db.leer_uno(
            "SELECT MIN(laboratorio_id) AS id FROM {e}.laboratorio WHERE propio = ?", True)["id"]
        if not db.leer_uno("SELECT 1 AS x FROM {e}.laboratorio WHERE laboratorio_id = ? AND propio = ? AND activo = ?",
                           laboratorio_id, True, True, contingencia=False):
            raise ApiError("Elija una sucursal activa de la empresa.", 422, "SUCURSAL_INVALIDA")
    capacidad = entero(d, "capacidad", False) or (1 if medico_id else 3)
    creadas = db.ejecutar("""
        ;WITH d10 AS (SELECT i FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) v(i)),
         n AS (SELECT a.i + b.i * 10 + c.i * 100 AS i FROM d10 a CROSS JOIN d10 b CROSS JOIN d10 c),
         dias AS (SELECT DATEADD(DAY, i, CAST(? AS DATE)) AS fecha FROM n WHERE i <= DATEDIFF(DAY, ?, ?)),
         horas AS (SELECT DATEADD(MINUTE, i * ?, CAST(? AS TIME(0))) AS hora FROM n
                   WHERE (i + 1) * ? <= DATEDIFF(MINUTE, CAST(? AS TIME(0)), CAST(? AS TIME(0))))
        INSERT INTO dbo.franja_horaria (fecha, hora_inicio, hora_fin, capacidad, medico_id, laboratorio_id)
        SELECT d.fecha, h.hora, DATEADD(MINUTE, ?, h.hora), ?, ?, ?
        FROM dias d CROSS JOIN horas h
        WHERE DATEDIFF(DAY, '19000101', d.fecha) % 7 <> 6
          AND NOT EXISTS (SELECT 1 FROM dbo.franja_horaria f WHERE f.fecha = d.fecha AND f.hora_inicio = h.hora
                          AND (f.medico_id = ? OR (f.medico_id IS NULL AND ? IS NULL))
                          AND (f.laboratorio_id = ? OR (f.laboratorio_id IS NULL AND ? IS NULL)))
    """, desde, desde, hasta, intervalo, h_ini, intervalo, h_ini, h_fin, intervalo, capacidad, medico_id, laboratorio_id,
                          medico_id, medico_id, laboratorio_id, laboratorio_id)
    return jsonify(franjas_creadas=creadas), 201


# ------------------------------ horario de cada médico ------------------------------
def _hora(valor, campo: str) -> time:
    try:
        return time.fromisoformat(str(valor))
    except ValueError:
        raise ApiError(f"'{campo}' debe tener formato HH:MM.", 422, "TIPO_INVALIDO")


@bp.post("/horario")
@requiere("MEDICO", "ADMIN")
def generar_horario():
    """El médico arma su agenda: qué días atiende y bloques con su propia duración de consulta.

    Dos formas de elegir los días:
    - Días de la semana en un rango: {desde, hasta, dias: [1..7] (1 = lunes), bloques: [...]}
      Ej.: de lunes a viernes, mañana de 08:00 a 12:00 cada 30 min y tarde de 14:00 a 18:00 cada 60 min.
    - Fechas sueltas: {fechas: ["2026-11-28", ...], bloques: [...]}
      Ej.: solo el sábado 28, de 08:00 a 11:00 (tres horas).
    No pisa turnos que ya existan: los horarios que se cruzan con otros se omiten.
    """
    d = cuerpo()
    medico_id = perfil("medico_id") if rol_actual() == "MEDICO" else entero(d, "medico_id")
    limite = date.today() + timedelta(days=DIAS_RESERVAR + 2)
    fechas_sueltas = d.get("fechas")
    if fechas_sueltas:
        if not isinstance(fechas_sueltas, list) or len(fechas_sueltas) > 60:
            raise ApiError("Envíe entre 1 y 60 fechas.", 422, "TIPO_INVALIDO")
        try:
            elegidas = sorted({date.fromisoformat(str(x)) for x in fechas_sueltas})
        except ValueError:
            raise ApiError("Cada fecha debe tener formato AAAA-MM-DD.", 422, "TIPO_INVALIDO")
        if elegidas[0] < date.today() or elegidas[-1] > limite:
            raise ApiError(f"Las fechas deben estar entre hoy y los próximos {DIAS_RESERVAR} días.", 422, "RANGO_INVALIDO")
    else:
        try:
            desde, hasta = date.fromisoformat(d["desde"]), date.fromisoformat(d["hasta"])
        except (KeyError, ValueError, TypeError):
            raise ApiError("Envíe 'desde' y 'hasta' (AAAA-MM-DD) o una lista de 'fechas'.", 422, "TIPO_INVALIDO")
        if desde < date.today() or hasta < desde or hasta > limite:
            raise ApiError(f"El rango debe empezar hoy o después y llegar máximo a {DIAS_RESERVAR} días.", 422,
                           "RANGO_INVALIDO")
        dias = d.get("dias")
        if not isinstance(dias, list) or not dias or not all(isinstance(x, int) and 1 <= x <= 7 for x in dias):
            raise ApiError("Elija al menos un día de la semana (1 = lunes ... 7 = domingo).", 422, "TIPO_INVALIDO")
        elegidas = [desde + timedelta(days=i) for i in range((hasta - desde).days + 1)
                    if (desde + timedelta(days=i)).isoweekday() in dias]
    bloques = d.get("bloques")
    if not isinstance(bloques, list) or not 1 <= len(bloques) <= 6:
        raise ApiError("Envíe entre 1 y 6 bloques de horario.", 422, "TIPO_INVALIDO")
    rangos = []
    for b in bloques:
        if not isinstance(b, dict):
            raise ApiError("Cada bloque debe tener inicio, fin y minutos.", 422, "TIPO_INVALIDO")
        ini, fin = _hora(b.get("inicio"), "inicio"), _hora(b.get("fin"), "fin")
        minutos = b.get("minutos")
        if not isinstance(minutos, int) or not 10 <= minutos <= 240:
            raise ApiError("La duración de la consulta debe estar entre 10 y 240 minutos.", 422, "TIPO_INVALIDO")
        if fin <= ini:
            raise ApiError("En cada bloque la hora de fin debe ser posterior a la de inicio.", 422, "TIPO_INVALIDO")
        rangos.append((ini, fin, minutos))
    rangos.sort()
    for (a_ini, a_fin, _), (b_ini, _, _) in zip(rangos, rangos[1:]):
        if b_ini < a_fin:
            raise ApiError("Los bloques de horario no pueden cruzarse entre sí.", 422, "BLOQUES_CRUZADOS")

    turnos = []
    for dia in elegidas:
        for ini, fin, minutos in rangos:
            t = datetime.combine(dia, ini)
            tope = datetime.combine(dia, fin)
            while t + timedelta(minutes=minutos) <= tope:
                turnos.append({"fecha": dia.isoformat(), "inicio": t.strftime("%H:%M"),
                               "fin": (t + timedelta(minutes=minutos)).strftime("%H:%M")})
                t += timedelta(minutes=minutos)
    if not turnos:
        return jsonify(franjas_creadas=0, omitidas=0, mensaje="Con esos días y horas no se generó ningún turno."), 201
    # Primero se reactivan los turnos que se habían quitado a esa misma hora (el índice único no deja repetirlos),
    # luego se insertan los que no se cruzan con otros del mismo médico.
    reactivadas = db.ejecutar("""
        UPDATE f SET activa = 1, hora_fin = j.fin, updated_at = SYSUTCDATETIME()
        FROM dbo.franja_horaria f
        JOIN OPENJSON(?) WITH (fecha DATE, inicio TIME(0), fin TIME(0)) j ON j.fecha = f.fecha AND j.inicio = f.hora_inicio
        WHERE f.medico_id = ? AND f.activa = 0 AND f.ocupados = 0
          AND NOT EXISTS (SELECT 1 FROM dbo.franja_horaria o WHERE o.medico_id = f.medico_id AND o.fecha = f.fecha
                          AND o.activa = 1 AND o.franja_id <> f.franja_id AND o.hora_inicio < j.fin AND o.hora_fin > j.inicio)""",
                              json.dumps(turnos), medico_id)
    creadas = reactivadas + db.ejecutar("""
        INSERT INTO dbo.franja_horaria (fecha, hora_inicio, hora_fin, capacidad, medico_id)
        SELECT j.fecha, j.inicio, j.fin, 1, ?
        FROM OPENJSON(?) WITH (fecha DATE, inicio TIME(0), fin TIME(0)) j
        WHERE NOT EXISTS (SELECT 1 FROM dbo.franja_horaria f
                          WHERE f.medico_id = ? AND f.fecha = j.fecha
                            AND (f.hora_inicio = j.inicio OR (f.activa = 1 AND f.hora_inicio < j.fin AND f.hora_fin > j.inicio)))""",
                          medico_id, json.dumps(turnos), medico_id)
    db.ejecutar_sp("sp_auditar", usuario_id=usuario_actual()["usuario_id"], rol_actuante=rol_actual(),
                   accion="GENERAR_HORARIO", entidad="medico", entidad_id=str(medico_id),
                   detalle=json.dumps({"desde": elegidas[0].isoformat(), "hasta": elegidas[-1].isoformat(),
                                       "dias": len(elegidas), "creadas": creadas}))
    return jsonify(franjas_creadas=creadas, omitidas=len(turnos) - creadas), 201


@bp.post("/horario/quitar")
@requiere("MEDICO", "ADMIN")
def quitar_horario():
    """Quita los turnos LIBRES de las fechas indicadas (los que ya tienen cita se conservan).

    {fechas: ["2026-11-28", ...]} o {desde, hasta}; opcionalmente solo entre {hora_desde, hora_hasta}.
    Sirve para cambiar el horario de un día o de varios: se quitan y se vuelven a generar.
    """
    d = cuerpo()
    medico_id = perfil("medico_id") if rol_actual() == "MEDICO" else entero(d, "medico_id")
    try:
        if d.get("fechas"):
            fechas = sorted({date.fromisoformat(str(x)) for x in d["fechas"]})[:92]
        else:
            desde, hasta = date.fromisoformat(d["desde"]), date.fromisoformat(d["hasta"])
            if hasta < desde or (hasta - desde).days > DIAS_RESERVAR + 2:
                raise ApiError("Rango de fechas no válido.", 422, "RANGO_INVALIDO")
            fechas = [desde + timedelta(days=i) for i in range((hasta - desde).days + 1)]
    except (KeyError, ValueError, TypeError):
        raise ApiError("Envíe 'fechas' o 'desde' y 'hasta' (AAAA-MM-DD).", 422, "TIPO_INVALIDO")
    h_desde = _hora(d.get("hora_desde") or "00:00", "hora_desde")
    h_hasta = _hora(d.get("hora_hasta") or "23:59", "hora_hasta")
    quitados = db.ejecutar("""
        UPDATE f SET activa = 0, updated_at = SYSUTCDATETIME()
        FROM dbo.franja_horaria f JOIN OPENJSON(?) WITH (fecha DATE '$') j ON j.fecha = f.fecha
        WHERE f.medico_id = ? AND f.activa = 1 AND f.ocupados = 0 AND f.hora_inicio >= ? AND f.hora_inicio < ?""",
                           json.dumps([x.isoformat() for x in fechas]), medico_id, h_desde.strftime("%H:%M"),
                           h_hasta.strftime("%H:%M"))
    return jsonify(quitados=quitados)


@bp.get("/horario")
@requiere("MEDICO", "ADMIN")
def ver_horario():
    """Turnos del médico (libres y ocupados) desde ?desde por ?dias (máx. 62)."""
    medico_id = perfil("medico_id") if rol_actual() == "MEDICO" else request.args.get("medico_id", type=int)
    if not medico_id:
        raise ApiError("Indique medico_id.", 422, "CAMPO_REQUERIDO")
    desde = _fecha_param("desde", date.today())
    dias = min(max(request.args.get("dias", 14, type=int), 1), DIAS_RESERVAR + 2)
    return jsonify(db.leer(
        "SELECT franja_id, fecha, hora_inicio, hora_fin, capacidad, ocupados FROM {e}.franja_horaria "
        "WHERE medico_id = ? AND activa = ? AND fecha BETWEEN ? AND ? ORDER BY fecha, hora_inicio",
        medico_id, True, desde, desde + timedelta(days=dias)))


@bp.delete("/franjas/<int:franja_id>")
@requiere("MEDICO", "ADMIN")
def quitar_franja(franja_id: int):
    """Quita un turno libre de la agenda (el médico no atenderá a esa hora)."""
    filtro, params = ("", []) if rol_actual() == "ADMIN" else (" AND medico_id = ?", [perfil("medico_id")])
    if not db.ejecutar("UPDATE dbo.franja_horaria SET activa = 0, updated_at = SYSUTCDATETIME() "
                       f"WHERE franja_id = ? AND ocupados = 0{filtro}", franja_id, *params):
        raise ApiError("El turno no existe, no es suyo o ya tiene una cita.", 409, "FRANJA_OCUPADA")
    return jsonify(franja_id=franja_id, activa=False)


# ------------------------------ reprogramar ------------------------------
@bp.post("/<int:cita_id>/reprogramar")
@requiere("PACIENTE", "ADMIN")
def reprogramar(cita_id: int):
    """Mueve la cita a otro horario libre del mismo tipo (y médico), dentro de los próximos DIAS_REPROGRAMAR días.
    Conserva el pago: una cita confirmada sigue confirmada."""
    cita = db.leer_uno("SELECT paciente_id FROM {e}.cita WHERE cita_id = ?", cita_id, contingencia=False)
    if not cita:
        raise no_encontrado("La cita")
    if rol_actual() == "PACIENTE" and cita["paciente_id"] != perfil("paciente_id"):
        raise prohibido("Solo puede reprogramar sus propias citas.")
    franja_id = entero(cuerpo(), "franja_id")
    franja = db.leer_uno("SELECT fecha, laboratorio_id FROM {e}.franja_horaria WHERE franja_id = ?", franja_id,
                         contingencia=False)
    if not franja:
        raise no_encontrado("La franja")
    actual = db.leer_uno("SELECT f.laboratorio_id FROM {e}.cita c JOIN {e}.franja_horaria f ON f.franja_id = c.franja_id "
                         "WHERE c.cita_id = ?", cita_id, contingencia=False)
    if actual["laboratorio_id"] and franja["laboratorio_id"] != actual["laboratorio_id"]:
        raise ApiError("El nuevo horario debe ser en la misma sucursal.", 422, "SUCURSAL_DISTINTA")
    fecha = franja["fecha"] if isinstance(franja["fecha"], date) else date.fromisoformat(str(franja["fecha"]))
    if fecha > date.today() + timedelta(days=DIAS_REPROGRAMAR):
        raise ApiError(f"Solo se puede reprogramar dentro de los próximos {DIAS_REPROGRAMAR} días.", 422, "FUERA_DE_PLAZO")
    db.ejecutar_sp("sp_reprogramar_cita", cita_id=cita_id, franja_id=franja_id, usuario_id=usuario_actual()["usuario_id"])
    c = _con_vencimiento([db.leer_uno(SQL_CITAS + " WHERE c.cita_id = ?", cita_id)])[0]
    persona = db.leer_uno("SELECT persona_id FROM {e}.paciente WHERE paciente_id = ?", c["paciente_id"])
    encolar(persona["persona_id"], "CITA_REPROGRAMADA", f"Cita reprogramada para el {c['fecha']} a las {str(c['hora_inicio'])[:5]}",
            f"Su cita quedó para el {c['fecha']} a las {str(c['hora_inicio'])[:5]}"
            + (f" con Dr(a). {c['medico']}." if c["medico"] else " en el laboratorio."))
    return jsonify(c)
