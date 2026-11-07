import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

/// URL base de la API. En producción el portal y la API comparten dominio
/// (Nginx); en desarrollo se pasa con --dart-define=API=http://localhost:5000
const String _apiBase = String.fromEnvironment('API');

class ApiError implements Exception {
  ApiError(this.mensaje, [this.estado = 0, this.codigo]);
  final String mensaje;
  final int estado;
  final String? codigo;
  @override
  String toString() => mensaje;
}

/// Sesión del paciente: token JWT y datos básicos, guardados en sessionStorage.
class Sesion extends ChangeNotifier {
  static const _clave = 'portal-sesion';
  String? token;
  Map<String, dynamic>? usuario;

  /// true si la última respuesta vino de la réplica (Azure SQL no disponible).
  bool contingencia = false;

  Sesion() {
    final guardada = web.window.sessionStorage.getItem(_clave);
    if (guardada != null) {
      final d = jsonDecode(guardada) as Map<String, dynamic>;
      token = d['token'] as String?;
      usuario = d['usuario'] as Map<String, dynamic>?;
    }
  }

  bool get autenticado => token != null;
  String get nombre => (usuario?['nombre'] as String?) ?? '';

  void iniciar(String t, Map<String, dynamic> u) {
    token = t;
    usuario = u;
    web.window.sessionStorage.setItem(_clave, jsonEncode({'token': t, 'usuario': u}));
    notifyListeners();
  }

  void cerrar() {
    token = null;
    usuario = null;
    web.window.sessionStorage.removeItem(_clave);
    notifyListeners();
  }

  void marcarOrigen(String? origen) {
    final c = origen == 'supabase';
    if (c != contingencia) {
      contingencia = c;
      notifyListeners();
    }
  }
}

/// Cliente REST de la plataforma. El portal siempre actúa con el rol PACIENTE.
class Api {
  Api(this.sesion);
  final Sesion sesion;

  Uri _uri(String ruta, [Map<String, String>? params]) {
    final base = _apiBase.isEmpty ? Uri.base.origin : _apiBase;
    return Uri.parse('$base$ruta').replace(queryParameters: params);
  }

  Map<String, String> get _cabeceras => {
        'Content-Type': 'application/json',
        if (sesion.token != null) 'Authorization': 'Bearer ${sesion.token}',
        if (sesion.token != null) 'X-Rol-Activo': 'PACIENTE',
      };

  Future<dynamic> get(String ruta, [Map<String, String>? params]) =>
      _procesar(http.get(_uri(ruta, params), headers: _cabeceras));

  Future<dynamic> post(String ruta, [Object? cuerpo]) =>
      _procesar(http.post(_uri(ruta), headers: _cabeceras, body: jsonEncode(cuerpo ?? {})));

  Future<dynamic> delete(String ruta) => _procesar(http.delete(_uri(ruta), headers: _cabeceras));

  Future<dynamic> _procesar(Future<http.Response> peticion) async {
    late http.Response r;
    try {
      r = await peticion;
    } catch (_) {
      throw ApiError('No hay conexión con el servidor. Intente de nuevo.');
    }
    sesion.marcarOrigen(r.headers['x-origen-datos']);
    final cuerpo = r.body.isEmpty ? null : jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode >= 400) {
      final d = cuerpo is Map ? cuerpo : const {};
      if (r.statusCode == 503 && d['codigo'] == 'MODO_CONTINGENCIA') sesion.marcarOrigen('supabase');
      if (r.statusCode == 401 && sesion.autenticado) sesion.cerrar();
      throw ApiError((d['error'] as String?) ?? 'Error ${r.statusCode}', r.statusCode, d['codigo'] as String?);
    }
    return cuerpo;
  }

  /// Descarga el PDF de resultados con el token y lo abre en otra pestaña.
  Future<void> abrirPdf(String ruta) async {
    final r = await http.get(_uri(ruta), headers: _cabeceras);
    if (r.statusCode != 200) {
      final d = jsonDecode(utf8.decode(r.bodyBytes));
      throw ApiError((d['error'] as String?) ?? 'No se pudo generar el PDF', r.statusCode);
    }
    final blob = web.Blob([Uint8List.fromList(r.bodyBytes).toJS].toJS, web.BlobPropertyBag(type: 'application/pdf'));
    web.window.open(web.URL.createObjectURL(blob), '_blank');
  }

  /// Redirige el navegador (Stripe Checkout).
  void irA(String url) => web.window.location.href = url;
}
