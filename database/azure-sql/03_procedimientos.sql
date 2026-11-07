/* =====================================================================
   03_procedimientos.sql
   Operaciones críticas encapsuladas en transacciones.
   Códigos de error de negocio (THROW): 50001-50099.
   ===================================================================== */

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ---------------------------------------------------------------------
   Auditoría (la usan los demás procedimientos)
   ------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_auditar
    @usuario_id    BIGINT = NULL,
    @accion        VARCHAR(50),
    @entidad       VARCHAR(50),
    @entidad_id    VARCHAR(50) = NULL,
    @detalle       NVARCHAR(MAX) = NULL,
    @ip_origen     VARCHAR(45) = NULL,
    @instancia_api VARCHAR(30) = NULL,
    @rol_actuante  VARCHAR(30) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.auditoria (usuario_id, rol_actuante, accion, entidad, entidad_id, detalle, ip_origen, instancia_api)
    VALUES (@usuario_id, @rol_actuante, @accion, @entidad, @entidad_id, @detalle, @ip_origen, @instancia_api);
END;
GO

/* ---------------------------------------------------------------------
   Registro de paciente.
   Si la cédula ya existe (ej. un médico que ahora se atiende como
   paciente) reutiliza la persona y su usuario, y solo agrega el perfil
   y el rol PACIENTE.
   ------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_registrar_paciente
    @cedula            VARCHAR(13),
    @nombres           NVARCHAR(100),
    @apellidos         NVARCHAR(100),
    @fecha_nacimiento  DATE,
    @sexo              CHAR(1),
    @telefono          VARCHAR(20) = NULL,
    @email             VARCHAR(150),
    @direccion         NVARCHAR(250) = NULL,
    @password_hash     VARCHAR(255) = NULL,   -- NULL si lo registra ventanilla sin cuenta
    @tipo_sangre       VARCHAR(3) = NULL,
    @alergias          NVARCHAR(500) = NULL,
    @paciente_id       BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @persona_id BIGINT, @usuario_id BIGINT;
    DECLARE @rol_paciente SMALLINT = (SELECT rol_id FROM dbo.rol WHERE codigo = 'PACIENTE');

    BEGIN TRY
    BEGIN TRAN;

        SELECT @persona_id = persona_id
        FROM dbo.persona WITH (UPDLOCK, HOLDLOCK)
        WHERE cedula = @cedula;

        IF @persona_id IS NULL
        BEGIN
            INSERT INTO dbo.persona (cedula, nombres, apellidos, fecha_nacimiento, sexo, telefono, email, direccion)
            VALUES (@cedula, @nombres, @apellidos, @fecha_nacimiento, @sexo, @telefono, @email, @direccion);
            SET @persona_id = SCOPE_IDENTITY();
        END;

        IF EXISTS (SELECT 1 FROM dbo.paciente WHERE persona_id = @persona_id)
            THROW 50001, 'La persona ya está registrada como paciente.', 1;

        INSERT INTO dbo.paciente (persona_id, tipo_sangre, alergias)
        VALUES (@persona_id, @tipo_sangre, @alergias);
        SET @paciente_id = SCOPE_IDENTITY();

        SELECT @usuario_id = usuario_id FROM dbo.usuario WHERE persona_id = @persona_id;

        IF @usuario_id IS NULL AND @password_hash IS NOT NULL
        BEGIN
            INSERT INTO dbo.usuario (persona_id, email, password_hash)
            VALUES (@persona_id, @email, @password_hash);
            SET @usuario_id = SCOPE_IDENTITY();
        END;

        IF @usuario_id IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM dbo.usuario_rol WHERE usuario_id = @usuario_id AND rol_id = @rol_paciente)
            INSERT INTO dbo.usuario_rol (usuario_id, rol_id) VALUES (@usuario_id, @rol_paciente);

        DECLARE @det NVARCHAR(200) = CONCAT(N'{"persona_id":', @persona_id, N',"usuario_id":', ISNULL(CAST(@usuario_id AS VARCHAR(20)), 'null'), N'}');
        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @accion = 'REGISTRAR_PACIENTE',
             @entidad = 'paciente', @entidad_id = @paciente_id, @detalle = @det;

    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------
   Asigna un rol adicional a un usuario existente y crea el perfil.
   Permite que una misma persona sea, por ejemplo, MEDICO y PACIENTE.
   ------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_asignar_rol
    @usuario_id            BIGINT,
    @rol_codigo            VARCHAR(30),
    @registro_profesional  VARCHAR(30) = NULL,     -- MEDICO / LABORATORISTA
    @especialidad_o_area   NVARCHAR(100) = NULL,
    @admin_id              BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @rol_id SMALLINT = (SELECT rol_id FROM dbo.rol WHERE codigo = @rol_codigo);
    DECLARE @persona_id BIGINT = (SELECT persona_id FROM dbo.usuario WHERE usuario_id = @usuario_id);

    IF @rol_id IS NULL     THROW 50002, 'Rol inexistente.', 1;
    IF @persona_id IS NULL THROW 50003, 'Usuario inexistente.', 1;

    BEGIN TRY
    BEGIN TRAN;
        IF NOT EXISTS (SELECT 1 FROM dbo.usuario_rol WHERE usuario_id = @usuario_id AND rol_id = @rol_id)
            INSERT INTO dbo.usuario_rol (usuario_id, rol_id) VALUES (@usuario_id, @rol_id);

        IF @rol_codigo = 'MEDICO' AND NOT EXISTS (SELECT 1 FROM dbo.medico WHERE persona_id = @persona_id)
        BEGIN
            IF @registro_profesional IS NULL OR @especialidad_o_area IS NULL
                THROW 50004, 'El rol MEDICO requiere registro profesional y especialidad.', 1;
            INSERT INTO dbo.medico (persona_id, registro_profesional, especialidad)
            VALUES (@persona_id, @registro_profesional, @especialidad_o_area);
        END;

        IF @rol_codigo = 'LABORATORISTA' AND NOT EXISTS (SELECT 1 FROM dbo.laboratorista WHERE persona_id = @persona_id)
        BEGIN
            IF @registro_profesional IS NULL
                THROW 50005, 'El rol LABORATORISTA requiere registro profesional.', 1;
            INSERT INTO dbo.laboratorista (persona_id, registro_profesional, area)
            VALUES (@persona_id, @registro_profesional, @especialidad_o_area);
        END;

        IF @rol_codigo = 'PACIENTE' AND NOT EXISTS (SELECT 1 FROM dbo.paciente WHERE persona_id = @persona_id)
            INSERT INTO dbo.paciente (persona_id) VALUES (@persona_id);

        DECLARE @det NVARCHAR(200) = CONCAT(N'{"usuario_id":', @usuario_id, N',"rol":"', @rol_codigo, N'"}');
        EXEC dbo.sp_auditar @usuario_id = @admin_id, @accion = 'ASIGNAR_ROL',
             @entidad = 'usuario', @entidad_id = @usuario_id, @detalle = @det;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------
   ESCENARIO CRÍTICO DE CONCURRENCIA: reserva de cita.
   @protegido = 1 -> transacción + UPDLOCK/HOLDLOCK sobre la franja: el
                     segundo paciente espera a que el primero confirme y
                     luego ve el cupo real.
   @protegido = 0 -> lectura sin bloqueo + escritura del valor leído:
                     reproduce la "actualización perdida" (dos citas en
                     un cupo, contador incorrecto). Solo para la prueba
                     comparativa de la Fase VI.
   @espera_ms simula latencia entre leer y escribir para hacer visible
   la condición de carrera.
   ------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_reservar_cita
    @paciente_id    BIGINT,
    @franja_id      BIGINT,
    @motivo         NVARCHAR(300) = NULL,
    @canal          VARCHAR(20) = 'PORTAL',
    @usuario_id     BIGINT = NULL,
    @instancia_api  VARCHAR(30) = NULL,
    @protegido      BIT = 1,
    @espera_ms      INT = 0,
    @cita_id        BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @capacidad TINYINT, @ocupados TINYINT, @activa BIT, @fecha DATE, @hora TIME(0);
    DECLARE @delay DATETIME = DATEADD(MILLISECOND, @espera_ms, CAST(0 AS DATETIME));

    IF @protegido = 1
    BEGIN
        BEGIN TRY
    BEGIN TRAN;
            SELECT @capacidad = capacidad, @ocupados = ocupados, @activa = activa, @fecha = fecha, @hora = hora_inicio
            FROM dbo.franja_horaria WITH (UPDLOCK, HOLDLOCK, ROWLOCK)
            WHERE franja_id = @franja_id;

            IF @capacidad IS NULL THROW 50010, 'La franja no existe.', 1;
            IF @activa = 0 OR DATEADD(MINUTE, DATEDIFF(MINUTE, 0, @hora), CAST(@fecha AS DATETIME2(0))) < DATEADD(HOUR, -5, SYSUTCDATETIME())
                THROW 50011, 'La franja no está disponible.', 1;
            IF @ocupados >= @capacidad THROW 50012, 'La franja ya no tiene cupos disponibles.', 1;

            IF @espera_ms > 0 WAITFOR DELAY @delay;

            UPDATE dbo.franja_horaria
            SET ocupados = ocupados + 1, updated_at = SYSUTCDATETIME()
            WHERE franja_id = @franja_id;

            INSERT INTO dbo.cita (paciente_id, franja_id, motivo, canal)
            VALUES (@paciente_id, @franja_id, @motivo, @canal);
            SET @cita_id = SCOPE_IDENTITY();

            DECLARE @det NVARCHAR(200) = CONCAT(N'{"franja_id":', @franja_id, N',"paciente_id":', @paciente_id, N',"protegido":true}');
            EXEC dbo.sp_auditar @usuario_id = @usuario_id, @accion = 'RESERVAR_CITA', @entidad = 'cita',
                 @entidad_id = @cita_id, @detalle = @det, @instancia_api = @instancia_api;
        COMMIT;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK;
            THROW;
        END CATCH;
    END
    ELSE
    BEGIN
        -- SIN PROTECCIÓN (intencionalmente incorrecto)
        SELECT @capacidad = capacidad, @ocupados = ocupados
        FROM dbo.franja_horaria WITH (NOLOCK)
        WHERE franja_id = @franja_id;

        IF @capacidad IS NULL THROW 50010, 'La franja no existe.', 1;
        IF @ocupados >= @capacidad THROW 50012, 'La franja ya no tiene cupos disponibles.', 1;

        IF @espera_ms > 0 WAITFOR DELAY @delay;

        UPDATE dbo.franja_horaria
        SET ocupados = @ocupados + 1, updated_at = SYSUTCDATETIME()   -- escribe el valor leído: actualización perdida
        WHERE franja_id = @franja_id;

        INSERT INTO dbo.cita (paciente_id, franja_id, motivo, canal)
        VALUES (@paciente_id, @franja_id, @motivo, @canal);
        SET @cita_id = SCOPE_IDENTITY();

        DECLARE @det2 NVARCHAR(200) = CONCAT(N'{"franja_id":', @franja_id, N',"paciente_id":', @paciente_id, N',"protegido":false}');
        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @accion = 'RESERVAR_CITA', @entidad = 'cita',
             @entidad_id = @cita_id, @detalle = @det2, @instancia_api = @instancia_api;
    END;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_cancelar_cita
    @cita_id     BIGINT,
    @usuario_id  BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @franja_id BIGINT, @estado VARCHAR(20);

    BEGIN TRY
    BEGIN TRAN;
        SELECT @franja_id = franja_id, @estado = estado
        FROM dbo.cita WITH (UPDLOCK, HOLDLOCK)
        WHERE cita_id = @cita_id;

        IF @franja_id IS NULL THROW 50013, 'La cita no existe.', 1;
        IF @estado NOT IN ('PENDIENTE_PAGO', 'CONFIRMADA') THROW 50014, 'La cita no se puede cancelar en su estado actual.', 1;

        UPDATE dbo.cita SET estado = 'CANCELADA', cancelada_at = SYSUTCDATETIME(), updated_at = SYSUTCDATETIME()
        WHERE cita_id = @cita_id;

        UPDATE dbo.franja_horaria SET ocupados = ocupados - 1, updated_at = SYSUTCDATETIME()
        WHERE franja_id = @franja_id AND ocupados > 0;

        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @accion = 'CANCELAR_CITA', @entidad = 'cita', @entidad_id = @cita_id;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------
   Crea una solicitud de exámenes.
   @examenes: JSON con los ids de tipo_examen, ej. '[1, 4, 7]'
   ------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_crear_solicitud
    @paciente_id   BIGINT,
    @examenes      NVARCHAR(MAX),
    @medico_id     BIGINT = NULL,
    @cita_id       BIGINT = NULL,
    @observaciones NVARCHAR(500) = NULL,
    @usuario_id    BIGINT = NULL,
    @solicitud_id  BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF ISJSON(@examenes) = 0 THROW 50020, 'La lista de exámenes no es un JSON válido.', 1;

    DECLARE @items TABLE (tipo_examen_id INT PRIMARY KEY);
    INSERT INTO @items (tipo_examen_id)
    SELECT DISTINCT CAST([value] AS INT) FROM OPENJSON(@examenes);

    IF NOT EXISTS (SELECT 1 FROM @items) THROW 50021, 'Debe solicitar al menos un examen.', 1;
    IF EXISTS (SELECT 1 FROM @items i LEFT JOIN dbo.tipo_examen t ON t.tipo_examen_id = i.tipo_examen_id AND t.activo = 1
               WHERE t.tipo_examen_id IS NULL)
        THROW 50022, 'Uno o más exámenes no existen o están inactivos.', 1;
    IF @cita_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.cita WHERE cita_id = @cita_id AND paciente_id = @paciente_id)
        THROW 50023, 'La cita no pertenece al paciente.', 1;

    BEGIN TRY
    BEGIN TRAN;
        INSERT INTO dbo.solicitud_examen (codigo, paciente_id, medico_id, cita_id, observaciones)
        VALUES (CONCAT('TMP-', LEFT(REPLACE(CAST(NEWID() AS CHAR(36)), '-', ''), 16)), @paciente_id, @medico_id, @cita_id, @observaciones);
        SET @solicitud_id = SCOPE_IDENTITY();

        INSERT INTO dbo.solicitud_detalle (solicitud_id, tipo_examen_id, precio_unitario)
        SELECT @solicitud_id, t.tipo_examen_id, t.precio
        FROM @items i JOIN dbo.tipo_examen t ON t.tipo_examen_id = i.tipo_examen_id;

        UPDATE dbo.solicitud_examen
        SET codigo = CONCAT('SOL-', YEAR(SYSUTCDATETIME()), '-', RIGHT(CONCAT('000000', @solicitud_id), 6)),
            total  = (SELECT SUM(precio_unitario) FROM dbo.solicitud_detalle WHERE solicitud_id = @solicitud_id)
        WHERE solicitud_id = @solicitud_id;

        DECLARE @det NVARCHAR(MAX) = CONCAT(N'{"paciente_id":', @paciente_id, N',"examenes":', @examenes, N'}');
        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @accion = 'CREAR_SOLICITUD', @entidad = 'solicitud_examen',
             @entidad_id = @solicitud_id, @detalle = @det;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------
   Pagos. La API crea el pago (PENDIENTE) al abrir Stripe Checkout y el
   webhook de Stripe lo confirma o rechaza. Idempotente: si el webhook
   llega dos veces, la segunda no hace nada.
   ------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_crear_pago
    @solicitud_id                BIGINT,
    @metodo                      VARCHAR(20),
    @stripe_checkout_session_id  VARCHAR(100) = NULL,
    @referencia_transferencia    VARCHAR(50) = NULL,
    @usuario_id                  BIGINT = NULL,
    @pago_id                     BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @total DECIMAL(10,2), @estado VARCHAR(20);

    BEGIN TRY
    BEGIN TRAN;
        SELECT @total = total, @estado = estado
        FROM dbo.solicitud_examen WITH (UPDLOCK, HOLDLOCK)
        WHERE solicitud_id = @solicitud_id;

        IF @total IS NULL THROW 50030, 'La solicitud no existe.', 1;
        IF @estado <> 'REGISTRADA' THROW 50031, 'La solicitud ya fue pagada o anulada.', 1;

        -- Un pago pendiente anterior queda expirado (el paciente reintentó).
        UPDATE dbo.pago SET estado = 'EXPIRADO', updated_at = SYSUTCDATETIME()
        WHERE solicitud_id = @solicitud_id AND estado = 'PENDIENTE';

        INSERT INTO dbo.pago (solicitud_id, monto, metodo, stripe_checkout_session_id, referencia_transferencia, expira_at)
        VALUES (@solicitud_id, @total, @metodo, @stripe_checkout_session_id, @referencia_transferencia,
                DATEADD(MINUTE, 30, SYSUTCDATETIME()));
        SET @pago_id = SCOPE_IDENTITY();

        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @accion = 'CREAR_PAGO', @entidad = 'pago', @entidad_id = @pago_id;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_confirmar_pago
    @pago_id                   BIGINT,
    @aprobado                  BIT,
    @stripe_payment_intent_id  VARCHAR(100) = NULL,
    @motivo_rechazo            NVARCHAR(300) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @estado VARCHAR(20), @solicitud_id BIGINT, @cita_id BIGINT, @persona_id BIGINT,
            @email VARCHAR(150), @codigo VARCHAR(20), @monto DECIMAL(10,2);

    BEGIN TRY
    BEGIN TRAN;
        SELECT @estado = p.estado, @solicitud_id = p.solicitud_id, @monto = p.monto
        FROM dbo.pago p WITH (UPDLOCK, HOLDLOCK)
        WHERE p.pago_id = @pago_id;

        IF @estado IS NULL THROW 50032, 'El pago no existe.', 1;

        -- Idempotente: un evento repetido no hace nada. Un intento rechazado
        -- sí puede pasar a APROBADO (el paciente reintentó con otra tarjeta
        -- en la misma sesión de Stripe Checkout).
        IF @estado IN ('APROBADO', 'REEMBOLSADO', 'REEMBOLSO_PARCIAL', 'EXPIRADO')
           OR (@estado = 'RECHAZADO' AND @aprobado = 0)
        BEGIN
            COMMIT;
            RETURN;
        END;

        SELECT @cita_id = s.cita_id, @codigo = s.codigo, @persona_id = pe.persona_id, @email = pe.email
        FROM dbo.solicitud_examen s
        JOIN dbo.paciente pa ON pa.paciente_id = s.paciente_id
        JOIN dbo.persona pe ON pe.persona_id = pa.persona_id
        WHERE s.solicitud_id = @solicitud_id;

        IF @aprobado = 1
        BEGIN
            UPDATE dbo.pago SET estado = 'APROBADO', stripe_payment_intent_id = @stripe_payment_intent_id,
                   confirmado_at = SYSUTCDATETIME(), updated_at = SYSUTCDATETIME()
            WHERE pago_id = @pago_id;

            UPDATE dbo.solicitud_examen SET estado = 'PAGADA', updated_at = SYSUTCDATETIME()
            WHERE solicitud_id = @solicitud_id;

            IF @cita_id IS NOT NULL
                UPDATE dbo.cita SET estado = 'CONFIRMADA', updated_at = SYSUTCDATETIME()
                WHERE cita_id = @cita_id AND estado = 'PENDIENTE_PAGO';

            IF @email IS NOT NULL
                INSERT INTO dbo.notificacion (persona_id, tipo, destinatario, asunto, cuerpo)
                VALUES (@persona_id, 'PAGO_APROBADO', @email,
                        CONCAT(N'Pago confirmado - ', @codigo),
                        CONCAT(N'Su pago de USD ', @monto, N' para la solicitud ', @codigo, N' fue aprobado.'));
        END
        ELSE
        BEGIN
            UPDATE dbo.pago SET estado = 'RECHAZADO', motivo_rechazo = @motivo_rechazo,
                   stripe_payment_intent_id = ISNULL(@stripe_payment_intent_id, stripe_payment_intent_id),
                   updated_at = SYSUTCDATETIME()
            WHERE pago_id = @pago_id;

            IF @email IS NOT NULL
                INSERT INTO dbo.notificacion (persona_id, tipo, destinatario, asunto, cuerpo)
                VALUES (@persona_id, 'PAGO_RECHAZADO', @email,
                        CONCAT(N'Pago rechazado - ', @codigo),
                        CONCAT(N'Su pago para la solicitud ', @codigo, N' no fue aprobado: ', ISNULL(@motivo_rechazo, N'sin detalle'), N'. Puede intentarlo nuevamente.'));
        END;

        DECLARE @det NVARCHAR(300) = CONCAT(N'{"aprobado":', IIF(@aprobado = 1, 'true', 'false'),
                                             N',"payment_intent":"', ISNULL(@stripe_payment_intent_id, ''), N'"}');
        EXEC dbo.sp_auditar @accion = 'CONFIRMAR_PAGO', @entidad = 'pago', @entidad_id = @pago_id, @detalle = @det;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_registrar_reembolso
    @pago_id           BIGINT,
    @monto             DECIMAL(10,2),
    @motivo            NVARCHAR(300),
    @stripe_refund_id  VARCHAR(100) = NULL,
    @admin_id          BIGINT,
    @reembolso_id      BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @estado VARCHAR(20), @pagado DECIMAL(10,2), @reembolsado DECIMAL(10,2), @solicitud_id BIGINT;

    BEGIN TRY
    BEGIN TRAN;
        SELECT @estado = estado, @pagado = monto, @reembolsado = monto_reembolsado, @solicitud_id = solicitud_id
        FROM dbo.pago WITH (UPDLOCK, HOLDLOCK)
        WHERE pago_id = @pago_id;

        IF @estado IS NULL THROW 50040, 'El pago no existe.', 1;
        IF @estado NOT IN ('APROBADO', 'REEMBOLSO_PARCIAL') THROW 50041, 'Solo se reembolsan pagos aprobados.', 1;
        IF @monto + @reembolsado > @pagado THROW 50042, 'El reembolso supera el monto pagado.', 1;

        INSERT INTO dbo.reembolso (pago_id, monto, motivo, estado, stripe_refund_id, solicitado_por)
        VALUES (@pago_id, @monto, @motivo, IIF(@stripe_refund_id IS NULL, 'PENDIENTE', 'EXITOSO'), @stripe_refund_id, @admin_id);
        SET @reembolso_id = SCOPE_IDENTITY();

        UPDATE dbo.pago
        SET monto_reembolsado = monto_reembolsado + @monto,
            estado = IIF(monto_reembolsado + @monto = monto, 'REEMBOLSADO', 'REEMBOLSO_PARCIAL'),
            updated_at = SYSUTCDATETIME()
        WHERE pago_id = @pago_id;

        -- Reembolso total: la solicitud queda anulada si aún no tiene resultados.
        IF @monto + @reembolsado = @pagado
           AND NOT EXISTS (SELECT 1 FROM dbo.solicitud_detalle WHERE solicitud_id = @solicitud_id AND estado = 'RESULTADO_LISTO')
            UPDATE dbo.solicitud_examen SET estado = 'ANULADA', updated_at = SYSUTCDATETIME()
            WHERE solicitud_id = @solicitud_id;

        DECLARE @det NVARCHAR(300) = CONCAT(N'{"monto":', @monto, N',"stripe_refund_id":"', ISNULL(@stripe_refund_id, ''), N'"}');
        EXEC dbo.sp_auditar @usuario_id = @admin_id, @accion = 'REEMBOLSAR_PAGO', @entidad = 'pago',
             @entidad_id = @pago_id, @detalle = @det;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------
   Registro de resultados por el laboratorista.
   @valores: JSON '[{"parametro_id":1,"valor":13.5},{"parametro_id":2,"texto":"Negativo"}]'
   Calcula fuera_rango, actualiza estados y, si la solicitud quedó
   completa, encola la notificación al paciente.
   ------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_registrar_resultado
    @detalle_id        BIGINT,
    @laboratorista_id  BIGINT,
    @valores           NVARCHAR(MAX),
    @observaciones     NVARCHAR(1000) = NULL,
    @usuario_id        BIGINT = NULL,
    @instancia_api     VARCHAR(30) = NULL,
    @resultado_id      BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @tipo_examen_id INT, @solicitud_id BIGINT, @estado_det VARCHAR(20), @estado_sol VARCHAR(20);

    IF ISJSON(@valores) = 0 THROW 50050, 'Los valores no son un JSON válido.', 1;

    BEGIN TRY
    BEGIN TRAN;
        SELECT @tipo_examen_id = d.tipo_examen_id, @solicitud_id = d.solicitud_id, @estado_det = d.estado, @estado_sol = s.estado
        FROM dbo.solicitud_detalle d WITH (UPDLOCK, HOLDLOCK)
        JOIN dbo.solicitud_examen s ON s.solicitud_id = d.solicitud_id
        WHERE d.detalle_id = @detalle_id;

        IF @tipo_examen_id IS NULL THROW 50051, 'El examen solicitado no existe.', 1;
        IF @estado_sol NOT IN ('PAGADA', 'EN_PROCESO') THROW 50052, 'La solicitud no está pagada.', 1;
        IF @estado_det IN ('RESULTADO_LISTO', 'ANULADO') THROW 50053, 'El examen ya tiene resultado o está anulado.', 1;

        -- Conflicto de interés: un laboratorista que también es paciente
        -- no puede registrar sus propios resultados.
        IF EXISTS (SELECT 1
                   FROM dbo.solicitud_examen s
                   JOIN dbo.paciente pa ON pa.paciente_id = s.paciente_id
                   JOIN dbo.laboratorista l ON l.persona_id = pa.persona_id
                   WHERE s.solicitud_id = @solicitud_id AND l.laboratorista_id = @laboratorista_id)
            THROW 50055, 'Un laboratorista no puede registrar sus propios resultados.', 1;

        DECLARE @v TABLE (parametro_id INT PRIMARY KEY, valor DECIMAL(12,3) NULL, texto NVARCHAR(200) NULL);
        INSERT INTO @v (parametro_id, valor, texto)
        SELECT parametro_id, valor, texto
        FROM OPENJSON(@valores) WITH (parametro_id INT, valor DECIMAL(12,3), texto NVARCHAR(200));

        IF EXISTS (SELECT 1 FROM @v v LEFT JOIN dbo.parametro_examen p
                     ON p.parametro_id = v.parametro_id AND p.tipo_examen_id = @tipo_examen_id
                   WHERE p.parametro_id IS NULL)
            THROW 50054, 'Hay parámetros que no pertenecen a este examen.', 1;

        INSERT INTO dbo.resultado (detalle_id, laboratorista_id, observaciones, validado, validado_at)
        VALUES (@detalle_id, @laboratorista_id, @observaciones, 1, SYSUTCDATETIME());
        SET @resultado_id = SCOPE_IDENTITY();

        INSERT INTO dbo.resultado_valor (resultado_id, parametro_id, valor_numerico, valor_texto,
                                         unidad, valor_ref_min, valor_ref_max, valor_ref_texto, fuera_rango)
        SELECT @resultado_id, v.parametro_id, v.valor, v.texto,
               p.unidad, p.valor_ref_min, p.valor_ref_max, p.valor_ref_texto,
               CASE WHEN v.valor IS NOT NULL AND (v.valor < p.valor_ref_min OR v.valor > p.valor_ref_max) THEN 1 ELSE 0 END
        FROM @v v JOIN dbo.parametro_examen p ON p.parametro_id = v.parametro_id;

        UPDATE dbo.solicitud_detalle
        SET estado = 'RESULTADO_LISTO', laboratorista_id = @laboratorista_id,
            muestra_tomada_at = ISNULL(muestra_tomada_at, SYSUTCDATETIME()), updated_at = SYSUTCDATETIME()
        WHERE detalle_id = @detalle_id;

        IF NOT EXISTS (SELECT 1 FROM dbo.solicitud_detalle
                       WHERE solicitud_id = @solicitud_id AND estado NOT IN ('RESULTADO_LISTO', 'ANULADO'))
        BEGIN
            UPDATE dbo.solicitud_examen SET estado = 'COMPLETADA', updated_at = SYSUTCDATETIME()
            WHERE solicitud_id = @solicitud_id;

            INSERT INTO dbo.notificacion (persona_id, tipo, destinatario, asunto, cuerpo)
            SELECT pe.persona_id, 'RESULTADO_LISTO', pe.email,
                   CONCAT(N'Resultados disponibles - ', s.codigo),
                   CONCAT(N'Sus resultados de la solicitud ', s.codigo, N' ya están disponibles en el portal.')
            FROM dbo.solicitud_examen s
            JOIN dbo.paciente pa ON pa.paciente_id = s.paciente_id
            JOIN dbo.persona pe ON pe.persona_id = pa.persona_id
            WHERE s.solicitud_id = @solicitud_id AND pe.email IS NOT NULL;
        END
        ELSE
            UPDATE dbo.solicitud_examen SET estado = 'EN_PROCESO', updated_at = SYSUTCDATETIME()
            WHERE solicitud_id = @solicitud_id AND estado = 'PAGADA';

        DECLARE @det NVARCHAR(200) = CONCAT(N'{"detalle_id":', @detalle_id, N',"solicitud_id":', @solicitud_id, N'}');
        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @accion = 'REGISTRAR_RESULTADO', @entidad = 'resultado',
             @entidad_id = @resultado_id, @detalle = @det, @instancia_api = @instancia_api;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------
   Seguimiento médico. Un médico que también es paciente no puede
   registrarse tratamientos ni observaciones a sí mismo.
   ------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_registrar_tratamiento
    @paciente_id     BIGINT,
    @medico_id       BIGINT,
    @diagnostico     NVARCHAR(1000),
    @indicaciones    NVARCHAR(2000),
    @fecha_inicio    DATE,
    @fecha_fin       DATE = NULL,
    @solicitud_id    BIGINT = NULL,
    @usuario_id      BIGINT = NULL,
    @tratamiento_id  BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF EXISTS (SELECT 1 FROM dbo.paciente pa JOIN dbo.medico m ON m.persona_id = pa.persona_id
               WHERE pa.paciente_id = @paciente_id AND m.medico_id = @medico_id)
        THROW 50060, 'Un médico no puede registrarse tratamientos a sí mismo.', 1;
    IF @solicitud_id IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dbo.solicitud_examen WHERE solicitud_id = @solicitud_id AND paciente_id = @paciente_id)
        THROW 50061, 'La solicitud no pertenece al paciente.', 1;

    BEGIN TRY
    BEGIN TRAN;
        INSERT INTO dbo.tratamiento (paciente_id, medico_id, solicitud_id, diagnostico, indicaciones, fecha_inicio, fecha_fin)
        VALUES (@paciente_id, @medico_id, @solicitud_id, @diagnostico, @indicaciones, @fecha_inicio, @fecha_fin);
        SET @tratamiento_id = SCOPE_IDENTITY();

        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @rol_actuante = 'MEDICO', @accion = 'REGISTRAR_TRATAMIENTO',
             @entidad = 'tratamiento', @entidad_id = @tratamiento_id;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_registrar_observacion
    @resultado_id    BIGINT,
    @medico_id       BIGINT,
    @texto           NVARCHAR(2000),
    @usuario_id      BIGINT = NULL,
    @observacion_id  BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF EXISTS (SELECT 1
               FROM dbo.resultado r
               JOIN dbo.solicitud_detalle d ON d.detalle_id = r.detalle_id
               JOIN dbo.solicitud_examen s ON s.solicitud_id = d.solicitud_id
               JOIN dbo.paciente pa ON pa.paciente_id = s.paciente_id
               JOIN dbo.medico m ON m.persona_id = pa.persona_id
               WHERE r.resultado_id = @resultado_id AND m.medico_id = @medico_id)
        THROW 50062, 'Un médico no puede registrar observaciones sobre sus propios resultados.', 1;

    BEGIN TRY
    BEGIN TRAN;
        INSERT INTO dbo.observacion_medica (resultado_id, medico_id, texto)
        VALUES (@resultado_id, @medico_id, @texto);
        SET @observacion_id = SCOPE_IDENTITY();

        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @rol_actuante = 'MEDICO', @accion = 'REGISTRAR_OBSERVACION',
             @entidad = 'observacion_medica', @entidad_id = @observacion_id;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------
   Libera cupos de citas que nunca se pagaron. Lo ejecuta el
   sincronizador en cada ciclo.
   ------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_expirar_citas_pendientes
    @minutos   INT = 30,
    @expiradas INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @canceladas TABLE (cita_id BIGINT, franja_id BIGINT);

    BEGIN TRY
    BEGIN TRAN;
        UPDATE c
        SET estado = 'CANCELADA', cancelada_at = SYSUTCDATETIME(), updated_at = SYSUTCDATETIME()
        OUTPUT inserted.cita_id, inserted.franja_id INTO @canceladas
        FROM dbo.cita c WITH (UPDLOCK, READPAST)
        WHERE c.estado = 'PENDIENTE_PAGO'
          AND c.created_at < DATEADD(MINUTE, -@minutos, SYSUTCDATETIME())
          AND NOT EXISTS (SELECT 1 FROM dbo.solicitud_examen s JOIN dbo.pago p ON p.solicitud_id = s.solicitud_id
                          WHERE s.cita_id = c.cita_id AND p.estado = 'PENDIENTE' AND p.expira_at > SYSUTCDATETIME());

        UPDATE f
        SET ocupados = f.ocupados - x.n, updated_at = SYSUTCDATETIME()
        FROM dbo.franja_horaria f
        JOIN (SELECT franja_id, COUNT(*) AS n FROM @canceladas GROUP BY franja_id) x ON x.franja_id = f.franja_id;

        SET @expiradas = (SELECT COUNT(*) FROM @canceladas);
        IF @expiradas > 0
        BEGIN
            DECLARE @det NVARCHAR(100) = CONCAT(N'{"citas_expiradas":', @expiradas, N'}');
            EXEC dbo.sp_auditar @accion = 'EXPIRAR_CITAS', @entidad = 'cita', @detalle = @det;
        END;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------
   Pago no confirmado: la sesión de Stripe venció sin pagarse.
   ------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_marcar_pago_expirado
    @pago_id BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
    BEGIN TRAN;
        UPDATE dbo.pago SET estado = 'EXPIRADO', motivo_rechazo = N'Sesión de pago vencida sin confirmar', updated_at = SYSUTCDATETIME()
        WHERE pago_id = @pago_id AND estado IN ('PENDIENTE', 'RECHAZADO');

        IF @@ROWCOUNT > 0
            EXEC dbo.sp_auditar @accion = 'EXPIRAR_PAGO', @entidad = 'pago', @entidad_id = @pago_id;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------
   Alta de usuario del personal (o de cualquier rol) por el administrador.
   Si la cédula ya existe reutiliza la persona; si ya tiene cuenta, solo
   agrega el rol.
   ------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_crear_usuario
    @cedula                VARCHAR(13),
    @nombres               NVARCHAR(100),
    @apellidos             NVARCHAR(100),
    @fecha_nacimiento      DATE,
    @sexo                  CHAR(1),
    @telefono              VARCHAR(20) = NULL,
    @email                 VARCHAR(150),
    @password_hash         VARCHAR(255),
    @rol_codigo            VARCHAR(30),
    @registro_profesional  VARCHAR(30) = NULL,
    @especialidad_o_area   NVARCHAR(100) = NULL,
    @admin_id              BIGINT = NULL,
    @usuario_id            BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @persona_id BIGINT;

    BEGIN TRY
    BEGIN TRAN;
        SELECT @persona_id = persona_id FROM dbo.persona WITH (UPDLOCK, HOLDLOCK) WHERE cedula = @cedula;
        IF @persona_id IS NULL
        BEGIN
            INSERT INTO dbo.persona (cedula, nombres, apellidos, fecha_nacimiento, sexo, telefono, email)
            VALUES (@cedula, @nombres, @apellidos, @fecha_nacimiento, @sexo, @telefono, @email);
            SET @persona_id = SCOPE_IDENTITY();
        END;

        SELECT @usuario_id = usuario_id FROM dbo.usuario WHERE persona_id = @persona_id;
        IF @usuario_id IS NULL
        BEGIN
            INSERT INTO dbo.usuario (persona_id, email, password_hash) VALUES (@persona_id, @email, @password_hash);
            SET @usuario_id = SCOPE_IDENTITY();
        END;

        EXEC dbo.sp_asignar_rol @usuario_id = @usuario_id, @rol_codigo = @rol_codigo,
             @registro_profesional = @registro_profesional, @especialidad_o_area = @especialidad_o_area, @admin_id = @admin_id;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------
   Alta de un examen en el catálogo con sus parámetros.
   @parametros: '[{"nombre":"Hemoglobina","unidad":"g/dL","valor_ref_min":12,"valor_ref_max":17.5}]'
   ------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.sp_crear_tipo_examen
    @categoria             NVARCHAR(80),
    @codigo                VARCHAR(20),
    @nombre                NVARCHAR(120),
    @descripcion           NVARCHAR(500) = NULL,
    @tipo_muestra          NVARCHAR(50),
    @precio                DECIMAL(10,2),
    @requiere_ayuno        BIT = 0,
    @indicaciones          NVARCHAR(500) = NULL,
    @tiempo_entrega_horas  SMALLINT = 24,
    @parametros            NVARCHAR(MAX),
    @usuario_id            BIGINT = NULL,
    @tipo_examen_id        BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF ISJSON(@parametros) = 0 THROW 50070, 'Los parámetros no son un JSON válido.', 1;
    DECLARE @categoria_id INT;

    BEGIN TRY
    BEGIN TRAN;
        SELECT @categoria_id = categoria_id FROM dbo.categoria_examen WITH (UPDLOCK, HOLDLOCK) WHERE nombre = @categoria;
        IF @categoria_id IS NULL
        BEGIN
            INSERT INTO dbo.categoria_examen (nombre) VALUES (@categoria);
            SET @categoria_id = SCOPE_IDENTITY();
        END;

        INSERT INTO dbo.tipo_examen (categoria_id, codigo, nombre, descripcion, tipo_muestra, precio, requiere_ayuno,
                                     indicaciones, tiempo_entrega_horas)
        VALUES (@categoria_id, @codigo, @nombre, @descripcion, @tipo_muestra, @precio, @requiere_ayuno,
                @indicaciones, @tiempo_entrega_horas);
        SET @tipo_examen_id = SCOPE_IDENTITY();

        INSERT INTO dbo.parametro_examen (tipo_examen_id, nombre, unidad, valor_ref_min, valor_ref_max, valor_ref_texto, orden)
        SELECT @tipo_examen_id, nombre, unidad, valor_ref_min, valor_ref_max, valor_ref_texto,
               ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
        FROM OPENJSON(@parametros) WITH (nombre NVARCHAR(100), unidad NVARCHAR(30), valor_ref_min DECIMAL(12,3),
                                         valor_ref_max DECIMAL(12,3), valor_ref_texto NVARCHAR(100));

        IF @@ROWCOUNT = 0 THROW 50071, 'Debe indicar al menos un parámetro.', 1;

        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @rol_actuante = 'ADMIN', @accion = 'CREAR_TIPO_EXAMEN',
             @entidad = 'tipo_examen', @entidad_id = @tipo_examen_id;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO
