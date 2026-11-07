import 'package:flutter/material.dart';

import '../comun.dart';
import '../main.dart';
import 'solicitud.dart';

/// Reserva de cita: el paciente elige día y franja con cupo.
class ReservarCita extends StatefulWidget {
  const ReservarCita({super.key});

  @override
  State<ReservarCita> createState() => _ReservarCitaState();
}

class _ReservarCitaState extends State<ReservarCita> {
  late Future<List<dynamic>> _franjas = _cargar();
  String? _dia;
  Map<String, dynamic>? _franja;
  final _motivo = TextEditingController();
  bool _enviando = false;

  Future<List<dynamic>> _cargar() async => await api.get('/api/citas/franjas', {'dias': '14'}) as List<dynamic>;

  Future<void> _reservar() async {
    setState(() => _enviando = true);
    try {
      final cita = await api.post('/api/citas', {
        'franja_id': _franja!['franja_id'],
        'motivo': _motivo.text.trim().isEmpty ? null : _motivo.text.trim(),
      }) as Map<String, dynamic>;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Cita reservada'),
          content: Text('Su cita es el ${fechaLarga(cita['fecha'] as String)} a las ${hora(cita['hora_inicio'])}.\n\n'
              'Para confirmarla, elija sus exámenes y pague en los próximos 30 minutos.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Más tarde')),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pushReplacement(context,
                    MaterialPageRoute(builder: (_) => NuevaSolicitud(citaId: cita['cita_id'] as int)));
              },
              child: const Text('Elegir exámenes y pagar'),
            ),
          ],
        ),
      );
      if (mounted && Navigator.canPop(context)) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) mostrarMensaje(context, '$e', error: true);
      setState(() => _franjas = _cargar()); // el cupo pudo haberse ocupado
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reservar cita'), backgroundColor: verdeOscuro, foregroundColor: Colors.white),
      body: Centrado(
        child: Cargando<List<dynamic>>(
          futuro: _franjas,
          reintentar: () => setState(() => _franjas = _cargar()),
          constructor: (lista) {
            final porDia = <String, List<Map<String, dynamic>>>{};
            for (final f in lista.cast<Map<String, dynamic>>()) {
              porDia.putIfAbsent(f['fecha'] as String, () => []).add(f);
            }
            if (porDia.isEmpty) return const Center(child: Text('No hay horarios disponibles en los próximos días.'));
            _dia ??= porDia.keys.first;
            return ListView(padding: const EdgeInsets.all(16), children: [
              const Text('1. Elija el día', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final d in porDia.keys)
                  ChoiceChip(
                    label: Text(fechaLarga(d)),
                    selected: d == _dia,
                    onSelected: (_) => setState(() {
                      _dia = d;
                      _franja = null;
                    }),
                  ),
              ]),
              const SizedBox(height: 20),
              const Text('2. Elija la hora', style: TextStyle(fontWeight: FontWeight.bold)),
              const Text('Muchos exámenes requieren ayuno: le recomendamos los primeros horarios.',
                  style: TextStyle(color: Colors.grey, fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final f in porDia[_dia] ?? <Map<String, dynamic>>[])
                  ChoiceChip(
                    label: Text('${hora(f['hora_inicio'])}  ·  ${f['cupos_libres']} cupo${f['cupos_libres'] == 1 ? '' : 's'}'),
                    selected: _franja?['franja_id'] == f['franja_id'],
                    onSelected: (_) => setState(() => _franja = f),
                  ),
              ]),
              const SizedBox(height: 20),
              TextField(controller: _motivo, decoration: const InputDecoration(labelText: 'Motivo (opcional)')),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _franja == null || _enviando ? null : _reservar,
                icon: const Icon(Icons.check),
                label: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(_enviando ? 'Reservando…' : 'Reservar ${_franja == null ? '' : 'a las ${hora(_franja!['hora_inicio'])}'}'),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}
