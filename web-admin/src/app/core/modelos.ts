/** Tipos de las respuestas de la API (ver docs/04-servicios-rest-soap.md). */

export interface Parametro {
  parametro_id: number;
  nombre: string;
  unidad: string | null;
  valor_ref_min: number | null;
  valor_ref_max: number | null;
  valor_ref_texto: string | null;
}

export interface TipoExamen {
  tipo_examen_id: number;
  codigo: string;
  nombre: string;
  descripcion: string | null;
  tipo_muestra: string;
  precio: number;
  requiere_ayuno: boolean;
  indicaciones: string | null;
  tiempo_entrega_horas: number;
  categoria: string;
  parametros: Parametro[];
}

export interface Cita {
  cita_id: number;
  estado: string;
  motivo: string | null;
  canal: string;
  fecha: string;
  hora_inicio: string;
  hora_fin: string;
  paciente_id: number;
  paciente: string;
  cedula: string;
  solicitud_id: number | null;
  solicitud_codigo: string | null;
  solicitud_estado: string | null;
  solicitud_total?: number | null;
  examenes_resumen: string | null;
  franja_id: number;
  /** MUESTRA (turno de laboratorio) o CONSULTA (con un médico). */
  tipo: 'MUESTRA' | 'CONSULTA';
  /** PACIENTE (la reservó él) o MEDICO (control agendado por el médico). */
  origen: 'PACIENTE' | 'MEDICO';
  medico_id: number | null;
  medico: string | null;
  especialidad: string | null;
  vence_at: string | null;
}

export interface MedicoAgenda {
  medico_id: number;
  nombre: string;
  especialidad: string;
  turnos_libres: number;
  precio_consulta: number | null;
}

export interface Franja {
  franja_id: number;
  fecha: string;
  hora_inicio: string;
  hora_fin: string;
  cupos_libres: number;
}

export interface SolicitudResumen {
  solicitud_id: number;
  codigo: string;
  estado: string;
  total: number;
  created_at: string;
  paciente_id: number;
  cedula: string;
  paciente: string;
  medico_id: number | null;
  medico: string | null;
  examenes_resumen?: string | null;
  tipo?: 'EXAMENES' | 'CONSULTA';
}

export interface ValorResultado {
  parametro_id: number;
  parametro: string;
  valor_numerico: number | null;
  valor_texto: string | null;
  unidad: string | null;
  valor_ref_min: number | null;
  valor_ref_max: number | null;
  valor_ref_texto: string | null;
  fuera_rango: boolean;
  /** ALTO / BAJO / NORMAL frente al rango; ANORMAL si es texto fuera de rango. */
  nivel?: 'ALTO' | 'BAJO' | 'NORMAL' | 'ANORMAL';
}

export interface ObservacionMedica {
  observacion_id: number;
  texto: string;
  created_at: string;
  medico: string;
}

export interface ExamenSolicitado {
  detalle_id: number;
  estado: string;
  precio_unitario: number;
  tipo_examen_id: number;
  codigo: string;
  examen: string;
  resultado_id: number | null;
  fecha_resultado: string | null;
  observaciones_laboratorio: string | null;
  laboratorista: string | null;
  valores: ValorResultado[];
  observaciones_medicas: ObservacionMedica[];
}

export interface Solicitud extends SolicitudResumen {
  /** Pagada en ventanilla con datos de factura: el laboratorio también puede descargarla. */
  cobro_ventanilla?: boolean;
  subtotal: number;
  iva: number;
  iva_porcentaje: number;
  observaciones: string | null;
  cita_id: number | null;
  examenes: ExamenSolicitado[];
}

export interface Paciente {
  paciente_id: number;
  cedula: string;
  nombres: string;
  apellidos: string;
  fecha_nacimiento: string;
  sexo: string;
  telefono: string | null;
  email: string | null;
  tipo_sangre: string | null;
  alergias: string | null;
}

export interface Tratamiento {
  tratamiento_id: number;
  paciente_id: number;
  paciente: string;
  cedula: string;
  medico_id: number;
  medico: string;
  solicitud_id: number | null;
  diagnostico: string;
  indicaciones: string;
  fecha_inicio: string;
  fecha_fin: string | null;
  estado: string;
}

export interface Pago {
  pago_id: number;
  solicitud_id: number;
  solicitud_codigo: string;
  monto: number;
  moneda: string;
  metodo: string;
  estado: string;
  motivo_rechazo: string | null;
  monto_reembolsado: number;
  referencia_transferencia: string | null;
  stripe_payment_intent_id: string | null;
  confirmado_at: string | null;
  created_at: string;
  paciente_id: number;
  paciente: string;
  reembolsos?: { reembolso_id: number; monto: number; motivo: string; estado: string; stripe_refund_id: string | null; created_at: string }[];
}

export interface UsuarioAdmin {
  usuario_id: number;
  email: string;
  activo: boolean;
  ultimo_login: string | null;
  cedula: string;
  nombre: string;
  roles: string | null;
}

/* ---- Base de conocimientos para diagnósticos ---- */
export interface Sugerencia {
  sugerencia_id: number;
  solicitud_id: number;
  paciente_id: number;
  estado: 'PENDIENTE' | 'ACEPTADA' | 'DESCARTADA';
  confianza: 'BAJA' | 'MEDIA' | 'ALTA';
  explicacion: string;
  motivo: string | null;
  tratamiento_id: number | null;
  created_at: string;
  respondida_at: string | null;
  diagnostico_id: number;
  codigo_cie10: string;
  diagnostico: string;
  regla: string;
  recomendacion: string;
  fuente: string | null;
  guia_clave: string | null;
  protocolo: string | null;
  duracion_dias: number | null;
  respondida_por: string | null;
}

export interface CondicionRegla {
  parametro_id: number;
  parametro: string;
  unidad: string | null;
  operador: '<' | '<=' | '>' | '>=' | 'ENTRE';
  valor: number;
  valor2: number | null;
}

export interface Regla {
  regla_id: number;
  codigo: string;
  logica: 'TODAS' | 'ALGUNA';
  sexo: 'M' | 'F' | null;
  edad_min: number | null;
  edad_max: number | null;
  confianza: 'BAJA' | 'MEDIA' | 'ALTA';
  recomendacion: string;
  fuente: string | null;
  guia_clave: string | null;
  activa: boolean;
  diagnostico_id: number;
  codigo_cie10: string;
  diagnostico: string;
  sugerencias: number;
  aceptadas: number;
  descartadas: number;
  precision_pct: number | null;
  condiciones: CondicionRegla[];
}

export interface Diagnostico {
  diagnostico_id: number;
  codigo_cie10: string;
  nombre: string;
  descripcion: string | null;
  protocolo: string | null;
  duracion_dias: number | null;
}

export interface GuiaClinica {
  _id: string;
  titulo: string;
  fuente: string;
  diagnosticos: string[];
  criterios: { parametro: string; rango: string; interpretacion: string }[];
  secciones: { titulo: string; texto: string }[];
}

/** Medicamento del vademécum de la base de conocimientos. */
export interface Medicamento {
  medicamento_id: number;
  nombre: string;
  presentacion: string;
  via: string;
  dosis: string;
  frecuencia: string;
  duracion_dias: number | null;
  indicaciones: string;
  advertencias: string | null;
  diagnosticos: string | null;
  /** Solo en las sugerencias: para qué diagnóstico se propone. */
  para_cie10?: string;
  para_diagnostico?: string;
  nota?: string | null;
}

export interface RecetaItem {
  receta_item_id?: number;
  orden?: number;
  medicamento_id: number | null;
  nombre: string;
  presentacion: string | null;
  via: string | null;
  dosis: string;
  frecuencia: string;
  duracion_dias: number | null;
  cantidad: string | null;
  indicaciones: string | null;
  modificado: boolean;
}

export interface Receta {
  receta_id: number;
  solicitud_id: number;
  medico_id: number;
  medico: string;
  diagnostico: string | null;
  indicaciones_generales: string | null;
  created_at: string;
  updated_at: string;
  items: RecetaItem[];
}

export interface SugerenciaReceta {
  diagnosticos: { diagnostico_id: number; codigo_cie10: string; nombre: string }[];
  diagnostico: string;
  medicamentos: Medicamento[];
  indicaciones_generales: string;
}

export interface RecetasSolicitud {
  recetas: Receta[];
  propia?: Receta | null;
  sugerencia?: SugerenciaReceta;
}
