import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agrogestao/features/work/work_screen.dart';

void main() {
  Future<void> open(WidgetTester tester, List<WorkField> fields,
      ValueChanged<Map<String, dynamic>?> result,
      {Map<String, String>? lines}) async {
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => FilledButton(
                    onPressed: () async {
                      result(await showDialog<Map<String, dynamic>>(
                          context: context,
                          builder: (_) => WorkForm(
                              title: 'Formulário de teste',
                              fields: fields,
                              lineOptions: lines)));
                    },
                    child: const Text('Abrir'))))));
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
  }

  testWidgets('diário exige descrição e preserva custos ausentes como nulos',
      (tester) async {
    Map<String, dynamic>? body;
    await open(
        tester,
        [
          const WorkField('description', 'Descrição do andamento',
              type: 'notes'),
          const WorkField('labor_cost_cents', 'Custo',
              type: 'money', optional: true)
        ],
        (value) => body = value);
    await tester.tap(find.text('Salvar no aparelho'));
    await tester.pumpAndSettle();
    expect(find.text('Informe o valor.'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).first,
        'Aguardando a peça, conforme diagnóstico.');
    await tester.tap(find.text('Salvar no aparelho'));
    await tester.pumpAndSettle();
    expect(body!['description'], 'Aguardando a peça, conforme diagnóstico.');
    expect(body!['labor_cost_cents'], isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('zero informado é preservado e o formulário não fecha duas vezes',
      (tester) async {
    Map<String, dynamic>? body;
    var saves = 0;
    await open(tester, [
      const WorkField('labor_cost_cents', 'Custo',
          type: 'money', optional: true)
    ], (value) {
      body = value;
      saves++;
    });
    await tester.enterText(find.byType(TextFormField), '0');
    await tester.tap(find.text('Salvar no aparelho'));
    await tester.tap(find.text('Salvar no aparelho'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(body!['labor_cost_cents'], 0);
    expect(saves, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
      'permite vários itens e remover linha focada sem perder os restantes',
      (tester) async {
    Map<String, dynamic>? body;
    await open(tester, [], (value) => body = value,
        lines: {'part-a': 'Peça A (un)', 'part-b': 'Peça B (kg)'});
    await tester.tap(find.text('Adicionar produto / peça'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Peça A (un)').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, '2');
    await tester.tap(find.text('Adicionar produto / peça'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Peça B (kg)').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).last, '1,5');
    await tester.tap(find.text('Remover item').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salvar no aparelho'));
    await tester.pumpAndSettle();
    expect(body!['_items'], [
      {'input_id': 'part-b', 'quantity': '1.5'}
    ]);
    expect(tester.takeException(), isNull);
  });
}
