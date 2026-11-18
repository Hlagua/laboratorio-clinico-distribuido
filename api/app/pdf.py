"""Reportes PDF con ReportLab (sin dependencias del sistema)."""
from datetime import datetime, timedelta, timezone
from io import BytesIO
from xml.sax.saxutils import escape as _e

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import cm
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

from . import config

VERDE = colors.HexColor("#0b6e4f")
ROJO = colors.HexColor("#b00020")
_estilos = getSampleStyleSheet()
_titulo = ParagraphStyle("titulo", parent=_estilos["Title"], textColor=VERDE, fontSize=16)
_normal = _estilos["Normal"]
_pequeno = ParagraphStyle("pequeno", parent=_normal, fontSize=8, textColor=colors.grey)


def _hora_ecuador() -> str:
    return (datetime.now(timezone.utc) - timedelta(hours=5)).strftime("%Y-%m-%d %H:%M")


def _documento(elementos: list) -> bytes:
    buffer = BytesIO()
    SimpleDocTemplate(buffer, pagesize=A4, leftMargin=2 * cm, rightMargin=2 * cm, topMargin=1.5 * cm,
                      bottomMargin=1.5 * cm, title="Laboratorio Clínico").build(elementos)
    return buffer.getvalue()


def _tabla(datos: list, anchos: list, estilo_extra: list = ()) -> Table:
    t = Table(datos, colWidths=anchos, repeatRows=1)
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), VERDE), ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("FONTSIZE", (0, 0), (-1, -1), 9), ("GRID", (0, 0), (-1, -1), 0.3, colors.lightgrey),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"), *estilo_extra,
    ]))
    return t


def _num(v) -> str:
    return "" if v is None else f"{float(v):g}"


# Indicador junto a cada valor. Las flechas usan la fuente Symbol (Helvetica no las trae).
_ARRIBA, _ABAJO = '<font name="Symbol">↑</font>', '<font name="Symbol">↓</font>'
INDICADOR = {"ALTO": f"{_ARRIBA} alto", "BAJO": f"{_ABAJO} bajo", "ANORMAL": "fuera de rango", "NORMAL": "– normal"}
_celda = ParagraphStyle("celda", parent=_normal, fontSize=9, leading=11)


def pdf_resultados(s: dict) -> bytes:
    el = [Paragraph("Laboratorio Clínico — Informe de resultados", _titulo),
          Paragraph(f"<b>Paciente:</b> {_e(s['paciente'])} &nbsp; <b>Cédula:</b> {s['cedula']}", _normal),
          Paragraph(f"<b>Solicitud:</b> {_e(s['codigo'])} &nbsp; <b>Estado:</b> {s['estado']}"
                    + (f" &nbsp; <b>Médico:</b> {_e(s['medico'])}" if s.get("medico_id") else ""), _normal),
          Spacer(1, 0.4 * cm)]
    for ex in s["examenes"]:
        if not ex["resultado_id"]:
            el += [Paragraph(f"<b>{_e(ex['examen'])}</b> — pendiente", _normal), Spacer(1, 0.3 * cm)]
            continue
        el.append(Paragraph(f"<b>{_e(ex['examen'])}</b> ({ex['codigo']}) — procesado por {_e(ex['laboratorista'])}", _normal))
        filas = [["Parámetro", "Resultado", "Unidad", "Referencia", "Indicador"]]
        resaltar = []
        for i, v in enumerate(ex["valores"], start=1):
            ref = v["valor_ref_texto"] or (f"{_num(v['valor_ref_min'])} – {_num(v['valor_ref_max'])}"
                                           if v["valor_ref_min"] is not None else "")
            nivel = v.get("nivel") or ("ANORMAL" if v["fuera_rango"] else "NORMAL")
            color = "#b00020" if nivel != "NORMAL" else "#555555"
            filas.append([v["parametro"], v["valor_texto"] or _num(v["valor_numerico"]), v["unidad"] or "", ref,
                          Paragraph(f'<font color="{color}">{INDICADOR[nivel]}</font>', _celda)])
            if v["fuera_rango"]:
                resaltar += [("TEXTCOLOR", (1, i), (1, i), ROJO), ("FONTNAME", (1, i), (1, i), "Helvetica-Bold")]
        el.append(_tabla(filas, [5 * cm, 3 * cm, 2.5 * cm, 3.7 * cm, 2.8 * cm], resaltar))
        if ex.get("observaciones_laboratorio"):
            el.append(Paragraph(f"<i>Laboratorio:</i> {_e(ex['observaciones_laboratorio'])}", _normal))
        for o in ex.get("observaciones_medicas", []):
            el.append(Paragraph(f"<i>Dr(a). {_e(o['medico'])}:</i> {_e(o['texto'])}", _normal))
        el.append(Spacer(1, 0.4 * cm))
    el += [Paragraph(f"Indicador: {_ARRIBA} alto, {_ABAJO} bajo, – normal (según el rango de referencia). "
                     "Los valores en rojo están fuera del rango. Datos ficticios con fines académicos.", _pequeno),
           Paragraph(f"Generado: {_hora_ecuador()} (hora de Ecuador)", _pequeno)]
    return _documento(el)


def pdf_ingresos(filas: list, desde, hasta) -> bytes:
    datos = [["Día", "Método", "Pagos", "Bruto", "Reembolsado", "Neto"]]
    for f in filas:
        datos.append([str(f["dia"]), f["metodo"], f["pagos"], f"{float(f['bruto']):.2f}",
                      f"{float(f['reembolsado']):.2f}", f"{float(f['neto']):.2f}"])
    total = sum(float(f["neto"]) for f in filas)
    datos.append(["", "TOTAL", sum(f["pagos"] for f in filas), "", "", f"{total:.2f}"])
    el = [Paragraph("Laboratorio Clínico — Reporte de ingresos", _titulo),
          Paragraph(f"Período: {desde} a {hasta}", _normal), Spacer(1, 0.4 * cm),
          _tabla(datos, [3 * cm, 4 * cm, 1.8 * cm, 2.6 * cm, 2.8 * cm, 2.6 * cm],
                 [("FONTNAME", (0, -1), (-1, -1), "Helvetica-Bold"), ("ALIGN", (2, 1), (-1, -1), "RIGHT")]),
          Spacer(1, 0.3 * cm), Paragraph(f"Generado: {_hora_ecuador()} (hora de Ecuador)", _pequeno)]
    return _documento(el)


def pdf_factura(f: dict) -> bytes:
    """Representación impresa (RIDE) de la factura generada en factura.py."""
    s, pago = f["solicitud"], f["pago"]
    metodo = "Tarjeta (Stripe)" if pago["metodo"] == "STRIPE" else f"Transferencia {pago['referencia_transferencia'] or ''}"
    el = [Paragraph("Laboratorio Clínico — Factura", _titulo),
          Paragraph(f"<b>{_e(config.FACTURA_RAZON_SOCIAL)}</b> &nbsp; RUC {config.FACTURA_RUC}", _normal),
          Paragraph(_e(config.FACTURA_DIRECCION), _normal), Spacer(1, 0.3 * cm),
          Paragraph(f"<b>Factura N.º</b> {f['numero']} &nbsp; <b>Fecha:</b> {f['fecha']:%d/%m/%Y %H:%M} &nbsp; "
                    f"<b>Ambiente:</b> pruebas", _normal),
          Paragraph(f"<b>Clave de acceso:</b> <font size=8>{f['clave_acceso']}</font>", _normal), Spacer(1, 0.3 * cm),
          Paragraph(f"<b>Cliente:</b> {_e(s['apellidos'])} {_e(s['nombres'])} &nbsp; <b>C.I./RUC:</b> {s['cedula']}", _normal),
          Paragraph(f"<b>Correo:</b> {_e(s['email'] or '')} &nbsp; <b>Dirección:</b> {_e(s['direccion'] or 'S/N')}", _normal),
          Paragraph(f"<b>Solicitud:</b> {s['codigo']} &nbsp; <b>Forma de pago:</b> {_e(metodo)}", _normal),
          Spacer(1, 0.4 * cm)]
    datos = [["Código", "Descripción", "Cant.", "Precio unit.", "Subtotal"]]
    for ln in f["lineas"]:
        datos.append([ln["codigo"], Paragraph(_e(ln["nombre"]), _celda), "1", f"{ln['base']:.2f}", f"{ln['base']:.2f}"])
    n = len(datos)
    datos += [["", "", "", "Subtotal sin IVA", f"{f['subtotal']:.2f}"],
              ["", "", "", f"IVA {f['iva_porcentaje']} %", f"{f['iva']:.2f}"],
              ["", "", "", "TOTAL USD", f"{f['total']:.2f}"]]
    el.append(_tabla(datos, [2.5 * cm, 7 * cm, 1.5 * cm, 3 * cm, 3 * cm], [
        ("ALIGN", (2, 1), (-1, -1), "RIGHT"), ("GRID", (0, n), (2, -1), 0, colors.white),
        ("FONTNAME", (3, -1), (-1, -1), "Helvetica-Bold"), ("LINEABOVE", (3, n), (-1, n), 0.8, colors.black)]))
    el += [Spacer(1, 0.4 * cm),
           Paragraph("Comprobante de prueba generado con fines académicos: sigue la estructura de la factura electrónica "
                     "del SRI (XML adjunto) pero no está firmado ni autorizado, por lo que no tiene validez tributaria.", _pequeno),
           Paragraph(f"Generado: {_hora_ecuador()} (hora de Ecuador)", _pequeno)]
    return _documento(el)


def _edad_texto(nacimiento) -> str:
    if not nacimiento:
        return ""
    hoy = datetime.now(timezone.utc).date()
    n = nacimiento if not isinstance(nacimiento, str) else datetime.fromisoformat(nacimiento[:10]).date()
    return f"{hoy.year - n.year - ((hoy.month, hoy.day) < (n.month, n.day))} años"


def pdf_receta(r: dict) -> bytes:
    """Receta en el formato habitual: medicamentos a la izquierda (Rp.) e indicaciones a la derecha."""
    from reportlab.lib.pagesizes import landscape

    sub = ParagraphStyle("sub", parent=_normal, fontSize=11, textColor=VERDE, fontName="Helvetica-Bold", spaceAfter=4)
    fecha = (r["updated_at"] - timedelta(hours=5)).strftime("%d/%m/%Y")
    cabecera = [
        Paragraph("Laboratorio Clínico — Receta médica", _titulo),
        Paragraph(f"<b>Dr(a).</b> {_e(r['medico'])} · {_e(r['especialidad'] or '')} · Reg. {_e(r['registro_profesional'] or '')}"
                  f" &nbsp; <b>Fecha:</b> {fecha} &nbsp; <b>Solicitud:</b> {r['solicitud_codigo']}", _normal),
        Paragraph(f"<b>Paciente:</b> {_e(r['paciente'])} &nbsp; <b>Cédula:</b> {r['cedula']} &nbsp; "
                  f"<b>Edad:</b> {_edad_texto(r['fecha_nacimiento'])}", _normal),
    ]
    if r.get("diagnostico"):
        cabecera.append(Paragraph(f"<b>Diagnóstico:</b> {_e(r['diagnostico'])}", _normal))
    cabecera.append(Spacer(1, 0.3 * cm))

    izquierda = [Paragraph("Rp.", sub)]
    derecha = [Paragraph("Indicaciones", sub)]
    for n, i in enumerate(r["items"], start=1):
        como = " ".join(x for x in (i["dosis"], i["frecuencia"],
                                    f"por {i['duracion_dias']} días" if i["duracion_dias"] else "") if x)
        detalle = ". ".join(_e(x) for x in (como, i.get("indicaciones")) if x)
        izquierda.append(Paragraph(
            f"<b>{n}. {_e(i['nombre'])}</b> {_e(i['presentacion'] or '')}"
            + (f"<br/>Cantidad: {_e(i['cantidad'])}" if i.get("cantidad") else "")
            + (f"<br/><font color='#555555'>Vía {_e(i['via'].lower())}</font>" if i.get("via") else ""), _celda))
        izquierda.append(Spacer(1, 0.25 * cm))
        derecha.append(Paragraph(f"<b>{n}. {_e(i['nombre'])}:</b> {(detalle or 'según indicación médica').rstrip('.')}.", _celda))
        derecha.append(Spacer(1, 0.25 * cm))
    if r.get("indicaciones_generales"):
        derecha += [Spacer(1, 0.2 * cm), Paragraph("Además:", sub)]
        derecha += [Paragraph(_e(linea), _celda) for linea in r["indicaciones_generales"].splitlines() if linea.strip()]

    cuerpo = Table([[izquierda, derecha]], colWidths=[11.5 * cm, 13.5 * cm])
    cuerpo.setStyle(TableStyle([("VALIGN", (0, 0), (-1, -1), "TOP"), ("LINEAFTER", (0, 0), (0, 0), 0.6, colors.grey),
                                ("BOX", (0, 0), (-1, -1), 0.6, colors.grey), ("LEFTPADDING", (0, 0), (-1, -1), 10),
                                ("RIGHTPADDING", (0, 0), (-1, -1), 10), ("TOPPADDING", (0, 0), (-1, -1), 8)]))
    firma = Table([["", "______________________________"], ["", f"Dr(a). {r['medico']}"]], colWidths=[13 * cm, 12 * cm])
    firma.setStyle(TableStyle([("ALIGN", (1, 0), (1, -1), "CENTER"), ("FONTSIZE", (0, 0), (-1, -1), 9)]))
    el = cabecera + [cuerpo, Spacer(1, 1.2 * cm), firma, Spacer(1, 0.3 * cm),
                     Paragraph("Receta emitida con fines académicos. La base de conocimientos solo sugiere; "
                               "el tratamiento lo decide el médico.", _pequeno)]
    buffer = BytesIO()
    SimpleDocTemplate(buffer, pagesize=landscape(A4), leftMargin=1.5 * cm, rightMargin=1.5 * cm, topMargin=1.2 * cm,
                      bottomMargin=1.2 * cm, title="Receta médica").build(el)
    return buffer.getvalue()
