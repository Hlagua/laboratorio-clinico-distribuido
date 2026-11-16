"""Servicio de citas: franjas disponibles, reservas, cancelaciones y agenda."""
from datetime import date, timedelta

from flask import Blueprint, g, jsonify, request

from .. import config, db
from ..errores import ApiError, no_encontrado, prohibido
from ..seguridad import perfil, requiere, rol_actual, usuario_actual
from ..validacion import cuerpo, entero, texto
from .notificaciones import encolar

bp = Blueprint("citas", __name__, url_prefix="/api/citas")

# La cita es el turno para la toma de muestras en el laboratorio. Se confirma
# cuando se paga la solicitud de exámenes vinculada a ella (sp_confirmar_pago);
# si no se paga en MINUTOS_PARA_PAGAR, el sincronizador la cancela y libera el cupo.
MINUTOS_PARA_PAGAR = 30

SQL_CITAS = """
SELECT c.cita_id, c.estado, c.motivo, c.canal, c.created_at, f.franja_id, f.fecha, f.hora_inicio, f.hora_fin,
       pa.paciente_id, CONCAT(p.nombres, ' ', p.apellidos) AS paciente, p.cedula,
       s.solicitud_id, s.codigo AS solicitud_codigo, s.estado AS solicitud_estado, s.total AS solicitud_total,
       (SELECT STRING_AGG(t.nombre, ', ') FROM {e}.solicitud_detalle sd
        JOIN {e}.tipo_examen t ON t.tipo_examen_id = sd.tipo_examen_id WHERE sd.solicitud_id = s.solicitud_id) AS examenes_resumen
FROM {e}.cita c
JOIN {e}.franja_horaria f ON f.franja_id = c.franja_id
JOIN {e}.paciente pa ON pa.paciente_id = c.paciente_id
JOIN {e}.persona p ON p.persona_id = pa.persona_id
LEFT JOIN (SELECT cita_id, MAX(solicitud_id) AS solicitud_id FROM {e}.solicitud_examen
           WHERE cita_id IS NOT NULL AND estado <> 'ANULADA' GROUP BY cita_id) sx ON sx.cita_id = c.cita_id
LEFT JOIN {e}.solicitud_examen s ON s.solicitud_id = sx.solicitud_id
"""


def _con_vencimiento(citas: list[dict]) -> list[dict]:
    """Agrega 'vence_at' (UTC) a las citas pendientes de pago."""
    for c in citas:
        c["vence_at"] = (c["created_at"] + timedelta(minutes=MINUTOS_PARA_PAGAR)
                         if c["estado"] == "PENDIENTE_PAGO" and c.get("created_at") else None)
    return citas


def _fecha_param(nombre: str, defecto: date) -> date:
    valor = request.args.get(nombre)
    if not valor:
        return defecto
    try:
        return date.fromisoformat(valor)
    except ValueError:
        raise ApiError(f"El parámetro '{nombre}' debe tener formato AAAA-MM-DD.", 422, "TIPO_INVALIDO")


@bp.get("/franjas")
def franjas():
    """Público: franjas con cupo entre ?desde y ?desde + ?dias (máx. 31)."""
    desde = _fecha_param("desde", date.today())
    dias = min(max(request.args.get("dias", 7, type=int), 1), 31)
    filas = db.leer(
        "SELECT franja_id, fecha, hora_inicio, hora_fin, capacidad, ocupados, capacidad - ocupados AS cupos_libres "
        "FROM {e}.franja_horaria WHERE activa = ? AND ocupados < capacidad AND fecha BETWEEN ? AND ? "
        "ORDER BY fecha, hora_inicio", True, desde, desde + timedelta(days=dias))
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

    cita_id = db.ejecutar_sp(
        "sp_reservar_cita", "cita_id", paciente_id=paciente_id, franja_id=entero(d, "franja_id"),
        motivo=texto(d, "motivo", False, 300), canal="PORTAL", usuario_id=usuario_actual()["usuario_id"],
        instancia_api=config.INSTANCIA, protegido=proteccion, espera_ms=espera_ms)

    cita = _con_vencimiento([db.leer_uno(SQL_CITAS + " WHERE c.cita_id = ?", cita_id)])[0]
    encolar(usuario_actual()["persona_id"], "CITA_RESERVADA",
            f"Cita reservada para el {cita['fecha']} a las {str(cita['hora_inicio'])[:5]}",
            f"Su cita fue reservada para el {cita['fecha']} a las {str(cita['hora_inicio'])[:5]}. "
            f"Para confirmarla, elija sus exámenes y páguelos en los próximos {MINUTOS_PARA_PAGAR} minutos "
            "desde 'Mis citas' en el portal; si no, la cita se cancela y el cupo se libera.")
    return jsonify(cita), 201


@bp.get("/mias")
@requiere("PACIENTE")
def mias():
    return jsonify(_con_vencimiento(db.leer(SQL_CITAS + " WHERE c.paciente_id = ? ORDER BY f.fecha DESC, f.hora_inicio DESC",
                                            perfil("paciente_id"))))


@bp.delete("/<int:cita_id>")
@requiere("PACIENTE", "ADMIN")
def cancelar(cita_id: int):
    cita = db.leer_uno("SELECT paciente_id FROM {e}.cita WHERE cita_id = ?", cita_id, contingencia=False)
    if not cita:
        raise no_encontrado("La cita")
    if rol_actual() == "PACIENTE" and cita["paciente_id"] != perfil("paciente_id"):
        raise prohibido("Solo puede cancelar sus propias citas.")
    db.ejecutar_sp("sp_cancelar_cita", cita_id=cita_id, usuario_id=usuario_actual()["usuario_id"])
    return jsonify(mensaje="Cita cancelada.", cita_id=cita_id)


@bp.get("/agenda")
@requiere("LABORATORISTA", "ADMIN")
def agenda():
    """Turnos de toma de muestras del día (no son consultas médicas)."""
    dia = _fecha_param("fecha", date.today())
    return jsonify(db.leer(SQL_CITAS + " WHERE f.fecha = ? AND c.estado <> 'CANCELADA' ORDER BY f.hora_inicio, c.cita_id", dia))


@bp.post("/franjas")
@requiere("ADMIN")
def crear_franjas():
    """Genera franjas para un rango de fechas (lunes a sábado)."""
    d = cuerpo()
    try:
        desde, hasta = date.fromisoformat(d["desde"]), date.fromisoformat(d["hasta"])
        h_ini, h_fin = d.get("hora_inicio", "07:00"), d.get("hora_fin", "11:00")
    except (KeyError, ValueError, TypeError):
        raise ApiError("Envíe 'desde' y 'hasta' (AAAA-MM-DD).", 422, "TIPO_INVALIDO")
    if hasta < desde or (hasta - desde).days > 62:
        raise ApiError("El rango debe ser válido y de máximo 62 días.", 422, "RANGO_INVALIDO")
    intervalo = entero(d, "intervalo_minutos", False) or 30
    capacidad = entero(d, "capacidad", False) or 3
    creadas = db.ejecutar("""
        ;WITH d10 AS (SELECT i FROM (VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9)) v(i)),
         n AS (SELECT a.i + b.i * 10 + c.i * 100 AS i FROM d10 a CROSS JOIN d10 b CROSS JOIN d10 c),
         dias AS (SELECT DATEADD(DAY, i, CAST(? AS DATE)) AS fecha FROM n WHERE i <= DATEDIFF(DAY, ?, ?)),
         horas AS (SELECT DATEADD(MINUTE, i * ?, CAST(? AS TIME(0))) AS hora FROM n
                   WHERE (i + 1) * ? <= DATEDIFF(MINUTE, CAST(? AS TIME(0)), CAST(? AS TIME(0))))
        INSERT INTO dbo.franja_horaria (fecha, hora_inicio, hora_fin, capacidad)
        SELECT d.fecha, h.hora, DATEADD(MINUTE, ?, h.hora), ?
        FROM dias d CROSS JOIN horas h
        WHERE DATEDIFF(DAY, '19000101', d.fecha) % 7 <> 6
          AND NOT EXISTS (SELECT 1 FROM dbo.franja_horaria f WHERE f.fecha = d.fecha AND f.hora_inicio = h.hora)
    """, desde, desde, hasta, intervalo, h_ini, intervalo, h_ini, h_fin, intervalo, capacidad)
    return jsonify(franjas_creadas=creadas), 201
