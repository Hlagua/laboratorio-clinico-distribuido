"""Aplicación de lotes en MongoDB Atlas (documentos, auditoría, trazabilidad)."""
import json
from datetime import date, datetime, time, timezone
from decimal import Decimal

from pymongo import DeleteOne, MongoClient, ReplaceOne

from . import config
from .origen import Lote, OrigenAzureSQL, ids_json
from .tablas import COLECCIONES_DIRECTAS, TABLAS_MONGO

NOMBRE = "mongodb"

SQL_DOC_RESULTADO = """
SELECT r.resultado_id, (
    SELECT r2.resultado_id AS _id, r2.fecha_resultado, r2.validado, r2.validado_at,
           r2.observaciones AS observaciones_laboratorio, r2.updated_at,
           JSON_QUERY((SELECT s.solicitud_id AS id, s.codigo, s.estado, s.created_at
                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS solicitud,
           JSON_QUERY((SELECT pa.paciente_id AS id, pe.cedula, pe.nombres, pe.apellidos, pe.email
                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS paciente,
           JSON_QUERY((SELECT t.tipo_examen_id AS id, t.codigo, t.nombre, c.nombre AS categoria
                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS examen,
           JSON_QUERY((SELECT l.laboratorista_id AS id, CONCAT(pl.nombres, ' ', pl.apellidos) AS nombre
                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS laboratorista,
           JSON_QUERY(ISNULL((
               SELECT rv.resultado_valor_id AS id, pm.nombre AS parametro, rv.valor_numerico, rv.valor_texto,
                      rv.unidad, rv.valor_ref_min, rv.valor_ref_max, rv.valor_ref_texto, rv.fuera_rango
               FROM dbo.resultado_valor rv JOIN dbo.parametro_examen pm ON pm.parametro_id = rv.parametro_id
               WHERE rv.resultado_id = r2.resultado_id ORDER BY pm.orden FOR JSON PATH), '[]')) AS valores,
           JSON_QUERY(ISNULL((
               SELECT o.observacion_id AS id, o.medico_id, CONCAT(pmd.nombres, ' ', pmd.apellidos) AS medico,
                      o.texto, o.created_at
               FROM dbo.observacion_medica o
               JOIN dbo.medico m ON m.medico_id = o.medico_id
               JOIN dbo.persona pmd ON pmd.persona_id = m.persona_id
               WHERE o.resultado_id = r2.resultado_id ORDER BY o.created_at FOR JSON PATH), '[]')) AS observaciones_medicas
    FROM dbo.resultado r2
    JOIN dbo.solicitud_detalle d ON d.detalle_id = r2.detalle_id
    JOIN dbo.solicitud_examen s ON s.solicitud_id = d.solicitud_id
    JOIN dbo.paciente pa ON pa.paciente_id = s.paciente_id
    JOIN dbo.persona pe ON pe.persona_id = pa.persona_id
    JOIN dbo.tipo_examen t ON t.tipo_examen_id = d.tipo_examen_id
    JOIN dbo.categoria_examen c ON c.categoria_id = t.categoria_id
    JOIN dbo.laboratorista l ON l.laboratorista_id = r2.laboratorista_id
    JOIN dbo.persona pl ON pl.persona_id = l.persona_id
    WHERE r2.resultado_id = r.resultado_id
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS doc
FROM dbo.resultado r
WHERE r.resultado_id IN (SELECT CAST([value] AS BIGINT) FROM OPENJSON(?))
"""

SQL_DOC_PAGO = """
SELECT p.pago_id, (
    SELECT p2.pago_id AS _id, p2.solicitud_id, s.codigo AS solicitud_codigo, p2.monto, p2.moneda, p2.metodo,
           p2.estado, p2.stripe_checkout_session_id, p2.stripe_payment_intent_id, p2.referencia_transferencia,
           p2.motivo_rechazo, p2.monto_reembolsado, p2.expira_at, p2.confirmado_at, p2.created_at, p2.updated_at,
           JSON_QUERY((SELECT pa.paciente_id AS id, pe.cedula, CONCAT(pe.nombres, ' ', pe.apellidos) AS nombre
                       FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)) AS paciente,
           JSON_QUERY(ISNULL((
               SELECT re.reembolso_id AS id, re.monto, re.motivo, re.estado, re.stripe_refund_id, re.created_at
               FROM dbo.reembolso re WHERE re.pago_id = p2.pago_id ORDER BY re.reembolso_id FOR JSON PATH), '[]')) AS reembolsos
    FROM dbo.pago p2
    JOIN dbo.solicitud_examen s ON s.solicitud_id = p2.solicitud_id
    JOIN dbo.paciente pa ON pa.paciente_id = s.paciente_id
    JOIN dbo.persona pe ON pe.persona_id = pa.persona_id
    WHERE p2.pago_id = p.pago_id
    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER) AS doc
FROM dbo.pago p
WHERE p.pago_id IN (SELECT CAST([value] AS BIGINT) FROM OPENJSON(?))
"""


def _valor_bson(v):
    """Convierte tipos de SQL Server a tipos que MongoDB acepta."""
    if isinstance(v, Decimal):
        return float(v)
    if isinstance(v, datetime):
        return v
    if isinstance(v, date):
        return datetime(v.year, v.month, v.day)
    if isinstance(v, time):
        return v.isoformat()
    return v


def _fechas_iso(obj):
    """En los documentos FOR JSON las fechas llegan como texto ISO."""
    if isinstance(obj, dict):
        return {
            k: (datetime.fromisoformat(v) if isinstance(v, str) and (k.endswith("_at") or k.startswith("fecha")) else _fechas_iso(v))
            for k, v in obj.items()
        }
    if isinstance(obj, list):
        return [_fechas_iso(x) for x in obj]
    return obj


class DestinoMongo:
    nombre = NOMBRE
    tablas = TABLAS_MONGO

    def __init__(self, origen: OrigenAzureSQL):
        self._origen = origen
        self._cliente: MongoClient | None = None
        self._docs_resultados: dict[int, dict] = {}
        self._docs_pagos: dict[int, dict] = {}

    @property
    def db(self):
        if self._cliente is None:
            self._cliente = MongoClient(config.MONGO_URI, serverSelectionTimeoutMS=10000, tz_aware=False)
        return self._cliente[config.MONGO_DB]

    def cerrar(self):
        if self._cliente is not None:
            self._cliente.close()
        self._cliente = None

    def version(self) -> int | None:
        doc = self.db.sync_estado.find_one({"_id": NOMBRE})
        return doc["ultima_version"] if doc else None

    # ------------- se ejecuta DENTRO de la foto SNAPSHOT del origen -------------
    def preparar(self, cur, lote: Lote):
        """Arma los documentos desnormalizados afectados por el lote."""
        if lote.completo:
            ids_res = [r[0] for r in cur.execute("SELECT resultado_id FROM dbo.resultado").fetchall()]
            ids_pago = [r[0] for r in cur.execute("SELECT pago_id FROM dbo.pago").fetchall()]
        else:
            ids_res = set()
            for c in lote.cambios.get("resultado", []):
                if c.operacion != "D":
                    ids_res.add(c.pk["resultado_id"])
            for tabla in ("resultado_valor", "observacion_medica"):
                ids_res.update(c.fila["resultado_id"] for c in lote.cambios.get(tabla, []) if c.operacion != "D")
            sols = [c.pk["solicitud_id"] for c in lote.cambios.get("solicitud_examen", []) if c.operacion != "D"]
            if sols:
                ids_res.update(r[0] for r in cur.execute(
                    "SELECT r.resultado_id FROM dbo.resultado r JOIN dbo.solicitud_detalle d ON d.detalle_id = r.detalle_id "
                    "WHERE d.solicitud_id IN (SELECT CAST([value] AS BIGINT) FROM OPENJSON(?))", ids_json(sols)
                ).fetchall())

            ids_pago = {c.pk["pago_id"] for c in lote.cambios.get("pago", []) if c.operacion != "D"}
            ids_pago.update(c.fila["pago_id"] for c in lote.cambios.get("reembolso", []) if c.operacion != "D")

        self._docs_resultados = self._documentos(cur, SQL_DOC_RESULTADO, ids_res)
        self._docs_pagos = self._documentos(cur, SQL_DOC_PAGO, ids_pago)

    @staticmethod
    def _documentos(cur, sql: str, ids) -> dict[int, dict]:
        if not ids:
            return {}
        return {
            fila[0]: _fechas_iso(json.loads(fila[1]))
            for fila in cur.execute(sql, ids_json(ids)).fetchall()
            if fila[1]
        }

    # ------------------------- aplicación -------------------------
    def aplicar(self, lote: Lote, inicio: datetime) -> dict:
        db = self.db
        detalle = {}

        # 1) Tablas copiadas tal cual.
        for tabla, coleccion in COLECCIONES_DIRECTAS.items():
            cambios = lote.cambios.get(tabla, [])
            pk = self._origen.pk(tabla)[0]
            ops = []
            for c in cambios:
                if c.operacion == "D":
                    ops.append(DeleteOne({"_id": c.pk[pk]}))
                else:
                    doc = {k: _valor_bson(v) for k, v in c.fila.items() if k != pk}
                    for campo in ("detalle", "payload"):
                        if isinstance(doc.get(campo), str):
                            doc[campo] = json.loads(doc[campo])
                    doc["_id"] = c.pk[pk]
                    ops.append(ReplaceOne({"_id": doc["_id"]}, doc, upsert=True))
            if lote.completo:
                db[coleccion].delete_many({"_id": {"$nin": [c.pk[pk] for c in cambios]}})
            if ops:
                db[coleccion].bulk_write(ops, ordered=True)
            if cambios:
                detalle[coleccion] = len(ops)

        # 2) Documentos desnormalizados.
        self._aplicar_documentos(db.resultados, self._docs_resultados, lote, "resultado", "resultado_id",
                                 {"resultado_valor": ("valores", "resultado_valor_id"),
                                  "observacion_medica": ("observaciones_medicas", "observacion_id")})
        self._aplicar_documentos(db.pagos, self._docs_pagos, lote, "pago", "pago_id",
                                 {"reembolso": ("reembolsos", "reembolso_id")})
        if self._docs_resultados:
            detalle["resultados"] = len(self._docs_resultados)
        if self._docs_pagos:
            detalle["pagos"] = len(self._docs_pagos)

        # 3) La versión avanza al final: si algo falla antes, el lote se
        #    repite y, como todas las operaciones son idempotentes, no duplica.
        db.sync_estado.replace_one(
            {"_id": NOMBRE},
            {"_id": NOMBRE, "ultima_version": lote.hasta_version, "actualizado_at": datetime.now(timezone.utc)},
            upsert=True,
        )
        ups, dels = lote.total()
        if ups or dels or lote.completo:
            db.sync_log.insert_one({
                "inicio": inicio, "fin": datetime.now(timezone.utc),
                "modo": "COMPLETA" if lote.completo else "INCREMENTAL",
                "desde_version": lote.desde_version, "hasta_version": lote.hasta_version,
                "upserts": ups, "deletes": dels, "detalle": detalle, "instancia": config.INSTANCIA,
            })
        return detalle

    @staticmethod
    def _aplicar_documentos(coleccion, docs: dict, lote: Lote, tabla_padre: str, pk_padre: str, hijas: dict):
        ops = [ReplaceOne({"_id": i}, d, upsert=True) for i, d in docs.items()]
        if lote.completo:
            coleccion.delete_many({"_id": {"$nin": list(docs)}})
        else:
            ops += [DeleteOne({"_id": c.pk[pk_padre]}) for c in lote.cambios.get(tabla_padre, []) if c.operacion == "D"]
            # Un hijo borrado solo trae su PK: se quita del arreglo donde esté.
            for tabla_hija, (arreglo, pk_hija) in hijas.items():
                for c in lote.cambios.get(tabla_hija, []):
                    if c.operacion == "D":
                        coleccion.update_many({f"{arreglo}.id": c.pk[pk_hija]},
                                              {"$pull": {arreglo: {"id": c.pk[pk_hija]}}})
        if ops:
            coleccion.bulk_write(ops, ordered=True)
