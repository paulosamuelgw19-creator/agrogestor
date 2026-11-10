import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../sync/farm_api_client.dart';
import 'auth_service.dart';
import 'connection_dialogs.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() => _busy = true);
    final ok = await AuthService().login(_email.text, _password.text);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) _message(AuthService().lastError ?? 'Não foi possível entrar.');
  }

  Future<void> _configureServer() async {
    if (_busy) return;
    final current = await FarmApiClient.instance.baseUrl;
    if (!mounted) return;
    final address = await showDialog<String>(
        context: context,
        builder: (_) => ServerAddressDialog(initialAddress: current ?? ''));
    if (address == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await FarmApiClient.instance.configure(address);
      if (mounted) {
        _message('Endereço salvo. Entre com seu usuário da fazenda.');
      }
    } catch (error) {
      if (mounted) _message(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _acceptInvite() async {
    if (_busy) return;
    final details = await showDialog<InvitationDetails>(
        context: context,
        builder: (_) => AcceptInvitationDialog(initialEmail: _email.text));
    if (details == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await AuthService().acceptInvitation(
          email: details.email,
          code: details.code,
          name: details.name,
          password: details.password);
      if (!mounted) return;
      _message(result
          ? 'Conta ativada. Entre com seu e-mail e senha.'
          : AuthService().lastError ?? 'Convite não aceito.');
      if (result) _email.text = details.email;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppTheme.background,
        body: Center(
          child: SingleChildScrollView(
            padding: AppTheme.pagePadding(context),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Card(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 28, vertical: 34),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.agriculture_rounded,
                            size: 56, color: AppTheme.primary),
                        const SizedBox(height: 12),
                        const Text('AgroGestor',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.textPrimary)),
                        const SizedBox(height: 6),
                        const Text(
                            FarmApiClient.standaloneLocalMode
                                ? 'Gerencie sua fazenda diretamente neste aparelho.'
                                : 'Entre na sua fazenda para usar e sincronizar os cadastros.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppTheme.textSecondary)),
                        const SizedBox(height: 24),
                        if (FarmApiClient.standaloneLocalMode) ...[
                          const Text(
                            'Os dados ficam salvos somente neste aparelho. Esta versão não sincroniza nem faz backup automático.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 18),
                          FilledButton.icon(
                            onPressed: _busy
                                ? null
                                : () async {
                                    setState(() => _busy = true);
                                    await AuthService()
                                        .enterStandaloneLocalMode();
                                  },
                            icon: const Icon(Icons.phone_android),
                            label: const Text('Usar neste aparelho'),
                          ),
                        ] else ...[
                          TextField(
                              controller: _email,
                              keyboardType: TextInputType.emailAddress,
                              decoration: const InputDecoration(
                                  labelText: 'E-mail',
                                  prefixIcon: Icon(Icons.email_outlined))),
                          const SizedBox(height: 12),
                          TextField(
                              controller: _password,
                              obscureText: true,
                              onSubmitted: (_) => _login(),
                              decoration: const InputDecoration(
                                  labelText: 'Senha',
                                  prefixIcon: Icon(Icons.lock_outline))),
                          const SizedBox(height: 18),
                          FilledButton(
                            onPressed: _busy ? null : _login,
                            child: _busy
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2))
                                : const Text('Entrar'),
                          ),
                        ],
                        if (!FarmApiClient.standaloneLocalMode &&
                            FarmApiClient.showServerConfiguration)
                          TextButton(
                              onPressed: _busy ? null : _configureServer,
                              child: const Text(
                                  'Configurar conexão com o PC gestor')),
                        if (!FarmApiClient.standaloneLocalMode)
                          TextButton(
                              onPressed: _busy ? null : _acceptInvite,
                              child: const Text('Ativar convite recebido')),
                        if (kDebugMode &&
                            !FarmApiClient.standaloneLocalMode) ...[
                          const Divider(height: 24),
                          const Text('Demonstração local (sem sincronização)',
                              textAlign: TextAlign.center),
                          const SizedBox(height: 8),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 8,
                            children: AuthService.demoUsers
                                .map((user) => OutlinedButton(
                                      onPressed: () =>
                                          AuthService().selectDemoUser(user),
                                      child: Text(user.role.name == 'admin'
                                          ? 'Admin'
                                          : user.role.name == 'operator'
                                              ? 'Operador'
                                              : 'Mecânico'),
                                    ))
                                .toList(),
                          ),
                        ],
                      ]),
                ),
              ),
            ),
          ),
        ),
      );
}
