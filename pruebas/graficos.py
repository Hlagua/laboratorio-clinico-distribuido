"""Genera los gráficos de las pruebas en docs/capturas/ a partir de pruebas/resultados/.

Uso:  python pruebas/graficos.py
"""
import csv
from collections import Counter
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

RAIZ = Path(__file__).resolve().parent.parent
RES = RAIZ / "pruebas" / "resultados"
SALIDA = RAIZ / "docs" / "capturas"
VERDE, GRIS = "#0b6e4f", "#9aa5a2"
plt.rcParams.update({"font.size": 11, "axes.spines.top": False, "axes.spines.right": False})


def agregado(nombre):
    with open(RES / f"{nombre}_stats.csv", encoding="cp1252") as f:
        return next(r for r in csv.DictReader(f) if r["Name"] == "Aggregated")


# ---- 1 API frente a 4 APIs ----
a4, a1 = agregado("carga_4apis"), agregado("carga_1api")
fig, ejes = plt.subplots(1, 2, figsize=(10, 4))
ejes[0].bar(["1 API", "4 APIs"], [float(a1["Requests/s"]), float(a4["Requests/s"])], color=[GRIS, VERDE])
ejes[0].set_title("Rendimiento (peticiones/s, más es mejor)")
for i, v in enumerate([float(a1["Requests/s"]), float(a4["Requests/s"])]):
    ejes[0].text(i, v, f"{v:.1f}", ha="center", va="bottom")
x = range(3)
etiquetas = ["p50", "p95", "p99"]
ejes[1].bar([i - 0.2 for i in x], [int(a1[k]) for k in ("50%", "95%", "99%")], 0.4, label="1 API", color=GRIS)
ejes[1].bar([i + 0.2 for i in x], [int(a4[k]) for k in ("50%", "95%", "99%")], 0.4, label="4 APIs", color=VERDE)
ejes[1].set_xticks(list(x), etiquetas)
ejes[1].set_title("Latencia (ms, menos es mejor)")
ejes[1].legend(frameon=False)
fig.suptitle("Carga concurrente: 40 usuarios, 90 s, 0 errores en ambos escenarios")
fig.tight_layout()
fig.savefig(SALIDA / "grafico-carga-1-vs-4-apis.png", dpi=130)

# ---- Caída de una VM: qué VM atendió cada petición ----
filas = [l.split() for l in (RES / "caida_vm_monitor.txt").read_text().splitlines() if l.strip()]
fig, ax = plt.subplots(figsize=(10, 3))
y = {"vm1": 1, "vm2": 2, "-": 0}
colores = [VERDE if f[1] == "200" else "#b00020" for f in filas]
ax.scatter(range(len(filas)), [y.get(f[2] if len(f) > 2 else "-", 0) for f in filas], c=colores, s=14, zorder=3)
ax.set_yticks([0, 1, 2], ["falla", "VM1", "VM2"])
ax.set_xlabel("petición (1 por segundo, ~7 min)")
inicio = next(i for i, f in enumerate(filas) if f[0] >= "16:41:07")
fin = next(i for i, f in enumerate(filas) if f[0] >= "16:43:53")
ax.axvspan(inicio, fin, color="#fdecee", zorder=0)
ax.text((inicio + fin) / 2, 2.35, "VM2 apagada", ha="center", color="#b00020")
conteo = Counter(f[1] for f in filas)
ax.set_title(f"Caída de una VM detrás del Azure Load Balancer: {conteo['200']}/{len(filas)} peticiones correctas")
ax.set_ylim(-0.5, 2.7)
fig.tight_layout()
fig.savefig(SALIDA / "grafico-caida-vm.png", dpi=130)
print("Gráficos generados en", SALIDA)
