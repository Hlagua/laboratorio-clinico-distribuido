import 'package:flutter/material.dart';

import '../comun.dart';
import '../main.dart';
import 'solicitud.dart';

/// Reserva de cita. Dos tipos:
/// - Consulta médica: el paciente elige médico y turno, y paga la consulta. El médico le
///   ordena los exámenes y le agenda la cita de control.
/// - Toma de muestras: para quien ya sabe qué exámenes hacerse (o se los ordenó su médico).
class ReservarCita extends StatefulWidget {
  const ReservarCita({super.key});

  @override
  State<ReservarCita> createState() => _ReservarCitaState();
}

class _ReservarCitaState extends State<ReservarCita> {
  String _tipo = 'CONSULTA';
  late final Future<List<dynamic>> _medicos = _cargarMedicos();
  Map<String, dynamic>? _medico;
  Future<List<dynamic>>? _franjas;
  String? _dia;
  Map<String, dynamic>? _franja;
  final _motivo = TextEditingController();
  bool _enviando = false;

  Future<List<dynamic>> _cargarMedicos() async => await api.get('/api/citas/medicos') as List<dynamic>;

  Future<List<dynamic>> _cargarFranjas() async => await api.get('/api/citas/franjas', {
        'dias': '14',
        if (_tipo == 'CONSULTA' && _medico != null) 'medico_id': '${_medico!['medico_id']}',
      }) as List<dynamic>;

  void _cambiarTipo(String t) => setState(() {
        _tipo = t;
        _medico = null;
        _dia = null;
        _franja = null;
        _franjas = t == 'MUESTRA' ? _cargarFranjas() : null;
      });

  void _elegirMedico(Map<String, dynamic> m) => setState(() {
        _medico = m;
        _dia = null;
        _franja = null;
        _franjas = _cargarFranjas();
      });

  Future<void> _reservar() async {
    setState(() => _enviando = true);
    try {
      final cita = await api.post('/api/citas', {
        'franja_id': _franja!['franja_id'],
        'tipo': _tipo,
        'motivo': _motivo.text.trim().isEmpty ? null : _motivo.text.trim(),
      }) as Map<String, dynamic>;
      if (!mounted) return;
      final consulta = _tipo == 'CONSULTA';
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(consulta ? 'Consulta reservada' : 'Cita reservada'),
          content: Text('${consulta ? 'Su consulta con Dr(a). ${cita['medico']}' : 'Su turno de toma de muestras'} es el '
              '${fechaLarga(cita['fecha'] as String)} a las ${hora(cita['hora_inicio'])}.\n\n'
              '${consulta ? 'Para confirmarla, pague la consulta' : 'Para confirmarla, elija sus exámenes y páguelos'} '
              'en los próximos 30 minutos.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Más tarde')),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                        builder: (_) => consulta
                            ? DetalleSolicitud(id: cita['solicitud_id'] as int)
                            : NuevaSolicitud(citaId: cita['cita_id'] as int)));
              },
              child: Text(consulta ? 'Pagar la consulta' : 'Elegir exámenes y pagar'),
            ),
          ],
        ),
      );
      if (mounted && Navigator.canPop(context)) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) mostrarMensaje(context, '$e', error: true);
      setState(() => _franjas = _cargarFranjas()); // el cupo pudo haberse ocupado
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reservar cita'), backgroundColor: verdeOscuro, foregroundColor: Colors.white),
      body: Centrado(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('¿Qué necesita?', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'CONSULTA', icon: Icon(Icons.medical_services), label: Text('Consulta médica')),
              ButtonSegment(value: 'MUESTRA', icon: Icon(Icons.biotech), label: Text('Toma de muestras')),
            ],
            selected: {_tipo},
            onSelectionChanged: (v) => _cambiarTipo(v.first),
          ),
          const SizedBox(height: 6),
          Text(
            _tipo == 'CONSULTA'
                ? 'Si es su primera vez o no sabe qué exámenes necesita: el médico lo revisa, le ordena los exámenes y le agenda el control.'
                : 'Si ya tiene exámenes que hacerse (por ejemplo, los que le ordenó su médico).',
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
          const SizedBox(height: 16),
          if (_tipo == 'CONSULTA') ...[
            const Text('1. Elija el médico', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Cargando<List<dynamic>>(
              futuro: _medicos,
              reintentar: () => setState(() {}),
              constructor: (lista) => Column(children: [
                for (final m in lista.cast<Map<String, dynamic>>())
                  Card(
                    color: _medico?['medico_id'] == m['medico_id'] ? verde.withValues(alpha: .1) : null,
                    child: ListTile(
                      leading: const Icon(Icons.person, color: verde),
                      title: Text('Dr(a). ${m['nombre']}'),
                      subtitle: Text('${m['especialidad']} · consulta ${dinero(m['precio_consulta'])} · '
                          '${m['turnos_libres']} turno${m['turnos_libres'] == 1 ? '' : 's'} libres'),
                      trailing: _medico?['medico_id'] == m['medico_id'] ? const Icon(Icons.check_circle, color: verde) : null,
                      enabled: (m['turnos_libres'] as int) > 0,
                      onTap: () => _elegirMedico(m),
                    ),
                  ),
                if (lista.isEmpty) const Text('No hay médicos con agenda disponible.'),
              ]),
            ),
            const SizedBox(height: 16),
          ],
          if (_franjas != null)
            Cargando<List<dynamic>>(
              futuro: _franjas,
              reintentar: () => setState(() => _franjas = _cargarFranjas()),
              constructor: (lista) => _horarios(lista.cast<Map<String, dynamic>>()),
            ),
        ]),
      ),
    );
  }

  Widget _horarios(List<Map<String, dynamic>> lista) {
    final porDia = <String, List<Map<String, dynamic>>>{};
    for (final f in lista) {
      porDia.putIfAbsent(f['fecha'] as String, () => []).add(f);
    }
    if (porDia.isEmpty) return const Text('No hay horarios disponibles en los próximos días.');
    _dia ??= porDia.keys.first;
    final n = _tipo == 'CONSULTA' ? 2 : 1;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('$n. Elija el día', style: const TextStyle(fontWeight: FontWeight.bold)),
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
      Text('${n + 1}. Elija la hora', style: const TextStyle(fontWeight: FontWeight.bold)),
      if (_tipo == 'MUESTRA')
        const Text('Muchos exámenes requieren ayuno: le recomendamos los primeros horarios.',
            style: TextStyle(color: Colors.grey, fontSize: 13)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final f in porDia[_dia] ?? <Map<String, dynamic>>[])
          ChoiceChip(
            label: Text(_tipo == 'CONSULTA'
                ? hora(f['hora_inicio'])
                : '${hora(f['hora_inicio'])}  ·  ${f['cupos_libres']} cupo${f['cupos_libres'] == 1 ? '' : 's'}'),
            selected: _franja?['franja_id'] == f['franja_id'],
            onSelected: (_) => setState(() => _franja = f),
          ),
      ]),
      const SizedBox(height: 20),
      // La API acepta hasta 300 caracteres; se limita a 200 para que sea un resumen breve.
      TextField(
          controller: _motivo,
          maxLength: 200,
          inputFormatters: [sinEmojis],
          maxLines: 2,
          minLines: 1,
          decoration: InputDecoration(
              labelText: _tipo == 'CONSULTA' ? 'Motivo de la consulta (opcional)' : 'Motivo (opcional)',
              helperText: 'Breve: por ejemplo, "cansancio y sed desde hace un mes"')),
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
  }
}
