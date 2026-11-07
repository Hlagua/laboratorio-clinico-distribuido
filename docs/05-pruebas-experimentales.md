# Fase X — Pruebas y evaluación experimental

**Fecha de ejecución:** 2026-11-05, entre 16:19 y 17:10 UTC.
**Sistema bajo prueba:**

| Componente | Detalle |
|---|---|
| URL pública | `https://labclinico-henry.chilecentral.cloudapp.azure.com` (Azure Load Balancer `57.156.39.137`, certificado Let's Encrypt) |
| VM1 | `api1`, `api2`, `sync-vm1`, `nginx-vm1` |
| VM2 | `api3`, `api4`, `sync-vm2`, `nginx-vm2` |
| Máquinas virtuales | 2 VM B2als_v2 en Chile Central |
| Base principal | Azure SQL (Suiza Norte, oferta gratuita serverless) |
| Réplicas | Supabase (us-east-1) y MongoDB Atlas |

**Cliente de prueba:** el PC del equipo, en Ecuador. Las latencias medidas incluyen el viaje Ecuador → Chile (~0,2 s por HTTPS nuevo).

Todos los scripts están en [`pruebas/`](../pruebas) y sus salidas en [`pruebas/resultados/`](../pruebas/resultados), para que puedan repetirse en la defensa.

| # | Escenario del enunciado | Script / evidencia | Resultado |
|---|---|---|---|
| 1 | Funcionamiento con una sola API | `locustfile.py` → `carga_1api_*.csv` | ✅ 0 errores, 8,1 req/s, mediana 3,5 s |
| 2 | Funcionamiento con cuatro APIs | `locustfile.py` → `carga_4apis_*.csv` | ✅ 0 errores, **19,7 req/s**, mediana **0,55 s** |
| 3 | Solicitudes concurrentes | Locust (40 usuarios) + `concurrencia.py` | ✅ Sin protección hubo sobre-reserva; con protección, consistente |
| 4 | Interrupción de una API | Ráfagas con `api1` detenida | ✅ 16/16 atendidas por las otras 3 |
| 5 | Interrupción de una VM | `az vm stop` de VM2 + monitor → `caida_vm_monitor.txt` | ✅ 131/133; solo falló la petición en curso |
| 6 | Interrupción de Azure SQL | `caida_azure_sql.py` → `caida_azure_sql.json` | ✅ Contingencia automática; recuperación en ~8 s |
| 7 | Consulta de información desde Supabase | Ídem (`X-Origen-Datos: supabase`) | ✅ Login, resultados y catálogo; escrituras con 503 |
| 8 | Verificación de datos replicados en MongoDB Atlas | `verificar_replicacion.py` | ✅ 22/22 tablas y 5/5 colecciones consistentes |
| 9 | Consumo de los servicios REST y SOAP | `clientes/soap_cliente.py` → `soap_cliente.txt`, todas las pruebas REST | ✅ 3 operaciones SOAP desde un cliente independiente |
| 10 | Verificación de acceso seguro y roles | `seguridad.py` → `seguridad.json` | ✅ 17/17 (repetida sobre DuckDNS: 17/17) |
| — | Flujo completo | `flujo_completo.py` → `flujo_completo.json` y el PDF | ✅ 15/15 pasos, réplica en 4 s, 3 correos |

---

## 1–3. Carga concurrente: 1 API frente a 4 APIs

**Configuración:**
- **Herramienta:** Locust 2.47, 40 usuarios virtuales, 10 nuevos por segundo, 90 s por escenario, espera de 0,5 a 1,5 s entre acciones.
- **Mezcla de operaciones:** catálogo (público), franjas (público), mis solicitudes y mis citas (con JWT).
- **Escenario 1 API:** se detuvieron `api2`, `api3` y `api4`. Nginx de VM2 quedó sin APIs, así que la sonda del balanceador retiró a VM2; se verificó que solo respondía `api1`.

| Métrica (agregado) | **4 APIs** | **1 API** | Mejora |
|---|---|---|---|
| Peticiones atendidas en 90 s | 1 767 | 721 | ×2,45 |
| Rendimiento | **19,7 req/s** | 8,1 req/s | ×2,4 |
| Tiempo promedio | 655 ms | 3 029 ms | 4,6 veces menor |
| Mediana (p50) | **550 ms** | 3 500 ms | 6,4 veces menor |
| p95 | 850 ms | 4 200 ms | 4,9 veces menor |
| p99 | 1 400 ms | 4 400 ms | |
| Máximo | 3 771 ms | 6 897 ms | |
| Errores | **0** | **0** | |

| Endpoint | 4 APIs (p50 / p95) | 1 API (p50 / p95) |
|---|---|---|
| GET catálogo | 750 / 1 000 ms | 3 700 / 4 300 ms |
| GET franjas | 540 / 720 ms | 3 400 / 4 000 ms |
| GET mis solicitudes | 540 / 750 ms | 3 500 / 4 000 ms |
| GET mis citas | 540 / 760 ms | 3 500 / 4 200 ms |

**Interpretación:**
- Con una sola API, las peticiones se encolan en sus 2 procesos × 4 hilos de Gunicorn. La latencia sube hasta ~3,5 s aunque no se pierde ninguna petición.
- Con 4 APIs repartidas por Nginx y el Azure Load Balancer, la cola desaparece y el tiempo queda dominado por la red, de unos 0,5 s.
- La escalabilidad horizontal se comprueba: el rendimiento crece unas 2,4 veces con 4 veces más instancias. No llega a 4 veces porque cada consulta viaja hasta Azure SQL en Suiza (unos 0,2 s de ida y vuelta, ver R4).

**Login y fuerza bruta:** el login no se sometió a carga. Nginx lo limita a 10 por minuto por IP en cada VM (ráfaga de 5) como protección contra fuerza bruta, y toda la prueba sale de una sola IP. En un primer intento el limitador rechazó el 91 % de los logins, lo que confirma que funciona. Se cambió su respuesta a `429 Too Many Requests` y la prueba final hace un login por paciente y reutiliza el token.

## 3b. Reserva simultánea del mismo horario (Fase VI)

`pruebas/concurrencia.py` lanza **6 pacientes a la vez**, en hilos y conexiones independientes, sobre una franja con **3 cupos**, llamando a `dbo.sp_reservar_cita` en Azure SQL con 800 ms de espera artificial entre la lectura y la escritura.

| Modo | Reservadas | Rechazadas | Contador `ocupados` | Citas reales | Estado |
|---|---|---|---|---|---|
| **Sin protección** (lectura sin bloqueo) | 6 | 0 | **1** | **6** | ❌ Sobre-reserva (6 en 3 cupos) y actualización perdida (el contador dice 1) |
| **Con protección** (`UPDLOCK, HOLDLOCK`) | 3 | 3 ("La franja ya no tiene cupos disponibles") | 3 | 3 | ✅ Consistente |

Al terminar, el script cancela las citas de prueba y recalcula los contadores.

## 4. Interrupción de una API

Ráfagas de 16 peticiones a través del balanceador:

| Momento | Distribución | Errores | Tiempo promedio |
|---|---|---|---|
| Antes | api1=4, api2=4, api3=3, api4=5 | 0 | 1,54 s |
| `api1` detenida (`docker stop`) | api2=8, api3=5, api4=3 | **0** | 1,96 s |
| `api1` reiniciada | api1=5, api2=3, api3=3, api4=5 | 0 | 1,52 s |

**Hallazgo durante la prueba, ya corregido:** la primera ejecución dio 3 respuestas `502`. Nginx resolvía los nombres `api_a` y `api_b` solo al arrancar. Tras un redespliegue, los contenedores tenían otras IP internas y una de las dos entradas quedó apuntando a una dirección muerta, así que cada VM trabajaba con una sola API. Se corrigió con `resolve` y el resolver de Docker (`127.0.0.11`, renovación cada 5 s) en el `upstream`.

## 5. Interrupción de una máquina virtual

Monitor de 1 petición por segundo durante unos 7 minutos (`caida_vm_monitor.txt`), mientras se apagaba VM2 con `az vm stop`:

| Tramo (UTC) | Qué pasó | Respuestas |
|---|---|---|
| 16:40:30–16:41:07 | Normal | vm1 y vm2 alternan |
| 16:41:07 | VM2 apagada | **1 petición fallida** (la que estaba en curso) |
| 16:41:12–16:43:53 | Solo VM1 (la sonda `/health` retiró a VM2) | 100 % OK, todas por vm1 |
| 16:43:53 en adelante | VM2 encendida | El balanceador la reincorpora sola en ~10 s |

**Total:** 131 de 133 peticiones correctas. La otra falla (16:45:59) fue un tiempo de espera aislado, sin relación con la caída.

## 6–7. Interrupción de Azure SQL y consultas desde Supabase

**Simulación:** se agregó una regla **temporal** de salida en el NSG de cada VM que bloquea el tráfico hacia Azure SQL (etiqueta de servicio `Sql`, puertos 1433 y 11000–11999), y se cerraron con `KILL` las sesiones abiertas de `app_api` y `app_sync`.

> Primero se intentó quitando las reglas del firewall de Azure SQL, pero ese cambio tarda hasta 5 minutos en aplicarse y las VM seguían conectando. Por eso se usó la regla del NSG, que actúa en segundos.

| Momento | Mis solicitudes | Catálogo | Escritura (reservar cita) |
|---|---|---|---|
| Antes | 200, **azure** | 200, **azure** | Llega a Azure SQL (409 por cita duplicada) |
| Durante, 3 sondeos en ~1 min | 200, **supabase** | 200, **supabase** | **503 MODO_CONTINGENCIA** |
| Después de quitar el bloqueo | 200, **azure** (a los ~8 s) | 200, **azure** | Vuelve a Azure SQL |

Las 4 APIs pasaron a contingencia: en los sondeos respondieron api1, api2, api3 y api4 desde Supabase. Los sincronizadores registraron `origen_no_disponible` y luego `origen_recuperado`, y se pusieron al día solos.

## 8. Consistencia de la réplica

`pruebas/verificar_replicacion.py`, ejecutado después de todas las pruebas de caída:
- **Supabase:** las 22 tablas coinciden en número de filas, suma de claves primarias y última `updated_at`.
- **MongoDB:**

  | Colección | Azure SQL | MongoDB |
  |---|---|---|
  | `auditoria` | 47 | 47 |
  | `notificaciones` | 8 | 8 |
  | `resultados` | 4 | 4 |
  | `pagos` | 6 | 6 |
  | `stripe_eventos` | 0 | 0 |

  Además coinciden los valores del resultado más reciente.
- **Versión de Change Tracking:** Azure 63, Supabase 63 y Mongo 63, es decir, **sin retraso**.

**Relevo del sincronizador** (prueba del despliegue): al detener al líder `sync-vm1`, `sync-vm2` tomó el relevo en unos 38 s, que es lo que Azure SQL tarda en liberar el candado de la sesión. La replicación de un login hecho en VM2 llegó a MongoDB en unos 14 s.

## 9. Servicios REST y SOAP

- **REST:** todas las pruebas anteriores usan la API REST pública. La prueba de integración local cubre los 7 servicios (56/56).
- **SOAP:** el cliente independiente `clientes/soap_cliente.py` (zeep, en modo estricto) leyó el WSDL publicado y ejecutó:
  - `ListarExamenes`: 8 exámenes;
  - `ConsultarEstadoSolicitud`: `COMPLETADA`, pagado, 2/2;
  - `ConsultarResultados`: glucosa de 118 mg/dL marcada fuera de rango.

## 10. Acceso seguro y roles

`pruebas/seguridad.py`: **17/17**.
- **HTTPS:** certificado de Let's Encrypt válido, TLS 1.3, HSTS y redirección de HTTP a HTTPS.
- **Autenticación:** 401 sin token o con token falso; el login fallido no revela si el usuario existe.
- **Autorización:** 403 al paciente en endpoints de administrador o de laboratorio, y al ver datos de otro paciente.
- **Multirrol:** el médico usa `X-Rol-Activo: PACIENTE` para ver lo suyo; si pide un rol que no tiene, recibe 403.
- **Fuerza bruta:** el limitador devolvió 429 en 14 de 40 intentos rápidos.
- **SOAP:** clave inválida → Fault 401, clave válida → 200, XXE → rechazado.
- **Webhook de Stripe:** con firma falsa → 400.

## Flujo completo (rúbrica 7: cita, pago, examen, tratamiento y resultados)

`pruebas/flujo_completo.py`, 2026-11-05 19:45 UTC, sobre la plataforma publicada y con los tres roles. **15/15 pasos correctos:**

1. **Paciente nuevo:** se registra (cédula válida) e inicia sesión.
2. **Cita:** reservada a las 07:30, en estado `PENDIENTE_PAGO`.
3. **Solicitud:** SOL-2026-000008 con biometría y glucosa, USD 11,50.
4. **Stripe:** se crea una **sesión real de Checkout** (`cs_test_…`).
5. **Transferencia:** pago registrado con QR y confirmado por el administrador: `APROBADO`. La cita pasa a `CONFIRMADA`.
6. **Laboratorista:** toma de muestra y resultados de ambos exámenes.
7. **Médico** (actuando con `X-Rol-Activo: MEDICO`, porque también es paciente): registra observación y tratamiento.
8. **Paciente:** ve la solicitud `COMPLETADA` con la glucosa fuera de rango, descarga el PDF y ve su tratamiento.
9. **Réplica:** la solicitud aparece en Supabase y el documento con la observación en MongoDB a los **4 s**.
10. **Correos:** Mailjet envía al paciente `CITA_RESERVADA`, `PAGO_APROBADO` y `RESULTADO_LISTO`.

**Hallazgo:** sin la cabecera `X-Rol-Activo`, la API usa el rol de **menor privilegio** que el endpoint permite. Para un médico que también es paciente, ese rol es PACIENTE, y recibe 403 al consultar a otro paciente. Es intencional, porque es lo más seguro. Los clientes (Angular y el script) envían siempre el rol activo.

## Integraciones externas verificadas en la nube

- **Mailjet:** correo real enviado a `henrylagua1@gmail.com` (MessageID `576460794085623152`).
- **Stripe:** webhook `we_1UYTMhDBMsAArlFhxRWbnFes` registrado en modo prueba con 6 eventos. El pago completo desde Checkout se probará con el portal de pacientes.

## Limitaciones observadas

- **R4 — Latencia hacia Azure SQL:** el servidor está en Suiza Norte y las VM en Chile. Cada consulta tarda unos 0,2 s y abrir una conexión nueva entre 2 y 3 s, lo que limita la escalabilidad medida. Ya se mitigó con un **pool de conexiones** en cada API: el tiempo por petición bajó de ~3,4 s a ~1,1 s. La solución completa es mover la base a Chile Central, pero ahí no está disponible la oferta gratuita de Azure SQL (unos 5 USD al mes en el nivel Basic).
- **Relevo del sincronizador en ~38 s:** depende de cuánto tarda Azure SQL en liberar el candado de la sesión caída. Mientras tanto la réplica se retrasa, pero no se pierden cambios gracias a Change Tracking.
- **El login no se puede someter a carga desde una sola IP**, por diseño: el limitador lo protege contra fuerza bruta.
