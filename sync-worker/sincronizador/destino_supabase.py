"""Aplicación de lotes en Supabase (PostgreSQL, esquema lab)."""
from datetime import datetime, timezone

import psycopg
from psycopg.types.json import Jsonb

from . import config
from .origen import Lote, OrigenAzureSQL
from .tablas import TABLAS_SUPABASE

NOMBRE = "supabase"


def _q(identificador: str) -> str:
    return f'"{identificador}"'


def _lista(identificadores: list[str]) -> str:
    return ", ".join(_q(i) for i in identificadores)


class DestinoSupabase:
    nombre = NOMBRE
    tablas = TABLAS_SUPABASE

    def __init__(self, origen: OrigenAzureSQL):
        self._origen = origen
        self._conn: psycopg.Connection | None = None
        self._columnas: dict[str, list[str]] = {}

    def conectar(self):
        if self._conn is None or self._conn.closed:
            self._conn = psycopg.connect(config.SUPABASE_DSN, connect_timeout=10)
            self._columnas.clear()

    def cerrar(self):
        if self._conn is not None:
            self._conn.close()
        self._conn = None

    def version(self) -> int | None:
        self.conectar()
        with self._conn.cursor() as cur:
            cur.execute("SELECT ultima_version FROM lab.sync_estado WHERE destino = %s", (NOMBRE,))
            fila = cur.fetchone()
        self._conn.rollback()
        return fila[0] if fila else None

    def _columnas_destino(self, cur, tabla: str) -> list[str]:
        if tabla not in self._columnas:
            cur.execute(
                "SELECT column_name FROM information_schema.columns "
                "WHERE table_schema = 'lab' AND table_name = %s ORDER BY ordinal_position",
                (tabla,),
            )
            self._columnas[tabla] = [r[0] for r in cur.fetchall()]
            if not self._columnas[tabla]:
                raise RuntimeError(f"La tabla lab.{tabla} no existe en Supabase")
        return self._columnas[tabla]

    def aplicar(self, lote: Lote, inicio: datetime) -> dict:
        """Aplica el lote y avanza la versión en UNA transacción (todo o nada)."""
        self.conectar()
        detalle = {}
        with self._conn.transaction(), self._conn.cursor() as cur:
            if lote.completo:
                # Carga completa: se vacía la réplica y se vuelve a llenar.
                for tabla in reversed(self.tablas):
                    cur.execute(f"DELETE FROM lab.{_q(tabla)}")

            for tabla in self.tablas:
                cambios = lote.cambios.get(tabla, [])
                if not cambios:
                    continue
                pks = self._origen.pk(tabla)
                cols_dest = self._columnas_destino(cur, tabla)
                filas = [c.fila for c in cambios if c.operacion != "D"]
                borrados = [c.pk for c in cambios if c.operacion == "D"]

                if filas:
                    cols = [c for c in cols_dest if c in filas[0]]
                    no_pk = [c for c in cols if c not in pks]
                    conflicto = (
                        "DO UPDATE SET " + ", ".join(f"{_q(c)} = EXCLUDED.{_q(c)}" for c in no_pk)
                        if no_pk else "DO NOTHING"
                    )
                    sql = (
                        f"INSERT INTO lab.{_q(tabla)} ({_lista(cols)}) "
                        f"VALUES ({', '.join(['%s'] * len(cols))}) "
                        f"ON CONFLICT ({_lista(pks)}) {conflicto}"
                    )
                    cur.executemany(sql, [[f[c] for c in cols] for f in filas])

                if borrados:
                    condicion = " AND ".join(f"{_q(p)} = %s" for p in pks)
                    cur.executemany(
                        f"DELETE FROM lab.{_q(tabla)} WHERE {condicion}",
                        [[b[p] for p in pks] for b in borrados],
                    )
                detalle[tabla] = {"upserts": len(filas), "deletes": len(borrados)}

            cur.execute(
                "INSERT INTO lab.sync_estado (destino, ultima_version, actualizado_at) "
                "VALUES (%s, %s, now() AT TIME ZONE 'utc') "
                "ON CONFLICT (destino) DO UPDATE SET ultima_version = EXCLUDED.ultima_version, "
                "actualizado_at = EXCLUDED.actualizado_at",
                (NOMBRE, lote.hasta_version),
            )
            ups, dels = lote.total()
            if ups or dels or lote.completo:
                cur.execute(
                    "INSERT INTO lab.sync_log (inicio, fin, modo, desde_version, hasta_version, "
                    "upserts, deletes, detalle, instancia) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)",
                    (
                        inicio.replace(tzinfo=None),
                        datetime.now(timezone.utc).replace(tzinfo=None),
                        "COMPLETA" if lote.completo else "INCREMENTAL",
                        lote.desde_version, lote.hasta_version, ups, dels,
                        Jsonb(detalle), config.INSTANCIA,
                    ),
                )
        return detalle
