/** Formatos de presentación compartidos por las pantallas. */

const ESTADOS: Record<string, string> = {
  // verde (sin clase extra) = estado final correcto
  COMPLETADA: '', APROBADO: '', CONFIRMADA: '', RESULTADO_LISTO: '', ATENDIDA: '', ENVIADA: '', ACTIVO: '', EXITOSO: '',
  PAGADA: 'azul', EN_PROCESO: 'azul', MUESTRA_TOMADA: 'azul', EN_ANALISIS: 'azul',
  REGISTRADA: 'ambar', PENDIENTE: 'ambar', PENDIENTE_PAGO: 'ambar', REEMBOLSO_PARCIAL: 'ambar', SUSPENDIDO: 'ambar',
  RECHAZADO: 'rojo', ANULADA: 'rojo', ANULADO: 'rojo', FALLIDA: 'rojo', NO_ASISTIO: 'rojo',
  CANCELADA: 'gris', EXPIRADO: 'gris', REEMBOLSADO: 'gris', FINALIZADO: 'gris',
};

export function claseEstado(estado: string | null | undefined): string {
  return 'badge ' + (ESTADOS[estado ?? ''] ?? 'gris');
}

export function textoEstado(estado: string | null | undefined): string {
  return (estado ?? '').replaceAll('_', ' ').toLowerCase();
}

export function dinero(v: number | string | null | undefined): string {
  return v === null || v === undefined ? '' : `USD ${Number(v).toFixed(2)}`;
}

/** Las fechas de auditoría vienen en UTC; se muestran en hora de Ecuador. */
export function fechaHora(iso: string | null | undefined): string {
  if (!iso) return '';
  const d = new Date(iso.endsWith('Z') || iso.includes('+') ? iso : iso + 'Z');
  return d.toLocaleString('es-EC', { timeZone: 'America/Guayaquil', dateStyle: 'short', timeStyle: 'short' });
}

export function hora(h: string | null | undefined): string {
  return (h ?? '').slice(0, 5);
}

export function hoyIso(): string {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'America/Guayaquil' });
}

export function rango(min: number | null, max: number | null, texto: string | null): string {
  if (texto) return texto;
  if (min === null && max === null) return '';
  return `${min ?? ''} – ${max ?? ''}`;
}
