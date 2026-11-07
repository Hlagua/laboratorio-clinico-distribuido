import 'package:flutter/material.dart';

import '../comun.dart';
import '../main.dart';

/// Página pública: información del laboratorio y catálogo de exámenes.
class Inicio extends StatefulWidget {
  const Inicio({super.key});

  @override
  State<Inicio> createState() => _InicioState();
}

class _InicioState extends State<Inicio> {
  late Future<List<dynamic>> _catalogo = _cargar();

  Future<List<dynamic>> _cargar() async => await api.get('/api/examenes/catalogo') as List<dynamic>;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: verdeOscuro,
        foregroundColor: Colors.white,
        title: const Text('⚕ Laboratorio Clínico'),
        actions: [
          if (sesion.autenticado)
            TextButton(
              onPressed: () => Navigator.pushNamed(context, '/panel'),
              child: const Text('Mi cuenta', style: TextStyle(color: Colors.white)),
            )
          else ...[
            TextButton(
              onPressed: () => Navigator.pushNamed(context, '/ingresar'),
              child: const Text('Ingresar', style: TextStyle(color: Colors.white)),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton.tonal(
                onPressed: () => Navigator.pushNamed(context, '/registro'),
                child: const Text('Crear cuenta'),
              ),
            ),
          ],
        ],
      ),
      body: ListView(
        children: [
          const AvisoContingencia(),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
            decoration: const BoxDecoration(gradient: LinearGradient(colors: [verdeOscuro, verde])),
            child: Centrado(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Sus exámenes, sin filas',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text(
                  'Reserve su cita, pague en línea y consulte sus resultados desde cualquier lugar.\n'
                  'Atención de lunes a sábado de 07:00 a 11:00 · Ambato, Tungurahua.',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
                const SizedBox(height: 20),
                Wrap(spacing: 12, runSpacing: 8, children: [
                  FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: verdeOscuro),
                    onPressed: () => Navigator.pushNamed(context, sesion.autenticado ? '/panel' : '/registro'),
                    child: const Text('Reservar una cita'),
                  ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white70)),
                    onPressed: () => Navigator.pushNamed(context, sesion.autenticado ? '/panel' : '/ingresar'),
                    child: const Text('Ver mis resultados'),
                  ),
                ]),
              ]),
            ),
          ),
          Centrado(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Exámenes disponibles', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                Cargando<List<dynamic>>(
                  futuro: _catalogo,
                  reintentar: () => setState(() => _catalogo = _cargar()),
                  constructor: (lista) => Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [for (final t in lista) _TarjetaExamen(t as Map<String, dynamic>)],
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _TarjetaExamen extends StatelessWidget {
  const _TarjetaExamen(this.t);
  final Map<String, dynamic> t;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 300,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t['categoria'] as String, style: const TextStyle(color: Colors.grey, fontSize: 12)),
              Text(t['nombre'] as String, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 4),
              Text(dinero(t['precio']), style: const TextStyle(color: verde, fontWeight: FontWeight.w600)),
              if (t['requiere_ayuno'] == true) const Text('Requiere ayuno', style: TextStyle(color: ambar)),
              if (t['indicaciones'] != null) Text(t['indicaciones'] as String, style: const TextStyle(fontSize: 13)),
              Text('Resultados en ${t['tiempo_entrega_horas']} h · muestra: ${t['tipo_muestra']}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ]),
          ),
        ),
      );
}
