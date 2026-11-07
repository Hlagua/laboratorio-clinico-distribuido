"""Administración de usuarios, roles, pacientes, reportes y auditoría."""
from datetime import date, timedelta

from flask import Blueprint, Response, jsonify, request

from .. import db
from ..errores import ApiError
from ..pdf import pdf_ingresos
from ..seguridad import ROLES, hash_password, requiere, usuario_actual, validar_password
from ..validacion import cedula, cuerpo, fecha, texto

bp = Blueprint("usuarios", __name__, url_prefix="/api")


@bp.get("/usuarios")
@requiere("ADMIN")
def listar_usuarios():
    return jsonify(db.leer("""
        SELECT u.usuario_id, u.email, u.activo, u.ultimo_login, p.cedula, CONCAT(p.nombres, ' ', p.apellidos) AS nombre,
               STRING_AGG(r.codigo, ',') AS roles
        FROM {e}.usuario u
        JOIN {e}.persona p ON p.persona_id = u.persona_id
        LEFT JOIN {e}.usuario_rol ur ON ur.usuario_id = u.usuario_id
        LEFT JOIN {e}.rol r ON r.rol_id = ur.rol_id
        GROUP BY u.usuario_id, u.email, u.activo, u.ultimo_login, p.cedula, p.nombres, p.apellidos
        ORDER BY u.usuario_id"""))


@bp.post("/usuarios")
@requiere("ADMIN")
def crear_usuario():
    """Crea un usuario con un rol. Si la persona ya existe solo agrega el rol."""
    d = cuerpo()
    rol = texto(d, "rol", maximo=30).upper()
    if rol not in ROLES:
        raise ApiError(f"Rol inválido. Opciones: {', '.join(ROLES)}.", 422, "ROL_INVALIDO")
    password = texto(d, "password", maximo=72)
    validar_password(password)
    usuario_id = db.ejecutar_sp(
        "sp_crear_usuario", "usuario_id", cedula=cedula(texto(d, "cedula", maximo=10)),
        nombres=texto(d, "nombres", maximo=100), apellidos=texto(d, "apellidos", maximo=100),
        fecha_nacimiento=fecha(d, "fecha_nacimiento"), sexo=texto(d, "sexo", maximo=1).upper(),
        telefono=texto(d, "telefono", False, 20), email=texto(d, "email", maximo=150).lower(),
        password_hash=hash_password(password), rol_codigo=rol,
        registro_profesional=texto(d, "registro_profesional", False, 30),
        especialidad_o_area=texto(d, "especialidad_o_area", False, 100), admin_id=usuario_actual()["usuario_id"])
    return jsonify(usuario_id=usuario_id), 201


@bp.post("/usuarios/<int:usuario_id>/roles")
@requiere("ADMIN")
def asignar_rol(usuario_id: int):
    d = cuerpo()
    rol = texto(d, "rol", maximo=30).upper()
    if rol not in ROLES:
        raise ApiError(f"Rol inválido. Opciones: {', '.join(ROLES)}.", 422, "ROL_INVALIDO")
    db.ejecutar_sp("sp_asignar_rol", usuario_id=usuario_id, rol_codigo=rol,
                   registro_profesional=texto(d, "registro_profesional", False, 30),
                   especialidad_o_area=texto(d, "especialidad_o_area", False, 100),
                   admin_id=usuario_actual()["usuario_id"])
    return jsonify(mensaje=f"Rol {rol} asignado.", usuario_id=usuario_id)


@bp.patch("/usuarios/<int:usuario_id>")
@requiere("ADMIN")
def activar_usuario(usuario_id: int):
    activo = cuerpo().get("activo")
    if not isinstance(activo, bool):
        raise ApiError("Envíe 'activo': true | false.", 422, "TIPO_INVALIDO")
    if usuario_id == usuario_actual()["usuario_id"] and not activo:
        raise ApiError("No puede desactivar su propio usuario.", 409, "OPERACION_INVALIDA")
    if not db.ejecutar("UPDATE dbo.usuario SET activo = ?, updated_at = SYSUTCDATETIME() WHERE usuario_id = ?", activo, usuario_id):
        raise ApiError("El usuario no existe.", 404, "NO_ENCONTRADO")
    db.ejecutar_sp("sp_auditar", usuario_id=usuario_actual()["usuario_id"], rol_actuante="ADMIN",
                   accion="ACTIVAR_USUARIO" if activo else "DESACTIVAR_USUARIO", entidad="usuario", entidad_id=str(usuario_id))
    return jsonify(usuario_id=usuario_id, activo=activo)


@bp.get("/pacientes")
@requiere("LABORATORISTA", "MEDICO", "ADMIN")
def buscar_pacientes():
    """Búsqueda por cédula exacta o por parte del apellido (?q=)."""
    sql = ("SELECT pa.paciente_id, p.cedula, p.nombres, p.apellidos, p.fecha_nacimiento, p.sexo, p.telefono, p.email, "
           "pa.tipo_sangre, pa.alergias FROM {e}.paciente pa JOIN {e}.persona p ON p.persona_id = pa.persona_id")
    if request.args.get("cedula"):
        return jsonify(db.leer(sql + " WHERE p.cedula = ?", request.args["cedula"]))
    if request.args.get("q"):
        return jsonify(db.leer(sql + " WHERE UPPER(p.apellidos) LIKE ? ORDER BY p.apellidos",
                               f"%{request.args['q'].upper()}%")[:50])
    return jsonify(db.leer(sql + " ORDER BY p.apellidos")[:100])


# ------------------------------ reportes ------------------------------
@bp.get("/reportes/ingresos")
@requiere("ADMIN")
def reporte_ingresos():
    try:
        hasta = date.fromisoformat(request.args.get("hasta", date.today().isoformat()))
        desde = date.fromisoformat(request.args.get("desde", (hasta - timedelta(days=30)).isoformat()))
    except ValueError:
        raise ApiError("Use fechas AAAA-MM-DD.", 422, "TIPO_INVALIDO")
    filas = db.leer("""
        SELECT CAST(confirmado_at AS DATE) AS dia, metodo, COUNT(*) AS pagos, SUM(monto) AS bruto,
               SUM(monto_reembolsado) AS reembolsado, SUM(monto - monto_reembolsado) AS neto
        FROM {e}.pago
        WHERE estado IN ('APROBADO', 'REEMBOLSO_PARCIAL', 'REEMBOLSADO')
          AND CAST(confirmado_at AS DATE) BETWEEN ? AND ?
        GROUP BY CAST(confirmado_at AS DATE), metodo
        ORDER BY 1, 2""", desde, hasta)
    if request.args.get("formato") == "pdf":
        return Response(pdf_ingresos(filas, desde, hasta), mimetype="application/pdf",
                        headers={"Content-Disposition": f'attachment; filename="ingresos-{desde}-{hasta}.pdf"'})
    return jsonify(desde=desde, hasta=hasta, filas=filas,
                   total_neto=float(sum(f["neto"] for f in filas)) if filas else 0.0)


@bp.get("/reportes/examenes")
@requiere("ADMIN", "MEDICO")
def reporte_examenes():
    return jsonify(db.leer("""
        SELECT t.codigo, t.nombre, COUNT(d.detalle_id) AS solicitados,
               SUM(CASE WHEN d.estado = 'RESULTADO_LISTO' THEN 1 ELSE 0 END) AS con_resultado
        FROM {e}.tipo_examen t LEFT JOIN {e}.solicitud_detalle d ON d.tipo_examen_id = t.tipo_examen_id
        GROUP BY t.codigo, t.nombre ORDER BY solicitados DESC, t.nombre"""))


@bp.get("/auditoria")
@requiere("ADMIN")
def auditoria():
    """Solo en Azure SQL (en contingencia la auditoría se consulta en MongoDB)."""
    limite = min(max(request.args.get("limite", 100, type=int), 1), 500)
    return jsonify(db.leer("""
        SELECT TOP (?) a.auditoria_id, a.created_at, u.email, a.rol_actuante, a.accion, a.entidad, a.entidad_id,
               a.instancia_api, a.ip_origen, a.detalle
        FROM {e}.auditoria a LEFT JOIN {e}.usuario u ON u.usuario_id = a.usuario_id
        ORDER BY a.auditoria_id DESC""", limite, contingencia=False))
