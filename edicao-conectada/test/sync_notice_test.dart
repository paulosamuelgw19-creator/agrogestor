import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agrogestao/app/app_theme.dart';
import 'package:agrogestao/features/sync/sync_service.dart';
import 'package:agrogestao/features/sync/sync_notice.dart';

void main() {
  testWidgets('confirmação de sincronização não aparece como aviso de falha',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(
            body: SyncNotice(
                state: SyncState.idle, message: 'Sincronização concluída.'))));
    expect(find.text('Sincronização concluída.'), findsNothing);
    expect(find.byIcon(Icons.sync_problem_outlined), findsNothing);
  });

  testWidgets('aviso offline mostra a orientação completa com letras ampliadas',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const message =
        'PC gestor ou VPN indisponível. A fila está salva e tentará novamente. Conecte o aparelho para confirmar os lançamentos.';
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: const MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: Scaffold(
                body: Column(children: [
              SyncNotice(state: SyncState.offline, message: message)
            ])))));
    expect(find.text(message), findsOneWidget);
    expect(find.byIcon(Icons.sync_problem_outlined), findsOneWidget);
    final text = tester.getRect(find.text(message));
    final banner = tester.getRect(find.byType(Material).last);
    expect(text.right, lessThanOrEqualTo(320));
    expect(text.bottom, lessThanOrEqualTo(banner.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('fila pendente continua visível para o produtor', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: SyncNotice(
                state: SyncState.pending,
                message: 'Lançamentos aguardando envio.'))));
    expect(find.text('Lançamentos aguardando envio.'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_upload_outlined), findsOneWidget);
  });
}
