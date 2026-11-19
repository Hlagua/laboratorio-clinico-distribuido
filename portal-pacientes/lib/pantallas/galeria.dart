import 'dart:async';

import 'package:flutter/material.dart';

import '../comun.dart';

/// Fotos del lado del ingreso, con un mensaje cada una. Rotan solas cada 6 s.
/// Fotos de uso libre de Unsplash (licencia Unsplash).
class _Foto {
  const _Foto(this.archivo, this.titulo, this.texto, this.icono);
  final String archivo;
  final String titulo;
  final String texto;
  final IconData icono;
}

const _fotos = [
  _Foto('assets/img/tubos.jpg', 'Sus exámenes, sin filas',
      'Reserve su turno, pague en línea y reciba sus resultados con indicadores claros: ↑ alto, ↓ bajo, – normal.', Icons.biotech),
  _Foto('assets/img/medico-paciente.jpg', 'Su médico, siempre al tanto',
      'Consulta, exámenes, receta y control en un solo lugar. Los resultados le llegan a usted y a su médico.', Icons.medical_services),
  _Foto('assets/img/microscopio.jpg', 'Resultados en los que puede confiar',
      'Informe en PDF, factura y receta en su correo y en el portal, disponibles cuando los necesite.', Icons.verified),
];

class Galeria extends StatefulWidget {
  const Galeria({super.key, this.compacta = false});

  /// En el celular la galería es una franja arriba del formulario.
  final bool compacta;

  @override
  State<Galeria> createState() => _GaleriaState();
}

class _GaleriaState extends State<Galeria> {
  int _actual = 0;
  Timer? _reloj;

  @override
  void initState() {
    super.initState();
    _reloj = Timer.periodic(const Duration(seconds: 6), (_) {
      if (mounted) setState(() => _actual = (_actual + 1) % _fotos.length);
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    for (final f in _fotos) {
      precacheImage(AssetImage(f.archivo), context);
    }
  }

  @override
  void dispose() {
    _reloj?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = _fotos[_actual];
    final compacta = widget.compacta;
    return Stack(fit: StackFit.expand, children: [
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 900),
        child: Image.asset(f.archivo, key: ValueKey(f.archivo), fit: BoxFit.cover, width: double.infinity, height: double.infinity),
      ),
      // Velo de color para que el texto se lea sobre cualquier foto.
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [verdeOscuro.withValues(alpha: .35), verdeOscuro.withValues(alpha: .88)],
          ),
        ),
      ),
      Padding(
        padding: EdgeInsets.all(compacta ? 20 : 48),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.local_hospital, color: verde, size: 22),
            ),
            const SizedBox(width: 10),
            const Text('Laboratorio Clínico', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
          ]),
          const Spacer(),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            child: Column(
              key: ValueKey(f.titulo),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!compacta) Icon(f.icono, color: Colors.white70, size: 34),
                if (!compacta) const SizedBox(height: 12),
                Text(f.titulo,
                    style: TextStyle(color: Colors.white, fontSize: compacta ? 22 : 38, fontWeight: FontWeight.w800, height: 1.1)),
                const SizedBox(height: 10),
                if (!compacta)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 460),
                    child: Text(f.texto, style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.45)),
                  ),
              ],
            ),
          ),
          SizedBox(height: compacta ? 12 : 28),
          Row(children: [
            for (var i = 0; i < _fotos.length; i++)
              GestureDetector(
                onTap: () => setState(() => _actual = i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  margin: const EdgeInsets.only(right: 6),
                  width: i == _actual ? 26 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: i == _actual ? Colors.white : Colors.white54,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            const Spacer(),
            if (!compacta) const Text('Fotos: Unsplash', style: TextStyle(color: Colors.white54, fontSize: 11)),
          ]),
        ]),
      ),
    ]);
  }
}
