# Traspaso: consulta médica, control y cobro en ventanilla (18-11-2026)

Documento para continuar el trabajo. Responder siempre en **español (Ecuador)**.

## 1. Qué se pidió (equipo: Pedro)

1. El paciente pide una **cita de consulta con el médico** sin elegir exámenes (no sabe cuáles necesita).
2. El médico lo atiende, le **ordena los exámenes** y le **agenda la cita de control**.
3. Los resultados **le llegan al médico**; el paciente solo vuelve al control.
4. **La consulta también se cobra**, por la pasarela.
5. **Ventanilla:** el laboratorista crea la solicitud, toma los datos de facturación y cobra. **Todo cobro pasa por la pasarela (Stripe)**, con dos opciones: QR en el celular del paciente o Stripe abierto en la pantalla de ventanilla. La factura sale con los datos tomados.
6. Mejoras pequeñas:
   - la cita pasa a ATENDIDA al tomar la muestra;
   - el paciente no puede cancelar una cita ya pagada;
   - el administrador puede restablecer claves.

## 2. Qué está hecho, desplegado y probado

Todo está **desplegado en las 2 VM**, pero **NO tiene commit**.

**Base de datos**
- `database/azure-sql/09_consultas.sql` ya se ejecutó en Azure SQL.
- `database/supabase/05_consultas.sql` ya se ejecutó en Supabase.
- Columnas nuevas:
  - `franja_horaria.medico_id`: NULL = laboratorio. La restricción única pasó a ser `(fecha, hora_inicio, medico_id)`.
  - `cita.tipo` (`MUESTRA` | `CONSULTA`), `cita.medico_id` y `cita.origen` (`PACIENTE` | `MEDICO`).
  - `solicitud_examen.tipo` (`EXAMENES` | `CONSULTA`).
  - `pago.factura_identificacion`, `pago.factura_nombre`, `pago.factura_direccion` y `pago.factura_email`.
- La consulta se cobra como el ítem **`CONS-MED`** del catálogo: inactivo para que no aparezca entre los exámenes, a USD 25.00. Ese precio se cambia por SQL; aún no hay pantalla para hacerlo.
- Procedimientos:
  - nuevos: `sp_reservar_consulta` y `sp_atender_cita`;
  - redefinidos: `sp_cancelar_cita` (anula el cobro de una consulta no pagada), `sp_expirar_citas_pendientes` (la cita de control vence 2 h antes de la hora) y `sp_crear_pago` (datos de factura).

**API**
- `citas.py`:
  - `GET /api/citas/medicos`, `GET /api/citas/franjas?medico_id=`;
  - `POST /api/citas` con `tipo` (`MUESTRA` o `CONSULTA`);
  - `POST /api/citas/control` (médico), `GET /api/citas/<id>`, `POST /api/citas/<id>/atender`;
  - la agenda ahora la ve el médico, solo con sus consultas;
  - el paciente recibe 409 si intenta cancelar una cita CONFIRMADA;
  - `POST /api/citas/franjas` acepta `medico_id`.
- `examenes.py`:
  - filtro `?tipo=` (el laboratorista ve solo `EXAMENES`);
  - la toma de muestra marca la cita como ATENDIDA;
  - correo `RESULTADO_MEDICO` (con el PDF adjunto) al médico que ordenó los exámenes;
  - correo `EXAMENES_ORDENADOS` al paciente.
- `pagos.py`:
  - `POST /api/pagos/ventanilla` (laboratorista y administrador): devuelve `checkout_url` de Stripe y el `qr`;
  - la factura de ventanilla se puede enviar a otro correo;
  - el laboratorista puede descargar facturas.
- `factura.py`: usa los datos de factura del pago, incluido consumidor final 9999999999999 (código 07).
- `usuarios.py`: `POST /api/pacientes` (paciente de ventanilla sin cuenta) y `POST /api/usuarios/<id>/clave`.
- `errores.py`: códigos 50090–50106 y rango ampliado a menos de 50200.

**Portal del paciente (Flutter)**
- Reservar: "Consulta médica" (elige el médico, luego el turno, y paga) o "Toma de muestras".
- "Mis citas" muestra el tipo, el médico y la fecha límite de pago del control.
- Ya no hay botón de cancelar una cita pagada.
- **Se quitó el botón de transferencia:** todo cobro va por Stripe. El endpoint de transferencia sigue en la API solo para las pruebas automáticas.

**Sistema del personal (Angular)**
- Agenda: el médico ve "Mis consultas del día" con el botón "Atender".
- Página nueva **`/consulta/:id`**:
  - historial del paciente y alergias;
  - ordenar exámenes;
  - agendar el control en su agenda;
  - finalizar la consulta.
- Catálogo y franjas: elegir "Agenda de" el laboratorio o un médico.
- Nueva solicitud: "+ Registrar paciente de ventanilla".
- Detalle de la solicitud: panel **"Cobrar en ventanilla"**:
  - datos de factura o consumidor final;
  - QR y botón "Abrir el pago en esta pantalla";
  - consulta cada 4 s hasta que se confirma el pago.
- Usuarios: "Restablecer clave". Inicio del médico: "Mis consultas de hoy" y "Resultados de mis pacientes".

**Pruebas (dominio público)**
- Flujo nuevo: **24/24** (`scratchpad/flujo_consulta.py`; conviene copiarlo a `pruebas/flujo_consulta.py`).
- Regresión:
  - flujo de cita 6/6, receta 11/11, factura 10/10;
  - endpoints 15/16: la única "falla" es esperada, porque ahora el médico **sí** ve la agenda (sus consultas). Hay que actualizar esa expectativa en `prueba_vm.py`.
- Réplica en Supabase: las 31 tablas OK.
- MongoDB no se verificó: falta permitir en Atlas la IP actual del equipo.

## 3. Lo que falta hacer

1. **Apagar las VM** si siguen encendidas (ver §5).
2. **Bitácora** (`docs/BITACORA.md`):
   - decisiones:
     - **D44:** consulta médica con cobro por Stripe (solicitud tipo CONSULTA con el ítem CONS-MED).
     - **D45:** agenda por médico (`franja_horaria.medico_id`) y control agendado por el médico (vence 2 h antes). Esto revierte en parte D36: el médico ahora ve **sus** consultas.
     - **D46:** cobro en ventanilla solo por la pasarela (QR o pantalla), con los datos de factura en el pago.
     - **D47:** el paciente no cancela una cita pagada; la cita queda ATENDIDA al tomar la muestra o al cerrar la consulta; el administrador restablece claves.
   - entrada del 18-11 con las pruebas de arriba;
   - nota del orden de ejecución: primero Supabase, luego Azure y al final reiniciar `sync-vm1` y `sync-vm2`, para que lean las columnas nuevas.
3. **Documentación:**
   - `docs/04-servicios-rest-soap.md`: endpoints nuevos y cambiados (§2);
   - `docs/flujos-del-sistema.html`: actualizar el flujo del paciente (consulta → exámenes → control), el del médico (agenda, consulta) y el del laboratorista (ventanilla por Stripe), y marcar como resueltas las mejoras hechas;
   - el artefacto publicado se actualiza publicando el mismo archivo;
   - `README.md`: decisiones D1–D47.
4. **Pruebas en el repo:** copiar `flujo_consulta.py` a `pruebas/` y corregir la expectativa del médico en la agenda.
5. **Commit y push** cuando el usuario lo pida. Antes, escaneo de secretos (el repositorio es público). Nunca subir `secretos/`.
6. **Revisión en el navegador** (equipo): `/consulta/:id`, el panel de ventanilla con un pago real con la tarjeta de prueba 4242… y la factura de ventanilla con datos de empresa. La factura con datos de ventanilla solo se probó hasta crear el cobro: el pago real con Stripe lo hace una persona.
7. Opcional:
   - pantalla para cambiar el precio de la consulta (`CONS-MED`);
   - reprogramar citas pagadas;
   - en contingencia (Azure SQL caído) no se puede cobrar.

## 4. Datos de prueba que quedaron

- Sofía: consulta SOL-2026-000021 (atendida), exámenes SOL-2026-000022 (completados), control del 20-11 08:00 sin pagar y turno de muestras atendido.
- Paciente de ventanilla "Paciente Ventanilla 4654" (CI 1020054654), con su solicitud y dos cobros pendientes en Stripe.
- 36 franjas de consulta del Dr. Villacís (del 19-11 al 29-11, de 08:00 a 10:00).
- A Villacís se le restableció la clave al mismo valor de prueba.

## 5. Cómo se trabaja en este entorno

- **Azure CLI:** usar el envoltorio IPv4 (en esta red no hay IPv6):
  `"/c/Program Files/Microsoft SDKs/Azure/CLI2/python.exe" -B <scratchpad>/az_ipv4.py <args de az>`.
  - VM: `ad-2026` (68.211.136.29) y `lab-vm2` (68.211.73.83), en el grupo `AD-2026_GRUPO`.
  - Apagar con `vm deallocate -g AD-2026_GRUPO -n <vm> --no-wait`.
- **Si cambia la IP del PC:** actualizar `lab-vm2-nsg/SSH-solo-equipo` y la regla `henry-pc-actual` del firewall de Azure SQL.
- **SSH:** `ssh -i $HOME/.ssh/lab_clinico_vms -o IdentitiesOnly=yes -o BatchMode=yes azureuser@<ip>`.
- **Despliegue:**
  1. `python infra/generar_env.py`;
  2. `ng build` (web-admin) y `flutter build web --release --no-web-resources-cdn`;
  3. empaquetar con tar (código con `git ls-files`, más `admin.tgz` y `portal.tgz`);
  4. `scp` a `/tmp`, con `vmN.env` copiado como `infra.env`;
  5. `ssh … 'bash -s' < infra/desplegar.sh`.
- **SQL:**
  - Azure: `scratchpad/ejecutar_azure.py <script>` usa el token de az a través del envoltorio.
  - Supabase: `scratchpad/ejecutar_supabase.py <ruta>`.
- **Reglas fijas:**
  - en las VM solo se **agrega**: no tocar Apache, MariaDB ni WordPress, los crontabs, `/etc/letsencrypt`, el hostname ni las reglas NSG ajenas;
  - las credenciales nunca van al chat ni al repositorio;
  - mantener `docs/BITACORA.md` al día;
  - no tocar la VM de Pedro ni `AppDistribuidas_2026_DB`;
  - apagar las VM al terminar.
