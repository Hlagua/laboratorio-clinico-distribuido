"""Reportes PDF con ReportLab (sin dependencias del sistema)."""
from datetime import datetime, timedelta, timezone
from io import BytesIO
from xml.sax.saxutils import escape as _e

from reportlab.lib import colors
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import cm
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

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
        filas = [["Parámetro", "Resultado", "Unidad", "Referencia"]]
        resaltar = []
        for i, v in enumerate(ex["valores"], start=1):
            ref = v["valor_ref_texto"] or (f"{_num(v['valor_ref_min'])} – {_num(v['valor_ref_max'])}"
                                           if v["valor_ref_min"] is not None else "")
            filas.append([v["parametro"], v["valor_texto"] or _num(v["valor_numerico"]), v["unidad"] or "", ref])
            if v["fuera_rango"]:
                resaltar += [("TEXTCOLOR", (1, i), (1, i), ROJO), ("FONTNAME", (1, i), (1, i), "Helvetica-Bold")]
        el.append(_tabla(filas, [6 * cm, 3.5 * cm, 3 * cm, 4.5 * cm], resaltar))
        if ex.get("observaciones_laboratorio"):
            el.append(Paragraph(f"<i>Laboratorio:</i> {_e(ex['observaciones_laboratorio'])}", _normal))
        for o in ex.get("observaciones_medicas", []):
            el.append(Paragraph(f"<i>Dr(a). {_e(o['medico'])}:</i> {_e(o['texto'])}", _normal))
        el.append(Spacer(1, 0.4 * cm))
    el += [Paragraph("Los valores en rojo están fuera del rango de referencia. Datos ficticios con fines académicos.", _pequeno),
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
