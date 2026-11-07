"""Acceso a datos con contingencia automática.

- Escrituras: siempre en Azure SQL. Si no está disponible -> 503.
- Lecturas: en Azure SQL; si falla la conexión, el circuito se abre y,
  mientras siga abierto, las consultas permitidas van a Supabase
  (rol lab_lectura, solo lectura).

Las consultas se escriben UNA vez con:
  {e}  -> esquema (dbo en Azure SQL, lab en Supabase)
  ?    -> parámetro (se traduce a %s para PostgreSQL)
y SQL compatible con ambos motores (sin TOP/LIMIT, sin funciones propias).
"""
import logging
import threading
import time

import psycopg
import pyodbc
from flask import g
from psycopg.rows import dict_row

from . import config
from .errores import ApiError, ModoContingencia, desde_sql

log = logging.getLogger("api")

# SQLSTATE de pyodbc que indican que el servidor no responde (no errores de negocio).
_ESTADOS_CONEXION = ("08001", "08S01", "08004", "HYT00", "HYT01", "40613", "40197", "40501")

_circuito = {"abierto_hasta": 0.0, "fallos": 0}
_candado = threading.Lock()


# ---------------------------- circuit breaker ----------------------------
def azure_disponible() -> bool:
    return time.monotonic() >= _circuito["abierto_hasta"]


def _abrir_circuito(error: Exception):
    with _candado:
        ya_abierto = not azure_disponible()
        _circuito["abierto_hasta"] = time.monotonic() + config.CB_SEGUNDOS_ABIERTO
        _circuito["fallos"] += 1
    _pool.vaciar()                  # las conexiones guardadas probablemente están muertas
    if not ya_abierto:
        log.error('{"evento":"circuito_abierto","instancia":"%s","error":"%s"}',
                  config.INSTANCIA, str(error).replace('"', "'")[:200])


def _cerrar_circuito():
    if _circuito["fallos"]:
        with _candado:
            _circuito["fallos"] = 0
        log.warning('{"evento":"circuito_cerrado","instancia":"%s"}', config.INSTANCIA)


def es_error_conexion(e: pyodbc.Error) -> bool:
    estado = e.args[0] if e.args else ""
    return isinstance(e, (pyodbc.OperationalError, pyodbc.InterfaceError)) or estado in _ESTADOS_CONEXION


def nueva_conexion_azure() -> pyodbc.Connection:
    """Conexión nueva a Azure SQL (uso fuera de una petición, ej. hilos)."""
    if not azure_disponible():
        raise ModoContingencia()
    try:
        cn = pyodbc.connect(config.AZURE_SQL_CONN, autocommit=True, timeout=config.CB_TIMEOUT_CONEXION)
        cn.timeout = config.CB_TIMEOUT_CONSULTA
    except pyodbc.Error as e:
        if es_error_conexion(e):
            _abrir_circuito(e)
            raise ModoContingencia() from e
        raise
    _cerrar_circuito()
    return cn


class _PoolAzure:
    """Pool mínimo de conexiones por proceso.

    Abrir una conexión a Azure SQL cuesta 2-3 s (TLS + autenticación + la
    distancia hasta la región del servidor); reutilizarla, ~0 s. Las que
    estuvieron ociosas se validan antes de prestarlas.
    """
    MAXIMO = 8
    VALIDAR_TRAS_S = 60
    DESCARTAR_TRAS_S = 600

    def __init__(self):
        self._libres: list[tuple[pyodbc.Connection, float]] = []
        self._candado = threading.Lock()

    def obtener(self) -> pyodbc.Connection:
        while True:
            with self._candado:
                if not self._libres:
                    break
                cn, desde = self._libres.pop()
            ocioso = time.monotonic() - desde
            if ocioso > self.DESCARTAR_TRAS_S:
                self._cerrar(cn)
                continue
            if ocioso > self.VALIDAR_TRAS_S:
                try:
                    cn.execute("SELECT 1").fetchval()
                except pyodbc.Error:
                    self._cerrar(cn)
                    continue
            return cn
        return nueva_conexion_azure()

    def devolver(self, cn: pyodbc.Connection):
        with self._candado:
            if len(self._libres) < self.MAXIMO:
                self._libres.append((cn, time.monotonic()))
                return
        self._cerrar(cn)

    def vaciar(self):
        with self._candado:
            libres, self._libres = self._libres, []
        for cn, _ in libres:
            self._cerrar(cn)

    @staticmethod
    def _cerrar(cn):
        try:
            cn.close()
        except Exception:
            pass


_pool = _PoolAzure()


def _azure() -> pyodbc.Connection:
    if "azure" not in g:
        g.azure = _pool.obtener()
    return g.azure


def _descartar_azure():
    """La conexión de esta petición falló: no vuelve al pool."""
    cn = g.pop("azure", None)
    if cn is not None:
        _PoolAzure._cerrar(cn)


def _supabase() -> psycopg.Connection:
    if "supabase" not in g:
        try:
            g.supabase = psycopg.connect(config.SUPABASE_DSN, connect_timeout=5, row_factory=dict_row, autocommit=True)
        except psycopg.Error as e:
            log.error('{"evento":"supabase_no_disponible","error":"%s"}', str(e).replace('"', "'")[:200])
            raise ApiError("La base principal y la de contingencia no están disponibles.", 503, "SIN_BASES") from e
    return g.supabase


def cerrar_conexiones(_=None):
    cn = g.pop("azure", None)
    if cn is not None:
        _pool.devolver(cn)
    cn = g.pop("supabase", None)
    if cn is not None:
        try:
            cn.close()
        except Exception:
            pass


# ------------------------------ lecturas ------------------------------
def _filas(cursor) -> list[dict]:
    columnas = [c[0] for c in cursor.description]
    return [dict(zip(columnas, fila)) for fila in cursor.fetchall()]


def leer(sql: str, *params, contingencia: bool = True) -> list[dict]:
    """Ejecuta una consulta de lectura con fallback a Supabase."""
    # Dos intentos: si una conexión reutilizada estaba cortada, se prueba con
    # una nueva antes de declarar caída la base principal.
    for intento in (1, 2):
        if not azure_disponible():
            break
        try:
            cur = _azure().cursor()
            filas = _filas(cur.execute(sql.format(e="dbo"), *params))
            g.origen_datos = "azure"
            return filas
        except ModoContingencia:
            break
        except pyodbc.Error as e:
            if not es_error_conexion(e):
                raise
            _descartar_azure()
            if intento == 2:
                _abrir_circuito(e)
    if not contingencia:
        raise ModoContingencia()
    with _supabase().cursor() as cur:
        cur.execute(sql.format(e="lab").replace("?", "%s"), params)
        g.origen_datos = "supabase"
        return list(cur.fetchall())


def leer_uno(sql: str, *params, contingencia: bool = True) -> dict | None:
    filas = leer(sql, *params, contingencia=contingencia)
    return filas[0] if filas else None


# ------------------------------ escrituras ------------------------------
def _ejecutar(sql: str, params: list):
    try:
        cur = _azure().cursor()
        cur.execute(sql, *params)
        g.origen_datos = "azure"
        return cur
    except pyodbc.Error as e:
        if es_error_conexion(e):
            # Una escritura no se reintenta: pudo haberse aplicado antes del corte.
            _descartar_azure()
            _abrir_circuito(e)
            raise ModoContingencia() from e
        error = desde_sql(e)
        if error:
            raise error from e
        raise


def ejecutar_sp(_procedimiento: str, _salida: str | None = None, /, **params):
    """EXEC dbo.<procedimiento> @p1 = ?, ... [@salida = @out OUTPUT]; devuelve el OUTPUT.

    Los dos primeros argumentos son solo posicionales para que los parámetros
    del procedimiento puedan llamarse como sea (ej. @nombre).
    """
    asignaciones = [f"@{k} = ?" for k in params]
    if _salida:
        asignaciones.append(f"@{_salida} = @out OUTPUT")
    sql = "SET NOCOUNT ON; DECLARE @out BIGINT; EXEC dbo.{} {};{}".format(
        _procedimiento, ", ".join(asignaciones), " SELECT @out;" if _salida else "")
    cur = _ejecutar(sql, list(params.values()))
    return cur.fetchval() if _salida else None


def ejecutar(sql: str, *params) -> int:
    """Sentencia directa en Azure SQL; devuelve las filas afectadas."""
    return _ejecutar(sql, list(params)).rowcount
