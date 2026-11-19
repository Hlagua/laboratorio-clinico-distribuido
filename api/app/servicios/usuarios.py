"""Administración de usuarios, roles, pacientes, reportes y auditoría."""
from datetime import date, timedelta

from flask import Blueprint, Response, jsonify, request

from .. import db
from ..paginacion import donde, listar, rango_fechas
from ..errores import ApiError
from ..pdf import pdf_ingresos
from ..seguridad import ROLES, hash_password, requiere, usuario_actual, validar_password
from ..validacion import cedula, correo, cuerpo, fecha, nacimiento, nombre, telefono, texto

bp = Blueprint("usuarios", __name__, url_prefix="/api")


@bp.get("/usuarios")
@requiere("ADMIN")
def listar_usuarios():
    """Filtros: ?q (nombre, apellido, correo o cédula), ?rol, ?activo=1|0; paginado con ?pagina."""
    condiciones, params = [], []
    if request.args.get("q"):
        condiciones.append("(UPPER(p.nombres) LIKE ? OR UPPER(p.apellidos) LIKE ? OR UPPER(u.email) LIKE ? OR p.cedula LIKE ?)")
        patron = f"%{request.args['q'].strip().upper()}%"
        params += [patron, patron, patron, patron]
    if request.args.get("rol"):
        condiciones.append("EXISTS (SELECT 1 FROM {e}.usuario_rol x JOIN {e}.rol y ON y.rol_id = x.rol_id "
                           "WHERE x.usuario_id = u.usuario_id AND y.codigo = ?)")
        params.append(request.args["rol"].upper())
    if request.args.get("activo") in ("0", "1"):
        condiciones.append("u.activo = ?")
        params.append(request.args["activo"] == "1")
    return listar("""
        SELECT u.usuario_id, u.email, u.activo, u.ultimo_login, p.cedula, CONCAT(p.nombres, ' ', p.apellidos) AS nombre,
               STRING_AGG(r.codigo, ',') AS roles
        FROM {e}.usuario u
        JOIN {e}.persona p ON p.persona_id = u.persona_id
        LEFT JOIN {e}.usuario_rol ur ON ur.usuario_id = u.usuario_id
        LEFT JOIN {e}.rol r ON r.rol_id = ur.rol_id""" + donde(condiciones) + """
        GROUP BY u.usuario_id, u.email, u.activo, u.ultimo_login, p.cedula, p.nombres, p.apellidos""",
        params, "ORDER BY u.usuario_id", maximo=1000)


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
        nombres=nombre(d, "nombres"), apellidos=nombre(d, "apellidos"),
        fecha_nacimiento=nacimiento(d), sexo=texto(d, "sexo", maximo=1).upper(),
        telefono=telefono(d), email=correo(d),
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
    sql = ("SELECT pa.paciente_id, p.cedula, p.nombres, p.apellidos, p.fecha_nacimiento, p.sexo, p.telefono, p.email, p.direccion, "
           "pa.tipo_sangre, pa.alergias FROM {e}.paciente pa JOIN {e}.persona p ON p.persona_id = pa.persona_id")
    if request.args.get("cedula"):
        return jsonify(db.leer(sql + " WHERE p.cedula = ?", request.args["cedula"]))
    if request.args.get("q"):
        patron = f"%{request.args['q'].strip().upper()}%"
        return listar(sql + " WHERE UPPER(p.apellidos) LIKE ? OR UPPER(p.nombres) LIKE ?", [patron, patron],
                      "ORDER BY p.apellidos, p.nombres", maximo=50)
    return listar(sql, [], "ORDER BY p.apellidos, p.nombres", maximo=100)


@bp.post("/pacientes")
@requiere("LABORATORISTA", "MEDICO", "ADMIN")
def registrar_paciente_ventanilla():
    """Paciente atendido en ventanilla: queda registrado sin cuenta (puede crearla después en el portal)."""
    d = cuerpo()
    email = correo(d, requerido=False)
    sexo = texto(d, "sexo", maximo=1).upper()
    if sexo not in ("M", "F", "O"):
        raise ApiError("Sexo: M, F u O.", 422, "TIPO_INVALIDO")
    paciente_id = db.ejecutar_sp(
        "sp_registrar_paciente", "paciente_id", cedula=cedula(texto(d, "cedula", maximo=10)),
        nombres=nombre(d, "nombres"), apellidos=nombre(d, "apellidos"),
        fecha_nacimiento=nacimiento(d), sexo=sexo, telefono=telefono(d),
        email=email, direccion=texto(d, "direccion", False, 250), password_hash=None)
    return jsonify(db.leer_uno(
        "SELECT pa.paciente_id, p.cedula, p.nombres, p.apellidos, p.fecha_nacimiento, p.sexo, p.telefono, p.email, "
        "p.direccion, pa.tipo_sangre, pa.alergias FROM {e}.paciente pa JOIN {e}.persona p ON p.persona_id = pa.persona_id "
        "WHERE pa.paciente_id = ?", paciente_id)), 201


@bp.post("/usuarios/<int:usuario_id>/clave")
@requiere("ADMIN")
def restablecer_clave(usuario_id: int):
    """El administrador asigna una clave temporal (el usuario la cambia después) y desbloquea la cuenta."""
    password = texto(cuerpo(), "password", maximo=72)
    validar_password(password)
    if not db.ejecutar("UPDATE dbo.usuario SET password_hash = ?, intentos_fallidos = 0, bloqueado_hasta = NULL, "
                       "updated_at = SYSUTCDATETIME() WHERE usuario_id = ?", hash_password(password), usuario_id):
        raise ApiError("El usuario no existe.", 404, "NO_ENCONTRADO")
    db.ejecutar_sp("sp_auditar", usuario_id=usuario_actual()["usuario_id"], rol_actuante="ADMIN",
                   accion="RESTABLECER_CLAVE", entidad="usuario", entidad_id=str(usuario_id))
    return jsonify(usuario_id=usuario_id, mensaje="Clave restablecida.")


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
    """Solo en Azure SQL (en contingencia la auditoría se consulta en MongoDB).
    Filtros: ?desde, ?hasta (AAAA-MM-DD), ?accion, ?usuario (parte del correo); paginado con ?pagina."""
    condiciones, params = [], []
    rango_fechas("a.created_at", condiciones, params)
    if request.args.get("accion"):
        condiciones.append("a.accion = ?")
        params.append(request.args["accion"].upper())
    if request.args.get("usuario"):
        if request.args["usuario"].strip().lower() == "sistema":
            condiciones.append("a.usuario_id IS NULL")
        else:
            condiciones.append("LOWER(u.email) LIKE ?")
            params.append(f"%{request.args['usuario'].strip().lower()}%")
    limite = min(max(request.args.get("limite", 100, type=int), 1), 500)
    return listar("""
        SELECT a.auditoria_id, a.created_at, u.email, a.rol_actuante, a.accion, a.entidad, a.entidad_id,
               a.instancia_api, a.ip_origen, a.detalle
        FROM {e}.auditoria a LEFT JOIN {e}.usuario u ON u.usuario_id = a.usuario_id""" + donde(condiciones),
        params, "ORDER BY a.auditoria_id DESC", maximo=limite, contingencia=False)


@bp.get("/auditoria/acciones")
@requiere("ADMIN")
def acciones_auditoria():
    """Acciones registradas, para el filtro de la pantalla de auditoría."""
    return jsonify([f["accion"] for f in db.leer(
        "SELECT DISTINCT accion FROM {e}.auditoria ORDER BY accion", contingencia=False)])
