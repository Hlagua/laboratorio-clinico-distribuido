import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../comun.dart';
import '../main.dart';

// ------------------------------------------------------------------
// Centro de notificaciones: los mismos avisos que llegan por correo.
// ------------------------------------------------------------------
const _claveVistas = 'notificaciones-vistas';

int _ultimaVista() {
  try {
    return int.tryParse(web.window.localStorage.getItem(_claveVistas) ?? '') ?? 0;
  } catch (_) {
    return 0;
  }
}

void _marcarVistas(int id) {
  try {
    web.window.localStorage.setItem(_claveVistas, '$id');
  } catch (_) {}
}

/// Campana con el número de avisos nuevos; al tocarla abre el centro de notificaciones.
class Campana extends StatefulWidget {
  const Campana({super.key, this.alAbrir});

  /// Al tocar un aviso: adónde llevar al paciente (su solicitud o sus citas).
  final void Function(Map<String, dynamic> enlace)? alAbrir;

  @override
  State<Campana> createState() => _CampanaState();
}

class _CampanaState extends State<Campana> {
  List<Map<String, dynamic>> _avisos = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      final r = (await api.get('/api/notificaciones/mias') as List).cast<Map<String, dynamic>>();
      if (mounted) setState(() => _avisos = r);
    } catch (_) {
      // En contingencia o sin conexión la campana queda sin número.
    }
  }

  @override
  Widget build(BuildContext context) {
    final vista = _ultimaVista();
    final nuevos = _avisos.where((a) => (a['notificacion_id'] as int) > vista).length;
    return IconButton(
      tooltip: 'Notificaciones',
      icon: Badge(isLabelVisible: nuevos > 0, label: Text('$nuevos'), child: const Icon(Icons.notifications_outlined)),
      onPressed: () async {
        await _cargar();
        if (_avisos.isNotEmpty) _marcarVistas(_avisos.first['notificacion_id'] as int);
        if (!context.mounted) return;
        final enlace = await Navigator.push<Map<String, dynamic>>(
            context, MaterialPageRoute(builder: (_) => CentroNotificaciones(avisos: _avisos, vista: vista)));
        setState(() {});
        if (enlace != null) widget.alAbrir?.call(enlace);
      },
    );
  }
}

class CentroNotificaciones extends StatelessWidget {
  const CentroNotificaciones({super.key, required this.avisos, required this.vista});
  final List<Map<String, dynamic>> avisos;
  final int vista;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Notificaciones'), backgroundColor: verdeOscuro, foregroundColor: Colors.white),
        body: Centrado(
          child: avisos.isEmpty
              ? const Center(child: Text('No tiene notificaciones.', style: TextStyle(color: Colors.grey)))
              : ListView(padding: const EdgeInsets.all(12), children: [
                  for (final a in avisos)
                    Card(
                      color: (a['notificacion_id'] as int) > vista ? const Color(0xFFE6F2EE) : null,
                      child: ListTile(
                        // Tocar el aviso lleva a lo que avisa (la solicitud, el pago, las citas).
                        onTap: a['enlace'] == null ? null : () => Navigator.pop(context, a['enlace'] as Map<String, dynamic>),
                        trailing: a['enlace'] == null ? null : const Icon(Icons.chevron_right),
                        leading: Icon(_icono(a['tipo'] as String?), color: verde),
                        title: Text(a['asunto'] as String),
                        subtitle: Text('${a['cuerpo']}\n${fechaHora(a['created_at'])} · '
                            '${a['estado'] == 'ENVIADA' ? 'enviado a su correo' : a['estado'] == 'PENDIENTE' ? 'enviándose a su correo' : 'no se pudo enviar al correo'}'),
                        isThreeLine: true,
                      ),
                    ),
                ]),
        ),
      );

  static IconData _icono(String? tipo) => switch (tipo) {
        'PAGO_APROBADO' || 'PAGO_RECHAZADO' || 'REEMBOLSO' => Icons.receipt_long,
        'RESULTADO_LISTO' => Icons.science,
        'RECETA' => Icons.medication,
        'CITA_RESERVADA' || 'CITA_REPROGRAMADA' => Icons.event,
        _ => Icons.mail_outline,
      };
}

// ------------------------------------------------------------------
// Exámenes en otro laboratorio y su resultado en PDF.
// ------------------------------------------------------------------

/// Abre el selector de archivos del navegador y devuelve (nombre, bytes) del PDF elegido.
Future<(String, Uint8List)?> elegirPdf() async {
  final input = web.document.createElement('input') as web.HTMLInputElement
    ..type = 'file'
    ..accept = 'application/pdf';
  input.click();
  await web.EventStreamProviders.changeEvent.forTarget(input).first;
  final archivo = input.files?.item(0);
  if (archivo == null) return null;
  final datos = (await archivo.arrayBuffer().toDart).toDart.asUint8List();
  return (archivo.name, datos);
}

class OtroLaboratorio extends StatefulWidget {
  const OtroLaboratorio({super.key, required this.s, required this.alCambiar});
  final Map<String, dynamic> s;
  final VoidCallback alCambiar;

  @override
  State<OtroLaboratorio> createState() => _OtroLaboratorioState();
}

class _OtroLaboratorioState extends State<OtroLaboratorio> {
  List<Map<String, dynamic>> _docs = [];
  bool _subiendo = false;

  bool get _externo => widget.s['laboratorio_propio'] == false;

  @override
  void initState() {
    super.initState();
    if (_externo) _cargarDocs();
  }

  Future<void> _cargarDocs() async {
    try {
      final d = (await api.get('/api/solicitudes/${widget.s['solicitud_id']}/resultado-externo') as List).cast<Map<String, dynamic>>();
      if (mounted) setState(() => _docs = d);
    } catch (_) {}
  }

  Future<void> _elegirLaboratorio() async {
    final labs = (await api.get('/api/laboratorios') as List).cast<Map<String, dynamic>>().where((l) => l['propio'] != true).toList();
    if (!mounted) return;
    final lab = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('¿En qué laboratorio se hará los exámenes?'),
        children: [
          for (final l in labs)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, l),
              child: ListTile(title: Text(l['nombre'] as String), subtitle: Text('${l['direccion'] ?? ''} ${l['telefono'] ?? ''}')),
            ),
          if (labs.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No hay otros laboratorios registrados.')),
        ],
      ),
    );
    if (lab == null) return;
    try {
      await api.put('/api/solicitudes/${widget.s['solicitud_id']}/laboratorio', {'laboratorio_id': lab['laboratorio_id']});
      if (mounted) mostrarMensaje(context, 'Listo: se hará los exámenes en ${lab['nombre']}. Cuando tenga los resultados, súbalos en PDF.');
      widget.alCambiar();
    } catch (e) {
      if (mounted) mostrarMensaje(context, '$e', error: true);
    }
  }

  Future<void> _subir() async {
    final pdf = await elegirPdf();
    if (pdf == null) return;
    if (pdf.$2.length > 5 * 1024 * 1024) {
      if (mounted) mostrarMensaje(context, 'El PDF no puede pasar de 5 MB.', error: true);
      return;
    }
    setState(() => _subiendo = true);
    try {
      final r = await api.post('/api/solicitudes/${widget.s['solicitud_id']}/resultado-externo',
          {'nombre': pdf.$1, 'contenido_base64': base64Encode(pdf.$2)}) as Map<String, dynamic>;
      final n = (r['valores'] as List).length;
      if (mounted) {
        mostrarMensaje(context, n > 0
            ? 'Resultados subidos: se leyeron $n valores. El laboratorio los revisa y su médico los verá.'
            : 'PDF subido. No se pudieron leer valores automáticamente; el laboratorio los transcribirá.');
      }
      await _cargarDocs();
    } catch (e) {
      if (mounted) mostrarMensaje(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _subiendo = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.s;
    if (!_externo) {
      if (s['estado'] != 'REGISTRADA' || s['tipo'] == 'CONSULTA') return const SizedBox.shrink();
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          icon: const Icon(Icons.local_hospital_outlined),
          label: const Text('Prefiero hacerme los exámenes en otro laboratorio'),
          onPressed: _elegirLaboratorio,
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Exámenes en ${s['laboratorio']}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const Text('Se pagan en ese laboratorio. Cuando tenga los resultados, suba el PDF: el sistema lee los valores y su médico los verá.',
              style: TextStyle(color: Colors.grey, fontSize: 13)),
          const SizedBox(height: 10),
          FilledButton.icon(
            icon: const Icon(Icons.upload_file),
            label: Text(_subiendo ? 'Subiendo…' : 'Subir resultados (PDF)'),
            onPressed: _subiendo ? null : _subir,
          ),
          for (final d in _docs)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.picture_as_pdf),
              title: Text(d['nombre_archivo'] as String),
              subtitle: Text('${fechaHora(d['fecha'])} · ${(d['valores_leidos'] as List).length} valores leídos'),
              trailing: IconButton(
                tooltip: 'Ver PDF',
                icon: const Icon(Icons.open_in_new),
                onPressed: () => api.abrirPdf('/api/solicitudes/${s['solicitud_id']}/resultado-externo/${d['documento_id']}'),
              ),
            ),
        ]),
      ),
    );
  }
}
