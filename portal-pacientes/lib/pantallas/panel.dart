import 'package:flutter/material.dart';

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
      _Lista(key: ValueKey('s$_version'), ruta: '/api/solicitudes/mias', vacio: 'Aún no tiene exámenes.', item: _itemSolicitud),
      _Lista(key: ValueKey('t$_version'), ruta: '/api/tratamientos/mios', vacio: 'No tiene tratamientos registrados.', item: _itemTratamiento),
      _Lista(key: ValueKey('p$_version'), ruta: '/api/pagos/mios', vacio: 'No tiene pagos.', item: _itemPago),
    ];
    return Scaffold(
      appBar: AppBar(
        backgroundColor: verdeOscuro,
        foregroundColor: Colors.white,
        title: Text('Hola, ${sesion.nombre.split(' ').first}'),
        actions: [
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

  Widget _itemCita(Map<String, dynamic> c) => Card(
        child: ListTile(
          leading: const Icon(Icons.event, color: verde),
          title: Text('${fechaLarga(c['fecha'] as String)} · ${hora(c['hora_inicio'])}'),
          subtitle: Text(c['motivo'] as String? ?? 'Sin motivo'),
          trailing: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, children: [
            Etiqueta(c['estado'] as String?),
            if (c['estado'] == 'PENDIENTE_PAGO' || c['estado'] == 'CONFIRMADA')
              IconButton(
                tooltip: 'Cancelar cita',
                icon: const Icon(Icons.close),
                onPressed: () => _cancelar(c),
              ),
          ]),
        ),
      );

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
          trailing: Etiqueta(p['estado'] as String?),
        ),
      );
}

/// Lista genérica que carga una ruta de la API.
class _Lista extends StatefulWidget {
  const _Lista({super.key, required this.ruta, required this.vacio, required this.item});
  final String ruta;
  final String vacio;
  final Widget Function(Map<String, dynamic>) item;

  @override
  State<_Lista> createState() => _ListaState();
}

class _ListaState extends State<_Lista> {
  late Future<List<dynamic>> _datos = _cargar();

  Future<List<dynamic>> _cargar() async => await api.get(widget.ruta) as List<dynamic>;

  @override
  Widget build(BuildContext context) => Cargando<List<dynamic>>(
        futuro: _datos,
        reintentar: () => setState(() => _datos = _cargar()),
        constructor: (lista) => lista.isEmpty
            ? Center(child: Text(widget.vacio, style: const TextStyle(color: Colors.grey)))
            : ListView(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
                children: [for (final x in lista) widget.item(x as Map<String, dynamic>)],
              ),
      );
}
