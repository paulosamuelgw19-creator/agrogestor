import 'package:flutter/material.dart';
import '../../app/app_theme.dart';
import '../auth/auth_service.dart';
import 'local_activation_service.dart';

class LocalActivationNotice extends StatelessWidget {
  const LocalActivationNotice({super.key});
  @override
  Widget build(BuildContext context) {
    final license = LocalActivationService.instance;
    if (!license.enforced || !license.isValid) return const SizedBox.shrink();
    return Container(
        width: double.infinity,
        color: const Color(0xffeaf4eb),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: const Text(
            'AgroGestor Local · Piloto gratuito — sem vencimento\nAtivado neste aparelho',
            style: TextStyle(color: AppTheme.forest, fontSize: 12)));
  }
}

class ActivationGate extends StatefulWidget {
  const ActivationGate({super.key, required this.child, this.service});
  final Widget child;
  final LocalActivationService? service;
  @override
  State<ActivationGate> createState() => _ActivationGateState();
}

class _ActivationGateState extends State<ActivationGate>
    with WidgetsBindingObserver {
  final _code = TextEditingController();
  late final _license = widget.service ?? LocalActivationService.instance;
  bool _busy = false;
  String? _message;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _code.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) _license.refresh();
  }

  Future<void> _activate() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await _license.activate(_code.text);
      await AuthService().enterStandaloneLocalMode();
    } on LocalActivationException catch (e) {
      if (mounted) setState(() => _message = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _message =
            'Não foi possível concluir. Seus dados e o código preenchido foram preservados.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: _license,
      builder: (context, _) {
        if (_license.isValid) return widget.child;
        return Scaffold(
            backgroundColor: AppTheme.background,
            body: SafeArea(
                child: Center(
                    child: SingleChildScrollView(
                        padding: const EdgeInsets.all(20),
                        child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 450),
                            child: Card(
                                child: Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          const Icon(Icons.key_outlined,
                                              size: 44,
                                              color: AppTheme.primary),
                                          const SizedBox(height: 16),
                                          const Text('Ativar AgroGestor Local',
                                              style: TextStyle(
                                                  fontSize: 24,
                                                  fontWeight: FontWeight.w800)),
                                          const SizedBox(height: 12),
                                          const Text(
                                              'Informe o código exclusivo enviado pelo responsável. A primeira ativação precisa de internet. Seus cadastros existentes serão preservados.'),
                                          if (_license.reason ==
                                                  'invalid_license' ||
                                              _license.reason ==
                                                  'storage_error') ...[
                                            const SizedBox(height: 12),
                                            const Text(
                                                'A autorização salva não pôde ser validada para esta instalação. Tente recuperar com o código original ou contate o responsável. Não desinstale nem limpe os dados.'),
                                          ],
                                          const SizedBox(height: 20),
                                          TextField(
                                              controller: _code,
                                              enabled: !_busy,
                                              maxLength: 80,
                                              autocorrect: false,
                                              enableSuggestions: false,
                                              enableIMEPersonalizedLearning:
                                                  false,
                                              textCapitalization:
                                                  TextCapitalization.characters,
                                              decoration: const InputDecoration(
                                                  labelText:
                                                      'Código de ativação',
                                                  hintText: 'AGRO-…',
                                                  border: OutlineInputBorder()),
                                              onSubmitted: (_) => _activate()),
                                          const SizedBox(height: 12),
                                          FilledButton.icon(
                                              onPressed:
                                                  _busy ? null : _activate,
                                              icon: _busy
                                                  ? const SizedBox(
                                                      width: 18,
                                                      height: 18,
                                                      child:
                                                          CircularProgressIndicator(
                                                              strokeWidth: 2))
                                                  : const Icon(Icons
                                                      .verified_user_outlined),
                                              label: Text(_busy
                                                  ? 'Ativando…'
                                                  : 'Ativar neste aparelho')),
                                          if (_message != null)
                                            Padding(
                                                padding: const EdgeInsets.only(
                                                    top: 16),
                                                child: Semantics(
                                                    liveRegion: true,
                                                    child: Text(_message!))),
                                          const SizedBox(height: 16),
                                          const Text(
                                              'Depois de ativado, o aplicativo funciona localmente sem exigir o servidor novamente.'),
                                        ]))))))));
      });
}
