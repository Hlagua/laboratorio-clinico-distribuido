// =====================================================================
// MongoDB Atlas - guías clínicas de la base de conocimientos.
// Documentos de estructura flexible que las reglas diagnósticas citan
// por su clave (regla_diagnostica.guia_clave). Resúmenes académicos con
// valores referenciales: no sustituyen el criterio médico.
// Ejecutar:  mongosh "<cadena Atlas>" guias_clinicas.js
// Idempotente (reemplaza por _id). Siempre escribe en la base "laboratorio".
// =====================================================================

const base = db.getSiblingDB("laboratorio");

const guias = [
  {
    _id: "diabetes",
    titulo: "Alteraciones de la glucosa en ayunas",
    diagnosticos: ["R73.0", "E11"],
    fuente: "American Diabetes Association - Standards of Care in Diabetes (resumen académico)",
    criterios: [
      { parametro: "Glucosa en ayunas", rango: "100 - 125 mg/dL", interpretacion: "Glucosa alterada en ayunas (prediabetes)" },
      { parametro: "Glucosa en ayunas", rango: ">= 126 mg/dL", interpretacion: "Compatible con diabetes; confirmar con una segunda prueba" },
      { parametro: "HbA1c", rango: ">= 6.5 %", interpretacion: "Compatible con diabetes" }
    ],
    secciones: [
      { titulo: "Confirmación", texto: "Un valor aislado no basta: el diagnóstico requiere dos resultados alterados (misma prueba o pruebas distintas) salvo síntomas clásicos." },
      { titulo: "Manejo inicial", texto: "Cambios en el estilo de vida: alimentación con pocos azúcares simples y actividad física regular. El tratamiento farmacológico lo decide el médico." },
      { titulo: "Seguimiento", texto: "Control de glucosa en ayunas o HbA1c a los 3 meses." }
    ]
  },
  {
    _id: "anemia",
    titulo: "Anemia en adultos",
    diagnosticos: ["D64.9"],
    fuente: "Organización Mundial de la Salud - concentraciones de hemoglobina para diagnosticar anemia (resumen académico)",
    criterios: [
      { parametro: "Hemoglobina", rango: "< 12 g/dL (mujer) / < 13 g/dL (hombre)", interpretacion: "Anemia" }
    ],
    secciones: [
      { titulo: "Estudio", texto: "Ferritina, hierro sérico, índices eritrocitarios y frotis para orientar la causa (ferropénica, carencial, crónica)." },
      { titulo: "Manejo", texto: "Según la causa. La suplementación con hierro solo tras confirmar ferropenia." }
    ]
  },
  {
    _id: "dislipidemia",
    titulo: "Dislipidemias",
    diagnosticos: ["E78.0", "E78.1"],
    fuente: "Guía ESC/EAS para el manejo de las dislipidemias (resumen académico)",
    criterios: [
      { parametro: "Colesterol total", rango: "> 240 mg/dL", interpretacion: "Hipercolesterolemia" },
      { parametro: "LDL", rango: "> 160 mg/dL", interpretacion: "LDL elevado" },
      { parametro: "Triglicéridos", rango: "> 200 mg/dL", interpretacion: "Hipertrigliceridemia" }
    ],
    secciones: [
      { titulo: "Riesgo cardiovascular", texto: "La meta de LDL depende del riesgo global (edad, tabaquismo, presión arterial, diabetes)." },
      { titulo: "Manejo", texto: "Dieta baja en grasas saturadas, ejercicio aeróbico; estatinas según riesgo y criterio médico. Control en 8 semanas." }
    ]
  },
  {
    _id: "tiroides",
    titulo: "Alteraciones de la función tiroidea",
    diagnosticos: ["E03.9", "E05.9"],
    fuente: "American Thyroid Association (resumen académico)",
    criterios: [
      { parametro: "TSH", rango: "> 4.5 mUI/L", interpretacion: "Sugiere hipotiroidismo" },
      { parametro: "TSH", rango: "< 0.3 mUI/L", interpretacion: "Sugiere hipertiroidismo" }
    ],
    secciones: [
      { titulo: "Confirmación", texto: "Medir T4 libre (y T3 en sospecha de hipertiroidismo) para clasificar el trastorno como clínico o subclínico." }
    ]
  },
  {
    _id: "renal",
    titulo: "Alteración de la función renal",
    diagnosticos: ["N28.9"],
    fuente: "KDIGO - Enfermedad renal crónica (resumen académico)",
    criterios: [
      { parametro: "Creatinina", rango: "> 1.3 mg/dL", interpretacion: "Elevada" },
      { parametro: "Urea", rango: "> 45 mg/dL", interpretacion: "Elevada" }
    ],
    secciones: [
      { titulo: "Estudio", texto: "Calcular la tasa de filtración glomerular estimada, examen de orina y repetir en 3 meses para descartar un cuadro agudo." },
      { titulo: "Precauciones", texto: "Evitar nefrotóxicos (AINE) y ajustar dosis de medicamentos de eliminación renal." }
    ]
  }
];

for (const g of guias) {
  base.guias_clinicas.replaceOne({ _id: g._id }, { ...g, actualizado: new Date() }, { upsert: true });
}
base.guias_clinicas.createIndex({ diagnosticos: 1 });
print("Guías clínicas cargadas en laboratorio.guias_clinicas: " + base.guias_clinicas.countDocuments());
