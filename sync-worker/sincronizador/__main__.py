"""Sincronizador Azure SQL -> Supabase + MongoDB Atlas.

Ejecutar:  python -m sincronizador          (bucle continuo)
           python -m sincronizador --una-vez (un solo ciclo, para pruebas)
"""
import json
import logging
import signal
import sys
import time
from datetime import datetime, timezone

from . import config
from .destino_mongo import DestinoMongo
from .destino_supabase import DestinoSupabase
from .origen import OrigenAzureSQL

log = logging.getLogger("sincronizador")
_detener = False


def _evento(nivel: int, evento: str, **datos):
    """Log estructurado (una línea JSON) para evidenciar la replicación."""
    datos = {"ts": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
             "instancia": config.INSTANCIA, "evento": evento, **datos}
    log.log(nivel, json.dumps(datos, ensure_ascii=False, default=str))


def ciclo(origen: OrigenAzureSQL, destinos: list) -> bool:
    """Un ciclo de sincronización. Devuelve False si esta instancia no es líder."""
    if not origen.adquirir_liderazgo():
        return False

    expiradas = origen.expirar_citas_pendientes()
    if expiradas:
        _evento(logging.INFO, "citas_expiradas", cantidad=expiradas)

    for destino in destinos:
        inicio = datetime.now(timezone.utc)
        try:
            desde = destino.version()
            lote = origen.leer_lote(destino.tablas, desde, extra=getattr(destino, "preparar", None))
            ups, dels = lote.total()
            if not ups and not dels and not lote.completo:
                if desde != lote.hasta_version:
                    destino.aplicar(lote, inicio)      # solo avanza la versión
                continue
            detalle = destino.aplicar(lote, inicio)
            _evento(logging.INFO, "lote_aplicado", destino=destino.nombre,
                    modo="COMPLETA" if lote.completo else "INCREMENTAL",
                    desde_version=lote.desde_version, hasta_version=lote.hasta_version,
                    upserts=ups, deletes=dels, detalle=detalle,
                    ms=int((datetime.now(timezone.utc) - inicio).total_seconds() * 1000))
        except Exception as e:
            # Un destino caído no detiene al otro; se reintenta en el próximo ciclo.
            _evento(logging.ERROR, "error_destino", destino=destino.nombre, error=f"{type(e).__name__}: {e}")
            destino.cerrar()
    return True


def main():
    logging.basicConfig(level=logging.INFO, format="%(message)s", stream=sys.stdout)
    una_vez = "--una-vez" in sys.argv

    def _senal(*_):
        global _detener
        _detener = True

    signal.signal(signal.SIGINT, _senal)
    signal.signal(signal.SIGTERM, _senal)

    origen = OrigenAzureSQL()
    destinos = [DestinoSupabase(origen), DestinoMongo(origen)]
    espera = config.INTERVALO_SEGUNDOS
    origen_caido = False
    era_lider = None
    _evento(logging.INFO, "inicio", intervalo_s=config.INTERVALO_SEGUNDOS)

    while not _detener:
        try:
            lider = ciclo(origen, destinos)
            if origen_caido:
                _evento(logging.WARNING, "origen_recuperado")
                origen_caido = False
            if lider != era_lider:      # solo se registran los cambios de rol
                _evento(logging.INFO, "lider" if lider else "en_espera",
                        motivo="esta instancia replica" if lider else "otra instancia es la líder")
                era_lider = lider
            espera = config.INTERVALO_SEGUNDOS
        except Exception as e:
            # Azure SQL no disponible: se reintenta con espera exponencial.
            if not origen_caido:
                _evento(logging.ERROR, "origen_no_disponible", error=f"{type(e).__name__}: {e}")
            origen_caido = True
            era_lider = None            # al reconectar se vuelve a disputar el liderazgo
            origen.cerrar()
            espera = min(espera * 2, config.BACKOFF_MAXIMO)
        if una_vez:
            break
        _dormir(espera)

    origen.cerrar()
    for d in destinos:
        d.cerrar()
    _evento(logging.INFO, "fin")


def _dormir(segundos: float):
    fin = time.monotonic() + segundos
    while not _detener and time.monotonic() < fin:
        time.sleep(0.2)


if __name__ == "__main__":
    main()
