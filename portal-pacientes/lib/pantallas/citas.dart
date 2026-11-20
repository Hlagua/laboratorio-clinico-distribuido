import 'package:flutter/material.dart';

import '../comun.dart';
import '../main.dart';
import 'turnos.dart';

/// Reserva de cita. Dos tipos:
/// - Consulta médica: el paciente elige médico, fecha (en un calendario) y hora, y paga la consulta.
///   El médico le ordena los exámenes que necesite (o solo la receta) y le agenda el control.
/// - Toma de muestras: elige la sucursal, la fecha y la hora (para quien ya sabe qué exámenes hacerse).
/// Al terminar vuelve al panel con {cita, pagar}: el panel muestra la cita nueva en seguida.
class ReservarCita extends StatefulWidget {
  const ReservarCita({super.key});

  @override
  State<ReservarCita> createState() => _ReservarCitaState();
}

class _ReservarCitaState extends State<ReservarCita> {
  String _tipo = 'CONSULTA';
  late final Future<List<dynamic>> _medicos = _cargarMedicos();
  Map<String, dynamic>? _medico;
  Map<String, dynamic>? _sucursal;
  Map<String, dynamic>? _franja;
  final _motivo = TextEditingController();
  bool _enviando = false;

  Future<List<dynamic>> _cargarMedicos() async => await api.get('/api/citas/medicos') as List<dynamic>;

  void _cambiarTipo(String t) => setState(() {
        _tipo = t;
        _medico = null;
        _sucursal = null;
        _franja = null;
      });

  @override
  void dispose() {
    _motivo.dispose();
    super.dispose();
  }

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
      final pagar = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: Text(consulta ? 'Consulta reservada' : 'Cita reservada'),
          content: Text('${consulta ? 'Su consulta con Dr(a). ${cita['medico']}' : 'Su turno de toma de muestras en ${cita['sucursal']}'} es el '
              '${fechaLarga(cita['fecha'] as String)} a las ${hora(cita['hora_inicio'])}.\n\n'
              '${consulta ? 'Para confirmarla, pague la consulta' : 'Para confirmarla, elija sus exámenes y páguelos'} '
              'en los próximos 30 minutos. La verá desde ya en "Mis citas".'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Más tarde')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(consulta ? 'Pagar la consulta' : 'Elegir exámenes y pagar'),
            ),
          ],
        ),
      );
      if (mounted) Navigator.pop(context, {'cita': cita, 'pagar': pagar == true});
    } catch (e) {
      if (mounted) {
        mostrarMensaje(context, '$e', error: true);
        setState(() => _franja = null); // el cupo pudo haberse ocupado
      }
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  Widget _paso(String texto) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 8),
        child: Text(texto, style: const TextStyle(fontWeight: FontWeight.bold)),
      );

  @override
  Widget build(BuildContext context) {
    final consulta = _tipo == 'CONSULTA';
    final listoParaTurno = consulta ? _medico != null : _sucursal != null;
    return Scaffold(
      appBar: AppBar(title: const Text('Reservar cita'), backgroundColor: verdeOscuro, foregroundColor: Colors.white),
      body: Centrado(
        child: ListaConSubir(padding: const EdgeInsets.all(16), children: [
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
            consulta
                ? 'Si es su primera vez o no sabe qué exámenes necesita: el médico lo revisa, le receta o le ordena '
                    'exámenes y le agenda el control.'
                : 'Si ya tiene exámenes que hacerse (por ejemplo, los que le ordenó su médico).',
            style: const TextStyle(color: Colors.grey, fontSize: 13),
          ),
          if (consulta) ...[
            _paso('1. Elija el médico'),
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
                      onTap: () => setState(() {
                        _medico = m;
                        _franja = null;
                      }),
                    ),
                  ),
                if (lista.isEmpty) const Text('No hay médicos con agenda disponible.'),
              ]),
            ),
          ] else ...[
            _paso('1. Elija la sucursal'),
            SelectorSucursal(alElegir: (l) => setState(() {
                  _sucursal = l;
                  _franja = null;
                })),
          ],
          if (listoParaTurno) ...[
            _paso('2. Elija la fecha y la hora'),
            if (!consulta)
              const Text('Muchos exámenes requieren ayuno: le recomendamos los primeros horarios.',
                  style: TextStyle(color: Colors.grey, fontSize: 13)),
            const SizedBox(height: 6),
            SelectorTurno(
              key: ValueKey(consulta ? 'm${_medico!['medico_id']}' : 's${_sucursal!['laboratorio_id']}'),
              medicoId: consulta ? _medico!['medico_id'] as int : null,
              laboratorioId: consulta ? null : _sucursal!['laboratorio_id'] as int,
              cupos: !consulta,
              alElegir: (f) => setState(() => _franja = f),
            ),
            const SizedBox(height: 20),
            // La API acepta hasta 300 caracteres; se limita a 200 para que sea un resumen breve.
            TextField(
                controller: _motivo,
                maxLength: 200,
                inputFormatters: [sinEmojis],
                maxLines: 2,
                minLines: 1,
                decoration: InputDecoration(
                    labelText: consulta ? 'Motivo de la consulta (opcional)' : 'Motivo (opcional)',
                    helperText: 'Breve: por ejemplo, "cansancio y sed desde hace un mes"')),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _franja == null || _enviando ? null : _reservar,
              icon: const Icon(Icons.check),
              label: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(_enviando
                    ? 'Reservando…'
                    : _franja == null
                        ? 'Elija fecha y hora'
                        : 'Reservar el ${fechaLarga(_franja!['fecha'] as String)} a las ${hora(_franja!['hora_inicio'])}'),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
