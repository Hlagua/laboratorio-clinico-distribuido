import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web/web.dart' as web;

import '../comun.dart';
import '../main.dart';

/// Hasta cuándo se puede reservar o reagendar (la API usa el mismo límite).
const diasParaReservar = 90;

/// Abre un enlace en otra pestaña (por ejemplo, Google Maps).
void abrirEnlace(String url) => web.window.open(url, '_blank');

String _iso(DateTime d) => d.toIso8601String().substring(0, 10);

// ------------------------------------------------------------------
// Fecha (en un calendario) y hora libres.
// ------------------------------------------------------------------

/// Calendario con solo los días que tienen horarios libres (hasta 3 meses) y, debajo, las horas de ese día.
/// Para una consulta se pasa [medicoId]; para la toma de muestras, la sucursal ([laboratorioId]).
class SelectorTurno extends StatefulWidget {
  const SelectorTurno({super.key, this.medicoId, this.laboratorioId, this.excluir, required this.alElegir, this.cupos = false});
  final int? medicoId;
  final int? laboratorioId;
  final int? excluir;
  final bool cupos;
  final ValueChanged<Map<String, dynamic>?> alElegir;

  @override
  State<SelectorTurno> createState() => _SelectorTurnoState();
}

class _SelectorTurnoState extends State<SelectorTurno> {
  Set<String>? _dias;
  String? _dia;
  List<Map<String, dynamic>>? _horas;
  Map<String, dynamic>? _elegida;
  String? _error;

  Map<String, String> get _filtro => {
        if (widget.medicoId != null) 'medico_id': '${widget.medicoId}',
        if (widget.laboratorioId != null) 'laboratorio_id': '${widget.laboratorioId}',
      };

  @override
  void initState() {
    super.initState();
    _cargarDias();
  }

  @override
  void didUpdateWidget(SelectorTurno viejo) {
    super.didUpdateWidget(viejo);
    if (viejo.medicoId != widget.medicoId || viejo.laboratorioId != widget.laboratorioId) {
      setState(() {
        _dias = null;
        _dia = null;
        _horas = null;
        _elegida = null;
      });
      _cargarDias();
    }
  }

  Future<void> _cargarDias() async {
    try {
      final r = (await api.get('/api/citas/dias-libres', _filtro) as List).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() => _dias = {for (final d in r) d['fecha'] as String});
      if (_dias!.isNotEmpty) _elegirDia(_dias!.first);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _elegirDia(String dia) async {
    setState(() {
      _dia = dia;
      _horas = null;
      _elegida = null;
    });
    widget.alElegir(null);
    try {
      final r = (await api.get('/api/citas/franjas', {..._filtro, 'desde': dia, 'dias': '0'}) as List)
          .cast<Map<String, dynamic>>()
          .where((f) => f['fecha'] == dia && f['franja_id'] != widget.excluir)
          .toList();
      if (mounted && _dia == dia) setState(() => _horas = r);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _abrirCalendario() async {
    final hoy = DateTime.now();
    final inicio = DateTime(hoy.year, hoy.month, hoy.day);
    final dias = _dias ?? {};
    final elegido = await showDatePicker(
      context: context,
      initialDate: DateTime.parse(_dia ?? dias.first),
      firstDate: inicio,
      lastDate: inicio.add(const Duration(days: diasParaReservar)),
      selectableDayPredicate: (d) => dias.contains(_iso(d)),
      helpText: 'Días con horarios libres',
      cancelText: 'Cancelar',
      confirmText: 'Elegir',
    );
    if (elegido != null) _elegirDia(_iso(elegido));
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return Text(_error!, style: const TextStyle(color: rojo));
    if (_dias == null) return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
    if (_dias!.isEmpty) {
      return const Text('No hay horarios libres en los próximos 3 meses.', style: TextStyle(color: Colors.grey));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      OutlinedButton.icon(
        onPressed: _abrirCalendario,
        icon: const Icon(Icons.calendar_month),
        label: Text(_dia == null ? 'Elegir fecha' : '${fechaLarga(_dia!)}  ·  cambiar fecha'),
      ),
      Text('${_dias!.length} días con horarios libres hasta dentro de 3 meses.',
          style: const TextStyle(color: Colors.grey, fontSize: 12)),
      const SizedBox(height: 10),
      if (_horas == null && _dia != null)
        const LinearProgressIndicator()
      else if (_horas != null && _horas!.isEmpty)
        const Text('Ese día ya no tiene horarios libres. Elija otra fecha.')
      else if (_horas != null)
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final f in _horas!)
            ChoiceChip(
              label: Text(widget.cupos
                  ? '${hora(f['hora_inicio'])}  ·  ${f['cupos_libres']} cupo${f['cupos_libres'] == 1 ? '' : 's'}'
                  : hora(f['hora_inicio'])),
              selected: _elegida?['franja_id'] == f['franja_id'],
              onSelected: (_) {
                setState(() => _elegida = f);
                widget.alElegir(f);
              },
            ),
        ]),
    ]);
  }
}

// ------------------------------------------------------------------
// Sucursales y "Cómo llegar".
// ------------------------------------------------------------------

/// Sucursales de la empresa (y, si [conExternos], la opción de hacerse los exámenes en otro laboratorio).
class SelectorSucursal extends StatefulWidget {
  const SelectorSucursal({super.key, required this.alElegir, this.conExternos = false, this.inicial});
  final ValueChanged<Map<String, dynamic>> alElegir;
  final bool conExternos;
  final int? inicial;

  @override
  State<SelectorSucursal> createState() => _SelectorSucursalState();
}

class _SelectorSucursalState extends State<SelectorSucursal> {
  late final Future<List<Map<String, dynamic>>> _labs = _cargar();
  int? _elegido;

  Future<List<Map<String, dynamic>>> _cargar() async {
    final r = (await api.get('/api/laboratorios') as List).cast<Map<String, dynamic>>();
    final propias = r.where((l) => l['propio'] == true).toList();
    final inicial = propias.firstWhere((l) => l['laboratorio_id'] == widget.inicial, orElse: () => propias.first);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _elegido == null) _elegir(inicial);
    });
    return r;
  }

  void _elegir(Map<String, dynamic> l) {
    setState(() => _elegido = l['laboratorio_id'] as int);
    widget.alElegir(l);
  }

  Widget _opcion(Map<String, dynamic> l) {
    final propio = l['propio'] == true;
    final elegido = _elegido == l['laboratorio_id'];
    return Card(
      color: elegido ? verde.withValues(alpha: .1) : null,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12), side: BorderSide(color: elegido ? verde : Colors.grey.shade300)),
      child: ListTile(
        onTap: () => _elegir(l),
        leading: Icon(propio ? Icons.local_hospital : Icons.apartment, color: propio ? verde : Colors.grey),
        title: Text(l['nombre'] as String),
        subtitle: Text(propio
            ? '${l['direccion'] ?? ''}${l['telefono'] != null ? ' · ${l['telefono']}' : ''}'
            : 'Externo: allá se paga; luego sube el PDF de sus resultados para que le lleguen a su médico.'),
        trailing: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (propio && l['latitud'] != null)
            IconButton(
              tooltip: 'Ver en el mapa',
              icon: const Icon(Icons.map_outlined),
              onPressed: () => abrirEnlace(enlaceMapa(l['latitud'], l['longitud'])),
            ),
          if (elegido) const Icon(Icons.check_circle, color: verde),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Map<String, dynamic>>>(
        future: _labs,
        builder: (context, s) {
          if (s.hasError) return Text('${s.error}', style: const TextStyle(color: rojo));
          if (!s.hasData) return const LinearProgressIndicator();
          final propias = s.data!.where((l) => l['propio'] == true).toList();
          final externos = s.data!.where((l) => l['propio'] != true).toList();
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final l in propias) _opcion(l),
            if (widget.conExternos && externos.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.only(top: 8, bottom: 2),
                child: Text('O en otro laboratorio', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              for (final l in externos) _opcion(l),
            ],
          ]);
        },
      );
}

/// Google Maps con la ruta desde la ubicación del paciente hasta la sucursal.
String enlaceMapa(dynamic lat, dynamic lng) => 'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng';

/// Tarjeta del turno de toma de muestras: sucursal, fecha, hora y "Cómo llegar".
class TarjetaSucursal extends StatelessWidget {
  const TarjetaSucursal({super.key, required this.nombre, this.direccion, this.lat, this.lng, this.fecha, this.hora, this.titulo});
  final String nombre;
  final String? direccion;
  final dynamic lat;
  final dynamic lng;
  final String? fecha;
  final dynamic hora;
  final String? titulo;

  @override
  Widget build(BuildContext context) => Card(
        color: const Color(0xFFE6F2EE),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.place, color: verde, size: 30),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(titulo ?? 'Toma de muestras', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                if (fecha != null) Text('${fechaLarga(fecha!)} a las ${hora is String ? hora!.substring(0, 5) : hora}'),
                Text(nombre, style: const TextStyle(fontWeight: FontWeight.w600)),
                if (direccion != null) Text(direccion!, style: const TextStyle(color: Colors.black54)),
                if (lat != null) ...[
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () => abrirEnlace(enlaceMapa(lat, lng)),
                    icon: const Icon(Icons.directions),
                    label: const Text('Cómo llegar (Google Maps)'),
                  ),
                ],
              ]),
            ),
          ]),
        ),
      );
}

// ------------------------------------------------------------------
// Reagendar con el calendario.
// ------------------------------------------------------------------
Future<bool> reagendarCita(BuildContext context, Map<String, dynamic> cita) async {
  Map<String, dynamic>? elegida;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, actualizar) => AlertDialog(
        title: const Text('Reagendar la cita'),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Ahora: ${fechaLarga(cita['fecha'] as String)} a las ${hora(cita['hora_inicio'])}'
                  '${cita['sucursal'] != null ? ' · ${cita['sucursal']}' : ''}'),
              const SizedBox(height: 12),
              SelectorTurno(
                medicoId: cita['medico_id'] as int?,
                laboratorioId: cita['medico_id'] == null ? cita['laboratorio_id'] as int? : null,
                excluir: cita['franja_id'] as int?,
                alElegir: (f) => actualizar(() => elegida = f),
              ),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cerrar')),
          FilledButton(
            onPressed: elegida == null ? null : () => Navigator.pop(ctx, true),
            child: Text(elegida == null ? 'Elija fecha y hora' : 'Mover a las ${hora(elegida!['hora_inicio'])}'),
          ),
        ],
      ),
    ),
  );
  if (ok != true || elegida == null) return false;
  try {
    await api.post('/api/citas/${cita['cita_id']}/reprogramar', {'franja_id': elegida!['franja_id']});
    if (context.mounted) {
      mostrarMensaje(context, 'Cita reprogramada para el ${fechaLarga(elegida!['fecha'] as String)} a las ${hora(elegida!['hora_inicio'])}.');
    }
    return true;
  } catch (e) {
    if (context.mounted) mostrarMensaje(context, '$e', error: true);
    return false;
  }
}

// ------------------------------------------------------------------
// Cancelar: muestra antes cuánto se devuelve (o que ya solo se puede reagendar).
// ------------------------------------------------------------------
Future<bool> cancelarCita(BuildContext context, Map<String, dynamic> c) async {
  Map<String, dynamic> politica;
  try {
    politica = await api.get('/api/citas/${c['cita_id']}/cancelacion') as Map<String, dynamic>;
  } catch (e) {
    if (context.mounted) mostrarMensaje(context, '$e', error: true);
    return false;
  }
  if (!context.mounted) return false;
  final puede = politica['puede'] == true;
  final reembolso = politica['reembolso'] as num? ?? 0;
  final cuando = '${fechaLarga(c['fecha'] as String)} a las ${hora(c['hora_inicio'])}';
  final si = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(puede ? '¿Cancelar la cita?' : 'Ya no se puede cancelar'),
      content: Text(!puede
          ? '${politica['motivo']}\n\nPuede moverla a otro día con "Reagendar".'
          : reembolso > 0
              ? '$cuando.\n\nLa cita ya está pagada (${dinero(politica['pagado'])}). Al cancelar con 24 horas o más de '
                  'anticipación se le devuelve el ${politica['porcentaje']} %: ${dinero(reembolso)} a su tarjeta.\n\n'
                  'Si prefiere, puede reagendarla sin perder nada.'
              : '$cuando. El turno quedará libre para otro paciente.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(puede ? 'No' : 'Entendido')),
        if (puede)
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: rojo),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(reembolso > 0 ? 'Cancelar y recibir ${dinero(reembolso)}' : 'Sí, cancelar'),
          ),
      ],
    ),
  );
  if (si != true) return false;
  try {
    final r = await api.delete('/api/citas/${c['cita_id']}') as Map<String, dynamic>;
    if (context.mounted) mostrarMensaje(context, r['mensaje'] as String);
    return true;
  } catch (e) {
    if (context.mounted) mostrarMensaje(context, '$e', error: true);
    return false;
  }
}

// ------------------------------------------------------------------
// Titular de la tarjeta: solo letras y un espacio entre palabras.
// ------------------------------------------------------------------
final _soloLetras = FilteringTextInputFormatter.allow(RegExp(r'[A-Za-zÁÉÍÓÚÜÑáéíóúüñ ]'));

/// Quita el espacio inicial y no deja dos espacios seguidos.
final _espacios = TextInputFormatter.withFunction((viejo, nuevo) {
  final limpio = nuevo.text.replaceFirst(RegExp(r'^ +'), '').replaceAll(RegExp(r' {2,}'), ' ');
  if (limpio == nuevo.text) return nuevo;
  final corrido = nuevo.text.length - limpio.length;
  final pos = (nuevo.selection.baseOffset - corrido).clamp(0, limpio.length);
  return TextEditingValue(text: limpio, selection: TextSelection.collapsed(offset: pos));
});

final titularValido = RegExp(r'^[A-Za-zÁÉÍÓÚÜÑáéíóúüñ]+( [A-Za-zÁÉÍÓÚÜÑáéíóúüñ]+)+$');

Future<String?> pedirTitular(BuildContext context) {
  final ctrl = TextEditingController(text: sesion.nombre);
  final clave = GlobalKey<FormState>();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Titular de la tarjeta'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: clave,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Escriba el nombre como aparece en la tarjeta. Luego pasará a la página segura de Stripe '
                'para ingresar los datos de la tarjeta.'),
            const SizedBox(height: 12),
            TextFormField(
              controller: ctrl,
              autofocus: true,
              maxLength: 100,
              inputFormatters: [_soloLetras, _espacios],
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Nombre y apellido del titular', helperText: 'Solo letras'),
              validator: (v) => titularValido.hasMatch((v ?? '').trim())
                  ? null
                  : 'Escriba nombre y apellido, solo con letras y un espacio entre palabras.',
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
        FilledButton(
          onPressed: () {
            if (clave.currentState!.validate()) Navigator.pop(ctx, ctrl.text.trim());
          },
          child: const Text('Continuar al pago'),
        ),
      ],
    ),
  );
}

// ------------------------------------------------------------------
// Lista larga con botón para volver arriba.
// ------------------------------------------------------------------
class ListaConSubir extends StatefulWidget {
  const ListaConSubir({super.key, required this.children, this.padding, this.izquierda = false});
  final List<Widget> children;
  final EdgeInsets? padding;

  /// En el panel el botón principal ocupa la esquina derecha: este va a la izquierda.
  final bool izquierda;

  @override
  State<ListaConSubir> createState() => _ListaConSubirState();
}

class _ListaConSubirState extends State<ListaConSubir> {
  final _scroll = ScrollController();
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final v = _scroll.offset > 400;
      if (v != _visible) setState(() => _visible = v);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(children: [
        ListView(controller: _scroll, padding: widget.padding, children: widget.children),
        Positioned(
          bottom: 16,
          left: widget.izquierda ? 16 : null,
          right: widget.izquierda ? null : 16,
          child: AnimatedScale(
            scale: _visible ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: FloatingActionButton.small(
              heroTag: null,
              tooltip: 'Volver arriba',
              backgroundColor: Colors.white,
              foregroundColor: verde,
              onPressed: () => _scroll.animateTo(0, duration: const Duration(milliseconds: 400), curve: Curves.easeOut),
              child: const Icon(Icons.arrow_upward),
            ),
          ),
        ),
      ]);
}
