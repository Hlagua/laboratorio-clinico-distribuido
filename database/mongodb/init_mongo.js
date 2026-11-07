// =====================================================================
// MongoDB Atlas - réplica documental, auditoría y trazabilidad.
// Ejecutar:  mongosh "<cadena de conexión Atlas>/laboratorio" init_mongo.js
// Idempotente: se puede ejecutar varias veces.
// =====================================================================

const existentes = db.getCollectionNames();
function crear(nombre, opciones) {
  if (!existentes.includes(nombre)) db.createCollection(nombre, opciones || {});
}

// Documento completo de un resultado: paciente, examen, valores y
// observaciones embebidos (lo que se mostraría en el PDF).
crear("resultados", {
  validator: { $jsonSchema: {
    bsonType: "object",
    required: ["_id", "solicitud", "paciente", "examen", "valores"],
    properties: {
      _id: { bsonType: ["int", "long"], description: "resultado_id de Azure SQL" },
      valores: { bsonType: "array" },
      observaciones_medicas: { bsonType: "array" }
    }
  } }
});
db.resultados.createIndex({ "paciente.cedula": 1 });
db.resultados.createIndex({ "solicitud.codigo": 1 });

// Pago con sus reembolsos embebidos.
crear("pagos");
db.pagos.createIndex({ solicitud_id: 1 });
db.pagos.createIndex({ stripe_payment_intent_id: 1 }, { sparse: true });

// Eventos de auditoría (copia de dbo.auditoria).
crear("auditoria");
db.auditoria.createIndex({ created_at: -1 });
db.auditoria.createIndex({ accion: 1, entidad: 1 });

// Eventos crudos de Stripe y correos enviados.
crear("stripe_eventos");
crear("notificaciones");
db.notificaciones.createIndex({ estado: 1, created_at: -1 });

// Control del sincronizador.
crear("sync_estado");
crear("sync_log");
db.sync_log.createIndex({ inicio: -1 });

print("Colecciones listas: " + db.getCollectionNames().sort().join(", "));
