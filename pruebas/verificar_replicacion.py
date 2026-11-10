"""Prueba 8: consistencia de la réplica (Azure SQL vs Supabase vs MongoDB Atlas).

Por cada tabla replicada compara la cantidad de filas y una "huella" de las
claves primarias y de la última modificación (max updated_at). En MongoDB
compara las colecciones derivadas. Además mide el retraso: versión actual de
Change Tracking frente a la última versión aplicada en cada destino.

Uso:  python pruebas/verificar_replicacion.py
"""
from urllib.parse import quote

import psycopg
from pymongo import MongoClient

from comun import ahora, azure_sql_admin, credenciales, guardar

TABLAS = ["persona", "usuario", "rol", "permiso", "rol_permiso", "usuario_rol", "paciente", "medico", "laboratorista",
          "categoria_examen", "tipo_examen", "parametro_examen", "franja_horaria", "cita", "solicitud_examen",
          "solicitud_detalle", "resultado", "resultado_valor", "observacion_medica", "tratamiento", "pago", "reembolso",
          "diagnostico", "protocolo", "regla_diagnostica", "regla_condicion", "sugerencia_diagnostica"]

c = credenciales()
az = azure_sql_admin()
pg = psycopg.connect(f"postgresql://lab_lectura.{c['SUPABASE_PROJECT_REF']}:{quote(c['SUPABASE_LAB_LECTURA_PASSWORD'], safe='')}"
                     f"@{c['SUPABASE_POOLER_HOST']}:5432/postgres?sslmode=require")
mg = MongoClient(c["MONGO_URI"])["laboratorio"]


def pk(tabla: str) -> list[str]:
    return [r[0] for r in az.execute(
        "SELECT c.name FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id "
        "JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id "
        "WHERE i.is_primary_key = 1 AND i.object_id = OBJECT_ID(?) ORDER BY ic.key_ordinal", f"dbo.{tabla}").fetchall()]


def tiene_updated_at(tabla: str) -> bool:
    return az.execute("SELECT COL_LENGTH(?, 'updated_at')", f"dbo.{tabla}").fetchval() is not None


print(f"{ahora()}  Comparando Azure SQL -> Supabase ({len(TABLAS)} tablas)")
filas, diferencias = [], 0
for t in TABLAS:
    claves = pk(t)
    huella = " + ".join(f"CAST({k} AS BIGINT)" for k in claves)
    extra = ", MAX(updated_at)" if tiene_updated_at(t) else ", NULL"
    a = tuple(az.execute(f"SELECT COUNT(*), SUM({huella}){extra} FROM dbo.{t}").fetchone())
    s = pg.execute(f"SELECT COUNT(*), SUM({huella}){extra} FROM lab.{t}").fetchone()
    a_fecha = a[2].replace(microsecond=a[2].microsecond // 1000 * 1000) if a[2] else None
    s_fecha = s[2].replace(microsecond=s[2].microsecond // 1000 * 1000) if s[2] else None
    igual = a[0] == s[0] and int(a[1] or 0) == int(s[1] or 0) and a_fecha == s_fecha
    diferencias += not igual
    filas.append({"tabla": t, "azure_filas": a[0], "supabase_filas": s[0], "igual": igual})
    print(f"  {'OK ' if igual else 'DIF'}  {t:<20} azure={a[0]:<5} supabase={s[0]:<5}")

version_actual = az.execute("SELECT CHANGE_TRACKING_CURRENT_VERSION()").fetchval()
v_supabase = pg.execute("SELECT ultima_version FROM lab.sync_estado WHERE destino = 'supabase'").fetchone()[0]
v_mongo = mg.sync_estado.find_one({"_id": "mongodb"})["ultima_version"]

print(f"\n{ahora()}  Comparando Azure SQL -> MongoDB")
mongo = []
for tabla, coleccion in (("auditoria", "auditoria"), ("notificacion", "notificaciones"), ("resultado", "resultados"),
                         ("pago", "pagos"), ("stripe_evento", "stripe_eventos")):
    n_az = az.execute(f"SELECT COUNT(*) FROM dbo.{tabla}").fetchval()
    n_mg = mg[coleccion].count_documents({})
    mongo.append({"tabla": tabla, "coleccion": coleccion, "azure": n_az, "mongo": n_mg, "igual": n_az == n_mg})
    diferencias += n_az != n_mg
    print(f"  {'OK ' if n_az == n_mg else 'DIF'}  {tabla:<14} -> {coleccion:<15} azure={n_az:<5} mongo={n_mg}")

# Verificación de contenido: valores de un resultado en Mongo vs Azure SQL.
muestra = mg.resultados.find_one(sort=[("_id", -1)])
if muestra:
    valores_az = sorted(float(r[0]) for r in az.execute(
        "SELECT valor_numerico FROM dbo.resultado_valor WHERE resultado_id = ? AND valor_numerico IS NOT NULL", muestra["_id"]).fetchall())
    valores_mg = sorted(v["valor_numerico"] for v in muestra["valores"] if v.get("valor_numerico") is not None)
    print(f"  {'OK ' if valores_az == valores_mg else 'DIF'}  contenido del resultado {muestra['_id']} "
          f"({muestra['examen']['nombre']}, {len(valores_mg)} valores)")
    diferencias += valores_az != valores_mg

print(f"\nVersión Change Tracking: Azure={version_actual}  Supabase={v_supabase}  Mongo={v_mongo}")
print(f"RESULTADO: {'CONSISTENTE' if diferencias == 0 else f'{diferencias} diferencia(s)'}")
ruta = guardar("verificar_replicacion.json", {"hora": ahora(), "supabase": filas, "mongodb": mongo,
               "versiones": {"azure": version_actual, "supabase": v_supabase, "mongodb": v_mongo},
               "diferencias": diferencias})
print("Guardado en", ruta)
