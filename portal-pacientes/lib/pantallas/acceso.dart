import 'package:flutter/material.dart';

import '../comun.dart';
import '../main.dart';

/// Inicio de sesión y registro de pacientes.
class Acceso extends StatefulWidget {
  const Acceso({super.key, required this.registro});
  final bool registro;

  @override
  State<Acceso> createState() => _AccesoState();
}

class _AccesoState extends State<Acceso> {
  final _form = GlobalKey<FormState>();
  final _c = <String, TextEditingController>{
    for (final k in ['cedula', 'nombres', 'apellidos', 'telefono', 'email', 'password']) k: TextEditingController(),
  };
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
      if (!(usuario['roles'] as List).contains('PACIENTE')) {
        throw Exception('Su usuario no tiene perfil de paciente. El personal usa el sistema transaccional (/admin).');
      }
      sesion.iniciar(r['token'] as String, usuario);
      if (mounted) Navigator.pushNamedAndRemoveUntil(context, '/panel', (_) => false);
    } catch (e) {
      if (mounted) mostrarMensaje(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _enviando = false);
    }
  }

  String? _requerido(String? v) => (v == null || v.trim().isEmpty) ? 'Obligatorio' : null;

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
                    Text(reg ? 'Regístrese como paciente' : 'Bienvenido de nuevo', style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 16),
                    if (reg) ...[
                      TextFormField(controller: _c['cedula'], decoration: const InputDecoration(labelText: 'Cédula'),
                          keyboardType: TextInputType.number, validator: _cedula),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(child: TextFormField(controller: _c['nombres'], decoration: const InputDecoration(labelText: 'Nombres'), validator: _requerido)),
                        const SizedBox(width: 12),
                        Expanded(child: TextFormField(controller: _c['apellidos'], decoration: const InputDecoration(labelText: 'Apellidos'), validator: _requerido)),
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
                            DropdownMenuEntry(value: 'O', label: 'Otro'),
                          ],
                        ),
                      ]),
                      const SizedBox(height: 12),
                      TextFormField(controller: _c['telefono'], decoration: const InputDecoration(labelText: 'Teléfono (opcional)')),
                      const SizedBox(height: 12),
                    ],
                    TextFormField(
                      controller: _c['email'],
                      decoration: const InputDecoration(labelText: 'Correo electrónico'),
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      validator: (v) => (v ?? '').contains('@') ? null : 'Correo no válido',
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _c['password'],
                      decoration: InputDecoration(labelText: 'Contraseña', helperText: reg ? 'Mínimo 8 caracteres con letras y números' : null),
                      obscureText: true,
                      autofillHints: [reg ? AutofillHints.newPassword : AutofillHints.password],
                      validator: (v) => reg && ((v ?? '').length < 8) ? 'Mínimo 8 caracteres' : _requerido(v),
                      onFieldSubmitted: (_) => _enviar(),
                    ),
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
                      child: Text(reg ? '¿Ya tiene cuenta? Ingrese' : '¿No tiene cuenta? Regístrese'),
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
