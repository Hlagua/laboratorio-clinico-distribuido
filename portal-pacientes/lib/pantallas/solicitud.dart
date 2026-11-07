import 'dart:convert';

import 'package:flutter/material.dart';

import '../comun.dart';
import '../main.dart';

/// Detalle de una solicitud: resultados, PDF y pago.
class DetalleSolicitud extends StatefulWidget {
  const DetalleSolicitud({super.key, required this.id});
  final int id;

  @override
  State<DetalleSolicitud> createState() => _DetalleSolicitudState();
}

class _DetalleSolicitudState extends State<DetalleSolicitud> {
  late Future<Map<String, dynamic>> _s = _cargar();
  bool _procesando = false;

  Future<Map<String, dynamic>> _cargar() async => await api.get('/api/solicitudes/${widget.id}') as Map<String, dynamic>;

  Future<void> _pagarConTarjeta() async {
    setState(() => _procesando = true);
    try {
      final r = await api.post('/api/pagos/checkout', {'solicitud_id': widget.id}) as Map<String, dynamic>;
      api.irA(r['checkout_url'] as String); // página segura de Stripe
    } catch (e) {
      if (mounted) mostrarMensaje(context, '$e', error: true);
      if (mounted) setState(() => _procesando = false);
    }
  }

  Future<void> _pagarConTransferencia() async {
    setState(() => _procesando = true);
    try {
      final r = await api.post('/api/pagos/transferencia', {'solicitud_id': widget.id}) as Map<String, dynamic>;
      if (!mounted) return;
      final qr = base64Decode((r['qr'] as String).split(',').last);
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Pago por transferencia'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Image.memory(qr, width: 220, height: 220),
              Text('Monto: ${dinero(r['monto'])}', style: const TextStyle(fontWeight: FontWeight.bold)),
              SelectableText('Referencia: ${r['referencia']}'),
              const SizedBox(height: 8),
              Text(r['cuenta'] as String, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 8),
              const Text('Escanee el código con su banca móvil o transfiera indicando la referencia. '
                  'El laboratorio confirmará el pago y le avisará por correo.',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 12)),
            ]),
          ),
          actions: [FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Entendido'))],
        ),
      );
    } catch (e) {
      if (mounted) mostrarMensaje(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _procesando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mis exámenes'), backgroundColor: verdeOscuro, foregroundColor: Colors.white),
      body: Centrado(
        child: Cargando<Map<String, dynamic>>(
          futuro: _s,
          reintentar: () => setState(() => _s = _cargar()),
          constructor: (s) {
            final examenes = (s['examenes'] as List).cast<Map<String, dynamic>>();
            final conResultados = examenes.any((e) => e['resultado_id'] != null);
            return ListView(padding: const EdgeInsets.all(16), children: [
              Row(children: [
                Expanded(child: Text(s['codigo'] as String, style: Theme.of(context).textTheme.headlineSmall)),
                Etiqueta(s['estado'] as String?),
              ]),
              Text('${fechaHora(s['created_at'])} · Total ${dinero(s['total'])}'
                  '${s['medico_id'] != null ? ' · Ordenado por ${s['medico']}' : ''}'),
              const SizedBox(height: 12),
              if (s['estado'] == 'REGISTRADA')
                Card(
                  color: const Color(0xFFFFF4D6),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('Pendiente de pago: ${dinero(s['total'])}', style: const TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      Wrap(spacing: 10, runSpacing: 8, children: [
                        FilledButton.icon(
                          onPressed: _procesando ? null : _pagarConTarjeta,
                          icon: const Icon(Icons.credit_card),
                          label: const Text('Pagar con tarjeta'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _procesando ? null : _pagarConTransferencia,
                          icon: const Icon(Icons.qr_code),
                          label: const Text('Transferencia con QR'),
                        ),
                      ]),
                      const SizedBox(height: 6),
                      const Text('El pago con tarjeta se procesa en la página segura de Stripe (modo de prueba).',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ]),
                  ),
                ),
              if (conResultados)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      try {
                        await api.abrirPdf('/api/solicitudes/${widget.id}/pdf');
                      } catch (e) {
                        if (context.mounted) mostrarMensaje(context, '$e', error: true);
                      }
                    },
                    icon: const Icon(Icons.picture_as_pdf),
                    label: const Text('Descargar resultados en PDF'),
                  ),
                ),
              for (final ex in examenes) _Examen(ex),
            ]);
          },
        ),
      ),
    );
  }
}

class _Examen extends StatelessWidget {
  const _Examen(this.ex);
  final Map<String, dynamic> ex;

  @override
  Widget build(BuildContext context) {
    final valores = (ex['valores'] as List).cast<Map<String, dynamic>>();
    final obs = (ex['observaciones_medicas'] as List).cast<Map<String, dynamic>>();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(ex['examen'] as String, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
            Etiqueta(ex['estado'] as String?),
          ]),
          if (valores.isEmpty)
            const Padding(padding: EdgeInsets.only(top: 8), child: Text('Resultado pendiente.', style: TextStyle(color: Colors.grey)))
          else ...[
            const SizedBox(height: 8),
            for (final v in valores)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(flex: 3, child: Text(v['parametro'] as String)),
                  Expanded(
                    flex: 2,
                    child: Text(
                      '${v['valor_texto'] ?? v['valor_numerico']} ${v['unidad'] ?? ''}${v['fuera_rango'] == true ? '  ⚠' : ''}',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: v['fuera_rango'] == true ? rojo : null,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      v['valor_ref_texto'] as String? ??
                          (v['valor_ref_min'] != null ? '${v['valor_ref_min']} – ${v['valor_ref_max']}' : ''),
                      style: const TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                  ),
                ]),
              ),
            if (valores.any((v) => v['fuera_rango'] == true))
              const Text('⚠ Fuera del rango de referencia. Consulte con su médico.', style: TextStyle(color: rojo, fontSize: 12)),
          ],
          for (final o in obs)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: const Color(0xFFE8F0FA), borderRadius: BorderRadius.circular(6)),
              child: Text('Dr(a). ${o['medico']}: ${o['texto']}'),
            ),
        ]),
      ),
    );
  }
}

/// El paciente elige sus exámenes (opcionalmente asociados a una cita) y pasa al pago.
class NuevaSolicitud extends StatefulWidget {
  const NuevaSolicitud({super.key, this.citaId});
  final int? citaId;

  @override
  State<NuevaSolicitud> createState() => _NuevaSolicitudState();
}

class _NuevaSolicitudState extends State<NuevaSolicitud> {
  late Future<List<dynamic>> _catalogo = _cargar();
  final _elegidos = <int>{};
  bool _enviando = false;

  Future<List<dynamic>> _cargar() async => await api.get('/api/examenes/catalogo') as List<dynamic>;

  Future<void> _crear() async {
    setState(() => _enviando = true);
    try {
      final s = await api.post('/api/solicitudes', {
        'examenes': _elegidos.toList(),
        'cita_id': widget.citaId,
      }) as Map<String, dynamic>;
      if (mounted) {
        Navigator.pushReplacement(
            context, MaterialPageRoute(builder: (_) => DetalleSolicitud(id: s['solicitud_id'] as int)));
      }
    } catch (e) {
      if (mounted) mostrarMensaje(context, '$e', error: true);
      if (mounted) setState(() => _enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Solicitar exámenes'), backgroundColor: verdeOscuro, foregroundColor: Colors.white),
      body: Centrado(
        child: Cargando<List<dynamic>>(
          futuro: _catalogo,
          reintentar: () => setState(() => _catalogo = _cargar()),
          constructor: (lista) {
            final tipos = lista.cast<Map<String, dynamic>>();
            final total = tipos.where((t) => _elegidos.contains(t['tipo_examen_id'])).fold<num>(0, (a, t) => a + (t['precio'] as num));
            return Column(children: [
              if (widget.citaId != null)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text('Los exámenes quedarán asociados a la cita que acaba de reservar.'),
                ),
              Expanded(
                child: ListView(padding: const EdgeInsets.all(12), children: [
                  for (final t in tipos)
                    Card(
                      child: CheckboxListTile(
                        value: _elegidos.contains(t['tipo_examen_id']),
                        onChanged: (v) => setState(() => v == true
                            ? _elegidos.add(t['tipo_examen_id'] as int)
                            : _elegidos.remove(t['tipo_examen_id'])),
                        title: Text(t['nombre'] as String),
                        subtitle: Text('${t['categoria']} · ${dinero(t['precio'])}'
                            '${t['requiere_ayuno'] == true ? ' · requiere ayuno' : ''}'),
                      ),
                    ),
                ]),
              ),
              Material(
                elevation: 6,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    Expanded(child: Text('Total: ${dinero(total)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                    FilledButton(
                      onPressed: _elegidos.isEmpty || _enviando ? null : _crear,
                      child: Text(_enviando ? 'Creando…' : 'Continuar al pago'),
                    ),
                  ]),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}
