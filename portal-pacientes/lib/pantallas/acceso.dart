import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
import '../comun.dart';
import '../main.dart';

/// Login único de la plataforma y registro de pacientes.
///
/// Todos ingresan aquí. Según el rol se va al portal del paciente o al sistema
/// del personal (/admin); con varios roles se pregunta con cuál entrar.
/// Solo los pacientes pueden crear su cuenta: al personal lo crea el administrador.
class Acceso extends StatefulWidget {
  const Acceso({super.key, required this.registro});
  final bool registro;

  @override
  State<Acceso> createState() => _AccesoState();
}

class _AccesoState extends State<Acceso> {
  final _form = GlobalKey<FormState>();
  final _c = <String, TextEditingController>{
    for (final k in ['cedula', 'nombres', 'apellidos', 'telefono', 'email', 'password', 'confirmar']) k: TextEditingController(),
  };
  bool _verClave = false;
  bool _verConfirmacion = false;

  // Controles de escritura: solo dígitos en cédula y teléfono; solo letras (con tildes) y espacios en los nombres.
  static final _soloDigitos = FilteringTextInputFormatter.digitsOnly;
  static final _soloLetras = FilteringTextInputFormatter.allow(RegExp(r"[A-Za-zÁÉÍÓÚÜÑáéíóúüñ' ]"));
  // Sin espacio al inicio ni dos espacios seguidos.
  static final _unEspacio = TextInputFormatter.withFunction((anterior, nuevo) {
    final limpio = nuevo.text.replaceFirst(RegExp(r'^\s+'), '').replaceAll(RegExp(r'\s{2,}'), ' ');
    return limpio == nuevo.text
        ? nuevo
        : TextEditingValue(text: limpio, selection: TextSelection.collapsed(offset: limpio.length));
  });
  DateTime? _nacimiento;
  String _sexo = 'F';
  bool _enviando = false;

  Future<void> _enviar() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _enviando = true);
    try {
      final email = _c['email']!.text.trim().toLowerCase();
      if (widget.registro) {
        await api.post('/api/auth/registro', {
          'cedula': _c['cedula']!.text.trim(),
          'nombres': _c['nombres']!.text.trim(),
          'apellidos': _c['apellidos']!.text.trim(),
          'fecha_nacimiento': _nacimiento!.toIso8601String().substring(0, 10),
          'sexo': _sexo,
          'telefono': _c['telefono']!.text.trim(),
          'email': email,
          'password': _c['password']!.text,
        });
      }
      final r = await api.post('/api/auth/login', {'email': email, 'password': _c['password']!.text}) as Map<String, dynamic>;
      final usuario = r['usuario'] as Map<String, dynamic>;
      final roles = (usuario['roles'] as List).cast<String>()
          .where((x) => x == 'PACIENTE' || Sesion.rolesPersonal.contains(x)).toList();
      if (!mounted) return;
      final rol = await elegirRol(context, roles);
      if (rol == null) return; // cerró el diálogo sin elegir
      if (rol == 'PACIENTE') {
        sesion.iniciar(r['token'] as String, usuario);
        if (mounted) Navigator.pushNamedAndRemoveUntil(context, '/panel', (_) => false);
      } else {
        sesion.irAlPersonal(r['token'] as String, usuario, rol);
      }
    } catch (e) {
      if (mounted) mostrarMensaje(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  String? _requerido(String? v) => (v == null || v.trim().isEmpty) ? 'Obligatorio' : null;

  /// Misma regla que la API: al menos 8 caracteres, con letras y números.
  String? _clave(String? v) {
    final c = v ?? '';
    if (c.length < 8) return 'Mínimo 8 caracteres';
    if (!RegExp(r'[A-Za-zÁÉÍÓÚÑáéíóúñ]').hasMatch(c) || !RegExp(r'\d').hasMatch(c)) return 'Use letras y números';
    return null;
  }

  String? _cedula(String? v) {
    final c = (v ?? '').trim();
    if (!RegExp(r'^\d{10}$').hasMatch(c)) return 'La cédula tiene 10 dígitos';
    final coef = [2, 1, 2, 1, 2, 1, 2, 1, 2];
    var suma = 0;
    for (var i = 0; i < 9; i++) {
      var p = int.parse(c[i]) * coef[i];
      if (p > 9) p -= 9;
      suma += p;
    }
    return (10 - suma % 10) % 10 == int.parse(c[9]) ? null : 'Cédula no válida';
  }

  @override
  Widget build(BuildContext context) {
    final reg = widget.registro;
    return Scaffold(
      appBar: AppBar(title: Text(reg ? 'Crear cuenta' : 'Ingresar'), backgroundColor: verdeOscuro, foregroundColor: Colors.white),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Centrado(
          ancho: 520,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Form(
                key: _form,
                child: AutofillGroup(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(reg ? 'Regístrese como paciente' : 'Bienvenido', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 4),
                    Text(
                      reg
                          ? 'Las cuentas de médicos, laboratoristas y administradores las crea el administrador del laboratorio.'
                          : 'Un solo acceso para pacientes y personal del laboratorio. Si tiene varios roles, elegirá con cuál entrar.',
                      style: const TextStyle(color: Colors.grey, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    if (reg) ...[
                      TextFormField(
                          controller: _c['cedula'],
                          decoration: const InputDecoration(labelText: 'Cédula', counterText: ''),
                          keyboardType: TextInputType.number,
                          inputFormatters: [_soloDigitos, LengthLimitingTextInputFormatter(10)],
                          maxLength: 10,
                          validator: _cedula),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(
                            child: TextFormField(
                                controller: _c['nombres'],
                                decoration: const InputDecoration(labelText: 'Nombres', counterText: ''),
                                inputFormatters: [_soloLetras, _unEspacio, LengthLimitingTextInputFormatter(50)],
                                maxLength: 50,
                                textCapitalization: TextCapitalization.words,
                                validator: _requerido)),
                        const SizedBox(width: 12),
                        Expanded(
                            child: TextFormField(
                                controller: _c['apellidos'],
                                decoration: const InputDecoration(labelText: 'Apellidos', counterText: ''),
                                inputFormatters: [_soloLetras, _unEspacio, LengthLimitingTextInputFormatter(50)],
                                maxLength: 50,
                                textCapitalization: TextCapitalization.words,
                                validator: _requerido)),
                      ]),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(
                          child: FormField<DateTime>(
                            validator: (_) => _nacimiento == null ? 'Obligatorio' : null,
                            builder: (estado) => InkWell(
                              onTap: () async {
                                final d = await showDatePicker(
                                  context: context, initialDate: DateTime(1995), firstDate: DateTime(1900), lastDate: DateTime.now());
                                if (d != null) setState(() => _nacimiento = d);
                              },
                              child: InputDecorator(
                                decoration: InputDecoration(labelText: 'Fecha de nacimiento', errorText: estado.errorText),
                                child: Text(_nacimiento == null ? 'Seleccionar' : _nacimiento!.toIso8601String().substring(0, 10)),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        DropdownMenu<String>(
                          initialSelection: _sexo,
                          label: const Text('Sexo'),
                          onSelected: (v) => _sexo = v ?? 'F',
                          dropdownMenuEntries: const [
                            DropdownMenuEntry(value: 'F', label: 'Femenino'),
                            DropdownMenuEntry(value: 'M', label: 'Masculino'),
                            DropdownMenuEntry(value: 'O', label: 'Sin especificar'),
                          ],
                        ),
                      ]),
                      const SizedBox(height: 12),
                      TextFormField(
                          controller: _c['telefono'],
                          decoration: const InputDecoration(labelText: 'Teléfono (opcional)', hintText: '0991234567', counterText: ''),
                          keyboardType: TextInputType.phone,
                          inputFormatters: [_soloDigitos, LengthLimitingTextInputFormatter(10)],
                          maxLength: 10,
                          validator: (v) => (v ?? '').isEmpty || RegExp(r'^0\d{8,9}$').hasMatch(v!)
                              ? null
                              : 'Entre 9 y 10 dígitos, empezando con 0'),
                      const SizedBox(height: 12),
                    ],
                    TextFormField(
                      controller: _c['email'],
                      decoration: const InputDecoration(labelText: 'Correo electrónico'),
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s')), LengthLimitingTextInputFormatter(150)],
                      validator: (v) => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v ?? '') ? null : 'Correo no válido',
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _c['password'],
                      decoration: InputDecoration(
                        labelText: 'Contraseña',
                        helperText: reg ? 'Mínimo 8 caracteres con letras y números' : null,
                        suffixIcon: IconButton(
                          tooltip: _verClave ? 'Ocultar contraseña' : 'Ver contraseña',
                          icon: Icon(_verClave ? Icons.visibility_off : Icons.visibility),
                          onPressed: () => setState(() => _verClave = !_verClave),
                        ),
                      ),
                      obscureText: !_verClave,
                      inputFormatters: [LengthLimitingTextInputFormatter(72)],
                      autofillHints: [reg ? AutofillHints.newPassword : AutofillHints.password],
                      validator: (v) => reg ? _clave(v) : _requerido(v),
                      onFieldSubmitted: (_) => reg ? null : _enviar(),
                    ),
                    if (reg) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _c['confirmar'],
                        decoration: InputDecoration(
                          labelText: 'Repita la contraseña',
                          suffixIcon: IconButton(
                            tooltip: _verConfirmacion ? 'Ocultar contraseña' : 'Ver contraseña',
                            icon: Icon(_verConfirmacion ? Icons.visibility_off : Icons.visibility),
                            onPressed: () => setState(() => _verConfirmacion = !_verConfirmacion),
                          ),
                        ),
                        obscureText: !_verConfirmacion,
                        inputFormatters: [LengthLimitingTextInputFormatter(72)],
                        autofillHints: const [AutofillHints.newPassword],
                        validator: (v) => v == _c['password']!.text ? null : 'Las contraseñas no coinciden',
                        onFieldSubmitted: (_) => _enviar(),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _enviando ? null : _enviar,
                      child: Padding(
                        padding: const EdgeInsets.all(10),
                        child: Text(_enviando ? 'Un momento…' : (reg ? 'Crear cuenta' : 'Ingresar')),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pushReplacementNamed(context, reg ? '/ingresar' : '/registro'),
                      child: Text(reg ? '¿Ya tiene cuenta? Ingrese' : '¿Es paciente y no tiene cuenta? Regístrese'),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
