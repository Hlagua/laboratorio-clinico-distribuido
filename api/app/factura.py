"""Factura de una solicitud pagada: desglose del IVA, XML y datos para el PDF.

Los precios del catálogo ya incluyen el IVA (config.IVA_PORCENTAJE). Para la
factura se separa la base imponible de cada examen y el IVA se calcula como
la diferencia con el total cobrado, así la suma siempre cuadra al centavo.

El XML sigue la estructura de la factura electrónica del SRI (versión 1.1.0,
ambiente de PRUEBAS): clave de acceso de 49 dígitos con dígito verificador
módulo 11. No se firma ni se envía al SRI, por eso no tiene validez tributaria.
"""
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from decimal import ROUND_HALF_UP, Decimal

from . import config, db
from .errores import ApiError, no_encontrado

CENTAVO = Decimal("0.01")
# Código del SRI para la tarifa de IVA (tabla 17): 4 = 15 %, 0 = 0 %.
_CODIGO_PORCENTAJE = {15: "4", 0: "0", 12: "2", 14: "3", 5: "5"}
# Forma de pago del SRI (tabla 24): 19 = tarjeta de crédito, 20 = otros con sistema financiero.
_FORMA_PAGO = {"STRIPE": "19", "TRANSFERENCIA_QR": "20"}


def _d(v) -> Decimal:
    return Decimal(str(v)).quantize(CENTAVO, ROUND_HALF_UP)


def base_sin_iva(precio) -> Decimal:
    return (Decimal(str(precio)) / (1 + Decimal(config.IVA_PORCENTAJE) / 100)).quantize(CENTAVO, ROUND_HALF_UP)


def desglose(precios: list) -> dict:
    """Subtotal sin IVA, IVA y total de una lista de precios con IVA incluido."""
    total = sum((_d(p) for p in precios), Decimal("0.00"))
    subtotal = sum((base_sin_iva(p) for p in precios), Decimal("0.00"))
    return {"subtotal": subtotal, "iva": total - subtotal, "iva_porcentaje": config.IVA_PORCENTAJE, "total": total}


def datos(solicitud_id: int) -> dict:
    """Cabecera, comprador, pago aprobado y líneas de la factura."""
    s = db.leer_uno("""
        SELECT s.solicitud_id, s.codigo, s.total, s.paciente_id, p.cedula, p.nombres, p.apellidos, p.email,
               p.direccion, p.telefono
        FROM {e}.solicitud_examen s
        JOIN {e}.paciente pa ON pa.paciente_id = s.paciente_id
        JOIN {e}.persona p ON p.persona_id = pa.persona_id
        WHERE s.solicitud_id = ?""", solicitud_id)
    if not s:
        raise no_encontrado("La solicitud")
    pago = db.leer_uno("""
        SELECT pago_id, monto, metodo, estado, confirmado_at, referencia_transferencia,
               factura_identificacion, factura_nombre, factura_direccion, factura_email
        FROM {e}.pago WHERE solicitud_id = ? AND estado IN ('APROBADO', 'REEMBOLSO_PARCIAL', 'REEMBOLSADO')
        ORDER BY pago_id DESC OFFSET 0 ROWS FETCH NEXT 1 ROWS ONLY""", solicitud_id)
    if not pago:
        raise ApiError("La solicitud aún no tiene un pago aprobado: no hay factura.", 409, "SIN_FACTURA")
    lineas = db.leer("""
        SELECT t.codigo, t.nombre, d.precio_unitario
        FROM {e}.solicitud_detalle d JOIN {e}.tipo_examen t ON t.tipo_examen_id = d.tipo_examen_id
        WHERE d.solicitud_id = ? AND d.estado <> 'ANULADO' ORDER BY d.detalle_id""", solicitud_id)
    # Cobro en ventanilla: la factura sale a nombre de quien dio sus datos (o consumidor final).
    if pago["factura_identificacion"]:
        s = {**s, "cedula": pago["factura_identificacion"], "nombres": "", "apellidos": pago["factura_nombre"] or "",
             "direccion": pago["factura_direccion"], "email": pago["factura_email"] or s["email"]}
    for ln in lineas:
        ln["precio_con_iva"] = _d(ln["precio_unitario"])
        ln["base"] = base_sin_iva(ln["precio_unitario"])
    fecha = (pago["confirmado_at"] or datetime.now(timezone.utc).replace(tzinfo=None)) - timedelta(hours=5)  # Ecuador
    secuencial = f"{pago['pago_id']:09d}"
    return {
        "solicitud": s, "pago": pago, "lineas": lineas, "fecha": fecha,
        "numero": f"001-001-{secuencial}", "secuencial": secuencial,
        "clave_acceso": clave_acceso(fecha, secuencial, pago["pago_id"]),
        **desglose([ln["precio_unitario"] for ln in lineas]),
    }


def modulo11(cadena: str) -> str:
    """Dígito verificador del SRI: pesos 2..7 de derecha a izquierda."""
    suma = sum(int(c) * (2 + i % 6) for i, c in enumerate(reversed(cadena)))
    digito = 11 - suma % 11
    return "0" if digito == 11 else "1" if digito == 10 else str(digito)


def clave_acceso(fecha, secuencial: str, pago_id: int) -> str:
    codigo_numerico = f"{(pago_id * 7919) % 10**8:08d}"
    base = (f"{fecha:%d%m%Y}" "01" f"{config.FACTURA_RUC}" "1" "001001" f"{secuencial}" f"{codigo_numerico}" "1")
    return base + modulo11(base)


def _sub(padre, etiqueta: str, valor=None) -> ET.Element:
    e = ET.SubElement(padre, etiqueta)
    if valor is not None:
        e.text = str(valor)
    return e


def xml(f: dict) -> bytes:
    s, pago = f["solicitud"], f["pago"]
    codigo_iva = _CODIGO_PORCENTAJE.get(config.IVA_PORCENTAJE, "4")
    raiz = ET.Element("factura", id="comprobante", version="1.1.0")

    it = _sub(raiz, "infoTributaria")
    for k, v in (("ambiente", "1"), ("tipoEmision", "1"), ("razonSocial", config.FACTURA_RAZON_SOCIAL),
                 ("nombreComercial", "Laboratorio Clínico"), ("ruc", config.FACTURA_RUC),
                 ("claveAcceso", f["clave_acceso"]), ("codDoc", "01"), ("estab", "001"), ("ptoEmi", "001"),
                 ("secuencial", f["secuencial"]), ("dirMatriz", config.FACTURA_DIRECCION)):
        _sub(it, k, v)

    inf = _sub(raiz, "infoFactura")
    _sub(inf, "fechaEmision", f"{f['fecha']:%d/%m/%Y}")
    _sub(inf, "dirEstablecimiento", config.FACTURA_DIRECCION)
    _sub(inf, "obligadoContabilidad", "SI")
    # Tabla 6 del SRI: 04 RUC, 05 cédula, 07 consumidor final.
    tipo_id = "07" if s["cedula"] == "9999999999999" else "05" if len(s["cedula"]) == 10 else "04"
    _sub(inf, "tipoIdentificacionComprador", tipo_id)
    _sub(inf, "razonSocialComprador", f"{s['apellidos']} {s['nombres']}".strip())
    _sub(inf, "identificacionComprador", s["cedula"])
    _sub(inf, "direccionComprador", s["direccion"] or "S/N")
    _sub(inf, "totalSinImpuestos", f["subtotal"])
    _sub(inf, "totalDescuento", "0.00")
    ti = _sub(_sub(inf, "totalConImpuestos"), "totalImpuesto")
    for k, v in (("codigo", "2"), ("codigoPorcentaje", codigo_iva), ("baseImponible", f["subtotal"]), ("valor", f["iva"])):
        _sub(ti, k, v)
    _sub(inf, "propina", "0.00")
    _sub(inf, "importeTotal", f["total"])
    _sub(inf, "moneda", "DOLAR")
    p = _sub(_sub(inf, "pagos"), "pago")
    _sub(p, "formaPago", _FORMA_PAGO.get(pago["metodo"], "20"))
    _sub(p, "total", f["total"])

    dets = _sub(raiz, "detalles")
    for ln in f["lineas"]:
        d = _sub(dets, "detalle")
        for k, v in (("codigoPrincipal", ln["codigo"]), ("descripcion", ln["nombre"]), ("cantidad", "1.00"),
                     ("precioUnitario", ln["base"]), ("descuento", "0.00"), ("precioTotalSinImpuesto", ln["base"])):
            _sub(d, k, v)
        imp = _sub(_sub(d, "impuestos"), "impuesto")
        for k, v in (("codigo", "2"), ("codigoPorcentaje", codigo_iva), ("tarifa", f"{config.IVA_PORCENTAJE}.00"),
                     ("baseImponible", ln["base"]), ("valor", ln["precio_con_iva"] - ln["base"])):
            _sub(imp, k, v)

    ad = _sub(raiz, "infoAdicional")
    for nombre, valor in (("Solicitud", s["codigo"]), ("Email", s["email"] or ""),
                          ("Nota", "Comprobante de prueba generado con fines académicos, sin validez tributaria")):
        _sub(ad, "campoAdicional", valor).set("nombre", nombre)

    ET.indent(raiz)
    return ET.tostring(raiz, encoding="UTF-8", xml_declaration=True)
