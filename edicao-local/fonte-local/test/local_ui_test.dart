import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agrogestao/features/local_backup/local_data_screen.dart';
import 'package:agrogestao/features/auth/login_screen.dart';
import 'package:agrogestao/features/services/services_screen.dart';

void main() {
  for (final size in [
    const Size(320, 640),
    const Size(360, 800),
    const Size(800, 600)
  ]) {
    testWidgets('local backup fits $size with larger text', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          builder: (ctx, child) => MediaQuery(
              data: MediaQuery.of(ctx)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!),
          home: const Scaffold(body: LocalDataScreen())));
      await tester.pumpAndSettle();
      expect(find.text('Salvar backup'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
    testWidgets('local entry does not ask for server and fits $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          home: const LoginScreen(),
          builder: (ctx, child) => MediaQuery(
              data: MediaQuery.of(ctx)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!)));
      await tester.pumpAndSettle();
      expect(find.text('Usar neste aparelho'), findsOneWidget);
      expect(find.text('E-mail'), findsNothing);
      expect(find.text('Configurar conexão com o PC gestor'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('cancellation requires a reason and closes safely while focused',
      (tester) async {
    String? result;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (ctx) => FilledButton(
                    onPressed: () async {
                      result = await showDialog<String>(
                          context: ctx,
                          builder: (_) => const OperationCancellationDialog());
                    },
                    child: const Text('Abrir'))))));
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirmar cancelamento'));
    await tester.pumpAndSettle();
    expect(find.text('Informe o motivo'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'Chuva TESTE');
    await tester.tap(find.text('Confirmar cancelamento'));
    await tester.pumpAndSettle();
    expect(result, 'Chuva TESTE');
    expect(tester.takeException(), isNull);
  });
}
