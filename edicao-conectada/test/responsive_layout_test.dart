import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agrogestao/app/app_theme.dart';
import 'package:agrogestao/app/responsive_summary.dart';
import 'package:agrogestao/features/work/work_screen.dart';
import 'package:agrogestao/features/properties/properties_screen.dart';
import 'package:agrogestao/features/operations_v2/operations_screen.dart';

void main() {
  for (final width in [320.0, 360.0, 514.0, 900.0]) {
    testWidgets('cartões têm dimensões proporcionais em largura $width',
        (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          home: MediaQuery(
              data: MediaQueryData(
                  size: Size(width, 800),
                  textScaler: TextScaler.linear(width == 320 ? 1.5 : 1)),
              child: const Scaffold(
                  body: SingleChildScrollView(
                      padding: EdgeInsets.all(16),
                      child: ResponsiveSummary(values: [
                        (label: 'Tarefas pendentes', value: 7),
                        (label: 'Máquinas paradas', value: 5),
                        (label: 'Ordens em andamento', value: 100),
                        (label: 'Aguardando peças', value: 0),
                      ]))))));
      await tester.pumpAndSettle();
      final cards = find.byType(Card);
      expect(cards, findsNWidgets(4));
      final first = tester.getRect(cards.at(0));
      for (var i = 0; i < 4; i++) {
        final rect = tester.getRect(cards.at(i));
        expect(rect.width, closeTo(first.width, .1));
        expect(rect.left, greaterThanOrEqualTo(16));
        expect(rect.right, lessThanOrEqualTo(width - 16));
      }
      if (width == 320) {
        expect(tester.getTopLeft(cards.at(1)).dy, greaterThan(first.bottom));
      } else if (width == 900) {
        expect(tester.getRect(cards.at(3)).top, first.top);
        expect(tester.getRect(cards.at(3)).height, first.height);
      } else {
        expect(tester.getRect(cards.at(1)).top, first.top);
        expect(tester.getRect(cards.at(2)).top, greaterThan(first.bottom));
        expect(
            tester.getRect(cards.at(3)).top, tester.getRect(cards.at(2)).top);
        expect(tester.getTopLeft(find.text('100')).dy,
            tester.getTopLeft(find.text('0')).dy);
      }
      expect(tester.takeException(), isNull);
    });
  }
  Future<void> open(WidgetTester tester, Widget dialog,
      {Size size = const Size(320, 640), double scale = 1.5}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => showDialog<void>(
                        context: context, builder: (_) => dialog),
                    child: const Text('Abrir'))))));
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
  }

  for (final size in [const Size(320, 640), const Size(720, 460)]) {
    testWidgets('operação e abastecimento cabem em $size com letras ampliadas',
        (tester) async {
      await open(
          tester,
          const OperationDialog(cycleId: 'cycle', data: {
            'cycles': [
              {
                'id': 'cycle',
                'name': 'Safra de café FICTÍCIA 2026/2027',
                'plot_id': 'plot'
              }
            ],
            'plots': [
              {
                'id': 'plot',
                'name': 'Talhão da entrada da propriedade FICTÍCIA'
              }
            ],
            'machines': [
              {
                'id': 'machine',
                'name': 'Trator com pulverizador FICTÍCIO',
                'hour_meter': '100'
              }
            ],
            'inputs': [
              {
                'id': 'fuel',
                'name': 'Diesel S10 FICTÍCIO',
                'unit': 'L',
                'product_type': 'Diesel'
              }
            ]
          }),
          size: size);
      expect(tester.takeException(), isNull);
      final cycleField = find.widgetWithText(
          DropdownButtonFormField<String>, 'Talhão e safra');
      final selectedCycle = find
          .descendant(
              of: cycleField,
              matching: find.text(
                  'Talhão da entrada da propriedade FICTÍCIA · Safra de café FICTÍCIA 2026/2027'))
          .first;
      expect(tester.getRect(selectedCycle).bottom,
          lessThanOrEqualTo(tester.getRect(cycleField).bottom));
      await tester.ensureVisible(find.text('Adicionar abastecimento'));
      await tester.tap(find.text('Adicionar abastecimento'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final source = find.widgetWithText(
          DropdownButtonFormField<String>, 'Origem do combustível');
      await tester.ensureVisible(source);
      await tester.pumpAndSettle();
      await tester.tap(source);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Estoque da propriedade').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(find.byType(OperationDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'propriedade permite digitar e cancelar com teclado e fonte grande',
      (tester) async {
    await open(
        tester,
        const CatalogEntityDialog(clients: [
          {'id': 'client', 'name': 'Cliente com nome completo extenso FICTÍCIO'}
        ]));
    final name = find.widgetWithText(TextFormField, 'Nome ou identificação');
    await tester.ensureVisible(name);
    await tester.enterText(name, 'Propriedade FICTÍCIA de teste');
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Cancelar'));
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.byType(CatalogEntityDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('diário e peças mantêm ações acessíveis com teclado aberto',
      (tester) async {
    await open(
        tester,
        const WorkForm(title: 'Descrever o andamento da manutenção', fields: [
          WorkField('description', 'Descrição do andamento', type: 'notes')
        ], lineOptions: {
          'part': 'Filtro de combustível FICTÍCIO (un)'
        }));
    await tester.enterText(
        find.byType(TextFormField).first, 'Serviço em andamento');
    tester.view.viewInsets = const FakeViewPadding(bottom: 220);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Cancelar'));
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(find.byType(WorkForm), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
