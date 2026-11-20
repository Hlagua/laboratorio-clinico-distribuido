import 'dart:async';

import 'package:flutter/material.dart';

import '../comun.dart';
import '../main.dart';
import 'turnos.dart';

/// Página pública: carrusel de fotos, servicios, cómo funciona, catálogo de exámenes y datos de atención.
/// Fotos de uso libre de Unsplash (licencia Unsplash).
class Inicio extends StatefulWidget {
  const Inicio({super.key});

  @override
  State<Inicio> createState() => _InicioState();
}

class _Diapositiva {
  const _Diapositiva(this.foto, this.titulo, this.texto);
  final String foto;
  final String titulo;
  final String texto;
}

const _diapositivas = [
  _Diapositiva('assets/img/tubos.jpg', 'Sus exámenes, sin filas',
      'Reserve su turno, pague en línea y reciba los resultados en su correo y en el portal.'),
  _Diapositiva('assets/img/medico-paciente.jpg', 'Consulta con su médico',
      'El médico revisa su caso, le ordena los exámenes que necesita y le agenda el control.'),
  _Diapositiva('assets/img/microscopio.jpg', 'Resultados claros y confiables',
      'Cada valor con su rango de referencia e indicador: ↑ alto, ↓ bajo, – normal.'),
];

class _InicioState extends State<Inicio> {
  late Future<List<dynamic>> _catalogo = _cargar();
  final _servicios = GlobalKey();
  final _pasos = GlobalKey();
  final _examenes = GlobalKey();
  String _buscar = '';
  String? _categoria;

  Future<List<dynamic>> _cargar() async => await api.get('/api/examenes/catalogo') as List<dynamic>;

  void _ir(GlobalKey k) =>
      Scrollable.ensureVisible(k.currentContext!, duration: const Duration(milliseconds: 500), curve: Curves.easeInOut);

  void _empezar() => Navigator.pushNamed(context, sesion.autenticado ? '/panel' : '/registro');

  @override
  Widget build(BuildContext context) {
    final ancho = MediaQuery.sizeOf(context).width;
    final escritorio = ancho >= 900;
    final celular = ancho < 600;
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7F6),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 1,
        shadowColor: Colors.black12,
        toolbarHeight: 64,
        titleSpacing: 16,
        title: _Logo(compacto: celular),
        actions: [
          if (escritorio) ...[
            TextButton(onPressed: () => _ir(_servicios), child: const Text('Servicios')),
            TextButton(onPressed: () => _ir(_pasos), child: const Text('Cómo funciona')),
            TextButton(onPressed: () => _ir(_examenes), child: const Text('Exámenes')),
            const SizedBox(width: 12),
          ],
          if (sesion.autenticado)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: FilledButton.icon(
                onPressed: () => Navigator.pushNamed(context, '/panel'),
                icon: const Icon(Icons.person),
                label: const Text('Mi cuenta'),
              ),
            )
          else if (celular)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(onPressed: () => Navigator.pushNamed(context, '/ingresar'), child: const Text('Ingresar')),
            )
          else ...[
            TextButton(onPressed: () => Navigator.pushNamed(context, '/ingresar'), child: const Text('Ingresar')),
            Padding(
              padding: const EdgeInsets.only(right: 16, left: 4),
              child: FilledButton(onPressed: () => Navigator.pushNamed(context, '/registro'), child: const Text('Crear cuenta')),
            ),
          ],
        ],
      ),
      body: ListaConSubir(children: [
        const AvisoContingencia(),
        Padding(
          padding: EdgeInsets.fromLTRB(escritorio ? 40 : 12, 20, escritorio ? 40 : 12, 0),
          child: _Carrusel(alto: escritorio ? 460 : 340, alEmpezar: _empezar, alResultados: () {
            Navigator.pushNamed(context, sesion.autenticado ? '/panel' : '/ingresar');
          }),
        ),
        _seccion(
          clave: _servicios,
          titulo: 'Nuestros servicios',
          subtitulo: 'Todo lo que necesita para cuidar su salud, en un solo lugar.',
          hijo: Wrap(spacing: 20, runSpacing: 20, alignment: WrapAlignment.center, children: [
            _Servicio(foto: 'assets/img/medico-paciente.jpg', icono: Icons.medical_services, titulo: 'Consulta médica',
                texto: 'Elija médico y horario. Si no sabe qué exámenes necesita, empiece aquí.', alTocar: _empezar),
            _Servicio(foto: 'assets/img/tubos.jpg', icono: Icons.biotech, titulo: 'Toma de muestras',
                texto: 'Reserve su turno en el laboratorio y pague en línea antes de venir.', alTocar: _empezar),
            _Servicio(foto: 'assets/img/microscopio.jpg', icono: Icons.description, titulo: 'Resultados, receta y factura',
                texto: 'En su correo y en el portal: resultados en PDF, receta de su médico y factura electrónica.',
                alTocar: () => Navigator.pushNamed(context, sesion.autenticado ? '/panel' : '/ingresar')),
          ]),
        ),
        Container(
          key: _pasos,
          color: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
          child: Centrado(
            ancho: 1100,
            child: Column(children: [
              _titulo('Cómo funciona', 'Cuatro pasos, sin filas ni papeles.'),
              const SizedBox(height: 28),
              Wrap(spacing: 24, runSpacing: 24, alignment: WrapAlignment.center, children: const [
                _Paso(n: 1, icono: Icons.event_available, titulo: 'Reserve', texto: 'Una consulta con su médico o un turno de toma de muestras.'),
                _Paso(n: 2, icono: Icons.credit_card, titulo: 'Pague en línea', texto: 'Con tarjeta, de forma segura. Vea el resumen con IVA antes de pagar.'),
                _Paso(n: 3, icono: Icons.bloodtype, titulo: 'Acuda a su cita', texto: 'Llegue a su hora; si el examen lo pide, en ayunas.'),
                _Paso(n: 4, icono: Icons.mark_email_read, titulo: 'Reciba sus resultados', texto: 'Le llegan por correo y su médico los revisa.'),
              ]),
            ]),
          ),
        ),
        _seccion(
          clave: _examenes,
          titulo: 'Exámenes disponibles',
          subtitulo: 'Precios con IVA incluido. Busque por nombre o filtre por área.',
          hijo: Cargando<List<dynamic>>(
            futuro: _catalogo,
            reintentar: () => setState(() => _catalogo = _cargar()),
            constructor: (lista) => _catalogoVista(lista.cast<Map<String, dynamic>>()),
          ),
        ),
        Container(
          color: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
          child: Centrado(
            ancho: 1100,
            child: Wrap(spacing: 40, runSpacing: 20, alignment: WrapAlignment.spaceAround, children: const [
              _Dato(icono: Icons.schedule, titulo: 'Horario', texto: 'Lunes a sábado\n07:00 a 11:00 toma de muestras'),
              _Dato(icono: Icons.place, titulo: 'Dónde estamos', texto: 'Av. Los Chasquis y Río Payamino\nAmbato, Tungurahua'),
              _Dato(icono: Icons.verified_user, titulo: 'Sus datos, protegidos', texto: 'Resultados y recetas solo para\nusted y su médico'),
            ]),
          ),
        ),
        Container(
          color: verdeOscuro,
          padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 16),
          child: const Centrado(
            ancho: 1100,
            child: Wrap(spacing: 20, runSpacing: 8, alignment: WrapAlignment.spaceBetween, children: [
              Text('Laboratorio Clínico · Proyecto académico, Universidad Técnica de Ambato',
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
              Text('Fotos: Unsplash', style: TextStyle(color: Colors.white38, fontSize: 12)),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _titulo(String titulo, String subtitulo) => Column(children: [
        Text(titulo,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: verdeOscuro)),
        const SizedBox(height: 6),
        Text(subtitulo, textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54, fontSize: 15)),
      ]);

  Widget _seccion({required GlobalKey clave, required String titulo, required String subtitulo, required Widget hijo}) => Padding(
        key: clave,
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
        child: Centrado(ancho: 1100, child: Column(children: [_titulo(titulo, subtitulo), const SizedBox(height: 28), hijo])),
      );

  Widget _catalogoVista(List<Map<String, dynamic>> tipos) {
    final categorias = {for (final t in tipos) t['categoria'] as String}.toList()..sort();
    final q = _buscar.trim().toLowerCase();
    final visibles = tipos
        .where((t) => (_categoria == null || t['categoria'] == _categoria) && (q.isEmpty || '${t['nombre']} ${t['categoria']}'.toLowerCase().contains(q)))
        .toList();
    return Column(children: [
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: TextField(
          inputFormatters: [sinEmojis],
          decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search), hintText: 'Buscar examen', filled: true, fillColor: Colors.white),
          onChanged: (v) => setState(() => _buscar = v),
        ),
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
        ChoiceChip(label: const Text('Todos'), selected: _categoria == null, onSelected: (_) => setState(() => _categoria = null)),
        for (final c in categorias)
          ChoiceChip(label: Text(c), selected: _categoria == c, onSelected: (_) => setState(() => _categoria = c)),
      ]),
      const SizedBox(height: 20),
      if (visibles.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Ningún examen coincide con la búsqueda.')),
      Wrap(spacing: 16, runSpacing: 16, alignment: WrapAlignment.center, children: [
        for (final t in visibles) _TarjetaExamen(t, alPedir: _empezar),
      ]),
    ]);
  }
}

class _Logo extends StatelessWidget {
  const _Logo({this.compacto = false});
  final bool compacto;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(color: verde, borderRadius: BorderRadius.circular(10)),
          child: const Icon(Icons.local_hospital, color: Colors.white, size: 22),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text('Laboratorio Clínico',
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: verdeOscuro, fontWeight: FontWeight.w800, fontSize: compacto ? 16 : 19)),
        ),
      ]);
}

/// Carrusel principal: foto a todo lo ancho con su mensaje; cambia cada 6 s o con las flechas.
class _Carrusel extends StatefulWidget {
  const _Carrusel({required this.alto, required this.alEmpezar, required this.alResultados});
  final double alto;
  final VoidCallback alEmpezar;
  final VoidCallback alResultados;

  @override
  State<_Carrusel> createState() => _CarruselState();
}

class _CarruselState extends State<_Carrusel> {
  int _i = 0;
  Timer? _reloj;

  @override
  void initState() {
    super.initState();
    _reiniciar();
  }

  void _reiniciar() {
    _reloj?.cancel();
    _reloj = Timer.periodic(const Duration(seconds: 6), (_) => _mover(1, manual: false));
  }

  void _mover(int paso, {bool manual = true}) {
    if (!mounted) return;
    setState(() => _i = (_i + paso + _diapositivas.length) % _diapositivas.length);
    if (manual) _reiniciar();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    for (final d in _diapositivas) {
      precacheImage(AssetImage(d.foto), context);
    }
  }

  @override
  void dispose() {
    _reloj?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = _diapositivas[_i];
    final angosto = MediaQuery.sizeOf(context).width < 700;
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: SizedBox(
        height: widget.alto,
        child: Stack(fit: StackFit.expand, children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 900),
            child: Image.asset(d.foto, key: ValueKey(d.foto), fit: BoxFit.cover, width: double.infinity, height: double.infinity),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [verdeOscuro.withValues(alpha: .92), verdeOscuro.withValues(alpha: .55), Colors.transparent],
                stops: const [0, .5, 1],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: angosto ? 22 : 72, vertical: 24),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 500),
                  child: Column(
                    key: ValueKey(d.titulo),
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(d.titulo,
                          style: TextStyle(color: Colors.white, fontSize: angosto ? 30 : 48, fontWeight: FontWeight.w800, height: 1.05)),
                      const SizedBox(height: 14),
                      Text(d.texto, style: TextStyle(color: Colors.white, fontSize: angosto ? 15 : 18, height: 1.4)),
                      const SizedBox(height: 24),
                      Wrap(spacing: 12, runSpacing: 10, children: [
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                              backgroundColor: Colors.white, foregroundColor: verdeOscuro, padding: const EdgeInsets.all(18)),
                          onPressed: widget.alEmpezar,
                          icon: const Icon(Icons.event_available),
                          label: const Text('Reservar una cita'),
                        ),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white, side: const BorderSide(color: Colors.white70), padding: const EdgeInsets.all(18)),
                          onPressed: widget.alResultados,
                          icon: const Icon(Icons.science_outlined),
                          label: const Text('Ver mis resultados'),
                        ),
                      ]),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (!angosto) ...[
            Align(alignment: Alignment.centerLeft, child: _Flecha(icono: Icons.chevron_left, alTocar: () => _mover(-1))),
            Align(alignment: Alignment.centerRight, child: _Flecha(icono: Icons.chevron_right, alTocar: () => _mover(1))),
          ],
          Positioned(
            bottom: 16,
            left: 0,
            right: 0,
            child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var k = 0; k < _diapositivas.length; k++)
                GestureDetector(
                  onTap: () => _mover(k - _i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    width: k == _i ? 26 : 9,
                    height: 9,
                    decoration: BoxDecoration(color: k == _i ? Colors.white : Colors.white54, borderRadius: BorderRadius.circular(5)),
                  ),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _Flecha extends StatelessWidget {
  const _Flecha({required this.icono, required this.alTocar});
  final IconData icono;
  final VoidCallback alTocar;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: IconButton.outlined(
          style: IconButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white70)),
          onPressed: alTocar,
          icon: Icon(icono, size: 28),
        ),
      );
}

class _Servicio extends StatelessWidget {
  const _Servicio({required this.foto, required this.icono, required this.titulo, required this.texto, required this.alTocar});
  final String foto;
  final IconData icono;
  final String titulo;
  final String texto;
  final VoidCallback alTocar;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 340,
        child: Card(
          elevation: 0,
          clipBehavior: Clip.antiAlias,
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: Colors.grey.shade300)),
          child: InkWell(
            onTap: alTocar,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(height: 170, width: double.infinity, child: Image.asset(foto, fit: BoxFit.cover)),
              Padding(
                padding: const EdgeInsets.all(18),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    CircleAvatar(radius: 18, backgroundColor: verde.withValues(alpha: .12), child: Icon(icono, color: verde, size: 20)),
                    const SizedBox(width: 10),
                    Expanded(child: Text(titulo, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
                  ]),
                  const SizedBox(height: 10),
                  Text(texto, style: const TextStyle(color: Colors.black87, height: 1.4)),
                  const SizedBox(height: 10),
                  const Row(children: [
                    Text('Empezar', style: TextStyle(color: verde, fontWeight: FontWeight.w600)),
                    Icon(Icons.arrow_forward, color: verde, size: 18),
                  ]),
                ]),
              ),
            ]),
          ),
        ),
      );
}

class _Paso extends StatelessWidget {
  const _Paso({required this.n, required this.icono, required this.titulo, required this.texto});
  final int n;
  final IconData icono;
  final String titulo;
  final String texto;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 230,
        child: Column(children: [
          Stack(clipBehavior: Clip.none, children: [
            CircleAvatar(radius: 34, backgroundColor: verde.withValues(alpha: .1), child: Icon(icono, color: verde, size: 30)),
            Positioned(
              right: -4,
              top: -4,
              child: CircleAvatar(
                  radius: 12, backgroundColor: verde, child: Text('$n', style: const TextStyle(color: Colors.white, fontSize: 12))),
            ),
          ]),
          const SizedBox(height: 12),
          Text(titulo, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
          const SizedBox(height: 6),
          Text(texto, textAlign: TextAlign.center, style: const TextStyle(color: Colors.black54, height: 1.4)),
        ]),
      );
}

class _Dato extends StatelessWidget {
  const _Dato({required this.icono, required this.titulo, required this.texto});
  final IconData icono;
  final String titulo;
  final String texto;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icono, color: verde, size: 28),
        const SizedBox(width: 12),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(titulo, style: const TextStyle(fontWeight: FontWeight.w700)),
          Text(texto, style: const TextStyle(color: Colors.black54, height: 1.4)),
        ]),
      ]);
}

/// Ícono por área del catálogo, para reconocer el tipo de examen de un vistazo.
IconData _iconoArea(String categoria) {
  final c = categoria.toLowerCase();
  if (c.contains('hemat')) return Icons.bloodtype;
  if (c.contains('inmuno')) return Icons.shield_outlined;
  if (c.contains('uro') || c.contains('orina')) return Icons.water_drop_outlined;
  if (c.contains('química') || c.contains('quimica')) return Icons.science_outlined;
  return Icons.biotech;
}

class _TarjetaExamen extends StatelessWidget {
  const _TarjetaExamen(this.t, {required this.alPedir});
  final Map<String, dynamic> t;
  final VoidCallback alPedir;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 340,
        child: Card(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: BorderSide(color: Colors.grey.shade300)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: verde.withValues(alpha: .1),
                child: Icon(_iconoArea(t['categoria'] as String), color: verde),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t['categoria'] as String, style: const TextStyle(color: Colors.grey, fontSize: 12)),
                  Text(t['nombre'] as String, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    _Pastilla(Icons.schedule, 'Resultados en ${t['tiempo_entrega_horas']} h'),
                    _Pastilla(Icons.colorize, '${t['tipo_muestra']}'),
                    if (t['requiere_ayuno'] == true) const _Pastilla(Icons.no_food, 'Ayuno', aviso: true),
                  ]),
                  if (t['indicaciones'] != null) ...[
                    const SizedBox(height: 6),
                    Text(t['indicaciones'] as String, style: const TextStyle(fontSize: 13, color: Colors.black54)),
                  ],
                  const SizedBox(height: 8),
                  Row(children: [
                    Text(dinero(t['precio']), style: const TextStyle(color: verde, fontWeight: FontWeight.w800, fontSize: 18)),
                    const Spacer(),
                    TextButton(onPressed: alPedir, child: const Text('Solicitar')),
                  ]),
                ]),
              ),
            ]),
          ),
        ),
      );
}

class _Pastilla extends StatelessWidget {
  const _Pastilla(this.icono, this.texto, {this.aviso = false});
  final IconData icono;
  final String texto;
  final bool aviso;

  @override
  Widget build(BuildContext context) {
    final color = aviso ? ambar : Colors.black54;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: .08), borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icono, size: 13, color: color),
        const SizedBox(width: 4),
        Text(texto, style: TextStyle(fontSize: 12, color: color)),
      ]),
    );
  }
}
