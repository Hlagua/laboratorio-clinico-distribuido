import 'dart:async';

import 'package:flutter/material.dart';

import '../comun.dart';
import '../main.dart';

/// Página de retorno desde Stripe Checkout. La confirmación real llega por
/// webhook a la API; aquí se consulta el estado hasta que cambie.
class PagoResultado extends StatefulWidget {
  const PagoResultado({super.key, required this.parametros});
  final Map<String, String> parametros;

  @override
  State<PagoResultado> createState() => _PagoResultadoState();
}

class _PagoResultadoState extends State<PagoResultado> {
  String _estado = 'CONSULTANDO';
  Map<String, dynamic>? _pago;
  Timer? _temporizador;
  int _intentos = 0;

  bool get _exito => widget.parametros['estado'] == 'exito';

  @override
  void initState() {
    super.initState();
    if (_exito && sesion.autenticado) {
      _consultar();
      _temporizador = Timer.periodic(const Duration(seconds: 3), (_) => _consultar());
    } else {
      _estado = _exito ? 'SIN_SESION' : 'CANCELADO';
    }
  }

  Future<void> _consultar() async {
    _intentos++;
    try {
      final pagos = (await api.get('/api/pagos/mios') as List).cast<Map<String, dynamic>>();
      if (pagos.isNotEmpty) {
        final ultimo = pagos.first; // ordenados del más reciente al más antiguo
        setState(() {
          _pago = ultimo;
          _estado = ultimo['estado'] as String;
        });
        if (_estado != 'PENDIENTE' || _intentos >= 20) _temporizador?.cancel();
      }
    } catch (_) {
      if (_intentos >= 20) _temporizador?.cancel();
    }
  }

  @override
  void dispose() {
    _temporizador?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (icono, color, titulo, detalle) = switch (_estado) {
      'APROBADO' => (Icons.check_circle, verde, '¡Pago aprobado!',
          'Su pago de ${dinero(_pago?['monto'])} fue confirmado. Le enviamos un correo con el detalle.'),
      'RECHAZADO' => (Icons.cancel, rojo, 'Pago rechazado', '${_pago?['motivo_rechazo'] ?? ''}. Puede intentarlo de nuevo.'),
      'CANCELADO' => (Icons.info, ambar, 'Pago cancelado', 'No se realizó ningún cobro. Puede pagar más tarde desde "Mis exámenes".'),
      'SIN_SESION' => (Icons.info, ambar, 'Pago enviado', 'Inicie sesión para ver el estado de su pago.'),
      _ => (Icons.hourglass_top, ambar, 'Confirmando su pago…', 'Estamos esperando la confirmación de Stripe. No cierre esta página.'),
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Resultado del pago'), backgroundColor: verdeOscuro, foregroundColor: Colors.white),
      body: Centrado(
        ancho: 520,
        child: Card(
          margin: const EdgeInsets.all(24),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icono, size: 64, color: color),
              const SizedBox(height: 12),
              Text(titulo, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 8),
              Text(detalle, textAlign: TextAlign.center),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => Navigator.pushNamedAndRemoveUntil(context, sesion.autenticado ? '/panel' : '/ingresar', (_) => false),
                child: const Text('Ir a mi cuenta'),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
