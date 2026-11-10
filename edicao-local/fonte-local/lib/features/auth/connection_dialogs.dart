import 'package:flutter/material.dart';
import '../../app/app_theme.dart';
import 'user_model.dart';

/// Controllers belong to the dialog route and stay alive for its exit animation.
class ServerAddressDialog extends StatefulWidget {
  const ServerAddressDialog({super.key, required this.initialAddress});
  final String initialAddress;
  @override
  State<ServerAddressDialog> createState() => _ServerAddressDialogState();
}

class _ServerAddressDialogState extends State<ServerAddressDialog> {
  late final _address = TextEditingController(text: widget.initialAddress);
  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Conectar ao PC gestor'),
        content: SizedBox(
            width: AppTheme.dialogWidth(context, maxWidth: 440),
            child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text(
                  'No emulador Android deste PC, use http://10.0.2.2:8766 para o piloto v2. O servidor anterior usa a porta 8765. No celular físico, use o endereço HTTPS privado do PC gestor.'),
              const SizedBox(height: 12),
              TextField(
                  controller: _address,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                      labelText: 'URL privada do servidor',
                      hintText: 'http://10.0.2.2:8766')),
            ]))),
        actions: [
          TextButton(
              onPressed: () {
                FocusScope.of(context).unfocus();
                Navigator.pop(context);
              },
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () {
                FocusScope.of(context).unfocus();
                Navigator.pop(context, _address.text);
              },
              child: const Text('Salvar endereço'))
        ],
      );
}

typedef InvitationDetails = ({
  String name,
  String email,
  String code,
  String password
});

class AcceptInvitationDialog extends StatefulWidget {
  const AcceptInvitationDialog({super.key, required this.initialEmail});
  final String initialEmail;
  @override
  State<AcceptInvitationDialog> createState() => _AcceptInvitationDialogState();
}

class _AcceptInvitationDialogState extends State<AcceptInvitationDialog> {
  final _name = TextEditingController(),
      _code = TextEditingController(),
      _password = TextEditingController();
  late final _email = TextEditingController(text: widget.initialEmail);
  @override
  void dispose() {
    for (final c in [_name, _email, _code, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Ativar convite da fazenda'),
        content: SizedBox(
            width: AppTheme.dialogWidth(context, maxWidth: 440),
            child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Seu nome')),
              TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration:
                      const InputDecoration(labelText: 'E-mail do convite')),
              TextField(
                  controller: _code,
                  decoration:
                      const InputDecoration(labelText: 'Código de convite')),
              TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'Crie uma senha (mínimo 12 caracteres)')),
            ]))),
        actions: [
          TextButton(
              onPressed: () {
                FocusScope.of(context).unfocus();
                Navigator.pop(context);
              },
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () {
                final InvitationDetails details = (
                  name: _name.text,
                  email: _email.text,
                  code: _code.text,
                  password: _password.text
                );
                FocusScope.of(context).unfocus();
                Navigator.pop(context, details);
              },
              child: const Text('Ativar conta'))
        ],
      );
}

class CreateInvitationDialog extends StatefulWidget {
  const CreateInvitationDialog({super.key, required this.create});
  final Future<String> Function(String email, String role) create;
  @override
  State<CreateInvitationDialog> createState() => _CreateInvitationDialogState();
}

class _CreateInvitationDialogState extends State<CreateInvitationDialog> {
  final _email = TextEditingController();
  UserRole _role = UserRole.operator;
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    FocusScope.of(context).unfocus();
    try {
      final code = await widget.create(_email.text, _role.name);
      if (mounted) Navigator.pop(context, code);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('Convidar para esta fazenda'),
          content: SizedBox(
              width: AppTheme.dialogWidth(context, maxWidth: 400),
              child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                    controller: _email,
                    enabled: !_busy,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'E-mail')),
                const SizedBox(height: 12),
                DropdownButtonFormField<UserRole>(
                    initialValue: _role,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Perfil'),
                    items: [UserRole.operator, UserRole.mechanic]
                        .map((r) =>
                            DropdownMenuItem(value: r, child: Text(r.label)))
                        .toList(),
                    onChanged: _busy
                        ? null
                        : (r) => setState(() => _role = r ?? _role)),
                const SizedBox(height: 8),
                const Text(
                    'O convite é válido por 7 dias e é vinculado ao e-mail informado.'),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null) Text(_error!),
              ]))),
          actions: [
            TextButton(
                onPressed: () {
                  FocusScope.of(context).unfocus();
                  Navigator.pop(context);
                },
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: _busy ? null : _submit,
                child: const Text('Gerar convite'))
          ]);
}
