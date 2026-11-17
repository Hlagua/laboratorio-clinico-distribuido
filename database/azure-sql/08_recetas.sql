/* =====================================================================
   08_recetas.sql  -  Medicamentos en la base de conocimientos y recetas
   ---------------------------------------------------------------------
   La base de conocimientos se amplía con un vademécum básico:
   - medicamento: dosis, frecuencia, duración e indicaciones habituales;
   - diagnostico_medicamento: qué medicamentos se suelen indicar para
     cada diagnóstico CIE-10.
   Con eso, cuando el médico revisa los resultados, el sistema SUGIERE la
   receta (izquierda) y las indicaciones (derecha). Todo es editable: el
   médico decide y lo que guarda es su receta, no la sugerencia.
   Dosis referenciales, con fines académicos.
   Ejecutar después de 07_base_conocimiento.sql (idempotente en los datos).
   ===================================================================== */

SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ---------------------------------------------------------------------
   1. TABLAS
   ------------------------------------------------------------------- */
IF OBJECT_ID('dbo.medicamento') IS NULL
CREATE TABLE dbo.medicamento (
    medicamento_id  INT IDENTITY(1,1) NOT NULL,
    nombre          NVARCHAR(120)  NOT NULL,         -- nombre genérico
    presentacion    NVARCHAR(120)  NOT NULL,         -- ej. Tableta 500 mg
    via             NVARCHAR(30)   NOT NULL CONSTRAINT df_med_via DEFAULT N'Oral',
    dosis           NVARCHAR(60)   NOT NULL,         -- ej. 1 tableta (500 mg)
    frecuencia      NVARCHAR(60)   NOT NULL,         -- ej. cada 12 horas
    duracion_dias   SMALLINT       NULL,
    indicaciones    NVARCHAR(1000) NOT NULL,         -- cómo tomarlo
    advertencias    NVARCHAR(500)  NULL,
    activo          BIT            NOT NULL CONSTRAINT df_med_activo DEFAULT 1,
    updated_at      DATETIME2(3)   NOT NULL CONSTRAINT df_med_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_medicamento PRIMARY KEY (medicamento_id),
    CONSTRAINT uq_medicamento UNIQUE (nombre, presentacion),
    CONSTRAINT ck_med_duracion CHECK (duracion_dias IS NULL OR duracion_dias > 0)
);
GO

IF OBJECT_ID('dbo.diagnostico_medicamento') IS NULL
CREATE TABLE dbo.diagnostico_medicamento (
    diagnostico_medicamento_id INT IDENTITY(1,1) NOT NULL,
    diagnostico_id  INT           NOT NULL,
    medicamento_id  INT           NOT NULL,
    nota            NVARCHAR(200) NULL,              -- ej. "según criterio médico"
    updated_at      DATETIME2(3)  NOT NULL CONSTRAINT df_dxmed_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_diagnostico_medicamento PRIMARY KEY (diagnostico_medicamento_id),
    CONSTRAINT uq_diagnostico_medicamento UNIQUE (diagnostico_id, medicamento_id),
    CONSTRAINT fk_dxmed_diagnostico FOREIGN KEY (diagnostico_id) REFERENCES dbo.diagnostico(diagnostico_id),
    CONSTRAINT fk_dxmed_medicamento FOREIGN KEY (medicamento_id) REFERENCES dbo.medicamento(medicamento_id)
);
GO

/* Una receta por solicitud de exámenes y médico: la que escribe al revisar los resultados. */
IF OBJECT_ID('dbo.receta') IS NULL
CREATE TABLE dbo.receta (
    receta_id               BIGINT IDENTITY(1,1) NOT NULL,
    solicitud_id            BIGINT          NOT NULL,
    paciente_id             BIGINT          NOT NULL,
    medico_id               BIGINT          NOT NULL,
    diagnostico             NVARCHAR(500)   NULL,
    indicaciones_generales  NVARCHAR(2000)  NULL,    -- dieta, controles, signos de alarma…
    created_at              DATETIME2(3)    NOT NULL CONSTRAINT df_receta_created DEFAULT SYSUTCDATETIME(),
    updated_at              DATETIME2(3)    NOT NULL CONSTRAINT df_receta_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_receta PRIMARY KEY (receta_id),
    CONSTRAINT uq_receta_solicitud_medico UNIQUE (solicitud_id, medico_id),
    CONSTRAINT fk_receta_solicitud FOREIGN KEY (solicitud_id) REFERENCES dbo.solicitud_examen(solicitud_id),
    CONSTRAINT fk_receta_paciente FOREIGN KEY (paciente_id) REFERENCES dbo.paciente(paciente_id),
    CONSTRAINT fk_receta_medico FOREIGN KEY (medico_id) REFERENCES dbo.medico(medico_id)
);
GO

/* Cada medicamento recetado. Se guarda el texto que dejó el médico (aunque haya
   partido de la base de conocimientos) y si lo modificó respecto de la sugerencia. */
IF OBJECT_ID('dbo.receta_item') IS NULL
CREATE TABLE dbo.receta_item (
    receta_item_id  BIGINT IDENTITY(1,1) NOT NULL,
    receta_id       BIGINT          NOT NULL,
    orden           TINYINT         NOT NULL,
    medicamento_id  INT             NULL,             -- NULL si no está en la base de conocimientos
    nombre          NVARCHAR(120)   NOT NULL,
    presentacion    NVARCHAR(120)   NULL,
    via             NVARCHAR(30)    NULL,
    dosis           NVARCHAR(60)    NOT NULL,
    frecuencia      NVARCHAR(60)    NOT NULL,
    duracion_dias   SMALLINT        NULL,
    cantidad        NVARCHAR(40)    NULL,             -- ej. 60 tabletas
    indicaciones    NVARCHAR(1000)  NULL,
    modificado      BIT             NOT NULL CONSTRAINT df_ritem_mod DEFAULT 0,
    updated_at      DATETIME2(3)    NOT NULL CONSTRAINT df_ritem_updated DEFAULT SYSUTCDATETIME(),
    CONSTRAINT pk_receta_item PRIMARY KEY (receta_item_id),
    CONSTRAINT fk_ritem_receta FOREIGN KEY (receta_id) REFERENCES dbo.receta(receta_id),
    CONSTRAINT fk_ritem_medicamento FOREIGN KEY (medicamento_id) REFERENCES dbo.medicamento(medicamento_id),
    CONSTRAINT ck_ritem_duracion CHECK (duracion_dias IS NULL OR duracion_dias > 0)
);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'ix_ritem_receta')
    CREATE INDEX ix_ritem_receta ON dbo.receta_item (receta_id);
GO

/* ---------------------------------------------------------------------
   2. CHANGE TRACKING (se replican a Supabase: consultables en contingencia).
      Se activa ANTES de cargar los datos para que la carga también se replique.
   ------------------------------------------------------------------- */
IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID('dbo.medicamento'))
    ALTER TABLE dbo.medicamento ENABLE CHANGE_TRACKING;
IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID('dbo.diagnostico_medicamento'))
    ALTER TABLE dbo.diagnostico_medicamento ENABLE CHANGE_TRACKING;
IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID('dbo.receta'))
    ALTER TABLE dbo.receta ENABLE CHANGE_TRACKING;
IF NOT EXISTS (SELECT 1 FROM sys.change_tracking_tables WHERE object_id = OBJECT_ID('dbo.receta_item'))
    ALTER TABLE dbo.receta_item ENABLE CHANGE_TRACKING;
GO

/* ---------------------------------------------------------------------
   3. PROCEDIMIENTOS
   ------------------------------------------------------------------- */
/* Guarda (crea o reemplaza) la receta del médico para una solicitud.
   @items: '[{"medicamento_id":1,"nombre":"Metformina","presentacion":"Tableta 500 mg","via":"Oral",
              "dosis":"1 tableta","frecuencia":"cada 12 horas","duracion_dias":90,"cantidad":"180 tabletas",
              "indicaciones":"Tomar con el desayuno y la cena","modificado":false}]' */
CREATE OR ALTER PROCEDURE dbo.sp_guardar_receta
    @solicitud_id            BIGINT,
    @medico_id               BIGINT,
    @diagnostico             NVARCHAR(500) = NULL,
    @indicaciones_generales  NVARCHAR(2000) = NULL,
    @items                   NVARCHAR(MAX),
    @usuario_id              BIGINT = NULL,
    @receta_id               BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @receta_id = NULL;
    IF ISJSON(@items) = 0 THROW 50090, 'Los medicamentos no son un JSON válido.', 1;
    IF NOT EXISTS (SELECT 1 FROM OPENJSON(@items)) THROW 50091, 'La receta necesita al menos un medicamento.', 1;
    IF EXISTS (SELECT 1 FROM OPENJSON(@items) WITH (nombre NVARCHAR(120), dosis NVARCHAR(60), frecuencia NVARCHAR(60))
               WHERE NULLIF(LTRIM(RTRIM(nombre)), N'') IS NULL OR NULLIF(LTRIM(RTRIM(dosis)), N'') IS NULL
                  OR NULLIF(LTRIM(RTRIM(frecuencia)), N'') IS NULL)
        THROW 50092, 'Cada medicamento necesita nombre, dosis y frecuencia.', 1;
    DECLARE @paciente_id BIGINT, @estado VARCHAR(20);
    SELECT @paciente_id = paciente_id, @estado = estado FROM dbo.solicitud_examen WHERE solicitud_id = @solicitud_id;
    IF @paciente_id IS NULL THROW 50093, 'La solicitud no existe.', 1;
    IF @estado NOT IN ('EN_PROCESO', 'COMPLETADA') THROW 50094, 'La solicitud aún no tiene resultados.', 1;
    IF EXISTS (SELECT 1 FROM dbo.paciente pa JOIN dbo.medico m ON m.persona_id = pa.persona_id
               WHERE pa.paciente_id = @paciente_id AND m.medico_id = @medico_id)
        THROW 50095, 'Un médico no puede recetarse a sí mismo.', 1;
    BEGIN TRY
    BEGIN TRAN;
        SELECT @receta_id = receta_id FROM dbo.receta WITH (UPDLOCK, HOLDLOCK)
        WHERE solicitud_id = @solicitud_id AND medico_id = @medico_id;
        IF @receta_id IS NULL
        BEGIN
            INSERT INTO dbo.receta (solicitud_id, paciente_id, medico_id, diagnostico, indicaciones_generales)
            VALUES (@solicitud_id, @paciente_id, @medico_id, @diagnostico, @indicaciones_generales);
            SET @receta_id = SCOPE_IDENTITY();
        END
        ELSE
        BEGIN
            UPDATE dbo.receta SET diagnostico = @diagnostico, indicaciones_generales = @indicaciones_generales,
                   updated_at = SYSUTCDATETIME()
            WHERE receta_id = @receta_id;
            DELETE FROM dbo.receta_item WHERE receta_id = @receta_id;
        END;
        INSERT INTO dbo.receta_item (receta_id, orden, medicamento_id, nombre, presentacion, via, dosis, frecuencia,
                                     duracion_dias, cantidad, indicaciones, modificado)
        SELECT @receta_id, CAST(j.[key] AS INT) + 1,
               (SELECT m.medicamento_id FROM dbo.medicamento m WHERE m.medicamento_id = v.medicamento_id),
               LTRIM(RTRIM(v.nombre)), v.presentacion, v.via, LTRIM(RTRIM(v.dosis)), LTRIM(RTRIM(v.frecuencia)),
               NULLIF(v.duracion_dias, 0), v.cantidad, v.indicaciones, ISNULL(v.modificado, 0)
        FROM OPENJSON(@items) j
        CROSS APPLY OPENJSON(j.[value]) WITH (
            medicamento_id INT, nombre NVARCHAR(120), presentacion NVARCHAR(120), via NVARCHAR(30),
            dosis NVARCHAR(60), frecuencia NVARCHAR(60), duracion_dias SMALLINT, cantidad NVARCHAR(40),
            indicaciones NVARCHAR(1000), modificado BIT) v;

        DECLARE @det NVARCHAR(200) = CONCAT(N'{"solicitud_id":', @solicitud_id, N',"medicamentos":',
                                             (SELECT COUNT(*) FROM OPENJSON(@items)), N'}');
        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @rol_actuante = 'MEDICO', @accion = 'GUARDAR_RECETA',
             @entidad = 'receta', @entidad_id = @receta_id, @detalle = @det;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* Agrega o actualiza un medicamento de la base de conocimientos (administrador). */
CREATE OR ALTER PROCEDURE dbo.sp_guardar_medicamento
    @nombre         NVARCHAR(120),
    @presentacion   NVARCHAR(120),
    @via            NVARCHAR(30) = N'Oral',
    @dosis          NVARCHAR(60),
    @frecuencia     NVARCHAR(60),
    @duracion_dias  SMALLINT = NULL,
    @indicaciones   NVARCHAR(1000),
    @advertencias   NVARCHAR(500) = NULL,
    @diagnosticos   NVARCHAR(MAX) = NULL,     -- '[3, 5]' (diagnostico_id)
    @usuario_id     BIGINT = NULL,
    @medicamento_id BIGINT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    SET @medicamento_id = NULL;
    IF @diagnosticos IS NOT NULL AND ISJSON(@diagnosticos) = 0 THROW 50096, 'Los diagnósticos no son un JSON válido.', 1;
    BEGIN TRY
    BEGIN TRAN;
        SELECT @medicamento_id = medicamento_id FROM dbo.medicamento WITH (UPDLOCK, HOLDLOCK)
        WHERE nombre = @nombre AND presentacion = @presentacion;
        IF @medicamento_id IS NULL
        BEGIN
            INSERT INTO dbo.medicamento (nombre, presentacion, via, dosis, frecuencia, duracion_dias, indicaciones, advertencias)
            VALUES (@nombre, @presentacion, ISNULL(@via, N'Oral'), @dosis, @frecuencia, @duracion_dias, @indicaciones, @advertencias);
            SET @medicamento_id = SCOPE_IDENTITY();
        END
        ELSE
            UPDATE dbo.medicamento
            SET via = ISNULL(@via, N'Oral'), dosis = @dosis, frecuencia = @frecuencia, duracion_dias = @duracion_dias,
                indicaciones = @indicaciones, advertencias = @advertencias, activo = 1, updated_at = SYSUTCDATETIME()
            WHERE medicamento_id = @medicamento_id;
        IF @diagnosticos IS NOT NULL
            INSERT INTO dbo.diagnostico_medicamento (diagnostico_id, medicamento_id)
            SELECT DISTINCT CAST(j.[value] AS INT), @medicamento_id FROM OPENJSON(@diagnosticos) j
            WHERE EXISTS (SELECT 1 FROM dbo.diagnostico d WHERE d.diagnostico_id = CAST(j.[value] AS INT))
              AND NOT EXISTS (SELECT 1 FROM dbo.diagnostico_medicamento x
                              WHERE x.diagnostico_id = CAST(j.[value] AS INT) AND x.medicamento_id = @medicamento_id);
        EXEC dbo.sp_auditar @usuario_id = @usuario_id, @rol_actuante = 'ADMIN', @accion = 'GUARDAR_MEDICAMENTO',
             @entidad = 'medicamento', @entidad_id = @medicamento_id;
    COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        THROW;
    END CATCH;
END;
GO

/* ---------------------------------------------------------------------
   4. VADEMÉCUM INICIAL (dosis referenciales de adulto, uso académico)
   ------------------------------------------------------------------- */
MERGE dbo.medicamento AS m
USING (VALUES
 (N'Metformina', N'Tableta 500 mg', N'Oral', N'1 tableta (500 mg)', N'cada 12 horas', 90,
  N'Tomar con el desayuno y con la merienda para reducir las molestias digestivas. Iniciar con 1 tableta al día la primera semana.',
  N'No usar con insuficiencia renal grave. Suspender 48 h antes de estudios con contraste yodado.'),
 (N'Sulfato ferroso', N'Tableta 300 mg (60 mg de hierro elemental)', N'Oral', N'1 tableta', N'una vez al día', 90,
  N'Tomar en ayunas o 1 hora antes de las comidas, con jugo de naranja (la vitamina C mejora la absorción). No tomar con leche, té ni café.',
  N'Las heces se oscurecen; puede causar estreñimiento o molestias gástricas.'),
 (N'Ácido fólico', N'Tableta 1 mg', N'Oral', N'1 tableta (1 mg)', N'una vez al día', 90,
  N'Tomar a la misma hora todos los días, con o sin alimentos.', NULL),
 (N'Atorvastatina', N'Tableta 20 mg', N'Oral', N'1 tableta (20 mg)', N'una vez al día, en la noche', 90,
  N'Tomar en la noche. Acompañar con dieta baja en grasas saturadas y ejercicio.',
  N'Avisar al médico si hay dolor o debilidad muscular. Evitar el jugo de toronja.'),
 (N'Fenofibrato', N'Cápsula 160 mg', N'Oral', N'1 cápsula (160 mg)', N'una vez al día', 90,
  N'Tomar con la comida principal. Evitar el alcohol y los azúcares simples.',
  N'Precaución en enfermedad renal o hepática; no combinar con estatinas sin control médico.'),
 (N'Omega 3', N'Cápsula blanda 1 g', N'Oral', N'1 cápsula (1 g)', N'cada 12 horas', 90,
  N'Tomar con las comidas.', NULL),
 (N'Levotiroxina', N'Tableta 50 mcg', N'Oral', N'1 tableta (50 mcg)', N'una vez al día, en ayunas', 45,
  N'Tomar en ayunas con agua, 30 a 60 minutos antes del desayuno. Separar 4 horas del calcio, del hierro y de los antiácidos.',
  N'Control de TSH en 6 a 8 semanas para ajustar la dosis.'),
 (N'Propranolol', N'Tableta 10 mg', N'Oral', N'1 tableta (10 mg)', N'cada 8 horas', 30,
  N'Para controlar palpitaciones y temblor mientras lo valora endocrinología. No suspender de golpe.',
  N'Contraindicado en asma. Puede bajar la frecuencia cardíaca y la presión.'),
 (N'Paracetamol', N'Tableta 500 mg', N'Oral', N'1 tableta (500 mg)', N'cada 8 horas si hay dolor o fiebre', 5,
  N'Tomar solo si hay dolor o fiebre. Puede tomarse con o sin alimentos.',
  N'No pasar de 4 g al día. Evitar el alcohol.'),
 (N'Amoxicilina', N'Cápsula 500 mg', N'Oral', N'1 cápsula (500 mg)', N'cada 8 horas', 7,
  N'Completar los 7 días aunque se sienta mejor. Tomar a horas fijas.',
  N'Solo si se confirma una infección bacteriana. No usar en alergia a la penicilina.')
) AS v(nombre, presentacion, via, dosis, frecuencia, duracion, indicaciones, advertencias)
ON m.nombre = v.nombre AND m.presentacion = v.presentacion
WHEN NOT MATCHED THEN INSERT (nombre, presentacion, via, dosis, frecuencia, duracion_dias, indicaciones, advertencias)
     VALUES (v.nombre, v.presentacion, v.via, v.dosis, v.frecuencia, v.duracion, v.indicaciones, v.advertencias);

MERGE dbo.diagnostico_medicamento AS x
USING (SELECT d.diagnostico_id, m.medicamento_id, v.nota
       FROM (VALUES
        ('E11',   N'Metformina',      N'Si se confirma el diagnóstico'),
        ('D64.9', N'Sulfato ferroso', N'Si la anemia es por déficit de hierro'),
        ('D64.9', N'Ácido fólico',    NULL),
        ('E78.0', N'Atorvastatina',   N'Según el riesgo cardiovascular'),
        ('E78.1', N'Fenofibrato',     N'Si no mejora con dieta y ejercicio'),
        ('E78.1', N'Omega 3',         NULL),
        ('E03.9', N'Levotiroxina',    N'Según la T4 libre y los síntomas'),
        ('E05.9', N'Propranolol',     N'Solo para síntomas, hasta la valoración de endocrinología'),
        ('D72.8', N'Amoxicilina',     N'Solo si hay un foco bacteriano'),
        ('D72.8', N'Paracetamol',     NULL),
        ('R79.8', N'Paracetamol',     NULL)
       ) v(cie10, medicamento, nota)
       JOIN dbo.diagnostico d ON d.codigo_cie10 = v.cie10
       JOIN dbo.medicamento m ON m.nombre = v.medicamento) AS s
ON x.diagnostico_id = s.diagnostico_id AND x.medicamento_id = s.medicamento_id
WHEN NOT MATCHED THEN INSERT (diagnostico_id, medicamento_id, nota) VALUES (s.diagnostico_id, s.medicamento_id, s.nota);
GO
