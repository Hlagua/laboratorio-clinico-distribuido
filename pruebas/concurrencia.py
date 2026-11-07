"""Fase VI: reserva simultánea del mismo horario, con y sin protección, en Azure SQL.

N pacientes distintos llaman a la vez a dbo.sp_reservar_cita sobre una franja
con 3 cupos libres (cada llamada en su propia conexión e hilo):
  - @protegido = 0 -> lectura sin bloqueo + escritura del valor leído
  - @protegido = 1 -> transacción con UPDLOCK/HOLDLOCK
@espera_ms agranda la ventana entre leer y escribir para hacer visible la carrera.
Al final cancela las citas de prueba y recalcula los contadores.

Uso:  python pruebas/concurrencia.py [pacientes] [espera_ms]
"""
import sys
import threading
import time

import pyodbc

from comun import ahora, azure_sql_admin, guardar

N = int(sys.argv[1]) if len(sys.argv) > 1 else 6
ESPERA = int(sys.argv[2]) if len(sys.argv) > 2 else 800

admin = azure_sql_admin()
pacientes = [r[0] for r in admin.execute("SELECT TOP (?) paciente_id FROM dbo.paciente ORDER BY paciente_id", N).fetchall()]
if len(pacientes) < N:
    sys.exit(f"Se necesitan {N} pacientes; hay {len(pacientes)}")
# Dos franjas futuras vacías y con capacidad 3, una por escenario.
franjas = [r[0] for r in admin.execute(
    "SELECT TOP 2 franja_id FROM dbo.franja_horaria f WHERE f.activa = 1 AND f.ocupados = 0 AND f.capacidad = 3 "
    "AND f.fecha > CAST(DATEADD(HOUR, -5, SYSUTCDATETIME()) AS DATE) "
    "AND NOT EXISTS (SELECT 1 FROM dbo.cita c WHERE c.franja_id = f.franja_id) ORDER BY f.fecha DESC, f.hora_inicio DESC").fetchall()]


def escenario(franja_id: int, protegido: int) -> dict:
    conexiones = [azure_sql_admin() for _ in pacientes]       # una sesión por "usuario"
    resultados, barrera = [], threading.Barrier(len(pacientes))

    def reservar(cn, paciente_id):
        barrera.wait()                                      # todos arrancan a la vez
        t0 = time.perf_counter()
        try:
            cita = cn.execute("SET NOCOUNT ON; DECLARE @c BIGINT; EXEC dbo.sp_reservar_cita @paciente_id = ?, "
                              "@franja_id = ?, @motivo = N'Prueba de concurrencia', @protegido = ?, @espera_ms = ?, "
                              "@cita_id = @c OUTPUT; SELECT @c;", paciente_id, franja_id, protegido, ESPERA).fetchval()
            resultados.append(("RESERVADA", paciente_id, cita, round(time.perf_counter() - t0, 2)))
        except pyodbc.Error as e:
            msg = str(e).split("[SQL Server]")[-1].split("(500")[0].strip()
            resultados.append(("RECHAZADA", paciente_id, msg, round(time.perf_counter() - t0, 2)))

    hilos = [threading.Thread(target=reservar, args=(cn, p)) for cn, p in zip(conexiones, pacientes)]
    [h.start() for h in hilos]
    [h.join() for h in hilos]
    for cn in conexiones:
        cn.close()
    f = admin.execute("SELECT capacidad, ocupados, (SELECT COUNT(*) FROM dbo.cita c WHERE c.franja_id = f.franja_id "
                      "AND c.estado <> 'CANCELADA') FROM dbo.franja_horaria f WHERE franja_id = ?", franja_id).fetchone()
    return {"protegido": bool(protegido), "franja_id": franja_id, "capacidad": f[0], "contador_ocupados": f[1],
            "citas_reales": f[2], "consistente": f[1] == f[2] and f[2] <= f[0],
            "reservadas": sum(r[0] == "RESERVADA" for r in resultados),
            "rechazadas": sum(r[0] == "RECHAZADA" for r in resultados), "detalle": sorted(resultados)}


informe = {"hora": ahora(), "pacientes": N, "espera_ms": ESPERA, "escenarios": []}
for franja_id, protegido in zip(franjas, (0, 1)):
    r = escenario(franja_id, protegido)
    informe["escenarios"].append(r)
    print(f"\n{'CON' if protegido else 'SIN'} protección - franja {franja_id} (capacidad {r['capacidad']}), {N} pacientes a la vez")
    print(f"  reservadas={r['reservadas']} rechazadas={r['rechazadas']} | contador ocupados={r['contador_ocupados']} "
          f"citas reales={r['citas_reales']} -> {'CONSISTENTE' if r['consistente'] else 'INCONSISTENTE (sobre-reserva / actualización perdida)'}")

# Limpieza: cancelar las citas de prueba y recalcular los contadores.
admin.execute("UPDATE dbo.cita SET estado = 'CANCELADA', cancelada_at = SYSUTCDATETIME(), updated_at = SYSUTCDATETIME() "
              "WHERE motivo = N'Prueba de concurrencia' AND estado <> 'CANCELADA'")
for franja_id in franjas:
    admin.execute("UPDATE f SET ocupados = (SELECT COUNT(*) FROM dbo.cita c WHERE c.franja_id = f.franja_id AND c.estado <> 'CANCELADA'), "
                  "updated_at = SYSUTCDATETIME() FROM dbo.franja_horaria f WHERE f.franja_id = ?", franja_id)
print("\nCitas de prueba canceladas y contadores recalculados.")
print("Guardado en", guardar("concurrencia.json", informe))
