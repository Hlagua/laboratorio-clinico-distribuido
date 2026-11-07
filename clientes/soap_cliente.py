"""Cliente SOAP independiente (simula un sistema externo, ej. una aseguradora).

Lee el contrato WSDL publicado y consume las operaciones con zeep.

Uso:
  pip install zeep
  python soap_cliente.py https://<dominio>/soap?wsdl <API_KEY> SOL-2026-000001
"""
import sys

from zeep import Client, Settings
from zeep.exceptions import Fault


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    wsdl, api_key = sys.argv[1], sys.argv[2]
    codigo = sys.argv[3] if len(sys.argv) > 3 else "SOL-2026-000001"

    cliente = Client(wsdl, settings=Settings(strict=True))
    cabecera = {"credencial": {"ApiKey": api_key}}      # <lab:Credencial> definida en el WSDL

    print("== Operaciones publicadas en el WSDL ==")
    for servicio in cliente.wsdl.services.values():
        for puerto in servicio.ports.values():
            print(f"  {puerto.binding_options['address']}")
            for nombre in puerto.binding._operations:
                print(f"   - {nombre}")

    try:
        print("\n== ListarExamenes ==")
        for e in cliente.service.ListarExamenes(_soapheaders=cabecera):
            print(f"  {e.codigo:<10} {e.nombre:<28} USD {e.precio:>6}  ayuno={e.requiereAyuno}")

        print(f"\n== ConsultarEstadoSolicitud({codigo}) ==")
        est = cliente.service.ConsultarEstadoSolicitud(codigoSolicitud=codigo, _soapheaders=cabecera)
        print(f"  estado={est.estado} total={est.total} pagado={est.pagado} "
              f"exámenes listos={est.examenesListos}/{est.examenesTotales}")

        print(f"\n== ConsultarResultados({codigo}) ==")
        res = cliente.service.ConsultarResultados(codigoSolicitud=codigo, _soapheaders=cabecera)
        print(f"  Paciente: {res.pacienteNombre} ({res.pacienteCedula})  Estado: {res.estado}")
        for ex in res.examen:
            print(f"  [{ex.codigo}] {ex.nombre} - {ex.estado}")
            for p in ex.parametro or []:
                marca = "  <-- fuera de rango" if p.fueraRango else ""
                print(f"      {p.nombre:<18} {p.valor:>8} {p.unidad or '':<10} ref: {p.referencia or '-'}{marca}")
    except Fault as f:
        print(f"SOAP Fault: {f.message}")
        sys.exit(2)


if __name__ == "__main__":
    main()
