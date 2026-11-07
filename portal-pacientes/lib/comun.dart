import 'package:flutter/material.dart';

/// Colores y utilidades compartidas por las pantallas del portal.
const verde = Color(0xFF0B6E4F);
const verdeOscuro = Color(0xFF08513A);
const rojo = Color(0xFFB00020);
const ambar = Color(0xFF9A6700);

String dinero(dynamic v) => v == null ? '' : 'USD ${(v as num).toStringAsFixed(2)}';
String hora(dynamic h) {
  final s = h as String? ?? '';
  return s.length >= 5 ? s.substring(0, 5) : s;
}
String texto(dynamic estado) => (estado as String? ?? '').replaceAll('_', ' ').toLowerCase();

const _dias = ['lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo'];
const _meses = ['ene', 'feb', 'mar', 'abr', 'may', 'jun', 'jul', 'ago', 'sep', 'oct', 'nov', 'dic'];

/// "2026-11-06" -> "viernes 6 nov"
String fechaLarga(String iso) {
  final d = DateTime.parse(iso);
  return '${_dias[d.weekday - 1]} ${d.day} ${_meses[d.month - 1]}';
}

/// Fecha UTC de la API -> hora de Ecuador (UTC-5).
String fechaHora(dynamic iso) {
  if (iso == null) return '';
  final d = DateTime.parse('${(iso as String).replaceAll('Z', '')}Z').subtract(const Duration(hours: 5));
  return '${d.day} ${_meses[d.month - 1]} ${d.year}, ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

Color colorEstado(String? estado) => switch (estado) {
      'COMPLETADA' || 'APROBADO' || 'CONFIRMADA' || 'RESULTADO_LISTO' || 'ACTIVO' || 'ATENDIDA' => verde,
      'PAGADA' || 'EN_PROCESO' || 'MUESTRA_TOMADA' => const Color(0xFF1F5FA8),
      'REGISTRADA' || 'PENDIENTE' || 'PENDIENTE_PAGO' || 'REEMBOLSO_PARCIAL' || 'SUSPENDIDO' => ambar,
      'RECHAZADO' || 'ANULADA' || 'ANULADO' => rojo,
      _ => Colors.grey.shade600,
    };

class Etiqueta extends StatelessWidget {
  const Etiqueta(this.estado, {super.key});
  final String? estado;

  @override
  Widget build(BuildContext context) {
    final c = colorEstado(estado);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: .12), borderRadius: BorderRadius.circular(20)),
      child: Text(texto(estado), style: TextStyle(color: c, fontWeight: FontWeight.w600, fontSize: 12)),
    );
  }
}

/// Contenedor centrado con ancho máximo (se ve bien en móvil y escritorio).
class Centrado extends StatelessWidget {
  const Centrado({super.key, required this.child, this.ancho = 960});
  final Widget child;
  final double ancho;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(constraints: BoxConstraints(maxWidth: ancho), child: child),
      );
}

void mostrarMensaje(BuildContext context, String texto, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(texto),
    backgroundColor: error ? rojo : verdeOscuro,
    behavior: SnackBarBehavior.floating,
  ));
}

/// Pantalla con carga asíncrona, error y "volver a intentar".
class Cargando<T> extends StatelessWidget {
  const Cargando({super.key, required this.futuro, required this.constructor, required this.reintentar});
  final Future<T>? futuro;
  final Widget Function(T datos) constructor;
  final VoidCallback reintentar;

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
        future: futuro,
        builder: (context, s) {
          if (s.hasError) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Column(children: [
                Text('${s.error}', style: const TextStyle(color: rojo)),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: reintentar, child: const Text('Reintentar')),
              ]),
            );
          }
          if (!s.hasData) return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
          return constructor(s.data as T);
        },
      );
}
