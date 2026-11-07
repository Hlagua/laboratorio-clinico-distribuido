"""Servicio SOAP 1.1 (document/literal) para interoperabilidad con sistemas externos.

  GET  /soap?wsdl  -> contrato WSDL
  POST /soap       -> operaciones: ConsultarResultados, ConsultarEstadoSolicitud, ListarExamenes

Autenticación: cabecera SOAP <lab:Credencial><lab:ApiKey>...</lab:ApiKey></lab:Credencial>
(o cabecera HTTP X-API-Key). El XML se analiza con defusedxml (protección XXE).
Funciona también en modo contingencia porque solo consulta.
"""
import hmac
import xml.etree.ElementTree as ET

from defusedxml import ElementTree as DefusedET
from defusedxml.common import DefusedXmlException
from flask import Blueprint, Response, request

from .. import config, db
from ..errores import ApiError

bp = Blueprint("soap", __name__)

NS = "urn:labclinico:resultados"
NS_SOAP = "http://schemas.xmlsoap.org/soap/envelope/"
ET.register_namespace("soap", NS_SOAP)
ET.register_namespace("lab", NS)

WSDL = """<?xml version="1.0" encoding="UTF-8"?>
<definitions name="LaboratorioResultados" targetNamespace="urn:labclinico:resultados"
    xmlns="http://schemas.xmlsoap.org/wsdl/" xmlns:soap="http://schemas.xmlsoap.org/wsdl/soap/"
    xmlns:tns="urn:labclinico:resultados" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <types>
    <xsd:schema targetNamespace="urn:labclinico:resultados" elementFormDefault="qualified">
      <xsd:element name="Credencial">
        <xsd:complexType><xsd:sequence><xsd:element name="ApiKey" type="xsd:string"/></xsd:sequence></xsd:complexType>
      </xsd:element>
      <xsd:complexType name="Parametro">
        <xsd:sequence>
          <xsd:element name="nombre" type="xsd:string"/>
          <xsd:element name="valor" type="xsd:string"/>
          <xsd:element name="unidad" type="xsd:string" minOccurs="0"/>
          <xsd:element name="referencia" type="xsd:string" minOccurs="0"/>
          <xsd:element name="fueraRango" type="xsd:boolean"/>
        </xsd:sequence>
      </xsd:complexType>
      <xsd:complexType name="Examen">
        <xsd:sequence>
          <xsd:element name="codigo" type="xsd:string"/>
          <xsd:element name="nombre" type="xsd:string"/>
          <xsd:element name="estado" type="xsd:string"/>
          <xsd:element name="fechaResultado" type="xsd:dateTime" minOccurs="0"/>
          <xsd:element name="parametro" type="tns:Parametro" minOccurs="0" maxOccurs="unbounded"/>
        </xsd:sequence>
      </xsd:complexType>
      <xsd:complexType name="ExamenCatalogo">
        <xsd:sequence>
          <xsd:element name="codigo" type="xsd:string"/>
          <xsd:element name="nombre" type="xsd:string"/>
          <xsd:element name="precio" type="xsd:decimal"/>
          <xsd:element name="requiereAyuno" type="xsd:boolean"/>
        </xsd:sequence>
      </xsd:complexType>
      <xsd:element name="ConsultarResultadosRequest">
        <xsd:complexType><xsd:sequence><xsd:element name="codigoSolicitud" type="xsd:string"/></xsd:sequence></xsd:complexType>
      </xsd:element>
      <xsd:element name="ConsultarResultadosResponse">
        <xsd:complexType>
          <xsd:sequence>
            <xsd:element name="codigo" type="xsd:string"/>
            <xsd:element name="estado" type="xsd:string"/>
            <xsd:element name="pacienteCedula" type="xsd:string"/>
            <xsd:element name="pacienteNombre" type="xsd:string"/>
            <xsd:element name="examen" type="tns:Examen" minOccurs="0" maxOccurs="unbounded"/>
          </xsd:sequence>
        </xsd:complexType>
      </xsd:element>
      <xsd:element name="ConsultarEstadoSolicitudRequest">
        <xsd:complexType><xsd:sequence><xsd:element name="codigoSolicitud" type="xsd:string"/></xsd:sequence></xsd:complexType>
      </xsd:element>
      <xsd:element name="ConsultarEstadoSolicitudResponse">
        <xsd:complexType>
          <xsd:sequence>
            <xsd:element name="codigo" type="xsd:string"/>
            <xsd:element name="estado" type="xsd:string"/>
            <xsd:element name="total" type="xsd:decimal"/>
            <xsd:element name="pagado" type="xsd:boolean"/>
            <xsd:element name="examenesListos" type="xsd:int"/>
            <xsd:element name="examenesTotales" type="xsd:int"/>
          </xsd:sequence>
        </xsd:complexType>
      </xsd:element>
      <xsd:element name="ListarExamenesRequest"><xsd:complexType><xsd:sequence/></xsd:complexType></xsd:element>
      <xsd:element name="ListarExamenesResponse">
        <xsd:complexType><xsd:sequence>
          <xsd:element name="examen" type="tns:ExamenCatalogo" minOccurs="0" maxOccurs="unbounded"/>
        </xsd:sequence></xsd:complexType>
      </xsd:element>
    </xsd:schema>
  </types>

  <message name="CredencialHeader"><part name="credencial" element="tns:Credencial"/></message>
  <message name="ConsultarResultadosInput"><part name="parameters" element="tns:ConsultarResultadosRequest"/></message>
  <message name="ConsultarResultadosOutput"><part name="parameters" element="tns:ConsultarResultadosResponse"/></message>
  <message name="ConsultarEstadoSolicitudInput"><part name="parameters" element="tns:ConsultarEstadoSolicitudRequest"/></message>
  <message name="ConsultarEstadoSolicitudOutput"><part name="parameters" element="tns:ConsultarEstadoSolicitudResponse"/></message>
  <message name="ListarExamenesInput"><part name="parameters" element="tns:ListarExamenesRequest"/></message>
  <message name="ListarExamenesOutput"><part name="parameters" element="tns:ListarExamenesResponse"/></message>

  <portType name="LaboratorioPortType">
    <operation name="ConsultarResultados">
      <documentation>Resultados de una solicitud por su código (ej. SOL-2026-000001).</documentation>
      <input message="tns:ConsultarResultadosInput"/><output message="tns:ConsultarResultadosOutput"/>
    </operation>
    <operation name="ConsultarEstadoSolicitud">
      <documentation>Estado, total y avance de una solicitud.</documentation>
      <input message="tns:ConsultarEstadoSolicitudInput"/><output message="tns:ConsultarEstadoSolicitudOutput"/>
    </operation>
    <operation name="ListarExamenes">
      <documentation>Catálogo de exámenes activos con precio.</documentation>
      <input message="tns:ListarExamenesInput"/><output message="tns:ListarExamenesOutput"/>
    </operation>
  </portType>

  <binding name="LaboratorioBinding" type="tns:LaboratorioPortType">
    <soap:binding style="document" transport="http://schemas.xmlsoap.org/soap/http"/>
    <operation name="ConsultarResultados">
      <soap:operation soapAction="urn:labclinico:resultados#ConsultarResultados"/>
      <input><soap:header message="tns:CredencialHeader" part="credencial" use="literal"/><soap:body use="literal"/></input>
      <output><soap:body use="literal"/></output>
    </operation>
    <operation name="ConsultarEstadoSolicitud">
      <soap:operation soapAction="urn:labclinico:resultados#ConsultarEstadoSolicitud"/>
      <input><soap:header message="tns:CredencialHeader" part="credencial" use="literal"/><soap:body use="literal"/></input>
      <output><soap:body use="literal"/></output>
    </operation>
    <operation name="ListarExamenes">
      <soap:operation soapAction="urn:labclinico:resultados#ListarExamenes"/>
      <input><soap:header message="tns:CredencialHeader" part="credencial" use="literal"/><soap:body use="literal"/></input>
      <output><soap:body use="literal"/></output>
    </operation>
  </binding>

  <service name="LaboratorioService">
    <documentation>Servicio SOAP del laboratorio clínico (datos ficticios).</documentation>
    <port name="LaboratorioPort" binding="tns:LaboratorioBinding"><soap:address location="{url}"/></port>
  </service>
</definitions>
"""


def _q(nombre: str) -> str:
    return f"{{{NS}}}{nombre}"


def _sub(padre, nombre: str, valor=None):
    el = ET.SubElement(padre, _q(nombre))
    if valor is not None:
        el.text = ("true" if valor else "false") if isinstance(valor, bool) else str(valor)
    return el


def _sobre(cuerpo_respuesta: ET.Element | None = None, falla: tuple[str, str] | None = None, estado: int = 200) -> Response:
    sobre = ET.Element(f"{{{NS_SOAP}}}Envelope")
    body = ET.SubElement(sobre, f"{{{NS_SOAP}}}Body")
    if falla:
        fault = ET.SubElement(body, f"{{{NS_SOAP}}}Fault")
        ET.SubElement(fault, "faultcode").text = f"soap:{falla[0]}"
        ET.SubElement(fault, "faultstring").text = falla[1]
    else:
        body.append(cuerpo_respuesta)
    xml = ET.tostring(sobre, encoding="utf-8", xml_declaration=True)
    return Response(xml, status=estado, mimetype="text/xml", headers={"Content-Type": "text/xml; charset=utf-8"})


def _url_publica() -> str:
    proto = request.headers.get("X-Forwarded-Proto", request.scheme)
    return f"{proto}://{request.host}/soap"


@bp.get("/soap")
def wsdl():
    return Response(WSDL.replace("{url}", _url_publica()), mimetype="text/xml")


@bp.post("/soap")
def soap():
    try:
        sobre = DefusedET.fromstring(request.get_data())
    except (DefusedET.ParseError, DefusedXmlException):
        return _sobre(falla=("Client", "XML inválido o no permitido."), estado=400)

    api_key = request.headers.get("X-API-Key") or sobre.findtext(f".//{_q('Credencial')}/{_q('ApiKey')}", "")
    if not config.SOAP_API_KEY or not hmac.compare_digest(api_key.strip(), config.SOAP_API_KEY):
        return _sobre(falla=("Client", "Credencial inválida."), estado=401)

    body = sobre.find(f"{{{NS_SOAP}}}Body")
    operacion = body[0] if body is not None and len(body) else None
    if operacion is None:
        return _sobre(falla=("Client", "El sobre SOAP no contiene operación."), estado=400)

    try:
        if operacion.tag == _q("ConsultarResultadosRequest"):
            respuesta = _consultar_resultados(operacion.findtext(_q("codigoSolicitud"), "").strip())
        elif operacion.tag == _q("ConsultarEstadoSolicitudRequest"):
            respuesta = _consultar_estado(operacion.findtext(_q("codigoSolicitud"), "").strip())
        elif operacion.tag == _q("ListarExamenesRequest"):
            respuesta = _listar_examenes()
        else:
            return _sobre(falla=("Client", f"Operación no soportada: {operacion.tag}"), estado=400)
    except ApiError as e:
        return _sobre(falla=("Client" if e.estado < 500 else "Server", e.mensaje), estado=500)
    return _sobre(respuesta)


def _consultar_resultados(codigo: str) -> ET.Element:
    from .examenes import obtener_solicitud
    s = obtener_solicitud(0, codigo=codigo.upper())
    r = ET.Element(_q("ConsultarResultadosResponse"))
    for campo, valor in (("codigo", s["codigo"]), ("estado", s["estado"]),
                         ("pacienteCedula", s["cedula"]), ("pacienteNombre", s["paciente"])):
        _sub(r, campo, valor)
    for ex in s["examenes"]:
        e = _sub(r, "examen")
        _sub(e, "codigo", ex["codigo"])
        _sub(e, "nombre", ex["examen"])
        _sub(e, "estado", ex["estado"])
        if ex["fecha_resultado"]:
            _sub(e, "fechaResultado", ex["fecha_resultado"].isoformat())
        for v in ex["valores"]:
            p = _sub(e, "parametro")
            _sub(p, "nombre", v["parametro"])
            _sub(p, "valor", v["valor_texto"] or f"{float(v['valor_numerico']):g}")
            if v["unidad"]:
                _sub(p, "unidad", v["unidad"])
            referencia = v["valor_ref_texto"] or (
                f"{float(v['valor_ref_min']):g} - {float(v['valor_ref_max']):g}" if v["valor_ref_min"] is not None else None)
            if referencia:
                _sub(p, "referencia", referencia)
            _sub(p, "fueraRango", bool(v["fuera_rango"]))
    return r


def _consultar_estado(codigo: str) -> ET.Element:
    s = db.leer_uno("""
        SELECT s.codigo, s.estado, s.total,
               (SELECT COUNT(*) FROM {e}.pago p WHERE p.solicitud_id = s.solicitud_id
                  AND p.estado IN ('APROBADO', 'REEMBOLSO_PARCIAL')) AS pagos_aprobados,
               (SELECT COUNT(*) FROM {e}.solicitud_detalle d WHERE d.solicitud_id = s.solicitud_id
                  AND d.estado = 'RESULTADO_LISTO') AS listos,
               (SELECT COUNT(*) FROM {e}.solicitud_detalle d WHERE d.solicitud_id = s.solicitud_id
                  AND d.estado <> 'ANULADO') AS totales
        FROM {e}.solicitud_examen s WHERE s.codigo = ?""", codigo.upper())
    if not s:
        raise ApiError("La solicitud no existe.", 404)
    r = ET.Element(_q("ConsultarEstadoSolicitudResponse"))
    _sub(r, "codigo", s["codigo"])
    _sub(r, "estado", s["estado"])
    _sub(r, "total", f"{float(s['total']):.2f}")
    _sub(r, "pagado", s["pagos_aprobados"] > 0)
    _sub(r, "examenesListos", s["listos"])
    _sub(r, "examenesTotales", s["totales"])
    return r


def _listar_examenes() -> ET.Element:
    r = ET.Element(_q("ListarExamenesResponse"))
    for t in db.leer("SELECT codigo, nombre, precio, requiere_ayuno FROM {e}.tipo_examen WHERE activo = ? ORDER BY nombre", True):
        e = _sub(r, "examen")
        _sub(e, "codigo", t["codigo"])
        _sub(e, "nombre", t["nombre"])
        _sub(e, "precio", f"{float(t['precio']):.2f}")
        _sub(e, "requiereAyuno", bool(t["requiere_ayuno"]))
    return r
