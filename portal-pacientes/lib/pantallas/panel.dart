import 'package:flutter/material.dart';

import '../api.dart';
import '../comun.dart';
import '../main.dart';
import 'citas.dart';
import 'solicitud.dart';

/// Panel del paciente autenticado.
class Panel extends StatefulWidget {
  const Panel({super.key});

  @override
  State<Panel> createState() => _PanelState();
}

class _PanelState extends State<Panel> {
  int _pestana = 0;
  int _version = 0; // se incrementa para recargar las listas

  void _recargar() => setState(() => _version++);

  @override
  Widget build(BuildContext context) {
    final paginas = [
      _Lista(key: ValueKey('c$_version'), ruta: '/api/citas/mias', vacio: 'Aún no tiene citas.', item: _itemCita),
      _Lista(key: ValueKey('s$_version'), ruta: '/api/solicitudes/mias?tipo=EXAMENES', vacio: 'Aún no tiene exámenes.', item: _itemSolicitud),
      _Lista(key: ValueKey('t$_version'), ruta: '/api/tratamientos/mios', vacio: 'No tiene tratamientos registrados.', item: _itemTratamiento),
      _Lista(key: ValueKey('p$_version'), ruta: '/api/pagos/mios', vacio: 'No tiene pagos.', item: _itemPago),
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
        Expanded(child: Centrado(child: paginas[_pestana])),
      ]),
      floatingActionButton: switch (_pestana) {
        0 => FloatingActionButton.extended(
            onPressed: () async {
              final hecho = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const ReservarCita()));
              if (hecho == true) _recargar();
            },
            icon: const Icon(Icons.event_available),
            label: const Text('Reservar cita'),
          ),
        1 => FloatingActionButton.extended(
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => const NuevaSolicitud()));
              _recargar();
            },
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

  /// Una cita es el turno para la toma de muestras. Queda "pendiente de pago" hasta que
  /// se pagan los exámenes vinculados a ella; si no se pagan a tiempo, se cancela sola.
  Widget _itemCita(Map<String, dynamic> c) {
    final estado = c['estado'] as String?;
    final pendiente = estado == 'PENDIENTE_PAGO';
    final solicitudId = c['solicitud_id'] as int?;
    final consulta = c['tipo'] == 'CONSULTA';
    final control = c['origen'] == 'MEDICO';
    // Las citas de control las agenda el médico y se pagan hasta 2 horas antes: se muestra la fecha completa.
    final limite = control ? fechaHora(c['vence_at']) : 'las ${horaLocal(c['vence_at'])}';
    final textos = <String>[
      consulta
          ? '${control ? 'Control' : 'Consulta'} con Dr(a). ${c['medico']} (${c['especialidad']})'
          : 'Toma de muestras en el laboratorio',
      if (c['motivo'] != null) c['motivo'] as String,
      if (solicitudId != null && !consulta)
        'Exámenes ${c['solicitud_codigo']}: ${c['examenes_resumen'] ?? ''} · ${dinero(c['solicitud_total'])}',
      if (solicitudId != null && consulta) 'Consulta ${c['solicitud_codigo']} · ${dinero(c['solicitud_total'])}',
      if (control) 'Control incluido en su consulta · sin costo',
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          ListTile(
            leading: Icon(consulta ? Icons.medical_services : Icons.biotech, color: verde),
            // Tocar la cita abre su detalle: el pedido, el pago y la factura (o los exámenes vinculados).
            onTap: solicitudId == null ? null : () => _abrirSolicitud(solicitudId),
            title: Text('${fechaLarga(c['fecha'] as String)} · ${hora(c['hora_inicio'])}'),
            subtitle: Text(textos.join('\n')),
            trailing: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
              Etiqueta(estado),
              // Una cita pagada no se cancela desde aquí: la reprograma o reembolsa el laboratorio.
              if (pendiente || (control && estado == 'CONFIRMADA'))
                IconButton(tooltip: 'Cancelar cita', icon: const Icon(Icons.close), onPressed: () => _cancelar(c)),
            ]),
          ),
          if (pendiente)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text(
                  solicitudId == null
                      ? 'Para confirmarla elija sus exámenes y páguelos antes de $limite.'
                      : 'Pague ${consulta ? 'la consulta' : 'los exámenes'} antes de $limite para confirmar la cita.',
                  style: const TextStyle(color: ambar, fontSize: 13),
                ),
                FilledButton.icon(
                  icon: Icon(solicitudId == null ? Icons.biotech : Icons.payment),
                  label: Text(solicitudId == null
                      ? 'Elegir exámenes y pagar'
                      : consulta
                          ? 'Pagar la consulta'
                          : 'Pagar ${c['solicitud_codigo']}'),
                  onPressed: () async {
                    await Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => solicitudId == null
                                ? NuevaSolicitud(citaId: c['cita_id'] as int)
                                : DetalleSolicitud(id: solicitudId)));
                    _recargar();
                  },
                ),
              ]),
            )
          else if (estado == 'CONFIRMADA' && !control)
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text('Cita pagada. Para reprogramarla o cancelarla, comuníquese con el laboratorio.',
                  style: TextStyle(color: Colors.grey, fontSize: 12)),
            ),
          if (solicitudId != null && estado == 'CONFIRMADA' && !consulta)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.science_outlined),
                label: Text('Ver exámenes ${c['solicitud_codigo']}'),
                onPressed: () async {
                  await Navigator.push(context, MaterialPageRoute(builder: (_) => DetalleSolicitud(id: solicitudId)));
                  _recargar();
                },
              ),
            ),
        ]),
      ),
    );
  }

  Future<void> _abrirSolicitud(int id) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => DetalleSolicitud(id: id)));
    _recargar();
  }

  Future<void> _cancelar(Map<String, dynamic> c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('¿Cancelar la cita?'),
        content: Text('${fechaLarga(c['fecha'] as String)} a las ${hora(c['hora_inicio'])}. El cupo quedará libre para otro paciente.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sí, cancelar')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.delete('/api/citas/${c['cita_id']}');
      if (mounted) mostrarMensaje(context, 'Cita cancelada.');
      _recargar();
    } catch (e) {
      if (mounted) mostrarMensaje(context, '$e', error: true);
    }
  }

  Widget _itemSolicitud(Map<String, dynamic> s) => Card(
        child: ListTile(
          leading: const Icon(Icons.science_outlined, color: verde),
          title: Text(s['codigo'] as String),
          subtitle: Text('${fechaHora(s['created_at'])} · ${dinero(s['total'])}'
              '${s['estado'] == 'REGISTRADA' ? ' · pendiente de pago' : ''}'),
          trailing: Etiqueta(s['estado'] as String?),
          onTap: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => DetalleSolicitud(id: s['solicitud_id'] as int)));
            _recargar();
          },
        ),
      );

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
          onTap: () => _abrirSolicitud(p['solicitud_id'] as int),
        ),
      );
}

/// Lista genérica que carga una ruta de la API, con buscador y páginas de 10.
class _Lista extends StatefulWidget {
  const _Lista({super.key, required this.ruta, required this.vacio, required this.item});
  final String ruta;
  final String vacio;
  final Widget Function(Map<String, dynamic>) item;

  @override
  State<_Lista> createState() => _ListaState();
}

class _ListaState extends State<_Lista> {
  static const porPagina = 10;
  late Future<List<dynamic>> _datos = _cargar();
  final _buscar = TextEditingController();
  int _pagina = 0;

  Future<List<dynamic>> _cargar() async => await api.get(widget.ruta) as List<dynamic>;

  /// Texto en el que se busca: todos los valores del elemento (código, exámenes, fechas, estado…).
  static String _texto(Map<String, dynamic> x) => x.values.where((v) => v != null).join(' ').toLowerCase();

  @override
  void dispose() {
    _buscar.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Cargando<List<dynamic>>(
        futuro: _datos,
        reintentar: () => setState(() => _datos = _cargar()),
        constructor: (lista) {
          if (lista.isEmpty) return Center(child: Text(widget.vacio, style: const TextStyle(color: Colors.grey)));
          final q = _buscar.text.trim().toLowerCase();
          final filtrados = lista.cast<Map<String, dynamic>>().where((x) => q.isEmpty || _texto(x).contains(q)).toList();
          final paginas = (filtrados.length / porPagina).ceil().clamp(1, 1 << 30);
          final pagina = _pagina.clamp(0, paginas - 1);
          final visibles = filtrados.skip(pagina * porPagina).take(porPagina);
          return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 90), children: [
            TextField(
              controller: _buscar,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Buscar por código, examen, fecha o estado'),
              onChanged: (_) => setState(() => _pagina = 0),
            ),
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
                Text('${pagina * porPagina + 1}–${(pagina * porPagina + porPagina).clamp(0, filtrados.length)} '
                    'de ${filtrados.length} · página ${pagina + 1} de $paginas'),
                IconButton(
                    tooltip: 'Siguiente',
                    onPressed: pagina < paginas - 1 ? () => setState(() => _pagina = pagina + 1) : null,
                    icon: const Icon(Icons.chevron_right)),
              ]),
          ]);
        },
      );
}
