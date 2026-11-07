"""Pruebas 1-3: carga concurrente contra el sistema publicado (Azure Load Balancer).

Mezcla de operaciones de pacientes:
  - consultar catálogo y franjas (público)
  - consultar sus solicitudes y citas (autenticado)

Cada paciente inicia sesión UNA vez y reutiliza su token (como una app
real). El login no se somete a carga: Nginx lo limita a 10/min por IP como
protección contra fuerza bruta y todas las peticiones de la prueba salen de
una sola IP.

Uso (sin interfaz, guarda CSV en pruebas/resultados):
  locust -f pruebas/locustfile.py --host https://<dominio> --headless -u 40 -r 10 -t 90s \
         --csv pruebas/resultados/carga_4apis
"""
import random
import threading

import requests
from locust import HttpUser, between, events, task

PACIENTES = ["pedro.castillo@correo.test", "sofia.navarrete@correo.test", "luis.chavez@correo.test",
             "gabriela.rios@correo.test", "andres.pazmino@correo.test"]
TOKENS: list[str] = []
_candado = threading.Lock()


@events.test_start.add_listener
def iniciar_sesiones(environment, **_):
    """5 logins antes de la carga (dentro del límite de Nginx)."""
    with _candado:
        if TOKENS:
            return
        for email in PACIENTES:
            r = requests.post(f"{environment.host}/api/auth/login", json={"email": email, "password": "Lab2026*"}, timeout=30)
            r.raise_for_status()
            TOKENS.append(r.json()["token"])


class Paciente(HttpUser):
    wait_time = between(0.5, 1.5)

    def on_start(self):
        self.cabecera = {"Authorization": f"Bearer {random.choice(TOKENS)}"}

    @task(4)
    def catalogo(self):
        self.client.get("/api/examenes/catalogo", name="GET catálogo")

    @task(3)
    def franjas(self):
        self.client.get("/api/citas/franjas?dias=7", name="GET franjas")

    @task(3)
    def mis_solicitudes(self):
        self.client.get("/api/solicitudes/mias", headers=self.cabecera, name="GET mis solicitudes")

    @task(2)
    def mis_citas(self):
        self.client.get("/api/citas/mias", headers=self.cabecera, name="GET mis citas")
