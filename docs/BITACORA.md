# Bitácora del proyecto — Plataforma distribuida de laboratorio clínico

Memoria viva del proyecto: qué se hizo, qué falta, qué se cambió (en el código, en las VM y en la nube) y **por qué** se tomó cada decisión. Se actualiza al cerrar cada bloque de trabajo. La entrada más reciente va al final de la sección 5.

---

## 1. Estado actual (resumen)

| Fase del enunciado | Estado | Dónde |
|---|---|---|
| I. Análisis de requerimientos | ✅ Documento listo | `docs/01-analisis-requerimientos.md` |
| II. Base de datos (Azure SQL) | ✅ Desplegada en Azure SQL (`laboratorio`) | `database/azure-sql/` |
| III. Replicación (Supabase + MongoDB) | ✅ Corriendo en las 2 VM con líder y relevo automático (unos 38 s) | `sync-worker/`, `database/supabase/`, `database/mongodb/` |
| IV. Aplicaciones cliente (Flutter, Angular) | ✅ Publicadas: portal en `/` y sistema transaccional en `/admin/` | `web-admin/`, `portal-pacientes/` |
| V. APIs Flask y arquitectura distribuida | ✅ Desplegadas en la nube (api1–api4) | `api/`, `infra/` |
| VI. Control de concurrencia | ✅ Probado en BD y vía API | `sp_reservar_cita`, `docs/02` |
| VII. Servicios SOA, REST y SOAP | ✅ Listo, con cliente SOAP | `api/app/servicios/`, `clientes/` |
| VIII. Servicios externos (Mailjet, Stripe) | ✅ Correo real enviado · ✅ webhook de Stripe registrado · ⏳ falta un pago completo desde Checkout | `notificaciones.py`, `pagos.py` |
| IX. Seguridad y despliegue | ✅ DuckDNS + HTTPS real + Load Balancer + roles + limitador | `infra/` |
| X. Pruebas experimentales | ✅ Las 10 pruebas en la nube con evidencias | `docs/05-pruebas-experimentales.md`, `pruebas/` |
| Extra: base de conocimientos para diagnósticos | ✅ Desplegada en la nube; 18/18 pruebas | `docs/06-base-conocimiento.md`, `07_base_conocimiento.sql`, `conocimiento.py` |

## 2. Infraestructura

| Recurso | Dato | Notas |
|---|---|---|
| VM1 | `azureuser@68.211.136.29` (hostname `ad-2026`, IP privada 172.16.0.4/24) | Ubuntu 24.04, 2 CPU, 3.8 GB. Tiene Apache, MariaDB, WordPress y Netdata de la Unidad 2 (`henry-ad.duckdns.org`) **que no se tocan**. `ufw` activo. ✅ Docker 29.9.3 instalado; imágenes `laboratorio-api:1` y `laboratorio-sync:1` construidas en `/opt/laboratorio`. |
| VM2 | `azureuser@68.211.73.83` (**`lab-vm2`**, IP privada 172.16.0.5) | Creada el 2026-11-04 en **la misma red virtual que VM1**. B2als_v2 **normal (no Spot)**, Ubuntu 24.04, Trusted Launch, zona 1, Premium SSD de 30 GB. NSG propio `lab-vm2-nsg`: SSH solo desde la IP del equipo (192.188.46.70). ✅ Docker e imágenes en `/opt/laboratorio`. |
| ~~VM de Pedro~~ | `azureuser@68.211.136.42` (otra suscripción, `3ccb4eeb…`) | **Ya no se usa** (B1). No se le instaló nada. Pendiente: que Pedro quite la línea `claude-proyecto-lab-clinico` de su `~/.ssh/authorized_keys`. |
| Suscripción | Azure for Students `0f3feb79…6677`, grupo `ad-2026_grupo`, red `vnet-chilecentral-1` (172.16.0.0/16), subred `snet-chilecentral-1` | Azure CLI 2.92.0 instalado en el PC de Henry; él inicia sesión con `az login`. |
| Acceso SSH de Claude | Clave `~/.ssh/lab_clinico_vms` (en el PC de Henry) | Para revocarla, borrar la línea `claude-proyecto-lab-clinico` de `~/.ssh/authorized_keys` en cada VM. |
| Carpeta del proyecto en las VM | `/opt/laboratorio/` | Todo lo nuevo vive aquí. |
| Puertos del proyecto en las VM | 8080 (HTTP y sonda de salud), 8443 (HTTPS) | Los puertos 80 y 443 siguen siendo de Apache. |
| Azure Load Balancer | ✅ `lab-lb` (Standard), IP `lab-lb-ip` **57.156.39.137** (zonas 1–3), DNS `labclinico-henry.chilecentral.cloudapp.azure.com`; reglas 443→8443 y 80→8080; sonda HTTP 8080 `/health` cada 5 s (2 fallos) | Cuesta unos 0,025 USD/h mientras exista (más la IP). |
| Dominio del proyecto | ✅ **`labclinico-uta.duckdns.org`** → 57.156.39.137 (balanceador). Certificado Let's Encrypt para este dominio y para el de Azure (`labclinico-henry.chilecentral.cloudapp.azure.com`, de respaldo); vence 2027-02-03 | El token de DuckDNS está solo en `secretos/`. No hace falta cron: la IP del balanceador es fija. `henry-ad` (Unidad 2) no se tocó. |
| Azure SQL | Servidor `ad-2026-henry` · ✅ base **`laboratorio`** (GP Serverless Gen5 2 vCore, **oferta gratuita**: `useFreeLimit=true`; si se agota, se pausa, no cobra) con los scripts 01–04 y 06 ejecutados. Usuarios `app_api` y `app_sync` verificados. Firewall: reglas nuevas `lab-vm1` y `lab-vm2`. | La base `AppDistribuidas_2026_DB` de la Unidad 2 no se toca. Los scripts se ejecutan con `database/ejecutar_azure_sql.py` (token Entra, sin contraseña de admin). |
| Supabase | Proyecto `ad_proyecto` (ref `pdumrkfxcodrzrbcpqed`, AWS us-east-1), PostgreSQL 17.11 · ✅ esquema `lab` (24 tablas con RLS) y roles `lab_sync` (escritura) y `lab_lectura` (solo lectura) verificados | Conexión por el session pooler (puerto 5432); el usuario lleva el sufijo `.pdumrkfxcodrzrbcpqed`. |
| MongoDB Atlas | Proyecto `adProyecto`, cluster **`adMongo`** (`admongo.se5kpuq.mongodb.net`, MongoDB 8.0.37) · ✅ base `laboratorio` con 7 colecciones | Network Access: VM1, VM2 y el PC del equipo. Trae `sample_mflix` (datos de ejemplo de Atlas), que no se toca. |
| Mailjet | ✅ claves verificadas; remitente `henrylagua1@gmail.com` activo | Las claves están en `api/.env`, que no se sube al repositorio. |
| Stripe | ✅ Modo prueba · webhook `we_1UYTMhDBMsAArlFhxRWbnFes` → `https://labclinico-uta.duckdns.org/api/pagos/webhook` | Falta un pago con tarjeta hecho por una persona en Checkout. |

## 3. Reglas acordadas

1. **En las VM solo se agregan cosas nuevas.** No se detiene ni se edita Apache, MariaDB, WordPress, PHP, los crontabs existentes, `/etc/letsencrypt`, el hostname ni las reglas NSG existentes. Tampoco se ejecuta `apt upgrade` ni se reinician las VM.
2. **Las credenciales nunca van por el chat ni al repositorio.** Viven solo en los archivos `.env` (permisos 600), que `.gitignore` excluye.
3. **Las acciones en las VM o en la nube se planifican y se aprueban antes de ejecutarse.**
4. **Todos los datos clínicos son ficticios.**

## 4. Decisiones y su justificación

| # | Decisión | Por qué | Alternativas descartadas |
|---|---|---|---|
| D1 | **Change Tracking + sincronizador propio en Python** para replicar hacia Supabase y MongoDB | Funciona en cualquier nivel de Azure SQL, detecta los DELETE y, si el sincronizador se apaga, al volver se pone al día solo (retención de 14 días). Responde a lo que pidió el ingeniero. | CDC (exige S3 o vCore, más costoso), Debezium/Kafka (demasiado pesado), polling por `updated_at` (no ve los borrados), triggers + outbox (más código que mantener) |
| D2 | **Una persona, una cuenta, varios roles** (`persona` → `usuario` → `usuario_rol`, con perfiles `paciente`, `medico` y `laboratorista`) | El ingeniero indicó que un médico también puede ser paciente. Se valida el conflicto de interés: nadie se trata ni registra resultados a sí mismo. | Una tabla por tipo de usuario con cuentas separadas |
| D3 | Se conservan las tablas `permiso` y `rol_permiso` | El enunciado pide explícitamente "usuarios, roles y permisos". | Quitarlas (lo sugirió Argon por simplicidad) |
| D4 | **Stripe** como pasarela (modo prueba) | Permite reembolsos totales y parciales, tiene tarjetas de prueba para simular rechazos, y Stripe CLI permite probar los webhooks. Ecuador no permite **activar** cuentas reales, pero el modo prueba no requiere activación. | PayPal Sandbox (simular rechazos es más engorroso) |
| D5 | **Mailjet** para los correos | Elección del equipo; el enunciado acepta "Brevo u otro equivalente". | Brevo |
| D6 | Los correos se encolan en la tabla `notificacion` y un hilo los envía | Si Mailjet falla, la operación de negocio no se pierde y se reintenta hasta 5 veces. Varias instancias pueden enviar sin duplicar gracias a `UPDLOCK + READPAST`. | Enviar el correo dentro de la petición |
| D7 | **Circuit breaker** en las APIs: si Azure SQL falla, las lecturas pasan a Supabase y las escrituras responden 503 | Es lo que pide la Fase III/V: seguir consultando en contingencia, en solo lectura. Supabase usa un rol `lab_lectura` que es de solo lectura incluso a nivel de PostgreSQL. | Conmutación manual |
| D8 | Concurrencia con `UPDLOCK/HOLDLOCK`, `CHECK (ocupados <= capacidad)` e índice único filtrado | Probado: sin protección quedan 4 citas en una franja de 3; con protección, la tercera se rechaza. | Solo validar en la aplicación |
| D9 | SOAP escrito a mano (WSDL + `defusedxml`) en lugar de spyne | Spyne da problemas con Python 3.12. El WSDL propio queda claro para la defensa y `defusedxml` bloquea ataques XXE. Se validó con el cliente zeep en modo estricto. | spyne |
| D10 | **Nginx del proyecto en 8080/8443 y el Load Balancer traduce 443→8443** | Respeta la regla 1: Apache sigue en 80/443 sin tocarse y el usuario final igual entra por `https://dominio` (puerto 443 del balanceador). | Detener Apache para liberar 80/443 (el usuario no lo aceptó) |
| D11 | Certificado Let's Encrypt por **DNS-01 de DuckDNS**, guardado en `/opt/laboratorio/letsencrypt` | El balanceador puede enviar la validación HTTP a cualquiera de las VM; DNS-01 no depende de eso. La carpeta aislada no se mezcla con `/etc/letsencrypt`. | HTTP-01, o guardar en `/etc/letsencrypt` |
| D12 | El sincronizador corre en ambas VM, pero solo una es líder (`sp_getapplock`) | Si cae una VM, la otra toma el relevo sin intervención. | Una sola instancia, que sería un punto único de falla |
| D13 | Se copia en `resultado_valor` el rango de referencia vigente, y en `solicitud_detalle` el precio | El histórico no debe cambiar si cambia el catálogo (sugerencia de Argon que se adoptó). | Leer siempre del catálogo |
| D14 | Docker se instala desde el repositorio oficial de Docker (`download.docker.com`) | Es la versión con `docker compose` v2 y `buildx`. Solo agrega paquetes; no se actualiza ningún paquete existente. | `docker.io` de Ubuntu (versión más antigua) |
| D15 | Las contraseñas internas (usuarios de base, JWT, clave SOAP) las genera Claude al azar en `secretos/credenciales.env` | Evita contraseñas débiles o repetidas y que viajen por el chat. El equipo solo llena las cuentas externas. | Que el equipo invente cada contraseña |
| D16 | La VM2 se crea **nueva, en la suscripción de Henry, dentro de la red de VM1** y la VM de Pedro deja de usarse | Resuelve B1: el Load Balancer exige que las VM estén en la misma red virtual (y por lo tanto en la misma suscripción). | Traffic Manager o Front Door (la rúbrica pide Azure Load Balancer); peering (no sirve para el backend pool) |
| D17 | La VM2 es de prioridad **normal (no Spot)** | La cuota Spot de la suscripción es de 3 vCPU y VM1 ya usa 2. Cuesta unos 2,3 USD más al mes con 6 h diarias, y además garantiza que al menos una VM no sea desalojada durante la presentación (mitiga R1). | Pedir más cuota Spot (trámite incierto) |
| D18 | Base `laboratorio` en el servidor Azure SQL existente con la **oferta gratuita** (100 000 s vCore al mes, 32 GB) y pausa automática al agotarse | Costo cero, y la pausa evita cargos inesperados. Se reutiliza el servidor de la Unidad 2 sin tocar su base. | Nivel Basic (unos 5 USD al mes); un servidor nuevo |
| D19 | Certificado autofirmado provisional hasta tener el dominio DuckDNS | Nginx necesita un certificado para levantar el puerto 8443 y permite probar todo ya. El script no sobrescribe un certificado real. | Esperar al dominio para desplegar |
| D20 | Imagen compartida por las 2 APIs de cada VM (`image: laboratorio-api:1`) | Una sola construcción, menos disco y versiones idénticas en ambas instancias. | Construir una imagen por servicio |
| D21 | Base de datos en la misma región que las VM: **intentado, no aplicado** | Azure no ofrece la base gratuita en Chile Central (`ProvisioningDisabled`). Se creó el servidor vacío `lab-sql-chile-henry` (sin costo) por si se decide pagar el nivel Basic (unos 5 USD al mes). | Mantener Suiza Norte con un pool de conexiones (D22) |
| D22 | **Pool de conexiones** a Azure SQL en cada API (máx. 8 por proceso, se valida tras 60 s ociosa, se descarta a los 600 s, un reintento en lecturas, sin reintento en escrituras) y timeout de conexión de 8 s | Abrir una conexión a Suiza cuesta 2–3 s; con el timeout de 3 s había falsas caídas. El tiempo por petición bajó de ~3,4 s a ~1,1 s. | Una conexión por petición |
| D23 | Nginx con `resolve` y el resolver de Docker en el `upstream` | Sin esto guardaba las IP del arranque y, tras recrear contenedores, enviaba tráfico a IP muertas (502 en la prueba de caída). | Reiniciar Nginx en cada despliegue |
| D24 | Certificado por **HTTP-01 con reto compartido** entre VM (si el archivo no está en una VM, Nginx lo pide a la otra por la red privada, una sola vez) | Funciona detrás del balanceador sin depender del token de DuckDNS y sirve para cualquier dominio que apunte al balanceador. | DNS-01 de DuckDNS (DuckDNS no funcionaba) |
| D25 | Dominio provisional con la **etiqueta DNS de Azure** en la IP del balanceador | Gratuito e inmediato; permitió el certificado real, el webhook de Stripe y las pruebas mientras DuckDNS no funciona. | Esperar a DuckDNS |
| D26 | La caída de Azure SQL se simula con una **regla NSG temporal de salida** más `KILL` de sesiones | Los cambios del firewall de Azure SQL tardan hasta 5 min; el NSG actúa en segundos y se revierte sin tocar nada existente. | Quitar las reglas del firewall de Azure SQL |
| D27 | Nginx responde **429** cuando se supera el límite de login, y la prueba de carga reutiliza tokens | 429 es el código correcto para un límite de peticiones; el login con bcrypt está protegido a propósito contra fuerza bruta. | 503 (el código por defecto) |
| D28 | El portal Flutter se compila con **CanvasKit servido desde el propio dominio** (`--no-web-resources-cdn`) | Desde el CDN de Google el motor no llegaba y la página quedaba en blanco. Además elimina una dependencia externa. | CDN de gstatic (valor por defecto) |
| D29 | **DuckDNS como dominio principal** y el dominio de Azure como respaldo en el mismo certificado | Cumple la rúbrica (DuckDNS) sin perder un acceso alternativo. Con HTTP-01 no se necesita el token de DuckDNS para renovar. | Solo uno de los dos |
| D30 | Sin `X-Rol-Activo`, la API usa el rol de **menor privilegio** permitido | Es lo más seguro para una persona multirrol; los clientes envían siempre el rol activo. | Usar el rol de mayor privilegio |
| D31 | Repositorio **público** en GitHub sin credenciales ni el enunciado del docente | El equipo necesita ver las investigaciones, decisiones y evidencias. Los secretos viven solo en `secretos/` y en los `.env` (excluidos); antes de publicar se escanearon los 155 archivos buscando cada valor real de credencial y patrones de claves. El PDF del enunciado es material del curso. | Repositorio privado |
| D32 | Base de conocimientos como **sistema experto basado en reglas**, sin IA | Lo pidió el equipo ("sin lo de la IA"). Las reglas son explicables (cada sugerencia muestra el valor que la disparó), deterministas y comprobables; no cuestan por consulta y no sacan datos clínicos de la plataforma. | Modelo de lenguaje o modelo entrenado |
| D33 | El sistema **sugiere** y el médico decide; la precisión se mide con sus respuestas | Responsabilidad clínica del médico. Aceptar enlaza el tratamiento y descartar exige un motivo; aceptadas / respondidas da la precisión de cada regla, para afinarla o desactivarla. | Diagnóstico automático |
| D34 | Reglas, diagnósticos y sugerencias en **Azure SQL** (replicados a Supabase); guías clínicas en **MongoDB** | Las reglas son relacionales y transaccionales (FK al parámetro del examen y a la solicitud), y en contingencia se siguen leyendo. Las guías son documentos de estructura libre. | Todo en Mongo; todo en SQL |
| D35 | Al agregar tablas a la réplica, **forzar una carga completa** (borrar `sync_estado`) | El sincronizador guarda una sola versión por destino. Si ya pasó la versión en que se cargaron las tablas nuevas, no las ve como cambios. La carga completa es idempotente (upserts) y tardó unos 35 s. | Versión por tabla (cambio mayor en el sincronizador) |

## 5. Registro cronológico

### 2026-11-03 / 04 — Diseño y base de datos
- Se analizó el enunciado y se resolvieron las dudas: GitHub **no** es obligatorio (se pide el código fuente, no un repositorio); Stripe sí permite reembolsos.
- Se diseñó el modelo de datos (25 tablas) con soporte multirrol.
- Scripts de Azure SQL: esquema, Change Tracking, 15 procedimientos, datos de prueba, consultas de evidencia y usuarios de mínimo privilegio.
- Esquemas de Supabase (`lab`, con FK diferidas, RLS y roles `lab_sync` y `lab_lectura`) y de MongoDB (colecciones con validador).
- Sincronizador en Python, con prueba local completa (carga inicial, apagado y cambios, reencendido): **pasó**.
- La revisión cruzada con Gemini 4 Argon (CLI de Antigravity) aportó las decisiones D1, D3 y D13 y la lectura en SNAPSHOT.
- Documentos de las fases I, II y III, y un diccionario de datos generado desde la base.

### 2026-11-04 — APIs
- APIs Flask con 7 servicios REST + SOAP, JWT multirrol, circuit breaker, Stripe, Mailjet, PDF (ReportLab) y QR.
- Se verificó con el documento de la Unidad 2 que las claves de Mailjet funcionan; se guardaron solo en `api/.env`.
- `docker-compose.yml` único para ambas VM, plantilla de Nginx y script del certificado.
- Prueba de integración local: **56/56**. Encontró y corrigió 4 errores: el webhook de Stripe v16, un choque de nombres de parámetros en `ejecutar_sp`, la generación de franjas que cruzaba la medianoche y el nombre de la cabecera SOAP en zeep.
- Se agregaron al SQL los procedimientos `sp_marcar_pago_expirado`, `sp_crear_usuario` y `sp_crear_tipo_examen`. `sp_confirmar_pago` ahora permite pasar de RECHAZADO a APROBADO cuando el paciente reintenta en la misma sesión.

### 2026-11-04 — Acceso a las VM y plan de despliegue
- Se creó la clave SSH dedicada y el usuario la autorizó en ambas VM; el acceso se verificó con `sudo` sin contraseña.
- Hallazgo: ambas VM son copias de la VM de la Unidad 2, con Apache ocupando 80 y 443.
- Se acordaron la regla 1 (solo agregar) y la decisión D10 (puertos 8080/8443 detrás del balanceador).

### 2026-11-04 — Bitácora, inventario de las VM y Docker en la VM1
- Se crea esta bitácora a pedido del equipo.
- **Fase 0 (inventario de solo lectura).** Hallazgos:
  - **B1 (bloqueante):** las dos VM tienen la misma IP privada `172.16.0.4/24`, por lo que están en **redes virtuales distintas**. La VM2 además tiene el certificado de `pedro-ad.duckdns.org`. Según la documentación de Microsoft, los miembros del backend pool del Azure Load Balancer deben estar en **la misma red virtual** que el balanceador ([backend pool management](https://learn.microsoft.com/en-us/Azure/load-balancer/backend-pool-management), [componentes](https://docs.azure.cn/en-us/load-balancer/components)). Con la topología actual no se pueden balancear ambas VM con un Azure Load Balancer.
  - En la VM1 `ufw` está activo. Docker publica sus puertos con sus propias reglas de iptables, que ufw no filtra; las reglas nuevas del NSG controlan el acceso a 8080 y 8443.
  - Las dos VM tienen libres los puertos 8080 y 8443, unos 3 GB de RAM disponibles y el cron de DuckDNS de la Unidad 2 (no se toca).
- `infra/docker-compose.yml` ahora publica 8080:80 y 8443:443, y los certificados quedan en `infra/letsencrypt/` (decisiones D10 y D11).
- **Fase 1 en la VM1:** Docker 29.9.3 y Compose v5.7.0 instalados; `azureuser` agregado al grupo `docker`. Después de instalar se verificó que Apache, MariaDB y Netdata siguen activos y que WordPress responde.
- **Fase 2 en la VM1:** proyecto copiado a `/opt/laboratorio` (sin ningún `.env`); imágenes construidas y verificadas (driver ODBC 18 presente, imports correctos).
  - Corrección: en el Dockerfile del sincronizador, el usuario `sync` ya existe en Debian; se renombró a `sincronizador`.
- Se creó `secretos/credenciales.env` (excluido del repositorio) con las contraseñas internas generadas y los campos para que el equipo llene las cuentas externas.

### 2026-11-04 — Suscripciones y costos
- Metadatos de Azure leídos desde dentro de las VM (servicio de metadatos, sin iniciar sesión en Azure):
  - **VM1:** suscripción `0f3feb79…6677`, Chile Central, `Standard_B2als_v2`, **Spot**, disco Premium SSD de 30 GB, grupo `ad-2026_grupo`.
  - **VM2:** suscripción `3ccb4eeb…f401`, distinta, con los mismos tamaño, región y prioridad Spot. Esto **confirma B1**: es de otra cuenta.
- **Riesgo R1:** las VM Spot pueden ser **desalojadas por Azure en cualquier momento**, por ejemplo durante la presentación. En Chile Central el precio normal de la B2als_v2 es solo un 30 % mayor (0,0526 frente a 0,0400 USD/h).
- Estimación con precios públicos de Azure (Chile Central):

| Recurso | USD/hora | 24/7 al mes | Nota |
|---|---|---|---|
| VM B2als_v2 Spot | 0,040 | 29,2 | Solo se cobra encendida |
| VM B2als_v2 normal | 0,0526 | 38,4 | |
| Disco Premium P4 (30 GB) | — | 7,1 | Se cobra aunque la VM esté apagada |
| IP pública Standard | 0,005 | 3,65 | Se cobra siempre |
| Azure Load Balancer Standard | 0,025 | 18,25 | Se cobra mientras exista |
| Azure SQL | — | 0 | Oferta gratuita (100 000 s vCore al mes) o Basic ≈ 5 |

- **Conclusión:** con 2 VM y el balanceador encendidos 24/7 se gastarían unos **100 USD al mes**, lo que no es viable. Apagando (desasignando) las VM cuando no se trabaja (unas 6 h al día) y creando el balanceador solo para las últimas 2 semanas, se gastarían unos **45–50 USD**, que sí es viable si queda saldo suficiente.

### 2026-11-04 — VM2 nueva en la red de VM1 (resuelve B1)
- Se instaló Azure CLI 2.92.0 en el PC (winget, MSI oficial de Microsoft) y Henry inició sesión con `az login` en su navegador.
- Revisión de solo lectura: la red `vnet-chilecentral-1` y el NSG `ad-2026-nsg` de VM1 (reglas 80, 443 y 22 abiertas a todos, no se tocan). Cuota en Chile Central: vCPU Spot 2/3, vCPU normales 0/6.
- La cuota Spot no alcanza para otra VM Spot, así que se decidió D17 (VM normal).
- Recursos **nuevos** creados en `ad-2026_grupo`, todos con la etiqueta `proyecto=laboratorio`:
  - NSG `lab-vm2-nsg`, con la regla `SSH-solo-equipo` (TCP 22 solo desde 192.188.46.70/32);
  - IP pública Standard estática `lab-vm2-ip` (68.211.73.83);
  - VM `lab-vm2` (172.16.0.5), con su NIC y el disco `lab-vm2-disco`.
- Verificado: SSH con la clave del proyecto, `sudo`, y **ping por la red privada hacia VM1 (172.16.0.4): OK**.
- En `lab-vm2`: Docker 29.9.3, el proyecto en `/opt/laboratorio` (sin `.env`) y las imágenes `laboratorio-api:1` y `laboratorio-sync:1` construidas.
- **B1 resuelto.**

### 2026-11-04 — Script de encendido/apagado
- `infra/vms.ps1` (`estado`, `apagar`, `encender`) usa Azure CLI. "Apagar" desasigna la VM para que no se cobre el cómputo.
- Ambas VM se desasignaron a pedido de Henry; estado verificado: `VM deallocated`. Las IP públicas se conservan porque son estáticas.

### 2026-11-05 — Credenciales y verificación
- Henry entregó las credenciales de Supabase, Stripe y el usuario de Atlas. Se guardaron solo en `secretos/credenciales.env`.
  - **Nota:** se pegaron en el chat. Al terminar el proyecto conviene cambiarlas (contraseña de Supabase, usuario de Atlas y rotar la clave de Stripe).
- Azure SQL no necesita la contraseña de administrador: Henry es administrador Entra ID de `ad-2026-henry` y se usa el token de `az login`.
- Verificaciones de solo lectura:
  - **Supabase:** conexión OK por ambos poolers (PostgreSQL 17.11) y proyecto vacío.
  - **Stripe:** cuenta OK en modo prueba (país US, porque Ecuador no se puede activar; ver D4).

### 2026-11-05 — Bases en la nube y primera replicación real
- Atlas: Henry creó el cluster `adMongo` y permitió las IP de las 2 VM y del PC. Conexión verificada (MongoDB 8.0.37).
- **Azure SQL:** se creó la base **`laboratorio`** con la **oferta gratuita** (D18). Se agregó `database/ejecutar_azure_sql.py`, que ejecuta los scripts con el token Entra de `az login`. Scripts 01, 02, 03, 04 y 06 ejecutados sin errores.
- **Supabase:** se ejecutaron `01_esquema_replica.sql` y `02_roles.sql` con las contraseñas generadas: 24 tablas, RLS activo, y los roles `lab_sync` y `lab_lectura` entran por el pooler (este último en solo lectura).
- **Atlas:** se ejecutó `init_mongo.js` y la base `laboratorio` quedó con 7 colecciones.
- Reglas **nuevas** en el firewall de Azure SQL: `lab-vm1` (68.211.136.29) y `lab-vm2` (68.211.73.83). Las reglas existentes se mantienen.
- **Primera replicación real**, desde el PC y con el usuario `app_sync`:
  - Supabase recibió una carga completa de 248 filas, idéntica a Azure SQL.
  - Mongo recibió 41 eventos de auditoría, 8 notificaciones, 4 resultados y 6 pagos.
  - Versión de Change Tracking 52.
- **Observación R2:** la carga completa hacia Supabase tardó unos 35 s (unos 140 ms por fila, por la latencia hacia us-east-1). Los lotes incrementales son pequeños y no se ven afectados. Queda como mejora opcional agrupar los upserts.

### 2026-11-05 — Despliegue en las 2 VM
- **Encendido de VM2:** el primer intento falló con `ZonalAllocationFailed` (Azure no tenía capacidad de B2als_v2 en la zona 1 de Chile Central). El reintento funcionó. Ver riesgo R3.
- `infra/generar_env.py` genera, desde `secretos/credenciales.env`, los `.env` de despliegue en `secretos/despliegue/`: `api.env` (usuario `app_api`, Supabase `lab_lectura`), `sync.env` (`app_sync`, `lab_sync`, Atlas), `vm1.env` y `vm2.env`. En las VM quedan con permisos 600.
  - Las claves de Mailjet se movieron también a `secretos/credenciales.env`.
- `docker-compose.yml`: las dos APIs de cada VM comparten la imagen `laboratorio-api:1`, y el sincronizador usa `laboratorio-sync:1` (D20).
- Mientras no exista el dominio DuckDNS se usa un **certificado autofirmado provisional** (`infra/certificado_temporal.sh`, dominio `laboratorio.pendiente`) (D19).
- Reglas **nuevas** en los NSG: `Laboratorio-8080-8443` (prioridad 330, origen Internet) en `ad-2026-nsg` y en `lab-vm2-nsg`. Las reglas existentes no se tocaron.
- Páginas provisionales en `web/portal` y `web/admin`, hasta que estén Flutter y Angular.
- **Errores encontrados y corregidos:**
  1. Los `.env` generados en Windows tenían saltos de línea `

`, y el dominio llegaba a Linux con un `
` pegado, así que Nginx no encontraba el certificado. Se corrigió con `newline="
"` en `generar_env.py`.
  2. El sincronizador dejaba la sesión en aislamiento SNAPSHOT; en el ciclo siguiente, `sp_expirar_citas_pendientes` (que usa READPAST) fallaba, el líder perdía la conexión y el liderazgo saltaba de una VM a otra. Se corrigió restableciendo READ COMMITTED después de cada lote (`origen.py`). La prueba local no lo detectó porque ejecutaba un solo ciclo.
  3. El sincronizador en espera registraba "en_espera" cada 5 s. Ahora solo registra los cambios de rol (`lider` o `en_espera`).
- **Evidencias del despliegue:**
  - 8 peticiones a cada VM: `api1`/`api2` atienden en vm1 y `api3`/`api4` en vm2, con 2 peticiones cada una (Nginx reparte por turnos). Cabeceras `X-Instancia` y `X-VM`.
  - `/api/estado` en ambas VM: Azure SQL y Supabase disponibles, modo normal.
  - Un login hecho en VM2 (`api3`) genera auditoría en Azure SQL, y **se replica a MongoDB en unos 14 s** (sync_log: INCREMENTAL, versión 52→54). El mismo token JWT sirve en VM1.
  - **Relevo del sincronizador:** se detuvo `sync-vm1` (líder) a las 15:30:49 y `sync-vm2` tomó el liderazgo a las 15:31:27, **unos 38 s después** (el tiempo que tarda Azure SQL en liberar la sesión). Al volver, `sync-vm1` quedó en espera.
  - Apache y WordPress en VM1 siguen respondiendo en el puerto 80 (HTTP 301, igual que antes). Uso de RAM: queda unos 2,7 GB libre en VM1.

- Al cerrar la sesión de trabajo, ambas VM quedaron **desasignadas**. Al encenderlas, los contenedores arrancan solos (`restart: unless-stopped`).

### 2026-11-05 — Load Balancer, HTTPS real, integraciones y pruebas en la nube
- **Azure Load Balancer** creado (D25): 12 peticiones repartidas entre las 4 APIs y las 2 VM. Las NIC de las VM se agregaron al backend; Apache sigue respondiendo directo en las IP de las VM.
- **Certificado Let's Encrypt real** con el reto compartido (D24): validado en ambas VM y por el balanceador.
  - Error: el script provisional no "veía" el certificado de root y abortaba el despliegue. Se corrigió con `sudo test`.
  - Error: un apóstrofo en `certificado.sh` rompía la sintaxis de bash. Corregido.
- **Stripe:** webhook creado por la API, con su secreto en `api.env`. **Mailjet:** correo real enviado a Henry.
- **Hallazgos de rendimiento y disponibilidad, todos corregidos:**
  - R4: Azure SQL está en Suiza Norte, a 2–3 s por conexión. Se resolvió con el pool (D22). La base en Chile Central no es posible gratis (D21).
  - Nginx tenía IP de upstream obsoletas: 502 en la caída de una API (D23).
  - El limitador de login devolvía 503 en la prueba de carga (D27).
- **Pruebas de la Fase X:** las 10 completas. Detalle en `docs/05-pruebas-experimentales.md` y salidas en `pruebas/resultados/`.

  | Prueba | Resultado |
  |---|---|
  | 4 APIs | 19,7 req/s, p50 550 ms, 0 errores |
  | 1 API | 8,1 req/s, p50 3,5 s, 0 errores |
  | Caída de una API | 16/16 OK |
  | Caída de una VM | 131/133; solo falló la petición en curso |
  | Caída de Azure SQL | Supabase responde y las escrituras dan 503; recuperación en ~8 s |
  | Réplica | Consistente (22/22 tablas, 5/5 colecciones, versión 63 en los 3) |
  | Concurrencia en Azure SQL | Sin protección, 6 citas en 3 cupos con contador 1; con protección, 3+3 rechazadas |
  | Seguridad | 17/17 |
  | SOAP desde cliente independiente | OK |
- Scripts reutilizables en `pruebas/`: `comun.py`, `caida_azure_sql.py`, `verificar_replicacion.py`, `concurrencia.py`, `locustfile.py`, `seguridad.py`.
- VM desasignadas al terminar. **El balanceador y su IP siguen existiendo** (unos 0,6 USD al día).

### 2026-11-05 — Aplicaciones cliente
- **Angular 22** (`web-admin/`), el sistema transaccional, se publica en `/admin/`:
  - Pantallas: login con rol activo, inicio con indicadores, agenda, solicitudes, detalle (toma de muestra, registro de resultados por parámetro con rango de referencia, observación médica, PDF), nueva solicitud, pacientes y tratamientos, pagos (confirmar transferencia, reembolso), usuarios y roles, catálogo y franjas, reportes (ingresos con PDF, exámenes más pedidos), auditoría y correos.
  - Detalles técnicos: sin Zone.js (usa signals), un interceptor (token, `X-Rol-Activo`, aviso de contingencia, cierre de sesión ante 401) y guardas por rol.
  - Compilación: 76 kB comprimidos iniciales; cada pantalla se carga cuando se abre.
  - Probado en local (API Flask + LocalDB):
    - el administrador ve todas sus pantallas con datos;
    - el laboratorista registró una toma de muestra y un resultado (densidad fuera de rango marcada; solicitud COMPLETADA);
    - el médico ve el historial y los tratamientos.
- **Flutter 3.47** (`portal-pacientes/`), el portal de pacientes, se publica en `/`:
  - Pantallas: inicio público con catálogo, registro (cédula validada) e ingreso; panel con mis citas (reservar por día y franja, cancelar), mis exámenes (solicitar, resultados con valores fuera de rango, PDF, pago con Stripe Checkout o transferencia con QR), tratamientos y pagos; página de retorno de Stripe (`/pagos/resultado`) que consulta el estado hasta que llega el webhook; aviso de contingencia.
  - `flutter analyze` sin observaciones. Probado en local: la página pública carga el catálogo desde la API.
- Desarrollo local: `.claude/launch.json` (api-local, admin-dev, portal-dev). En desarrollo el portal usa `--dart-define=API=...` y CORS; en producción comparte dominio con la API y no necesita CORS.
- Henry pidió apagar las VM: confirmado, ambas desasignadas.

### 2026-11-05 (tarde) — Frontends en la nube, flujo completo y DuckDNS
- Angular y Flutter compilados para producción y **desplegados en ambas VM** (`/opt/laboratorio/web/admin` y `web/portal`). Se reemplazó el contenido, no la carpeta, porque Nginx la monta. Las rutas profundas (`/admin/solicitudes/5`, `/pagos/resultado`) responden 200.
- **Fallo encontrado:** el portal quedaba en blanco porque CanvasKit no llegaba desde el CDN. Se corrigió con D28.
- **Flujo completo en la nube** (`pruebas/flujo_completo.py`): 15/15 pasos, réplica en 4 s y 3 correos reales a `henrylagua1+paciente4824@gmail.com`. Ver `docs/05`.
  - El primer intento dejó a medias SOL-2026-000007 (pagada y con resultados, sin tratamiento) porque el script no enviaba el rol activo del médico (D30). Son datos de prueba; se dejaron.
- **DuckDNS:**
  - Henry creó `labclinico-uta`; la IP se apuntó al balanceador con la API de DuckDNS (`OK … UPDATED`).
  - Nuevo certificado con ambos dominios (D29); `DOMINIO_PRINCIPAL` y `URL_PORTAL` pasaron a DuckDNS en ambas VM.
  - El webhook de Stripe se actualizó al nuevo dominio.
  - Verificado desde Internet: TLS válido, portal, `/admin/`, API, SOAP y las 4 APIs. `seguridad.py` dio **17/17 sobre DuckDNS**.
- **Informe técnico final:** `docs/00-informe-tecnico.md`.
- VM desasignadas al terminar.

### 2026-11-06 — Publicación del repositorio
- Repositorio público: **https://github.com/Hlagua/laboratorio-clinico-distribuido** (rama `main`).
- `.gitignore` raíz: excluye `secretos/`, `*.env` (salvo `.env.example`), certificados, entornos, compilados, `.claude/` y el enunciado.
- `README.md` con un índice de investigaciones y decisiones, la arquitectura, las capturas, la tabla de cumplimiento de la rúbrica y cómo ejecutar el proyecto.
- `docs/capturas/`: 8 capturas de las aplicaciones y 2 gráficos generados con `pruebas/graficos.py` (1 frente a 4 APIs, caída de una VM).
- **Escaneo de secretos antes de publicar:** encontró la clave SOAP escrita en `pruebas/concurrencia_real.py` (script nuevo del equipo). Se reemplazó por `c["SOAP_API_KEY"]` y se corrigió el XML para enviar la clave dentro de `<lab:Credencial>`, como define el WSDL; sin eso la API respondía 401. Escaneo final: 0 secretos.

### 2026-11-09 — Base de conocimientos para diagnósticos (sin IA)
- Pedido del ingeniero; el equipo eligió la opción "sin lo de la IA" (D32–D34). Detalle en `docs/06-base-conocimiento.md`.
- **Azure SQL** (`07_base_conocimiento.sql`):
  - 5 tablas con Change Tracking, la vista de precisión y 3 procedimientos;
  - semilla: 10 diagnósticos CIE-10 con protocolo y 11 reglas.
- **Supabase:** `03_base_conocimiento.sql`, con tablas espejo y RLS.
- **MongoDB:** 5 guías clínicas en `laboratorio.guias_clinicas`.
- **API** (`/api/conocimiento`): motor de reglas, sugerencias, respuesta del médico, administración de reglas y guías. Registrar un resultado dispara la evaluación.
- **Angular:** panel de sugerencias en el detalle de la solicitud; página "Base de conocimientos".
- **Despliegue:** nuevo script `infra/desplegar.sh`, reutilizable; ambas VM actualizadas con health OK.
- **Fallos encontrados y corregidos:**
  - `sp_guardar_regla` reutilizaba el id de salida de la llamada anterior y sobrescribía una regla. Ahora se pone a NULL al empezar.
  - Una regla de TSH tenía la lógica mal escrita.
  - El motor fallaba con condiciones sin `valor2`.
  - Los códigos 5008x devolvían 400; ahora tienen su estado HTTP.
  - El script de guías escribía en la base de la URL en vez de `laboratorio`.
  - **Réplica:** el sincronizador viejo ya había avanzado la versión de Supabase hasta 412 antes del redespliegue, así que las filas semilla de las tablas nuevas (versiones 399–412) no se replicaban. Se forzó una carga completa (D35): 421 filas en Supabase y 348 documentos en Mongo, en modo COMPLETA.
- **La IP pública del equipo cambió a 186.42.9.27:**
  - Se agregó la regla de firewall `pc-equipo-2026-11-09` en Azure SQL.
  - Se actualizó la regla propia `lab-vm2-nsg/SSH-solo-equipo`.
  - Atlas no tiene la IP nueva, así que las guías se cargaron desde la VM1 con un contenedor `mongo:8.0` temporal.
- **Pruebas:**
  - local: 25/25;
  - en la nube: `pruebas/base_conocimiento.py` **18/18**;
  - réplica en Supabase: **27/27 tablas iguales** (versión 431). `verificar_replicacion.py` ya incluye las 5 tablas nuevas.
- Capturas 09–11 en `docs/capturas/`.

## 6. Pendientes

**Necesito del equipo:**
- [ ] Revisar el saldo de Azure for Students que queda (portal: buscar "Education" o "Educación").
- [x] **B1:** resuelto con D16 y D17 (VM2 nueva `lab-vm2` en la red de VM1).
- [ ] Pedro: quitar la clave `claude-proyecto-lab-clinico` de su VM (68.211.136.42).
- [x] DuckDNS `labclinico-uta.duckdns.org` funcionando.
- [x] El Azure Load Balancer lo crea Claude con Azure CLI (sesión iniciada).
- [x] Credenciales de Azure SQL (vía Entra), Supabase y Stripe: verificadas.
- [x] MongoDB Atlas: cluster `adMongo`, IP permitidas y conexión verificada.
- [ ] DuckDNS: subdominio nuevo y token.
- [ ] Reglas nuevas para 8080 y 8443 en los NSG (`ad-2026-nsg` solo agregando reglas, `lab-vm2-nsg`); Claude las crea con Azure CLI.

**Trabajo técnico:**
- [x] Fase 0: inventario de solo lectura de las VM.
- [x] Fase 1: Docker en VM1 y en lab-vm2.
- [x] Fase 2: proyecto e imágenes en VM1 y en lab-vm2.
- [x] Ejecutar los scripts en Azure SQL, Supabase y Atlas, y la primera replicación.
- [x] `.env` y contenedores en las 2 VM (con certificado provisional).
- [x] Certificado Let's Encrypt real con DuckDNS y Azure.
- [ ] **R3:** la capacidad de B2als_v2 en la zona 1 de Chile Central puede faltar al encender. Si se repite, reintentar o mover la VM2 a la zona 2.
- [x] Load Balancer y pruebas de balanceo y de caída.
- [x] Certificado real (dominio provisional de Azure) y webhook de Stripe.
- [x] Angular (sistema transaccional) y Flutter Web (portal de pacientes) programados y probados en local.
- [x] **Frontends desplegados** (pasos de referencia para futuros despliegues):
  1. `cd web-admin && npx ng build`, y copiar `dist/web-admin/browser/*` a `/opt/laboratorio/web/admin/` en ambas VM;
  2. `cd portal-pacientes && flutter build web --release` (SIN `--dart-define`), y copiar `build/web/*` a `/opt/laboratorio/web/portal/` en ambas VM.
- [x] Flujo completo en la nube (script, con pago por transferencia). Queda por hacer desde el portal: registro → cita → exámenes → pago con Stripe (tarjeta 4242…, lo hace una persona en el navegador) → resultados del laboratorista → observación y tratamiento del médico → PDF.
- [x] Fase X: las 10 pruebas con evidencias (`docs/05`).
- [ ] Pago completo con Stripe Checkout desde el portal (lo hace un usuario en el navegador).
- [ ] Agregar la IP 186.42.9.27 en Atlas → Network Access, si se van a correr desde el PC las pruebas que leen MongoDB (`verificar_replicacion.py`, `flujo_completo.py`).
- [ ] Decidir D21: ¿pagar unos 5 USD al mes por la base en Chile Central? (opcional). Si no, eliminar el servidor vacío `lab-sql-chile-henry`.
- [x] Informe técnico final (`docs/00-informe-tecnico.md`).
