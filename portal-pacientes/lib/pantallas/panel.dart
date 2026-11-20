import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../comun.dart';
import '../main.dart';
import 'citas.dart';
import 'extras.dart';
import 'solicitud.dart';
import 'turnos.dart';

/// Panel del paciente autenticado.
class Panel extends StatefulWidget {
  const Panel({super.key});

  @override
  State<Panel> createState() => _PanelState();
}

class _PanelState extends State<Panel> {
  int _pestana = 0;
  int _version = 0; // al cambiar, las listas vuelven a pedir sus datos (sin perder el filtro)
  Timer? _reloj;

  @override
  void initState() {
    super.initState();
    // Los estados cambian solos (pago confirmado por Stripe, cita vencida, resultado listo):
    // se actualiza cada 30 s mientras el panel está a la vista.
    _reloj = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) _recargar();
    });
  }

  @override
  void dispose() {
    _reloj?.cancel();
    super.dispose();
  }

  void _recargar() => setState(() => _version++);

  /// Abre una pantalla y, al volver, actualiza las listas.
  Future<void> _abrir(Widget pantalla) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => pantalla));
    if (mounted) _recargar();
  }

  Future<void> _reservar() async {
    final r = await Navigator.push<Map<String, dynamic>>(context, MaterialPageRoute(builder: (_) => const ReservarCita()));
    if (!mounted) return;
    _recargar(); // la cita nueva aparece en seguida, sin recargar la página
    if (r == null || r['pagar'] != true) return;
    final cita = r['cita'] as Map<String, dynamic>;
    await _abrir(cita['solicitud_id'] != null
        ? DetalleSolicitud(id: cita['solicitud_id'] as int)
        : NuevaSolicitud(citaId: cita['cita_id'] as int));
  }

  void _irAEnlace(Map<String, dynamic> enlace) {
    if (enlace['tipo'] == 'citas') {
      setState(() => _pestana = 0);
    } else if (enlace['solicitud_id'] != null) {
      _abrir(DetalleSolicitud(id: enlace['solicitud_id'] as int));
    }
  }

  @override
  Widget build(BuildContext context) {
    final paginas = [
      _Lista(version: _version, ruta: '/api/citas/mias', vacio: 'Aún no tiene citas.', item: _itemCita, fecha: (x) => x['fecha']),
      _Lista(
          version: _version,
          ruta: '/api/solicitudes/mias?tipo=EXAMENES',
          vacio: 'Aún no tiene exámenes.',
          item: _itemSolicitud,
          fecha: (x) => x['created_at']),
      _Lista(
          version: _version,
          ruta: '/api/solicitudes/mias?tipo=EXAMENES',
          vacio: 'Aún no tiene resultados. Aparecen aquí cuando el laboratorio los registra.',
          filtro: (x) => (x['examenes_listos'] as int? ?? 0) > 0 && x['estado'] != 'ANULADA',
          item: _itemResultado,
          fecha: (x) => x['created_at']),
      _Lista(
          version: _version,
          ruta: '/api/tratamientos/mios',
          vacio: 'No tiene tratamientos registrados.',
          item: _itemTratamiento,
          fecha: (x) => x['fecha_inicio']),
      _Lista(
          version: _version,
          ruta: '/api/pagos/mios',
          vacio: 'No tiene pagos.',
          item: _itemPago,
          fecha: (x) => x['confirmado_at'] ?? x['created_at']),
    ];
    return Scaffold(
      appBar: AppBar(
        backgroundColor: verdeOscuro,
        foregroundColor: Colors.white,
        title: Text('Hola, ${sesion.nombre.split(' ').first}'),
        actions: [
          if (sesion.roles.any(Sesion.rolesPersonal.contains))
            TextButton.icon(
              onPressed: _cambiarRol,
              icon: const Icon(Icons.swap_horiz, color: Colors.white),
              label: const Text('Cambiar de rol', style: TextStyle(color: Colors.white)),
            ),
          Campana(key: ValueKey('campana$_version'), alAbrir: _irAEnlace),
          IconButton(tooltip: 'Actualizar', onPressed: _recargar, icon: const Icon(Icons.refresh)),
          TextButton(
            onPressed: () {
              sesion.cerrar();
              Navigator.pushNamedAndRemoveUntil(context, '/', (_) => false);
            },
            child: const Text('Salir', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Column(children: [
        const AvisoContingencia(),
        // Solo la pestaña a la vista pide sus datos (y se actualiza cada 30 s).
        Expanded(child: Centrado(child: KeyedSubtree(key: ValueKey('pestana$_pestana'), child: paginas[_pestana]))),
      ]),
      floatingActionButton: switch (_pestana) {
        0 => FloatingActionButton.extended(
            onPressed: _reservar,
            icon: const Icon(Icons.event_available),
            label: const Text('Reservar cita'),
          ),
        1 => FloatingActionButton.extended(
            onPressed: () => _abrir(const NuevaSolicitud()),
            icon: const Icon(Icons.biotech),
            label: const Text('Solicitar exámenes'),
          ),
        _ => null,
      },
      bottomNavigationBar: NavigationBar(
        selectedIndex: _pestana,
        onDestinationSelected: (i) => setState(() => _pestana = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.calendar_month), label: 'Mis citas'),
          NavigationDestination(icon: Icon(Icons.science), label: 'Mis exámenes'),
          NavigationDestination(icon: Icon(Icons.assignment_turned_in), label: 'Resultados'),
          NavigationDestination(icon: Icon(Icons.medication), label: 'Tratamientos'),
          NavigationDestination(icon: Icon(Icons.receipt_long), label: 'Pagos'),
        ],
      ),
    );
  }

  /// Pasa al sistema del personal con otro de sus roles, sin volver a ingresar.
  Future<void> _cambiarRol() async {
    final roles = ['PACIENTE', ...sesion.roles.where(Sesion.rolesPersonal.contains)];
    final rol = await elegirRol(context, roles, actual: 'PACIENTE');
    if (rol != null && rol != 'PACIENTE') sesion.irAlPersonal(sesion.token!, sesion.usuario!, rol);
  }

  /// Una cita es una consulta (o control) con un médico o un turno de toma de muestras en una sucursal.
  /// Queda "pendiente de pago" hasta que se paga; si no se paga a tiempo, se cancela sola.
  Widget _itemCita(Map<String, dynamic> c) {
    final estado = c['estado'] as String?;
    final pendiente = estado == 'PENDIENTE_PAGO';
    final activa = pendiente || estado == 'CONFIRMADA';
    final solicitudId = c['solicitud_id'] as int?;
    final consulta = c['tipo'] == 'CONSULTA';
    final control = c['origen'] == 'MEDICO';
    final futura = (c['fecha'] as String).compareTo(hoyIso()) >= 0;
    // El control se paga hasta 2 horas antes de la cita: se muestra la fecha completa.
    final limite = control ? fechaHora(c['vence_at']) : 'las ${horaLocal(c['vence_at'])}';
    final textos = <String>[
      consulta
          ? '${control ? 'Control' : 'Consulta'} con Dr(a). ${c['medico']} (${c['especialidad']})'
          : 'Toma de muestras${c['sucursal'] != null ? ' en ${c['sucursal']}' : ''}',
      if (c['motivo'] != null && !(c['motivo'] as String).startsWith('Toma de muestras')) c['motivo'] as String,
      if (solicitudId != null && !consulta)
        'Exámenes ${c['solicitud_codigo']}: ${c['examenes_resumen'] ?? ''} · ${dinero(c['solicitud_total'])}',
      if (solicitudId != null && consulta) '${control ? 'Control' : 'Consulta'} ${c['solicitud_codigo']} · ${dinero(c['solicitud_total'])}',
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ListTile(
            leading: Icon(consulta ? Icons.medical_services : Icons.biotech, color: verde),
            // Tocar la cita abre su detalle: el pedido, el pago y la factura (o los exámenes vinculados).
            onTap: solicitudId == null ? null : () => _abrir(DetalleSolicitud(id: solicitudId)),
            title: Text('${fechaLarga(c['fecha'] as String)} · ${hora(c['hora_inicio'])}'),
            subtitle: Text(textos.join('\n')),
            trailing: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, children: [
              Etiqueta(estado),
              // Reagendar: mismo tipo de cita (mismo médico o misma sucursal), en el calendario hasta 3 meses.
              if (activa && futura)
                IconButton(
                    tooltip: 'Reagendar',
                    icon: const Icon(Icons.edit_calendar),
                    onPressed: () async {
                      if (await reagendarCita(context, c)) _recargar();
                    }),
              // Cancelar: si está pagada, se devuelve una parte con 24 h de anticipación; si no, solo reagendar.
              if (activa && futura)
                IconButton(
                    tooltip: 'Cancelar cita',
                    icon: const Icon(Icons.close),
                    onPressed: () async {
                      if (await cancelarCita(context, c)) _recargar();
                    }),
            ]),
          ),
          if (pendiente)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text(
                  solicitudId == null
                      ? 'Para confirmarla elija sus exámenes y páguelos antes de $limite.'
                      : 'Pague ${consulta ? (control ? 'el control' : 'la consulta') : 'los exámenes'} antes de $limite para confirmar la cita.',
                  style: const TextStyle(color: ambar, fontSize: 13),
                ),
                FilledButton.icon(
                  icon: Icon(solicitudId == null ? Icons.biotech : Icons.payment),
                  label: Text(solicitudId == null
                      ? 'Elegir exámenes y pagar'
                      : consulta
                          ? (control ? 'Pagar el control' : 'Pagar la consulta')
                          : 'Pagar ${c['solicitud_codigo']}'),
                  onPressed: () => _abrir(solicitudId == null
                      ? NuevaSolicitud(citaId: c['cita_id'] as int)
                      : DetalleSolicitud(id: solicitudId)),
                ),
              ]),
            ),
          if (!consulta && activa && c['latitud'] != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.directions),
                label: Text('Cómo llegar a ${c['sucursal']}'),
                onPressed: () => abrirEnlace(enlaceMapa(c['latitud'], c['longitud'])),
              ),
            ),
          if (solicitudId != null && estado == 'CONFIRMADA' && !consulta)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.science_outlined),
                label: Text('Ver exámenes ${c['solicitud_codigo']}'),
                onPressed: () => _abrir(DetalleSolicitud(id: solicitudId)),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _itemSolicitud(Map<String, dynamic> s) => Card(
        child: ListTile(
          leading: const Icon(Icons.science_outlined, color: verde),
          title: Text(s['codigo'] as String),
          subtitle: Text([
            '${fechaHora(s['created_at'])} · ${dinero(s['total'])}${s['estado'] == 'REGISTRADA' ? ' · pendiente de pago' : ''}',
            if (s['examenes_resumen'] != null) s['examenes_resumen'],
            if (s['cita_fecha'] != null && s['laboratorio'] != null)
              'Toma de muestras: ${fechaLarga(s['cita_fecha'] as String)} ${hora(s['cita_hora'])} en ${s['laboratorio']}'
            else if (s['laboratorio_propio'] == false)
              'En ${s['laboratorio']} (externo)',
          ].join('\n')),
          trailing: Etiqueta(s['estado'] as String?),
          onTap: () => _abrir(DetalleSolicitud(id: s['solicitud_id'] as int)),
        ),
      );

  /// Resultados: cada solicitud con exámenes listos, con su informe en PDF.
  Widget _itemResultado(Map<String, dynamic> s) {
    final total = (s['examenes_resumen'] as String? ?? '').split(', ').where((x) => x.isNotEmpty).length;
    final listos = s['examenes_listos'] as int? ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.assignment_turned_in, color: verde),
            const SizedBox(width: 10),
            Expanded(child: Text(s['codigo'] as String, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
            Text(listos >= total ? 'Completos' : '$listos de $total listos',
                style: TextStyle(color: listos >= total ? verde : ambar, fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 4),
          Text(s['examenes_resumen'] as String? ?? ''),
          Text('Pedido el ${fechaHora(s['created_at'])}${s['medico'] != null ? ' · ordenado por Dr(a). ${s['medico']}' : ''}',
              style: const TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(
              icon: const Icon(Icons.visibility),
              label: const Text('Ver resultados'),
              onPressed: () => _abrir(DetalleSolicitud(id: s['solicitud_id'] as int)),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.picture_as_pdf),
              label: const Text('Informe en PDF'),
              onPressed: () async {
                try {
                  await api.abrirPdf('/api/solicitudes/${s['solicitud_id']}/pdf');
                } catch (e) {
                  if (mounted) mostrarMensaje(context, '$e', error: true);
                }
              },
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _itemTratamiento(Map<String, dynamic> t) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(t['diagnostico'] as String, style: const TextStyle(fontWeight: FontWeight.bold))),
              Etiqueta(t['estado'] as String?),
            ]),
            const SizedBox(height: 6),
            Text(t['indicaciones'] as String),
            const SizedBox(height: 6),
            Text('Dr(a). ${t['medico']} · desde ${t['fecha_inicio']}${t['fecha_fin'] != null ? ' hasta ${t['fecha_fin']}' : ''}',
                style: const TextStyle(color: Colors.grey, fontSize: 12)),
            if (t['solicitud_id'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.medication),
                  label: const Text('Ver receta'),
                  onPressed: () => _abrir(DetalleSolicitud(id: t['solicitud_id'] as int)),
                ),
              ),
          ]),
        ),
      );

  Widget _itemPago(Map<String, dynamic> p) => Card(
        child: ListTile(
          leading: Icon(p['metodo'] == 'STRIPE' ? Icons.credit_card : Icons.qr_code, color: verde),
          title: Text('${p['solicitud_codigo']} · ${dinero(p['monto'])}'),
          subtitle: Text([
            p['metodo'] == 'STRIPE' ? 'Tarjeta (Stripe)' : 'Transferencia ${p['referencia_transferencia'] ?? ''}',
            fechaHora(p['confirmado_at'] ?? p['created_at']),
            if (p['motivo_rechazo'] != null) p['motivo_rechazo'],
            if ((p['monto_reembolsado'] as num) > 0) 'Reembolsado ${dinero(p['monto_reembolsado'])}',
          ].join(' · ')),
          trailing: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, children: [
            Etiqueta(p['estado'] as String?),
            const Icon(Icons.chevron_right, color: Colors.grey),
          ]),
          // Tocar el pago abre el detalle del pedido con su factura (PDF y XML).
          onTap: () => _abrir(DetalleSolicitud(id: p['solicitud_id'] as int)),
        ),
      );
}

/// Lista genérica que carga una ruta de la API, con buscador, filtro por fechas, páginas de 10
/// y un botón para volver arriba.
class _Lista extends StatefulWidget {
  const _Lista({
    required this.version,
    required this.ruta,
    required this.vacio,
    required this.item,
    required this.fecha,
    this.filtro,
  });
  final int version;
  final String ruta;
  final String vacio;
  final Widget Function(Map<String, dynamic>) item;
  final dynamic Function(Map<String, dynamic>) fecha;
  final bool Function(Map<String, dynamic>)? filtro;

  @override
  State<_Lista> createState() => _ListaState();
}

class _ListaState extends State<_Lista> {
  static const porPagina = 10;
  late Future<List<dynamic>> _datos = _cargar();
  List<dynamic>? _ultimos; // se siguen mostrando mientras llega la actualización
  final _buscar = TextEditingController();
  int _pagina = 0;
  DateTime? _desde;
  DateTime? _hasta;

  Future<List<dynamic>> _cargar() async {
    final r = await api.get(widget.ruta) as List<dynamic>;
    _ultimos = r;
    return r;
  }

  @override
  void didUpdateWidget(_Lista viejo) {
    super.didUpdateWidget(viejo);
    if (viejo.version != widget.version) _datos = _cargar();
  }

  /// Texto en el que se busca: todos los valores del elemento (código, exámenes, fechas, estado…).
  static String _texto(Map<String, dynamic> x) => x.values.where((v) => v != null).join(' ').toLowerCase();

  bool _enRango(Map<String, dynamic> x) {
    if (_desde == null && _hasta == null) return true;
    final v = widget.fecha(x);
    if (v == null) return false;
    final f = DateTime.tryParse('$v'.length >= 10 ? '$v'.substring(0, 10) : '$v');
    if (f == null) return false;
    return (_desde == null || !f.isBefore(_desde!)) && (_hasta == null || !f.isAfter(_hasta!));
  }

  Future<void> _elegirFecha(bool desde) async {
    final hoy = DateTime.now();
    final f = await showDatePicker(
      context: context,
      initialDate: (desde ? _desde : _hasta) ?? hoy,
      firstDate: DateTime(2024),
      lastDate: hoy.add(const Duration(days: 366)),
      helpText: desde ? 'Desde' : 'Hasta',
    );
    if (f != null) {
      setState(() {
        if (desde) {
          _desde = f;
        } else {
          _hasta = f;
        }
        _pagina = 0;
      });
    }
  }

  String _corta(DateTime d) => fechaLarga(d.toIso8601String().substring(0, 10));

  @override
  void dispose() {
    _buscar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<dynamic>>(
        future: _datos,
        builder: (context, s) {
          final lista = s.data ?? _ultimos;
          if (s.hasError && lista == null) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('${s.error}', style: const TextStyle(color: rojo)),
                OutlinedButton(onPressed: () => setState(() => _datos = _cargar()), child: const Text('Reintentar')),
              ]),
            );
          }
          if (lista == null) return const Center(child: CircularProgressIndicator());
          final todos = lista.cast<Map<String, dynamic>>().where((x) => widget.filtro?.call(x) ?? true).toList();
          if (todos.isEmpty) {
            return Center(
                child: Padding(padding: const EdgeInsets.all(24), child: Text(widget.vacio, style: const TextStyle(color: Colors.grey))));
          }
          final q = _buscar.text.trim().toLowerCase();
          final filtrados = todos.where((x) => (q.isEmpty || _texto(x).contains(q)) && _enRango(x)).toList();
          final paginas = (filtrados.length / porPagina).ceil().clamp(1, 1 << 30);
          final pagina = _pagina.clamp(0, paginas - 1);
          final visibles = filtrados.skip(pagina * porPagina).take(porPagina);
          return ListaConSubir(izquierda: true, padding: const EdgeInsets.fromLTRB(12, 12, 12, 90), children: [
            TextField(
              controller: _buscar,
              inputFormatters: [sinEmojis],
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Buscar por código, examen, fecha o estado'),
              onChanged: (_) => setState(() => _pagina = 0),
            ),
            const SizedBox(height: 8),
            // Filtro por fechas: desde y hasta (cualquiera de los dos).
            Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              const Icon(Icons.date_range, size: 20, color: Colors.grey),
              ActionChip(label: Text(_desde == null ? 'Desde' : 'Desde ${_corta(_desde!)}'), onPressed: () => _elegirFecha(true)),
              ActionChip(label: Text(_hasta == null ? 'Hasta' : 'Hasta ${_corta(_hasta!)}'), onPressed: () => _elegirFecha(false)),
              if (_desde != null || _hasta != null)
                TextButton.icon(
                  icon: const Icon(Icons.clear, size: 18),
                  label: const Text('Quitar fechas'),
                  onPressed: () => setState(() {
                    _desde = null;
                    _hasta = null;
                  }),
                ),
            ]),
            const SizedBox(height: 8),
            if (filtrados.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Nada coincide con la búsqueda.')))
            else
              for (final x in visibles) widget.item(x),
            if (filtrados.length > porPagina)
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                IconButton(
                    tooltip: 'Anterior',
                    onPressed: pagina > 0 ? () => setState(() => _pagina = pagina - 1) : null,
                    icon: const Icon(Icons.chevron_left)),
                Flexible(
                  child: Text('${pagina * porPagina + 1}–${(pagina * porPagina + porPagina).clamp(0, filtrados.length)} '
                      'de ${filtrados.length} · página ${pagina + 1} de $paginas'),
                ),
                IconButton(
                    tooltip: 'Siguiente',
                    onPressed: pagina < paginas - 1 ? () => setState(() => _pagina = pagina + 1) : null,
                    icon: const Icon(Icons.chevron_right)),
              ]),
          ]);
        },
      );
}
