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
