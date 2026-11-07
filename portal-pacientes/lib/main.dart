import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'api.dart';
import 'comun.dart';
import 'pantallas/acceso.dart';
import 'pantallas/inicio.dart';
import 'pantallas/pago_resultado.dart';
import 'pantallas/panel.dart';

final sesion = Sesion();
final api = Api(sesion);

void main() {
  // URLs limpias (/pagos/resultado) para que Stripe pueda volver al portal.
  usePathUrlStrategy();
  runApp(const PortalPacientes());
}

class PortalPacientes extends StatelessWidget {
  const PortalPacientes({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Laboratorio Clínico · Portal de pacientes',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: verde, primary: verde),
        scaffoldBackgroundColor: const Color(0xFFF4F7F6),
        cardTheme: const CardThemeData(elevation: 0.5, margin: EdgeInsets.symmetric(vertical: 6)),
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), isDense: true),
      ),
      onGenerateRoute: (ajustes) {
        final uri = Uri.parse(ajustes.name ?? '/');
        final Widget pantalla = switch (uri.path) {
          '/ingresar' => const Acceso(registro: false),
          '/registro' => const Acceso(registro: true),
          '/panel' => sesion.autenticado ? const Panel() : const Acceso(registro: false),
          '/pagos/resultado' => PagoResultado(parametros: uri.queryParameters),
          _ => const Inicio(),
        };
        return MaterialPageRoute(builder: (_) => pantalla, settings: ajustes);
      },
    );
  }
}

/// Aviso que aparece cuando la API responde desde la base de contingencia.
class AvisoContingencia extends StatelessWidget {
  const AvisoContingencia({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: sesion,
        builder: (_, _) => sesion.contingencia
            ? Container(
                width: double.infinity,
                color: const Color(0xFFFFF4D6),
                padding: const EdgeInsets.all(10),
                child: const Text(
                  '⚠ Estamos en modo de contingencia: puede consultar sus resultados, '
                  'pero las reservas y los pagos están deshabilitados temporalmente.',
                  style: TextStyle(color: ambar, fontWeight: FontWeight.w600),
                ),
              )
            : const SizedBox.shrink(),
      );
}
