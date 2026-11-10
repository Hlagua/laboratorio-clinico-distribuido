/* =====================================================================
   07_base_conocimiento.sql  -  Base de conocimientos para diagnósticos
   ---------------------------------------------------------------------
   Sistema experto basado en reglas: cada regla relaciona condiciones
   sobre los parámetros de laboratorio (y opcionalmente sexo/edad) con un
   diagnóstico CIE-10. El motor (API Flask) evalúa las reglas sobre los
   resultados de una solicitud y registra SUGERENCIAS que el médico
   acepta o descarta. El sistema sugiere, no diagnostica.
   Los umbrales son referenciales, con fines académicos.
   Ejecutar después de 01-06 (idempotente en los datos iniciales).
   ===================================================================== */

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ---------------------------------------------------------------------
   1. TABLAS
   ------------------------------------------------------------------- */
CREATE TABLE dbo.diagnostico (
    diagnostico_id  INT IDENTITY(1,1) NOT NULL,
    codigo_cie10    VARCHAR(10)    NOT NULL,
    nombre          NVARCHAR(150)  NOT NULL,
    descripcion     NVARCHAR(500)  NULL,
    updated_at      DATETIME2(3)   NOT NULL CONSTRAINT df_diag_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_diagnostico PRIMARY KEY (diagnostico_id),
    CONSTRAINT uq_diagnostico_cie10 UNIQUE (codigo_cie10)
);
GO

CREATE TABLE dbo.protocolo (
    protocolo_id    INT IDENTITY(1,1) NOT NULL,
    diagnostico_id  INT             NOT NULL,
    indicaciones    NVARCHAR(2000)  NOT NULL,
    duracion_dias   SMALLINT        NULL,          -- sugerida para fecha_fin del tratamiento
    updated_at      DATETIME2(3)    NOT NULL CONSTRAINT df_prot_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_protocolo PRIMARY KEY (protocolo_id),
    CONSTRAINT uq_protocolo_diagnostico UNIQUE (diagnostico_id),   -- un protocolo base por diagnóstico
    CONSTRAINT fk_prot_diagnostico FOREIGN KEY (diagnostico_id) REFERENCES dbo.diagnostico(diagnostico_id),
    CONSTRAINT ck_prot_duracion CHECK (duracion_dias IS NULL OR duracion_dias > 0)
);
GO

CREATE TABLE dbo.regla_diagnostica (
    regla_id        INT IDENTITY(1,1) NOT NULL,
    codigo          VARCHAR(30)     NOT NULL,       -- ej. R-GLU-DIABETES
    diagnostico_id  INT             NOT NULL,
    logica          VARCHAR(10)     NOT NULL CONSTRAINT df_regla_logica DEFAULT 'TODAS',   -- TODAS (Y) / ALGUNA (O)
    sexo            CHAR(1)         NULL,           -- NULL = cualquiera
    edad_min        TINYINT         NULL,
    edad_max        TINYINT         NULL,
    confianza       VARCHAR(10)     NOT NULL,
    recomendacion   NVARCHAR(500)   NOT NULL,
    fuente          NVARCHAR(200)   NULL,           -- guía o referencia bibliográfica
    guia_clave      VARCHAR(50)     NULL,           -- documento en MongoDB (colección guias_clinicas)
    activa          BIT             NOT NULL CONSTRAINT df_regla_activa DEFAULT 1,
    updated_at      DATETIME2(3)    NOT NULL CONSTRAINT df_regla_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_regla_diagnostica PRIMARY KEY (regla_id),
    CONSTRAINT uq_regla_codigo UNIQUE (codigo),
    CONSTRAINT fk_regla_diagnostico FOREIGN KEY (diagnostico_id) REFERENCES dbo.diagnostico(diagnostico_id),
    CONSTRAINT ck_regla_logica CHECK (logica IN ('TODAS', 'ALGUNA')),
    CONSTRAINT ck_regla_sexo CHECK (sexo IS NULL OR sexo IN ('M', 'F')),
    CONSTRAINT ck_regla_edad CHECK (edad_min IS NULL OR edad_max IS NULL OR edad_min <= edad_max),
    CONSTRAINT ck_regla_confianza CHECK (confianza IN ('BAJA', 'MEDIA', 'ALTA'))
);
GO

CREATE TABLE dbo.regla_condicion (
    condicion_id  INT IDENTITY(1,1) NOT NULL,
    regla_id      INT            NOT NULL,
    parametro_id  INT            NOT NULL,
    operador      VARCHAR(6)     NOT NULL,          -- <, <=, >, >=, ENTRE
    valor         DECIMAL(12,3)  NOT NULL,
    valor2        DECIMAL(12,3)  NULL,              -- límite superior para ENTRE
    updated_at    DATETIME2(3)   NOT NULL CONSTRAINT df_cond_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_regla_condicion PRIMARY KEY (condicion_id),
    CONSTRAINT fk_cond_regla FOREIGN KEY (regla_id) REFERENCES dbo.regla_diagnostica(regla_id),
    CONSTRAINT fk_cond_parametro FOREIGN KEY (parametro_id) REFERENCES dbo.parametro_examen(parametro_id),
    CONSTRAINT ck_cond_operador CHECK (operador IN ('<', '<=', '>', '>=', 'ENTRE')),
    CONSTRAINT ck_cond_entre CHECK ((operador = 'ENTRE' AND valor2 IS NOT NULL AND valor2 >= valor) OR (operador <> 'ENTRE' AND valor2 IS NULL))
);
GO
CREATE INDEX ix_cond_regla ON dbo.regla_condicion (regla_id);
GO

CREATE TABLE dbo.sugerencia_diagnostica (
    sugerencia_id   BIGINT IDENTITY(1,1) NOT NULL,
    solicitud_id    BIGINT          NOT NULL,
    paciente_id     BIGINT          NOT NULL,
    regla_id        INT             NOT NULL,
    diagnostico_id  INT             NOT NULL,
    explicacion     NVARCHAR(1000)  NOT NULL,       -- qué valores activaron la regla
    confianza       VARCHAR(10)     NOT NULL,
    estado          VARCHAR(12)     NOT NULL CONSTRAINT df_sug_estado DEFAULT 'PENDIENTE',
    motivo          NVARCHAR(300)   NULL,           -- motivo del descarte o comentario del médico
    medico_id       BIGINT          NULL,           -- quien respondió
    tratamiento_id  BIGINT          NULL,           -- tratamiento creado a partir de la sugerencia
    respondida_at   DATETIME2(3)    NULL,
    created_at      DATETIME2(3)    NOT NULL CONSTRAINT df_sug_created DEFAULT SYSUTCDATETIME(),
    updated_at      DATETIME2(3)    NOT NULL CONSTRAINT df_sug_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_sugerencia_diagnostica PRIMARY KEY (sugerencia_id),
    CONSTRAINT uq_sugerencia_regla UNIQUE (solicitud_id, regla_id),   -- una vez por regla y solicitud
    CONSTRAINT fk_sug_solicitud FOREIGN KEY (solicitud_id) REFERENCES dbo.solicitud_examen(solicitud_id),
    CONSTRAINT fk_sug_paciente FOREIGN KEY (paciente_id) REFERENCES dbo.paciente(paciente_id),
    CONSTRAINT fk_sug_regla FOREIGN KEY (regla_id) REFERENCES dbo.regla_diagnostica(regla_id),
    CONSTRAINT fk_sug_diagnostico FOREIGN KEY (diagnostico_id) REFERENCES dbo.diagnostico(diagnostico_id),
    CONSTRAINT fk_sug_medico FOREIGN KEY (medico_id) REFERENCES dbo.medico(medico_id),
    CONSTRAINT fk_sug_tratamiento FOREIGN KEY (tratamiento_id) REFERENCES dbo.tratamiento(tratamiento_id),
    CONSTRAINT ck_sug_estado CHECK (estado IN ('PENDIENTE', 'ACEPTADA', 'DESCARTADA')),
    CONSTRAINT ck_sug_confianza CHECK (confianza IN ('BAJA', 'MEDIA', 'ALTA'))
);
GO
CREATE INDEX ix_sug_paciente ON dbo.sugerencia_diagnostica (paciente_id);
GO

/* Precisión de cada regla según las respuestas de los médicos. */
CREATE OR ALTER VIEW dbo.vw_precision_regla AS
SELECT r.regla_id, r.codigo,
       COUNT(s.sugerencia_id) AS sugerencias,
       SUM(CASE WHEN s.estado = 'ACEPTADA' THEN 1 ELSE 0 END) AS aceptadas,
       SUM(CASE WHEN s.estado = 'DESCARTADA' THEN 1 ELSE 0 END) AS descartadas,
       CAST(100.0 * SUM(CASE WHEN s.estado = 'ACEPTADA' THEN 1 ELSE 0 END)
            / NULLIF(SUM(CASE WHEN s.estado <> 'PENDIENTE' THEN 1 ELSE 0 END), 0) AS DECIMAL(5,1)) AS precision_pct
FROM dbo.regla_diagnostica r
LEFT JOIN dbo.sugerencia_diagnostica s ON s.regla_id = r.regla_id
GROUP BY r.regla_id, r.codigo;
GO

/* ---------------------------------------------------------------------
   2. CHANGE TRACKING (se replican a Supabase: consultables en contingencia)
   ------------------------------------------------------------------- */
ALTER TABLE dbo.diagnostico            ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.protocolo              ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.regla_diagnostica      ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.regla_condicion        ENABLE CHANGE_TRACKING;
ALTER TABLE dbo.sugerencia_diagnostica ENABLE CHANGE_TRACKING;
GO

/* ---------------------------------------------------------------------
   3. PROCEDIMIENTOS
   ------------------------------------------------------------------- */

/* Registra las sugerencias que calculó el motor (idempotente: una regla
   que ya sugirió para la solicitud no se repite).
   @sugerencias: '[{"regla_id":1,"explicacion":"Glucosa 148 >= 126"}]' */
CREATE OR ALTER PROCEDURE dbo.sp_registrar_sugerencias
    @solicitud_id  BIGINT,
    @sugerencias   NVARCHAR(MAX),
    @usuario_id    BIGINT = NULL,
    @nuevas        INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF ISJSON(@sugerencias) = 0 THROW 50080, 'Las sugerencias no son un JSON válido.', 1;
    DECLARE @paciente_id BIGINT = (SELECT paciente_id FROM dbo.solicitud_examen WHERE solicitud_id = @solicitud_id);
    IF @paciente_id IS NULL THROW 50081, 'La solicitud no existe.', 1;

    BEGIN TRY
    BEGIN TRAN;
        INSERT INTO dbo.sugerencia_diagnostica (solicitud_id, paciente_id, regla_id, diagnostico_id, explicacion, confianza)
        SELECT @solicitud_id, @paciente_id, r.regla_id, r.diagnostico_id, j.explicacion, r.confianza
        FROM OPENJSON(@sugerencias) WITH (regla_id INT, explicacion NVARCHAR(1000)) j
        JOIN dbo.regla_diagnostica r ON r.regla_id = j.regla_id
        WHERE NOT EXISTS (SELECT 1 FROM dbo.sugerencia_diagnostica s
                          WHERE s.solicitud_id = @solicitud_id AND s.regla_id = j.regla_id);
        SET @nuevas = @@ROWCOUNT;

        IF @nuevas > 0
        BEGIN
            DECLARE @det NVARCHAR(200) = CONCAT(N'{"solicitud_id":', @solicitud_id, N',"nuevas":', @nuevas, N'}');
            EXEC dbo.sp_auditar @usuario_id = @usuario_id, @accion = 'SUGERIR_DIAGNOSTICOS',
                 @entidad = 'solicitud_examen', @entidad_id = @solicitud_id, @detalle = @det;
        END;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* El médico acepta o descarta una sugerencia. Un médico que también es
   paciente no puede responder sugerencias sobre sí mismo. */
CREATE OR ALTER PROCEDURE dbo.sp_responder_sugerencia
    @sugerencia_id   BIGINT,
    @medico_id       BIGINT,
    @aceptar         BIT,
    @motivo          NVARCHAR(300) = NULL,
    @tratamiento_id  BIGINT = NULL,
    @usuario_id      BIGINT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @estado VARCHAR(12), @paciente_id BIGINT;

    BEGIN TRY
    BEGIN TRAN;
        SELECT @estado = estado, @paciente_id = paciente_id
        FROM dbo.sugerencia_diagnostica WITH (UPDLOCK, HOLDLOCK)
        WHERE sugerencia_id = @sugerencia_id;

        IF @estado IS NULL THROW 50082, 'La sugerencia no existe.', 1;
        IF @estado <> 'PENDIENTE' THROW 50083, 'La sugerencia ya fue respondida.', 1;
        IF @aceptar = 0 AND NULLIF(LTRIM(RTRIM(@motivo)), N'') IS NULL
            THROW 50084, 'Indique el motivo del descarte.', 1;
        IF EXISTS (SELECT 1 FROM dbo.paciente pa JOIN dbo.medico m ON m.persona_id = pa.persona_id
                   WHERE pa.paciente_id = @paciente_id AND m.medico_id = @medico_id)
            THROW 50085, 'Un médico no puede responder sugerencias sobre sí mismo.', 1;
        IF @tratamiento_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.tratamiento
                   WHERE tratamiento_id = @tratamiento_id AND paciente_id = @paciente_id)
            THROW 50086, 'El tratamiento no pertenece al paciente.', 1;

        UPDATE dbo.sugerencia_diagnostica
        SET estado = IIF(@aceptar = 1, 'ACEPTADA', 'DESCARTADA'), motivo = @motivo, medico_id = @medico_id,
            tratamiento_id = @tratamiento_id, respondida_at = SYSUTCDATETIME(), updated_at = SYSUTCDATETIME()
        WHERE sugerencia_id = @sugerencia_id;

        DECLARE @det NVARCHAR(400) = CONCAT(N'{"aceptada":', IIF(@aceptar = 1, 'true', 'false'),
                                             N',"tratamiento_id":', ISNULL(CAST(@tratamiento_id AS VARCHAR(20)), 'null'), N'}');
        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @rol_actuante = 'MEDICO', @accion = 'RESPONDER_SUGERENCIA',
             @entidad = 'sugerencia_diagnostica', @entidad_id = @sugerencia_id, @detalle = @det;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* Crea o reemplaza una regla con sus condiciones (administrador).
   @condiciones: '[{"parametro_id":5,"operador":">=","valor":126}]' */
CREATE OR ALTER PROCEDURE dbo.sp_guardar_regla
    @codigo          VARCHAR(30),
    @diagnostico_id  INT,
    @logica          VARCHAR(10),
    @confianza       VARCHAR(10),
    @recomendacion   NVARCHAR(500),
    @condiciones     NVARCHAR(MAX),
    @sexo            CHAR(1) = NULL,
    @edad_min        TINYINT = NULL,
    @edad_max        TINYINT = NULL,
    @fuente          NVARCHAR(200) = NULL,
    @guia_clave      VARCHAR(50) = NULL,
    @usuario_id      BIGINT = NULL,
    @regla_id        BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    IF ISJSON(@condiciones) = 0 THROW 50087, 'Las condiciones no son un JSON válido.', 1;
    IF NOT EXISTS (SELECT 1 FROM OPENJSON(@condiciones)) THROW 50088, 'La regla necesita al menos una condición.', 1;
    -- Es un parámetro OUTPUT: si el llamador reutiliza la variable, llega con el
    -- id de la llamada anterior y se actualizaría otra regla.
    SET @regla_id = NULL;

    BEGIN TRY
    BEGIN TRAN;
        SELECT @regla_id = regla_id FROM dbo.regla_diagnostica WITH (UPDLOCK, HOLDLOCK) WHERE codigo = @codigo;
        IF @regla_id IS NULL
        BEGIN
            INSERT INTO dbo.regla_diagnostica (codigo, diagnostico_id, logica, sexo, edad_min, edad_max, confianza,
                                               recomendacion, fuente, guia_clave)
            VALUES (@codigo, @diagnostico_id, @logica, @sexo, @edad_min, @edad_max, @confianza, @recomendacion, @fuente, @guia_clave);
            SET @regla_id = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            UPDATE dbo.regla_diagnostica
            SET diagnostico_id = @diagnostico_id, logica = @logica, sexo = @sexo, edad_min = @edad_min, edad_max = @edad_max,
                confianza = @confianza, recomendacion = @recomendacion, fuente = @fuente, guia_clave = @guia_clave,
                updated_at = SYSUTCDATETIME()
            WHERE regla_id = @regla_id;
            DELETE FROM dbo.regla_condicion WHERE regla_id = @regla_id;
        END;

        INSERT INTO dbo.regla_condicion (regla_id, parametro_id, operador, valor, valor2)
        SELECT @regla_id, parametro_id, operador, valor, valor2
        FROM OPENJSON(@condiciones) WITH (parametro_id INT, operador VARCHAR(6), valor DECIMAL(12,3), valor2 DECIMAL(12,3));

        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @rol_actuante = 'ADMIN', @accion = 'GUARDAR_REGLA',
             @entidad = 'regla_diagnostica', @entidad_id = @regla_id;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------
   4. CONOCIMIENTO INICIAL (umbrales referenciales, uso académico)
   ------------------------------------------------------------------- */
MERGE dbo.diagnostico AS d
USING (VALUES
 ('R73.0', N'Glucosa alterada en ayunas',            N'Glucemia en ayunas por encima de lo normal sin alcanzar el umbral de diabetes.'),
 ('E11',   N'Diabetes mellitus tipo 2 (probable)',  N'Glucemia en ayunas en rango diabético; requiere confirmación con una segunda medición o HbA1c.'),
 ('D64.9', N'Anemia, no especificada',               N'Hemoglobina y/o hematocrito por debajo del rango esperado.'),
 ('E78.0', N'Hipercolesterolemia pura',              N'Colesterol total o LDL elevados.'),
 ('E78.1', N'Hipertrigliceridemia pura',             N'Triglicéridos elevados.'),
 ('E03.9', N'Hipotiroidismo (probable)',             N'TSH elevada.'),
 ('E05.9', N'Hipertiroidismo (probable)',            N'TSH suprimida.'),
 ('N28.9', N'Alteración de la función renal',        N'Creatinina y urea elevadas.'),
 ('D72.8', N'Leucocitosis',                          N'Recuento de leucocitos elevado; posible proceso infeccioso o inflamatorio.'),
 ('R79.8', N'Marcador inflamatorio elevado',         N'Proteína C reactiva por encima del valor de referencia.')
) AS v(codigo, nombre, descripcion) ON d.codigo_cie10 = v.codigo
WHEN NOT MATCHED THEN INSERT (codigo_cie10, nombre, descripcion) VALUES (v.codigo, v.nombre, v.descripcion);

MERGE dbo.protocolo AS p
USING (SELECT d.diagnostico_id, v.indicaciones, v.duracion
       FROM (VALUES
        ('R73.0', N'Dieta baja en azúcares simples, actividad física 150 min/semana, control de glucosa en ayunas en 3 meses.', 90),
        ('E11',   N'Confirmar con segunda glucosa en ayunas o HbA1c. Dieta, actividad física y valorar metformina según criterio médico.', 90),
        ('D64.9', N'Biometría de control, ferritina y hierro sérico. Dieta rica en hierro; valorar suplementación según causa.', 60),
        ('E78.0', N'Dieta baja en grasas saturadas, ejercicio aeróbico; valorar estatina según riesgo cardiovascular. Perfil lipídico en 8 semanas.', 60),
        ('E78.1', N'Reducir azúcares y alcohol, ejercicio regular. Perfil lipídico en 8 semanas.', 60),
        ('E03.9', N'Solicitar T4 libre. Valorar levotiroxina según resultado y síntomas.', 45),
        ('E05.9', N'Solicitar T3 y T4 libre; derivar a endocrinología.', 30),
        ('N28.9', N'Hidratación, evitar nefrotóxicos (AINE). Repetir creatinina y urea; examen de orina.', 30),
        ('D72.8', N'Correlacionar con clínica; repetir biometría en 1-2 semanas.', 14),
        ('R79.8', N'Correlacionar con clínica; repetir PCR según evolución.', 14)
       ) v(codigo, indicaciones, duracion)
       JOIN dbo.diagnostico d ON d.codigo_cie10 = v.codigo) AS s
ON p.diagnostico_id = s.diagnostico_id
WHEN NOT MATCHED THEN INSERT (diagnostico_id, indicaciones, duracion_dias) VALUES (s.diagnostico_id, s.indicaciones, s.duracion);
GO

/* Reglas iniciales: se crean con el mismo procedimiento que usa el administrador. */
DECLARE @r BIGINT, @c NVARCHAR(MAX);
DECLARE @p_glu INT = (SELECT pm.parametro_id FROM dbo.parametro_examen pm JOIN dbo.tipo_examen t ON t.tipo_examen_id = pm.tipo_examen_id WHERE t.codigo = 'QS-GLU' AND pm.nombre = N'Glucosa');
DECLARE @p_hb  INT = (SELECT pm.parametro_id FROM dbo.parametro_examen pm JOIN dbo.tipo_examen t ON t.tipo_examen_id = pm.tipo_examen_id WHERE t.codigo = 'HEM-BH' AND pm.nombre = N'Hemoglobina');
DECLARE @p_hto INT = (SELECT pm.parametro_id FROM dbo.parametro_examen pm JOIN dbo.tipo_examen t ON t.tipo_examen_id = pm.tipo_examen_id WHERE t.codigo = 'HEM-BH' AND pm.nombre = N'Hematocrito');
DECLARE @p_leu INT = (SELECT pm.parametro_id FROM dbo.parametro_examen pm JOIN dbo.tipo_examen t ON t.tipo_examen_id = pm.tipo_examen_id WHERE t.codigo = 'HEM-BH' AND pm.nombre = N'Leucocitos');
DECLARE @p_col INT = (SELECT pm.parametro_id FROM dbo.parametro_examen pm JOIN dbo.tipo_examen t ON t.tipo_examen_id = pm.tipo_examen_id WHERE t.codigo = 'QS-LIP' AND pm.nombre = N'Colesterol total');
DECLARE @p_ldl INT = (SELECT pm.parametro_id FROM dbo.parametro_examen pm JOIN dbo.tipo_examen t ON t.tipo_examen_id = pm.tipo_examen_id WHERE t.codigo = 'QS-LIP' AND pm.nombre = N'LDL');
DECLARE @p_tg  INT = (SELECT pm.parametro_id FROM dbo.parametro_examen pm JOIN dbo.tipo_examen t ON t.tipo_examen_id = pm.tipo_examen_id WHERE t.codigo = 'QS-LIP' AND pm.nombre = N'Triglicéridos');
DECLARE @p_tsh INT = (SELECT pm.parametro_id FROM dbo.parametro_examen pm JOIN dbo.tipo_examen t ON t.tipo_examen_id = pm.tipo_examen_id WHERE t.codigo = 'IN-TSH' AND pm.nombre = N'TSH');
DECLARE @p_cre INT = (SELECT pm.parametro_id FROM dbo.parametro_examen pm JOIN dbo.tipo_examen t ON t.tipo_examen_id = pm.tipo_examen_id WHERE t.codigo = 'QS-CRE' AND pm.nombre = N'Creatinina');
DECLARE @p_ure INT = (SELECT pm.parametro_id FROM dbo.parametro_examen pm JOIN dbo.tipo_examen t ON t.tipo_examen_id = pm.tipo_examen_id WHERE t.codigo = 'QS-URE' AND pm.nombre = N'Urea');
DECLARE @p_pcr INT = (SELECT pm.parametro_id FROM dbo.parametro_examen pm JOIN dbo.tipo_examen t ON t.tipo_examen_id = pm.tipo_examen_id WHERE t.codigo = 'IN-PCR' AND pm.nombre = N'PCR');
DECLARE @d TABLE (codigo VARCHAR(10) PRIMARY KEY, id INT);
INSERT INTO @d SELECT codigo_cie10, diagnostico_id FROM dbo.diagnostico;
DECLARE @dx INT;

SET @dx = (SELECT id FROM @d WHERE codigo = 'R73.0');
SET @c = CONCAT('[{"parametro_id":', @p_glu, ',"operador":"ENTRE","valor":100,"valor2":125.9}]');
EXEC dbo.sp_guardar_regla 'R-GLU-ALTERADA', @dx, 'TODAS', 'MEDIA', N'Repetir glucosa en ayunas; considerar HbA1c.', @c,
     @fuente = N'ADA, Standards of Care in Diabetes', @guia_clave = 'diabetes', @regla_id = @r OUTPUT;

SET @dx = (SELECT id FROM @d WHERE codigo = 'E11');
SET @c = CONCAT('[{"parametro_id":', @p_glu, ',"operador":">=","valor":126}]');
EXEC dbo.sp_guardar_regla 'R-GLU-DIABETES', @dx, 'TODAS', 'MEDIA', N'Confirmar con una segunda glucosa en ayunas o HbA1c antes de diagnosticar.', @c,
     @fuente = N'ADA, Standards of Care in Diabetes', @guia_clave = 'diabetes', @regla_id = @r OUTPUT;

SET @dx = (SELECT id FROM @d WHERE codigo = 'D64.9');
SET @c = CONCAT('[{"parametro_id":', @p_hb, ',"operador":"<","valor":12},{"parametro_id":', @p_hto, ',"operador":"<","valor":36}]');
EXEC dbo.sp_guardar_regla 'R-HB-ANEMIA-F', @dx, 'ALGUNA', 'ALTA', N'Solicitar ferritina, hierro sérico y frotis de sangre periférica.', @c,
     @sexo = 'F', @fuente = N'OMS, valores de hemoglobina para anemia', @guia_clave = 'anemia', @regla_id = @r OUTPUT;
SET @c = CONCAT('[{"parametro_id":', @p_hb, ',"operador":"<","valor":13},{"parametro_id":', @p_hto, ',"operador":"<","valor":39}]');
EXEC dbo.sp_guardar_regla 'R-HB-ANEMIA-M', @dx, 'ALGUNA', 'ALTA', N'Solicitar ferritina, hierro sérico y frotis de sangre periférica.', @c,
     @sexo = 'M', @fuente = N'OMS, valores de hemoglobina para anemia', @guia_clave = 'anemia', @regla_id = @r OUTPUT;

SET @dx = (SELECT id FROM @d WHERE codigo = 'E78.0');
SET @c = CONCAT('[{"parametro_id":', @p_col, ',"operador":">","valor":240},{"parametro_id":', @p_ldl, ',"operador":">","valor":160}]');
EXEC dbo.sp_guardar_regla 'R-LIP-COLESTEROL', @dx, 'ALGUNA', 'MEDIA', N'Estimar riesgo cardiovascular global; repetir perfil lipídico en ayunas.', @c,
     @fuente = N'Guía ESC/EAS de dislipidemias', @guia_clave = 'dislipidemia', @regla_id = @r OUTPUT;

SET @dx = (SELECT id FROM @d WHERE codigo = 'E78.1');
SET @c = CONCAT('[{"parametro_id":', @p_tg, ',"operador":">","valor":200}]');
EXEC dbo.sp_guardar_regla 'R-LIP-TRIGLICERIDOS', @dx, 'TODAS', 'MEDIA', N'Confirmar en ayunas de 12 horas; revisar consumo de alcohol y azúcares.', @c,
     @fuente = N'Guía ESC/EAS de dislipidemias', @guia_clave = 'dislipidemia', @regla_id = @r OUTPUT;

SET @dx = (SELECT id FROM @d WHERE codigo = 'E03.9');
SET @c = CONCAT('[{"parametro_id":', @p_tsh, ',"operador":">","valor":4.5}]');
EXEC dbo.sp_guardar_regla 'R-TSH-HIPOTIROIDISMO', @dx, 'TODAS', 'MEDIA', N'Solicitar T4 libre para diferenciar hipotiroidismo clínico de subclínico.', @c,
     @fuente = N'ATA, guía de hipotiroidismo', @guia_clave = 'tiroides', @regla_id = @r OUTPUT;

SET @dx = (SELECT id FROM @d WHERE codigo = 'E05.9');
SET @c = CONCAT('[{"parametro_id":', @p_tsh, ',"operador":"<","valor":0.3}]');
EXEC dbo.sp_guardar_regla 'R-TSH-HIPERTIROIDISMO', @dx, 'TODAS', 'MEDIA', N'Solicitar T3 y T4 libre; valorar derivación a endocrinología.', @c,
     @fuente = N'ATA, guía de hipertiroidismo', @guia_clave = 'tiroides', @regla_id = @r OUTPUT;

SET @dx = (SELECT id FROM @d WHERE codigo = 'N28.9');
SET @c = CONCAT('[{"parametro_id":', @p_cre, ',"operador":">","valor":1.3},{"parametro_id":', @p_ure, ',"operador":">","valor":45}]');
EXEC dbo.sp_guardar_regla 'R-RENAL', @dx, 'TODAS', 'ALTA', N'Calcular tasa de filtración glomerular estimada y solicitar examen de orina.', @c,
     @fuente = N'KDIGO, guía de enfermedad renal crónica', @guia_clave = 'renal', @regla_id = @r OUTPUT;

SET @dx = (SELECT id FROM @d WHERE codigo = 'D72.8');
SET @c = CONCAT('[{"parametro_id":', @p_leu, ',"operador":">","valor":11}]');
EXEC dbo.sp_guardar_regla 'R-LEUCOCITOSIS', @dx, 'TODAS', 'BAJA', N'Correlacionar con la clínica y la fórmula leucocitaria.', @c,
     @fuente = N'Referencia hematológica general', @regla_id = @r OUTPUT;

SET @dx = (SELECT id FROM @d WHERE codigo = 'R79.8');
SET @c = CONCAT('[{"parametro_id":', @p_pcr, ',"operador":">","valor":10}]');
EXEC dbo.sp_guardar_regla 'R-PCR-ELEVADA', @dx, 'TODAS', 'BAJA', N'Buscar foco infeccioso o inflamatorio; repetir según evolución.', @c,
     @fuente = N'Referencia de marcadores inflamatorios', @regla_id = @r OUTPUT;
GO

/* El usuario de las APIs activa/desactiva reglas directamente (el resto
   de escrituras pasa por los procedimientos, cubiertos por EXECUTE). */
IF USER_ID('app_api') IS NOT NULL
    GRANT UPDATE ON dbo.regla_diagnostica TO app_api;
GO
