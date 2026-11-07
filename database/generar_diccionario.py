"""Genera docs/03-diccionario-datos.md leyendo los metadatos reales de SQL Server.

Uso:  python database/generar_diccionario.py "<cadena ODBC>"
      (sin argumento usa la base local de prueba en LocalDB)
"""
import sys
from pathlib import Path

import pyodbc

CONN = sys.argv[1] if len(sys.argv) > 1 else (
    "Driver={ODBC Driver 18 for SQL Server};Server=(localdb)\\MSSQLLocalDB;Database=lab_prueba;"
    "Trusted_Connection=yes;TrustServerCertificate=yes;"
)
SALIDA = Path(__file__).resolve().parent.parent / "docs" / "03-diccionario-datos.md"

DESCRIPCION = {
    "persona": "Datos personales únicos por cédula. Base de todos los perfiles.",
    "usuario": "Credenciales de acceso (0..1 por persona). Contraseña con bcrypt.",
    "rol": "Roles del sistema: PACIENTE, LABORATORISTA, MEDICO, ADMIN.",
    "permiso": "Permisos atómicos que se agrupan en roles.",
    "rol_permiso": "Relación N:M entre roles y permisos.",
    "usuario_rol": "Relación N:M entre usuarios y roles: una persona puede tener varios roles.",
    "paciente": "Perfil clínico de una persona atendida en el laboratorio.",
    "medico": "Perfil del médico tratante.",
    "laboratorista": "Perfil del profesional que procesa muestras y registra resultados.",
    "categoria_examen": "Agrupación de exámenes (hematología, química, etc.).",
    "tipo_examen": "Catálogo de exámenes con precio y requisitos.",
    "parametro_examen": "Parámetros que mide cada examen con su rango de referencia.",
    "franja_horaria": "Bloques de atención con capacidad; el contador de ocupados se protege ante concurrencia.",
    "cita": "Reserva de un paciente en una franja.",
    "solicitud_examen": "Orden de exámenes de un paciente (cabecera).",
    "solicitud_detalle": "Cada examen dentro de una solicitud, con su precio congelado.",
    "resultado": "Resultado emitido para un examen solicitado.",
    "resultado_valor": "Valor por parámetro, con copia del rango vigente y marca de fuera de rango.",
    "observacion_medica": "Comentarios del médico tratante sobre un resultado.",
    "tratamiento": "Diagnóstico e indicaciones del médico para un paciente.",
    "pago": "Pago de una solicitud (Stripe en modo prueba o transferencia con QR).",
    "reembolso": "Reembolsos totales o parciales de un pago.",
    "stripe_evento": "Eventos recibidos por webhook de Stripe (idempotencia y trazabilidad).",
    "notificacion": "Bandeja de salida de correos (Mailjet).",
    "auditoria": "Registro de operaciones relevantes; se replica a MongoDB.",
}

cn = pyodbc.connect(CONN)
tablas = [r[0] for r in cn.execute(
    "SELECT t.name FROM sys.tables t WHERE t.is_ms_shipped = 0 ORDER BY t.create_date, t.name").fetchall()]

lineas = ["# Diccionario de datos — Azure SQL Database", "",
          "_Generado automáticamente con `database/generar_diccionario.py` a partir de la base real._", ""]
for t in tablas:
    lineas += [f"## {t}", "", DESCRIPCION.get(t, ""), "",
               "| Columna | Tipo | Nulo | Clave | Por defecto |", "|---|---|---|---|---|"]
    cols = cn.execute("""
        SELECT c.name,
               ty.name + CASE
                   WHEN ty.name IN ('varchar','char','nvarchar','nchar') THEN
                        '(' + CASE WHEN c.max_length = -1 THEN 'MAX'
                                   ELSE CAST(c.max_length / IIF(ty.name LIKE 'n%', 2, 1) AS VARCHAR) END + ')'
                   WHEN ty.name IN ('decimal','numeric') THEN '(' + CAST(c.precision AS VARCHAR) + ',' + CAST(c.scale AS VARCHAR) + ')'
                   ELSE '' END,
               c.is_nullable, c.is_identity,
               IIF(EXISTS (SELECT 1 FROM sys.index_columns ic JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
                           WHERE i.is_primary_key = 1 AND ic.object_id = c.object_id AND ic.column_id = c.column_id), 1, 0),
               (SELECT TOP 1 OBJECT_NAME(fk.referenced_object_id) FROM sys.foreign_key_columns fk
                WHERE fk.parent_object_id = c.object_id AND fk.parent_column_id = c.column_id),
               dc.definition
        FROM sys.columns c
        JOIN sys.types ty ON ty.user_type_id = c.user_type_id
        LEFT JOIN sys.default_constraints dc ON dc.parent_object_id = c.object_id AND dc.parent_column_id = c.column_id
        WHERE c.object_id = OBJECT_ID(?) ORDER BY c.column_id""", f"dbo.{t}").fetchall()
    for nombre, tipo, nulo, ident, es_pk, fk, defecto in cols:
        clave = " ".join(filter(None, ["PK" if es_pk else "", "IDENTITY" if ident else "", f"FK → {fk}" if fk else ""]))
        lineas.append(f"| {nombre} | {tipo} | {'Sí' if nulo else 'No'} | {clave} | {(defecto or '').strip('()')} |")

    restricciones = cn.execute("""
        SELECT name, 'CHECK ' + definition FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(?)
        UNION ALL
        SELECT i.name, IIF(i.has_filter = 1, 'UNIQUE filtrado ' + i.filter_definition, 'UNIQUE') + ' (' +
               STRING_AGG(c.name, ', ') WITHIN GROUP (ORDER BY ic.key_ordinal) + ')'
        FROM sys.indexes i
        JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
        JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
        WHERE i.object_id = OBJECT_ID(?) AND i.is_unique = 1 AND i.is_primary_key = 0
        GROUP BY i.name, i.has_filter, i.filter_definition""", f"dbo.{t}", f"dbo.{t}").fetchall()
    if restricciones:
        lineas += ["", "**Restricciones:**", ""]
        lineas += [f"- `{n}`: `{d}`" for n, d in restricciones]
    lineas.append("")

SALIDA.parent.mkdir(exist_ok=True)
SALIDA.write_text("\n".join(lineas), encoding="utf-8")
print(f"Diccionario generado: {SALIDA} ({len(tablas)} tablas)")
