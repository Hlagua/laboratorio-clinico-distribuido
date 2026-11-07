"""Lectura de cambios desde Azure SQL mediante Change Tracking."""
import json
from dataclasses import dataclass, field

import pyodbc

from . import config


@dataclass
class Cambio:
    operacion: str              # 'I', 'U' o 'D'
    pk: dict                    # {columna_pk: valor}
    fila: dict | None           # fila completa (None si fue borrada)


@dataclass
class Lote:
    """Cambios leídos dentro de una misma transacción SNAPSHOT."""
    desde_version: int | None
    hasta_version: int
    completo: bool                                  # True = carga completa
    cambios: dict[str, list[Cambio]] = field(default_factory=dict)

    def total(self) -> tuple[int, int]:
        ups = sum(1 for cs in self.cambios.values() for c in cs if c.operacion != "D")
        dels = sum(1 for cs in self.cambios.values() for c in cs if c.operacion == "D")
        return ups, dels


class OrigenAzureSQL:
    def __init__(self):
        self._conn: pyodbc.Connection | None = None
        self._conn_lock: pyodbc.Connection | None = None
        self._columnas: dict[str, list[str]] = {}
        self._pks: dict[str, list[str]] = {}

    # ---------------- conexión y liderazgo ----------------
    def conectar(self):
        if self._conn is None:
            self._conn = pyodbc.connect(config.AZURE_SQL_CONN, autocommit=True, timeout=10)

    def cerrar(self):
        for c in (self._conn, self._conn_lock):
            try:
                if c is not None:
                    c.close()
            except pyodbc.Error:
                pass
        self._conn = self._conn_lock = None

    def adquirir_liderazgo(self) -> bool:
        """Solo un sincronizador activo a la vez (puede haber uno en cada VM).

        El candado de aplicación vive mientras la conexión siga abierta; si
        la instancia líder muere, SQL Server lo libera y otra toma el relevo.
        """
        if self._conn_lock is not None:
            return True
        conn = pyodbc.connect(config.AZURE_SQL_CONN, autocommit=True, timeout=10)
        resultado = conn.execute(
            "DECLARE @r INT; EXEC @r = sp_getapplock @Resource = 'lab_sincronizador', "
            "@LockMode = 'Exclusive', @LockOwner = 'Session', @LockTimeout = 0; SELECT @r;"
        ).fetchval()
        if resultado >= 0:
            self._conn_lock = conn
            return True
        conn.close()
        return False

    # ---------------- metadatos ----------------
    def _cargar_metadatos(self, tabla: str):
        if tabla in self._columnas:
            return
        cur = self._conn.cursor()
        cols = cur.execute(
            "SELECT c.name FROM sys.columns c JOIN sys.types t ON t.user_type_id = c.user_type_id "
            "WHERE c.object_id = OBJECT_ID(?) AND t.name <> 'timestamp' ORDER BY c.column_id",
            f"dbo.{tabla}",
        ).fetchall()
        pks = cur.execute(
            "SELECT c.name FROM sys.indexes i "
            "JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id "
            "JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id "
            "WHERE i.is_primary_key = 1 AND i.object_id = OBJECT_ID(?) ORDER BY ic.key_ordinal",
            f"dbo.{tabla}",
        ).fetchall()
        if not cols or not pks:
            raise RuntimeError(f"La tabla dbo.{tabla} no existe o no tiene PK")
        self._columnas[tabla] = [c[0] for c in cols]
        self._pks[tabla] = [p[0] for p in pks]

    def pk(self, tabla: str) -> list[str]:
        self._cargar_metadatos(tabla)
        return self._pks[tabla]

    # ---------------- lectura ----------------
    def leer_lote(self, tablas: list[str], desde_version: int | None, extra=None) -> Lote:
        """Lee los cambios de `tablas` desde `desde_version` en una foto consistente.

        Si `desde_version` es None o ya no es válida (el sincronizador estuvo
        apagado más que la retención), devuelve una carga completa.
        `extra(cursor, lote)` permite al destino consultar más datos dentro
        de la misma foto (ej. armar documentos desnormalizados para Mongo).
        """
        self.conectar()
        for t in tablas:
            self._cargar_metadatos(t)

        cur = self._conn.cursor()
        cur.execute("SET TRANSACTION ISOLATION LEVEL SNAPSHOT; BEGIN TRAN;")
        try:
            hasta = cur.execute("SELECT CHANGE_TRACKING_CURRENT_VERSION()").fetchval()
            completo = desde_version is None
            if not completo:
                for t in tablas:
                    minima = cur.execute(
                        "SELECT CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(?))", f"dbo.{t}"
                    ).fetchval()
                    if minima is None:
                        raise RuntimeError(f"Change Tracking no está habilitado en dbo.{t}")
                    if desde_version < minima:
                        completo = True
                        break

            lote = Lote(None if completo else desde_version, hasta, completo)
            for t in tablas:
                lote.cambios[t] = (
                    self._leer_todo(cur, t) if completo else self._leer_cambios(cur, t, desde_version)
                )
            if extra is not None:
                extra(cur, lote)
            # El nivel de aislamiento queda fijado en la sesión: se restablece
            # para que sp_expirar_citas_pendientes (usa READPAST) funcione.
            cur.execute("COMMIT; SET TRANSACTION ISOLATION LEVEL READ COMMITTED;")
            return lote
        except Exception:
            try:
                cur.execute("IF @@TRANCOUNT > 0 ROLLBACK; SET TRANSACTION ISOLATION LEVEL READ COMMITTED;")
            except pyodbc.Error:
                pass
            raise

    def _leer_cambios(self, cur, tabla: str, desde: int) -> list[Cambio]:
        pks, cols = self._pks[tabla], self._columnas[tabla]
        sel_pk = ", ".join(f"ct.[{p}] AS [__pk_{p}]" for p in pks)
        sel_cols = ", ".join(f"t.[{c}]" for c in cols)
        join = " AND ".join(f"t.[{p}] = ct.[{p}]" for p in pks)
        sql = (
            f"SELECT ct.SYS_CHANGE_OPERATION, {sel_pk}, {sel_cols} "
            f"FROM CHANGETABLE(CHANGES dbo.[{tabla}], ?) AS ct "
            f"LEFT JOIN dbo.[{tabla}] AS t ON {join} "
            f"ORDER BY ct.SYS_CHANGE_VERSION"
        )
        cambios = []
        for r in cur.execute(sql, desde).fetchall():
            op = r[0]
            pk = {p: r[1 + i] for i, p in enumerate(pks)}
            fila = {c: r[1 + len(pks) + i] for i, c in enumerate(cols)}
            # Si la fila ya no existe en la foto (borrada después), es un borrado.
            if op == "D" or fila[pks[0]] is None:
                cambios.append(Cambio("D", pk, None))
            else:
                cambios.append(Cambio(op, pk, fila))
        return cambios

    def _leer_todo(self, cur, tabla: str) -> list[Cambio]:
        pks, cols = self._pks[tabla], self._columnas[tabla]
        sql = f"SELECT {', '.join(f'[{c}]' for c in cols)} FROM dbo.[{tabla}]"
        cambios = []
        for r in cur.execute(sql).fetchall():
            fila = dict(zip(cols, r))
            cambios.append(Cambio("I", {p: fila[p] for p in pks}, fila))
        return cambios

    # ---------------- mantenimiento ----------------
    def expirar_citas_pendientes(self) -> int:
        self.conectar()
        return self._conn.execute(
            "SET NOCOUNT ON; SET TRANSACTION ISOLATION LEVEL READ COMMITTED; "
            "DECLARE @n INT; EXEC dbo.sp_expirar_citas_pendientes @minutos = ?, "
            "@expiradas = @n OUTPUT; SELECT @n;",
            config.MINUTOS_EXPIRAR_CITAS,
        ).fetchval()


def ids_json(ids) -> str:
    return json.dumps(sorted({int(i) for i in ids}))
