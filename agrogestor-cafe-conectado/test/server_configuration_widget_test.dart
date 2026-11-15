import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:agrogestao/features/auth/auth_service.dart';
import 'package:agrogestao/features/auth/login_screen.dart';
import 'package:agrogestao/features/auth/user_model.dart';
import 'package:agrogestao/features/auth/connection_dialogs.dart';
import 'package:agrogestao/features/sync/farm_api_client.dart';
import 'package:agrogestao/features/sync/sync_settings_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues(
        {'agro_farm_server_url_v1': 'https://old.example.invalid'});
    FlutterSecureStorage.setMockInitialValues({});
    await AuthService().logout();
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('cancelar endereço repetidamente preserva a conexão anterior',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    for (var attempt = 0; attempt < 3; attempt++) {
      final button = find.text('Configurar conexão com o PC gestor');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      await tester.enterText(
          find.descendant(
              of: find.byType(AlertDialog), matching: find.byType(TextField)),
          'https://discard.example.invalid');
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    expect(await FarmApiClient.instance.baseUrl, 'https://old.example.invalid');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
      'endereço HTTP remoto inválido mostra mensagem sem fechar o aplicativo',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    final button = find.text('Configurar conexão com o PC gestor');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.enterText(
        find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(TextField)),
        'http://example.invalid');
    await tester.tap(find.text('Salvar endereço'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('exigem HTTPS'), findsOneWidget);
    expect(await FarmApiClient.instance.baseUrl, 'https://old.example.invalid');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
      'convite com e-mail focado fecha sem descartar controlador antes da animação',
      (tester) async {
    String? result;
    var requests = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () async {
                      result = await showDialog<String>(
                          context: context,
                          builder: (_) => CreateInvitationDialog(
                                  create: (email, role) async {
                                requests++;
                                return 'CODIGO-FICTICIO';
                              }));
                    },
                    child: const Text('Abrir convite'))))));
    await tester.tap(find.text('Abrir convite'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'pessoa@example.invalid');
    await tester.tap(find.text('Gerar convite'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(result, 'CODIGO-FICTICIO');
    expect(requests, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
      'cancelar ativação de convite com senha focada não causa tela vermelha',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    final button = find.text('Ativar convite recebido');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.enterText(
        find
            .descendant(
                of: find.byType(AlertDialog), matching: find.byType(TextField))
            .last,
        'Senha-FICTICIA-2026');
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(AuthService().isAuthenticated, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
      'salvar endereço com campo focado não desmonta um controlador em uso',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: LoginScreen()));
    final button = find.text('Configurar conexão com o PC gestor');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    final input = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));
    await tester.enterText(input, 'https://new.example.invalid');
    await tester.tap(find.text('Salvar endereço'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(await FarmApiClient.instance.baseUrl, 'https://new.example.invalid');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
      'trocar PC conectado encerra sessão com campo focado sem erro de tela',
      (tester) async {
    await AuthService().selectDemoUser(const AppUser(
        id: 'demo',
        name: 'Admin',
        email: 'demo@example.invalid',
        role: UserRole.admin));
    await tester.pumpWidget(ListenableBuilder(
        listenable: AuthService(),
        builder: (_, __) => MaterialApp(
            home: AuthService().isAuthenticated
                ? const Scaffold(body: SyncSettingsScreen())
                : const LoginScreen())));
    await tester.pumpAndSettle();
    final input = find.byType(TextField);
    await tester.ensureVisible(input);
    await tester.enterText(input, 'https://new.example.invalid');
    await tester.ensureVisible(find.text('Salvar conexão'));
    await tester.tap(find.text('Salvar conexão'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(AuthService().isAuthenticated, isFalse);
    expect(await FarmApiClient.instance.baseUrl, 'https://new.example.invalid');
    expect(find.byType(LoginScreen), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  });
}
