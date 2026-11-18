# Fases V, VII y VIII — APIs, servicios REST/SOAP e integraciones

## 1. Organización (SOA)

Cada una de las 4 instancias Flask (`api1`…`api4`) contiene los mismos servicios lógicos. Cada servicio es un *blueprint* separado, con su propio prefijo y contrato:

| Servicio | Prefijo | Archivo |
|---|---|---|
| Autenticación | `/api/auth` | `api/app/servicios/auth.py` |
| Citas y consultas | `/api/citas` | `api/app/servicios/citas.py` |
| Exámenes y resultados | `/api/examenes`, `/api/solicitudes`, `/api/resultados` | `api/app/servicios/examenes.py` |
| Pagos y ventanilla | `/api/pagos` | `api/app/servicios/pagos.py` |
| Tratamientos | `/api/tratamientos`, `/api/observaciones` | `api/app/servicios/tratamientos.py` |
| Base de conocimientos | `/api/conocimiento` | `api/app/servicios/conocimiento.py` |
| Recetas y vademécum | `/api/recetas`, `/api/medicamentos` | `api/app/servicios/recetas.py` |
| Notificaciones | `/api/notificaciones` | `api/app/servicios/notificaciones.py` |
| Administración y reportes | `/api/usuarios`, `/api/pacientes`, `/api/reportes`, `/api/auditoria` | `api/app/servicios/usuarios.py` |
| SOAP (interoperabilidad) | `/soap` | `api/app/servicios/soap.py` |

**Convenciones comunes:**
- **Formato:** todo es JSON (UTF-8). Las fechas van en ISO-8601; las de auditoría, en UTC.
- **Autenticación:** cabecera `Authorization: Bearer <JWT>`. El token dura 8 h e incluye **todos** los roles del usuario.
- **Rol activo:** la cabecera opcional `X-Rol-Activo` indica con qué rol actúa una persona que tiene varios (por ejemplo, un médico que consulta sus propios resultados como `PACIENTE`). Si pide un rol que no tiene, recibe `403`.
- **Errores:** siempre con la forma `{"error": "mensaje", "codigo": "CODIGO", "instancia": "api3"}`.
- **Cabeceras de respuesta:**
  - `X-Instancia`: qué API atendió (evidencia del balanceo).
  - `X-Origen-Datos`: `azure` o `supabase` (evidencia de la contingencia).
  - `X-VM`: la añade Nginx e indica qué máquina virtual atendió.

| HTTP | Significado |
|---|---|
| 400 | JSON o XML inválido, firma de Stripe inválida |
| 401 | Sin token, token vencido o credenciales incorrectas |
| 403 | Rol insuficiente, recurso de otro paciente o conflicto de interés |
| 404 | No existe |
| 409 | Conflicto de estado: sin cupo, ya pagado, duplicado |
| 422 | Validación: cédula, montos, campos |
| 423 | Cuenta bloqueada por 5 intentos fallidos (15 min) |
| 503 | `MODO_CONTINGENCIA`: Azure SQL caído, solo se permiten consultas |

## 2. Endpoints REST

La columna **C** marca los endpoints que funcionan en contingencia (lectura desde Supabase).

**Listados paginados** (`api/app/paginacion.py`): `/api/usuarios`, `/api/pacientes`, `/api/solicitudes`, `/api/pagos`, `/api/notificaciones` y `/api/auditoria`.
- Con `?pagina=N&por_pagina=M` (máximo 100) responden `{items, total, pagina, por_pagina, paginas}`.
- Sin `?pagina`, devuelven la lista como antes, para no romper al portal, al cliente SOAP ni a las pruebas.
- Se pagina en la base con `OFFSET … FETCH`, que es SQL estándar y funciona igual en Azure SQL y en Supabase durante la contingencia.
- Los filtros de fecha `?desde=` y `?hasta=` usan formato AAAA-MM-DD e incluyen ambos días.

### Autenticación
| Método | Ruta | Rol | C | Descripción |
|---|---|---|---|---|
| POST | `/api/auth/registro` | público | | Registro de paciente. Valida la cédula ecuatoriana y la contraseña (≥ 8 caracteres, letras y números). |
| POST | `/api/auth/login` | público | ✔ | `{email, password}` → `{token, usuario{roles, paciente_id, medico_id, …}}` |
| GET | `/api/auth/me` | autenticado | ✔ | Perfil, roles y permisos efectivos |

### Citas y consultas médicas
| Método | Ruta | Rol | C | Descripción |
|---|---|---|---|---|
| GET | `/api/citas/medicos` | público | ✔ | Médicos activos con sus turnos libres y `precio_consulta` (`CONS-MED`) |
| GET | `/api/citas/franjas?desde=AAAA-MM-DD&dias=7&medico_id=` | público | ✔ | Franjas con cupo (`medico_id` vacío = laboratorio; con id = agenda de ese médico) |
| POST | `/api/citas` | PACIENTE | | `{franja_id, tipo: MUESTRA \| CONSULTA, motivo}` → cita `PENDIENTE_PAGO` (si es `CONSULTA`, crea automáticamente su solicitud de cobro con el ítem `CONS-MED`) |
| POST | `/api/citas/control` | MEDICO | | `{paciente_id, franja_id, motivo}` → agenda una cita de control en la propia agenda del médico (`origen: MEDICO`, vence 2 h antes de la hora) |
| GET | `/api/citas/mias` | PACIENTE | ✔ | Mis citas (`tipo`, `medico`, `origen`, solicitud vinculada y `vence_at` si está pendiente) |
| GET | `/api/citas/{id}` | MEDICO, LABORATORISTA, ADMIN | ✔ | Detalle de la cita, paciente y solicitud asociada |
| POST | `/api/citas/{id}/atender` | MEDICO (propia), ADMIN | | Finaliza la consulta médica: marca la cita como `ATENDIDA` y la solicitud de consulta como `COMPLETADA` |
| DELETE | `/api/citas/{id}` | PACIENTE (propia), ADMIN | | Cancela y libera el cupo. **El paciente recibe 409 si la cita ya está `CONFIRMADA` (pagada)**; si era consulta no pagada, anula su cobro |
| GET | `/api/citas/agenda?fecha=` | LABORATORISTA, MEDICO, ADMIN | ✔ | Agenda del día: el laboratorista ve solo turnos `MUESTRA`; el médico ve solo sus consultas (`CONSULTA`); el administrador ve todo |
| POST | `/api/citas/franjas` | ADMIN | | `{desde, hasta, hora_inicio, hora_fin, intervalo_minutos, capacidad, medico_id?}` genera franjas (del laboratorio o de un médico) |

**Flujo de la cita y de la consulta médica:**
1. **Turno de toma de muestras (`tipo = MUESTRA`):** reserva un cupo en el laboratorio (`medico_id IS NULL`). El paciente vincula sus exámenes y los paga (30 minutos para pagar). Al registrar la primera toma de muestra, la cita pasa automáticamente a `ATENDIDA`.
2. **Consulta médica (`tipo = CONSULTA`):** el paciente elige el médico y un turno de su agenda sin elegir exámenes; el sistema crea la solicitud `tipo = CONSULTA` con el ítem `CONS-MED` (USD 25,00, inactivo en el catálogo de exámenes). Al pagarla por Stripe queda `CONFIRMADA`.
3. **Atención médica y control:** el médico ve la cita en *"Mis consultas del día"*, la atiende en `/consulta/:id`, ordena los exámenes que el paciente necesita (se envía el correo `EXAMENES_ORDENADOS`), le agenda la cita de control en su propia agenda (que se puede pagar hasta **2 horas antes**) y finaliza la consulta (`ATENDIDA`).
4. **Cierre y envío al médico:** cuando el laboratorio completa los exámenes ordenados por un médico, además del correo al paciente se envía `RESULTADO_MEDICO` al médico con el PDF adjunto.
5. Una cita ya pagada (`CONFIRMADA`) no puede ser cancelada por el paciente (409).

Para la **prueba de concurrencia (Fase VI)**, con `PERMITIR_PRUEBA_CONCURRENCIA=true` se habilita `POST /api/citas?proteccion=0&espera_ms=800`, que ejecuta la reserva **sin** bloqueos y permite comparar ambos casos.

### Exámenes y resultados
| Método | Ruta | Rol | C | Descripción |
|---|---|---|---|---|
| GET | `/api/examenes/catalogo` | público | ✔ | Exámenes activos con parámetros y rangos (`CONS-MED` está inactivo y no aparece aquí) |
| POST | `/api/examenes/catalogo` | ADMIN | | Nuevo examen con sus parámetros |
| POST | `/api/solicitudes` | PACIENTE, MEDICO, LABORATORISTA | | `{examenes: [ids], paciente_id?, cita_id?}` (si lo crea el médico, registra `medico_id` y envía `EXAMENES_ORDENADOS`) |
| GET | `/api/solicitudes/mias` | PACIENTE | ✔ | Mis solicitudes |
| GET | `/api/solicitudes?tipo=&estado=&cedula=&codigo=&paciente=&desde=&hasta=&propias=1&pagina=` | LABORATORISTA, MEDICO, ADMIN | ✔ | Búsqueda paginada, con `examenes_resumen` (el laboratorista ve por defecto solo `tipo=EXAMENES`) |
| GET | `/api/solicitudes/{id}` | dueño o personal | ✔ | Solicitud completa: exámenes, valores con `nivel` (`ALTO`, `BAJO`, `NORMAL`, `ANORMAL`) y observaciones; además `subtotal`, `iva`, `iva_porcentaje` y `total` |
| GET | `/api/solicitudes/{id}/pdf` | dueño o personal | ✔ | **Informe PDF**: valores fuera de rango en rojo e indicador ↑ alto, ↓ bajo, – normal |
| POST | `/api/solicitudes/detalle/{id}/muestra` | LABORATORISTA | | Registra la toma de muestra y marca la cita vinculada como `ATENDIDA` |
| POST | `/api/resultados` | LABORATORISTA | | `{detalle_id, valores: [{parametro_id, valor \| texto}], observaciones}` (al completarse la solicitud, evalúa las reglas CIE-10 y envía el PDF al paciente y al médico solicitante) |

### Pagos y cobro en ventanilla (Stripe en modo prueba)
| Método | Ruta | Rol | C | Descripción |
|---|---|---|---|---|
| POST | `/api/pagos/checkout` | PACIENTE | | `{solicitud_id}` → `{checkout_url}`: **registro de la solicitud de pago** en el portal |
| POST | `/api/pagos/ventanilla` | LABORATORISTA, ADMIN | | `{solicitud_id, factura: {identificacion?, nombre?, direccion?, email?}}` → `{pago_id, checkout_url, qr}`: **cobro en ventanilla por Stripe** (QR para el celular o pago en pantalla, con datos de factura o consumidor final) |
| POST | `/api/pagos/webhook` | Stripe (firma) | | **Confirmación**: aprobado, rechazado o expirado (idempotente) |
| POST | `/api/pagos/transferencia` | PACIENTE | | Transferencia simulada (conservada en la API solo para las pruebas automatizadas; en el portal todo cobro pasa por Stripe) |
| POST | `/api/pagos/{id}/confirmar-transferencia` | ADMIN | | `{aprobado, motivo}` |
| POST | `/api/pagos/{id}/reembolso` | ADMIN | | `{monto, motivo}`: reembolso total o parcial en Stripe (con Idempotency-Key) |
| GET | `/api/pagos/factura/{solicitud_id}?formato=pdf\|xml` | dueño, LABORATORISTA o ADMIN | ✔ | **Factura** de una solicitud pagada con los datos de facturación del pago o consumidor final `9999999999999` (código 07) |
| GET | `/api/pagos/mios` | PACIENTE | ✔ | Mis pagos |
| GET | `/api/pagos/{id}` | dueño, LABORATORISTA o ADMIN | ✔ | Pago con sus reembolsos y datos de factura |
| GET | `/api/pagos?estado=&metodo=&q=&desde=&hasta=&pagina=` | ADMIN | ✔ | Listado filtrado y paginado |

**IVA y factura** (`api/app/factura.py`):
- Los precios del catálogo **incluyen el IVA** (`IVA_PORCENTAJE`, 15 % por defecto). El resumen del pedido y la factura lo separan al final: subtotal sin IVA, IVA y total.
- La base de cada examen se redondea al centavo y el IVA es la diferencia con el total, así la suma siempre cuadra.
- El XML sigue la estructura de la factura electrónica del SRI: versión 1.1.0, ambiente de pruebas y clave de acceso de 49 dígitos con dígito verificador módulo 11. Es un comprobante académico: no se firma ni se envía al SRI.
- Al aprobarse el pago, el correo `PAGO_APROBADO` lleva **la factura en PDF y XML**. Al completarse los resultados, el correo `RESULTADO_LISTO` lleva **el PDF de resultados**.
- Los adjuntos se generan al enviar el correo. Si fallan, el correo sale igual, sin adjuntos, y queda un aviso en el log (`adjuntos_no_generados`).

**Eventos de Stripe que se procesan:**

| Evento | Acción en el sistema |
|---|---|
| `checkout.session.completed` (pagado) | Pago `APROBADO`, solicitud `PAGADA`, cita `CONFIRMADA` y correo al paciente |
| `payment_intent.payment_failed` | Pago `RECHAZADO` con el motivo (por ejemplo `insufficient_funds`) y correo; el paciente puede reintentar en la misma sesión, y si lo logra pasa a `APROBADO` |
| `checkout.session.expired` | Pago `EXPIRADO` (pago no confirmado) |
| `checkout.session.async_payment_succeeded` / `_failed` | Igual que aprobado o rechazado |

**Tarjetas de prueba:** `4242 4242 4242 4242` (aprobada), `4000 0000 0000 0002` (declinada) y `4000 0000 0000 9995` (fondos insuficientes). En todas se usa cualquier fecha futura y cualquier CVC.

### Tratamientos y seguimiento
| Método | Ruta | Rol | C | Descripción |
|---|---|---|---|---|
| POST | `/api/observaciones` | MEDICO | | `{resultado_id, texto}`; no puede ser sobre sí mismo |
| POST | `/api/tratamientos` | MEDICO | | `{paciente_id, diagnostico, indicaciones, fecha_inicio, fecha_fin?, solicitud_id?}` |
| PATCH | `/api/tratamientos/{id}` | MEDICO (propio) | | `{estado: ACTIVO \| FINALIZADO \| SUSPENDIDO}` |
| GET | `/api/tratamientos/mios` | PACIENTE | ✔ | Mis tratamientos |
| GET | `/api/tratamientos?paciente_id=` | MEDICO, ADMIN | ✔ | Tratamientos de un paciente |

### Notificaciones (Mailjet)
| Método | Ruta | Rol | Descripción |
|---|---|---|---|
| GET | `/api/notificaciones?estado=&q=&desde=&hasta=&pagina=` | ADMIN | Bandeja de salida con el estado y el `MessageID` de Mailjet (filtrada y paginada) |
| POST | `/api/notificaciones/procesar` | ADMIN | Fuerza el envío de los pendientes |
| POST | `/api/notificaciones/prueba` | ADMIN | `{email}` envía un correo de prueba de inmediato |

Las operaciones solo **encolan** el correo en la tabla `notificacion`, así que si Mailjet falla la operación de negocio no se pierde. Un hilo en `api1` y otro en `api3` lo envían. Pueden trabajar a la vez sin duplicar correos porque cada uno toma filas distintas (`UPDLOCK + READPAST`). Cada correo se reintenta hasta 5 veces y queda guardado el `MessageID` de Mailjet.

### Administración y reportes
| Método | Ruta | Rol | C | Descripción |
|---|---|---|---|---|
| GET | `/api/usuarios?q=&rol=&activo=&pagina=` | ADMIN | ✔ | Usuarios con sus roles (búsqueda por nombre, correo o cédula) |
| POST | `/api/usuarios` | ADMIN | | Crea un usuario con un rol (si la cédula existe, reutiliza la persona) |
| POST | `/api/usuarios/{id}/roles` | ADMIN | | Agrega un rol y crea el perfil (multirrol) |
| POST | `/api/usuarios/{id}/clave` | ADMIN | | `{password}` restablece la contraseña del usuario y desbloquea la cuenta |
| PATCH | `/api/usuarios/{id}` | ADMIN | | `{activo}` |
| GET | `/api/pacientes?cedula=` o `?q=nombre o apellido&pagina=` | LABORATORISTA, MEDICO, ADMIN | ✔ | Búsqueda de pacientes |
| POST | `/api/pacientes` | LABORATORISTA, MEDICO, ADMIN | | `{cedula, nombres, apellidos, fecha_nacimiento, sexo, telefono?, direccion?, email?}` registra un paciente de ventanilla sin cuenta |
| GET | `/api/reportes/ingresos?desde=&hasta=&formato=pdf` | ADMIN | ✔ | Ingresos en JSON o **PDF** |
| GET | `/api/reportes/examenes` | ADMIN, MEDICO | ✔ | Exámenes más solicitados |
| GET | `/api/auditoria?desde=&hasta=&accion=&usuario=&pagina=` | ADMIN | | Auditoría filtrada y paginada (en contingencia se consulta en MongoDB) |
| GET | `/api/auditoria/acciones` | ADMIN | | Acciones registradas, para el filtro |

### Operación
| Método | Ruta | Descripción |
|---|---|---|
| GET | `/health` | Sonda para Nginx y el Azure Load Balancer. Responde `200` mientras la API esté viva, también en contingencia: `{instancia, modo}` |
| GET | `/api/estado` | Disponibilidad de Azure SQL y Supabase vista desde la instancia |

## 3. Servicio SOAP

- **WSDL:** `GET https://<dominio>/soap?wsdl`. Es SOAP 1.1, estilo document/literal, con espacio de nombres `urn:labclinico:resultados`.
- **Autenticación:** cabecera SOAP `<lab:Credencial><lab:ApiKey>…</lab:ApiKey></lab:Credencial>`, declarada en el WSDL, o la cabecera HTTP `X-API-Key`.
- **Seguridad:** el XML se analiza con `defusedxml`, que rechaza entidades externas (XXE) y DTD.
- **Contingencia:** funciona también en contingencia, porque solo consulta.

| Operación | Entrada | Salida |
|---|---|---|
| `ConsultarResultados` | `codigoSolicitud` | Paciente, estado y, por cada examen, sus parámetros (valor, unidad, referencia, `fueraRango`) |
| `ConsultarEstadoSolicitud` | `codigoSolicitud` | Estado, total, `pagado`, exámenes listos sobre totales |
| `ListarExamenes` | — | Catálogo con precio y si requiere ayuno |

Ejemplo de petición:

```xml
<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:lab="urn:labclinico:resultados">
  <soapenv:Header>
    <lab:Credencial><lab:ApiKey>CLAVE</lab:ApiKey></lab:Credencial>
  </soapenv:Header>
  <soapenv:Body>
    <lab:ConsultarResultadosRequest><lab:codigoSolicitud>SOL-2026-000001</lab:codigoSolicitud></lab:ConsultarResultadosRequest>
  </soapenv:Body>
</soapenv:Envelope>
```

**Cliente independiente:** [`clientes/soap_cliente.py`](../clientes/soap_cliente.py) usa zeep y lee el WSDL publicado. También puede usarse SoapUI importando la URL del WSDL.

```bash
python clientes/soap_cliente.py https://<dominio>/soap?wsdl <SOAP_API_KEY> SOL-2026-000001
```

## 4. Contingencia en las APIs (circuit breaker)

1. Cada petición abre su conexión a Azure SQL con un timeout de conexión de 3 s.
2. Si falla por conectividad (SQLSTATE `08001`, `08S01`, `HYT00`, etc.), el circuito se **abre** durante 15 s y la lectura se repite en Supabase con el rol `lab_lectura`.
3. Mientras el circuito está abierto, las lecturas van directo a Supabase, sin esperar el timeout. Las escrituras responden `503 MODO_CONTINGENCIA`.
4. Pasados 15 s se vuelve a probar Azure SQL. Si responde, el circuito se **cierra** y todo vuelve a la base principal.
5. Cada cambio de estado queda en el log: `circuito_abierto` y `circuito_cerrado`.

## 5. Prueba de integración realizada (local)

Entorno: LocalDB como Azure SQL, PostgreSQL embebido como Supabase, el sincronizador real, Stripe simulado con **webhooks firmados de verdad** (HMAC con el secreto del webhook) y Mailjet simulado. Resultado: **56/56 verificaciones correctas.**

| Área | Lo verificado |
|---|---|
| **Autenticación y roles** | Registro con cédula válida e inválida; login, contraseña incorrecta, sin token (401), rol insuficiente (403); permisos efectivos. |
| **Concurrencia vía API** | Dos pacientes en hilos por 1 cupo: `[201, 409]`. |
| **Pagos** | Checkout, tarjeta declinada (`RECHAZADO` con motivo), reintento aprobado, cita `CONFIRMADA`, webhook duplicado ignorado, firma falsa (400); reembolso parcial con Idempotency-Key y reembolso excesivo (422). |
| **Laboratorio** | Toma de muestra, resultados, glucosa fuera de rango, solicitud `COMPLETADA`, PDF. |
| **Multirrol** | El médico no puede tratarse a sí mismo (403). Con `X-Rol-Activo: PACIENTE` ve sus propias solicitudes pero no las de otros (403). |
| **Administración** | Crear usuario y agregar rol, generar 40 franjas, nuevo examen en el catálogo, reportes en PDF, auditoría. |
| **SOAP** | Con el cliente zeep: las 3 operaciones, clave inválida (Fault) y ataque XXE rechazado. |
| **Contingencia** | Con Azure SQL inalcanzable: login, resultados y PDF desde Supabase (`X-Origen-Datos: supabase`); escritura 503; `/health` en modo contingencia; SOAP sigue respondiendo. Al volver Azure SQL, regresa solo. |
