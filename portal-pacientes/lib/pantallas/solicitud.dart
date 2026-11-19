import 'package:flutter/material.dart';

import '../comun.dart';
import '../main.dart';
import 'extras.dart';

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

  Future<void> _documento(String ruta, String tipo, {String? nombre}) async {
    try {
      await api.abrirArchivo(ruta, tipo, nombre: nombre);
    } catch (e) {
      if (mounted) mostrarMensaje(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Detalle del pedido'), backgroundColor: verdeOscuro, foregroundColor: Colors.white),
      body: Centrado(
        child: Cargando<Map<String, dynamic>>(
          futuro: _s,
          reintentar: () => setState(() => _s = _cargar()),
          constructor: (s) {
            final examenes = (s['examenes'] as List).cast<Map<String, dynamic>>();
            final consulta = s['tipo'] == 'CONSULTA';
            final conResultados = !consulta && examenes.any((e) => e['resultado_id'] != null);
            return ListView(padding: const EdgeInsets.all(16), children: [
              Row(children: [
                Expanded(child: Text(s['codigo'] as String, style: Theme.of(context).textTheme.headlineSmall)),
                Etiqueta(s['estado'] as String?),
              ]),
              Text(consulta
                  ? 'Consulta con Dr(a). ${s['medico']} · ${fechaHora(s['created_at'])}'
                  : '${fechaHora(s['created_at'])} · Total ${dinero(s['total'])}'
                      '${s['medico_id'] != null ? ' · Ordenado por ${s['medico']}' : ''}'),
              const SizedBox(height: 12),
              // Elegir otro laboratorio (antes de pagar) o, si ya es externo, subir su resultado en PDF.
              OtroLaboratorio(s: s, alCambiar: () => setState(() => _s = _cargar())),
              if (s['estado'] == 'REGISTRADA' && s['laboratorio_propio'] != false)
                Card(
                  color: const Color(0xFFFFF4D6),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Revise su pedido antes de pagar', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 10),
                      ResumenPedido(s),
                      const SizedBox(height: 14),
                      Wrap(spacing: 10, runSpacing: 8, children: [
                        FilledButton.icon(
                          onPressed: _procesando ? null : _pagarConTarjeta,
                          icon: const Icon(Icons.credit_card),
                          label: const Text('Pagar con tarjeta'),
                        ),
                        // De momento todo cobro pasa por la pasarela (Stripe); la transferencia simulada
                        // queda solo en la API para las pruebas automáticas.
                      ]),
                      const SizedBox(height: 6),
                      const Text('El pago con tarjeta se procesa en la página segura de Stripe (modo de prueba).',
                          style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ]),
                  ),
                ),
              if (['PAGADA', 'EN_PROCESO', 'COMPLETADA'].contains(s['estado']))
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Pedido pagado', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 10),
                      ResumenPedido(s),
                      const SizedBox(height: 10),
                      Wrap(spacing: 10, runSpacing: 8, children: [
                        OutlinedButton.icon(
                          icon: const Icon(Icons.receipt_long),
                          label: const Text('Factura (PDF)'),
                          onPressed: () => _documento('/api/pagos/factura/${widget.id}', 'application/pdf'),
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.code),
                          label: const Text('Factura (XML)'),
                          onPressed: () => _documento('/api/pagos/factura/${widget.id}?formato=xml', 'application/xml',
                              nombre: 'factura-${s['codigo']}.xml'),
                        ),
                      ]),
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
              if (!consulta) for (final ex in examenes) _Examen(ex),
              if (['EN_PROCESO', 'COMPLETADA'].contains(s['estado'])) _Recetas(solicitudId: widget.id),
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
                      '${v['valor_texto'] ?? v['valor_numerico']} ${v['unidad'] ?? ''}',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: v['fuera_rango'] == true ? rojo : null,
                      ),
                    ),
                  ),
                  Expanded(flex: 2, child: Indicador(v['nivel'] as String?)),
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
              const Text('Hay valores fuera del rango de referencia (↑ alto, ↓ bajo). Consulte con su médico.',
                  style: TextStyle(color: rojo, fontSize: 12)),
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
  String _buscar = '';
  int _pagina = 0;
  static const porPagina = 10;
  late int? _citaId = widget.citaId;
  // Citas pendientes de pago que aún no tienen exámenes: se pueden vincular aquí.
  List<Map<String, dynamic>> _citasLibres = [];

  @override
  void initState() {
    super.initState();
    if (widget.citaId == null) _cargarCitas();
  }

  Future<void> _cargarCitas() async {
    try {
      final citas = (await api.get('/api/citas/mias') as List<dynamic>).cast<Map<String, dynamic>>();
      final libres = citas.where((c) => c['estado'] == 'PENDIENTE_PAGO' && c['solicitud_id'] == null).toList();
      if (mounted) {
        setState(() {
          _citasLibres = libres;
          if (libres.isNotEmpty) _citaId = libres.first['cita_id'] as int;
        });
      }
    } catch (_) {
      // Sin citas no pasa nada: la solicitud se crea sin cita.
    }
  }

  Future<List<dynamic>> _cargar() async => await api.get('/api/examenes/catalogo') as List<dynamic>;

  Future<void> _crear() async {
    setState(() => _enviando = true);
    try {
      final s = await api.post('/api/solicitudes', {
        'examenes': _elegidos.toList(),
        'cita_id': _citaId,
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
            // Buscador y páginas de 10; los exámenes marcados se conservan al cambiar de página.
            final filtrados = tipos
                .where((t) => _buscar.isEmpty || '${t['nombre']} ${t['categoria']} ${t['codigo']}'.toLowerCase().contains(_buscar))
                .toList();
            final paginas = (filtrados.length / porPagina).ceil().clamp(1, 1 << 30);
            final pagina = _pagina.clamp(0, paginas - 1);
            final visibles = filtrados.skip(pagina * porPagina).take(porPagina);
            return Column(children: [
              if (widget.citaId != null)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text('Los exámenes quedarán asociados a su cita. Al pagarlos, la cita queda confirmada.'),
                )
              else if (_citasLibres.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: DropdownButtonFormField<int?>(
                    initialValue: _citaId,
                    decoration: const InputDecoration(
                        labelText: 'Cita para la toma de muestras',
                        helperText: 'Al pagar estos exámenes, la cita elegida queda confirmada.'),
                    items: [
                      for (final c in _citasLibres)
                        DropdownMenuItem(
                            value: c['cita_id'] as int,
                            child: Text('${fechaLarga(c['fecha'] as String)} · ${hora(c['hora_inicio'])} (pendiente de pago)')),
                      const DropdownMenuItem(value: null, child: Text('Sin cita (acudiré sin turno)')),
                    ],
                    onChanged: (v) => setState(() => _citaId = v),
                  ),
                ),
              Expanded(
                child: ListView(padding: const EdgeInsets.all(12), children: [
                  TextField(
                    inputFormatters: [sinEmojis],
                    decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Buscar examen o categoría'),
                    onChanged: (v) => setState(() {
                      _buscar = v.trim().toLowerCase();
                      _pagina = 0;
                    }),
                  ),
                  const SizedBox(height: 6),
                  for (final t in visibles)
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
                  if (filtrados.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Ningún examen coincide.'))),
                  if (paginas > 1)
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      IconButton(
                          onPressed: pagina > 0 ? () => setState(() => _pagina = pagina - 1) : null,
                          icon: const Icon(Icons.chevron_left)),
                      Text('Página ${pagina + 1} de $paginas (${filtrados.length} exámenes)'),
                      IconButton(
                          onPressed: pagina < paginas - 1 ? () => setState(() => _pagina = pagina + 1) : null,
                          icon: const Icon(Icons.chevron_right)),
                    ]),
                ]),
              ),
              Material(
                elevation: 6,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Text('Total: ${dinero(total)}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        Text('${_elegidos.length} examen(es) · IVA incluido · verá el detalle antes de pagar',
                            style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      ]),
                    ),
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


/// Indicador del resultado frente al rango de referencia: ↑ alto, ↓ bajo, – normal.
class Indicador extends StatelessWidget {
  const Indicador(this.nivel, {super.key});
  final String? nivel;

  @override
  Widget build(BuildContext context) {
    final (texto, color) = switch (nivel) {
      'ALTO' => ('↑ alto', rojo),
      'BAJO' => ('↓ bajo', rojo),
      'ANORMAL' => ('fuera de rango', rojo),
      _ => ('– normal', Colors.grey.shade700),
    };
    return Text(texto, style: TextStyle(color: color, fontWeight: FontWeight.w600));
  }
}

/// Resumen del pedido, como en una tienda: cada examen, luego subtotal, IVA y total.
class ResumenPedido extends StatelessWidget {
  const ResumenPedido(this.s, {super.key});
  final Map<String, dynamic> s;

  Widget _fila(String a, String b, {bool fuerte = false, double tam = 14}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(a, style: TextStyle(fontSize: tam, fontWeight: fuerte ? FontWeight.bold : null))),
          Text(b, style: TextStyle(fontSize: tam, fontWeight: fuerte ? FontWeight.bold : null)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final examenes = (s['examenes'] as List).cast<Map<String, dynamic>>().where((e) => e['estado'] != 'ANULADO').toList();
    final n = examenes.length;
    final consulta = s['tipo'] == 'CONSULTA';
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFFF1F1F1), borderRadius: BorderRadius.circular(6)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('RESUMEN DEL PEDIDO', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: .5)),
        const SizedBox(height: 8),
        for (final e in examenes) _fila(e['examen'] as String, dinero(e['precio_unitario'])),
        if (s['cita_id'] != null && !consulta) _fila('Cita para la toma de muestras', 'sin costo'),
        const Divider(),
        _fila(consulta ? 'Subtotal (consulta, sin IVA)' : 'Subtotal ($n examen${n == 1 ? '' : 'es'}, sin IVA)', dinero(s['subtotal'])),
        _fila('IVA ${s['iva_porcentaje']} %', dinero(s['iva'])),
        const Divider(),
        _fila('Total del pedido', dinero(s['total']), fuerte: true, tam: 18),
        Text('(${s['iva_porcentaje']} % de IVA incluido en el precio${consulta ? '' : ' de cada examen'})',
            style: const TextStyle(fontSize: 12, color: Colors.grey)),
      ]),
    );
  }
}


/// Recetas del médico para esta solicitud: medicamentos a la izquierda e indicaciones a la derecha.
class _Recetas extends StatefulWidget {
  const _Recetas({required this.solicitudId});
  final int solicitudId;

  @override
  State<_Recetas> createState() => _RecetasState();
}

class _RecetasState extends State<_Recetas> {
  late final Future<List<dynamic>> _recetas = _cargar();

  Future<List<dynamic>> _cargar() async =>
      ((await api.get('/api/recetas/solicitud/${widget.solicitudId}')) as Map<String, dynamic>)['recetas'] as List<dynamic>;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<dynamic>>(
        future: _recetas,
        builder: (context, s) {
          final recetas = (s.data ?? const []).cast<Map<String, dynamic>>();
          if (recetas.isEmpty) return const SizedBox.shrink();
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final r in recetas) _receta(context, r),
          ]);
        },
      );

  Widget _receta(BuildContext context, Map<String, dynamic> r) {
    final items = (r['items'] as List).cast<Map<String, dynamic>>();
    const titulo = TextStyle(fontWeight: FontWeight.bold, color: verde, fontSize: 16);
    final rp = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Rp.', style: titulo),
      for (final i in items)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('${i['orden']}. ${i['nombre']} ${i['presentacion'] ?? ''}'
              '${i['cantidad'] != null ? '\nCantidad: ${i['cantidad']}' : ''}',
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
    ]);
    final indicaciones = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Indicaciones', style: titulo),
      for (final i in items)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: '${i['orden']}. ${i['nombre']}: ', style: const TextStyle(fontWeight: FontWeight.w600)),
            // La dosis puede venir sola en las indicaciones (receta simple): se arma sin huecos.
            TextSpan(
                text: [
              [i['dosis'], i['frecuencia'], if (i['duracion_dias'] != null) 'por ${i['duracion_dias']} días']
                  .where((x) => x != null && '$x'.isNotEmpty)
                  .join(' '),
              i['indicaciones'] ?? '',
            ].where((x) => '$x'.isNotEmpty).join('. ')),
          ])),
        ),
      if (r['indicaciones_generales'] != null) ...[
        const SizedBox(height: 10),
        const Text('Además', style: TextStyle(fontWeight: FontWeight.bold)),
        Text(r['indicaciones_generales'] as String),
      ],
    ]);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.medication, color: verde),
            const SizedBox(width: 8),
            Expanded(child: Text('Receta de Dr(a). ${r['medico']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
            OutlinedButton.icon(
              icon: const Icon(Icons.picture_as_pdf),
              label: const Text('Receta (PDF)'),
              onPressed: () async {
                try {
                  await api.abrirPdf('/api/recetas/${r['receta_id']}/pdf');
                } catch (e) {
                  if (context.mounted) mostrarMensaje(context, '$e', error: true);
                }
              },
            ),
          ]),
          if (r['diagnostico'] != null) Text('Diagnóstico: ${r['diagnostico']}', style: const TextStyle(color: Colors.grey)),
          const Divider(),
          // Como en la receta impresa: izquierda la receta, derecha las indicaciones (en el celular, una debajo de otra).
          LayoutBuilder(
            builder: (_, c) => c.maxWidth > 600
                ? IntrinsicHeight(
                    child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(child: rp),
                      const VerticalDivider(width: 28),
                      Expanded(child: indicaciones),
                    ]),
                  )
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [rp, const Divider(height: 24), indicaciones]),
          ),
        ]),
      ),
    );
  }
}
