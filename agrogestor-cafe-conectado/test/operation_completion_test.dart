import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:agrogestao/app/app_theme.dart';
import 'package:agrogestao/features/operations_v2/operations_screen.dart';
import 'package:agrogestao/features/operations_v2/v2_store.dart';
import 'package:agrogestao/features/products/products_screen.dart';

const data = <String, dynamic>{
  'cycles': [
    {'id': 'cycle', 'name': 'Safra FICTÍCIA', 'plot_id': 'plot'}
  ],
  'plots': [
    {'id': 'plot', 'name': 'Talhão FICTÍCIO'}
  ],
  'machines': [
    {'id': 'machine', 'name': 'Trator FICTÍCIO', 'hour_meter': '100'}
  ],
  'inputs': [
    {'id': 'fertilizer', 'name': 'Adubo FICTÍCIO', 'unit': 'kg'},
    {'id': 'bio', 'name': 'Bioinsumo FICTÍCIO', 'unit': 'L'},
  ],
};
const task = <String, dynamic>{
  'id': 'task',
  'version': 7,
  'cycle_id': 'cycle',
  'machine_id': 'machine',
  'title': 'Tarefa FICTÍCIA',
  'planned_hours': '5',
  'planned_inputs': [
    {'input_id': 'fertilizer', 'quantity': '99'}
  ],
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> open(WidgetTester tester, ValueChanged<Json?> result) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
            body: Builder(
                builder: (context) => FilledButton(
                    onPressed: () async => result(await showDialog<Json>(
                        context: context,
                        builder: (_) =>
                            const OperationDialog(data: data, task: task))),
                    child: const Text('Abrir'))))));
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'operações e produtos são áreas independentes sem abas misturadas',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light, home: const Scaffold(body: OperationsScreen())));
    await tester.pumpAndSettle();
    expect(find.text('Operações'), findsOneWidget);
    expect(find.text('Produtos e insumos'), findsNothing);
    expect(find.byType(TabBar), findsNothing);
    await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(
            body: OperationsScreen(section: OperationsSection.products))));
    await tester.pumpAndSettle();
    expect(find.text('Produtos e insumos'), findsOneWidget);
    expect(find.text('Operações'), findsNothing);
    expect(find.byType(TabBar), findsNothing);
    expect(find.text('Finalizar operação'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'finalização registra quantidades reais de cada insumo e a máquina atribuída',
      (tester) async {
    Json? saved;
    await open(tester, (value) => saved = value);
    expect(find.text('Finalizar operação'), findsOneWidget);
    expect(find.text('Trator FICTÍCIO'), findsOneWidget);
    final end = find.widgetWithText(TextFormField, 'Horímetro final');
    expect(tester.widget<TextFormField>(end).controller!.text, isEmpty);
    expect(
        find.widgetWithText(
            DropdownButtonFormField<String>, 'Insumo e unidade'),
        findsNothing);
    await tester.enterText(end, '101,5');
    for (final product in ['Adubo FICTÍCIO (kg)', 'Bioinsumo FICTÍCIO (L)']) {
      await tester.ensureVisible(find.text('Adicionar insumo consumido'));
      await tester.tap(find.text('Adicionar insumo consumido'));
      await tester.pumpAndSettle();
      final selector = find
          .widgetWithText(DropdownButtonFormField<String>, 'Insumo e unidade')
          .last;
      await tester.ensureVisible(selector);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text(product).last);
      await tester.pumpAndSettle();
      final quantity =
          find.widgetWithText(TextFormField, 'Quantidade consumida').last;
      await tester.ensureVisible(quantity);
      await tester.enterText(
          quantity, product.startsWith('Adubo') ? '2,5' : '1');
      expect(saved, isNull);
    }
    await tester.tap(find.text('Finalizar e salvar'));
    await tester.pumpAndSettle();
    expect(saved!['inputs'], [
      {'input_id': 'fertilizer', 'quantity': '2.5'},
      {'input_id': 'bio', 'quantity': '1'},
    ]);
    expect(saved!['machines'], [
      {'machine_id': 'machine', 'start_meter': '100', 'end_meter': '101.5'}
    ]);
    expect(saved!['task_id'], 'task');
    expect(saved!['task_expected_version'], 7);
    expect(saved!['inputs'].toString(), isNot(contains('99')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelar a finalização não cria consumo nem altera o catálogo',
      (tester) async {
    Json? saved;
    await open(tester, (value) => saved = value);
    await tester.ensureVisible(find.text('Adicionar insumo consumido'));
    await tester.tap(find.text('Adicionar insumo consumido'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Quantidade consumida'), '5');
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(items(data, 'inputs').length, 2);
    expect(data['inputs'], [
      {'id': 'fertilizer', 'name': 'Adubo FICTÍCIO', 'unit': 'kg'},
      {'id': 'bio', 'name': 'Bioinsumo FICTÍCIO', 'unit': 'L'},
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'cadastro anterior preserva histórico sem oferecer consumo separado',
      (tester) async {
    await tester.pumpWidget(
        MaterialApp(theme: AppTheme.light, home: const ProductsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('Registrar utilização'), findsNothing);
    await tester.tap(find.text('Histórico anterior'));
    await tester.pumpAndSettle();
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.text('Registrar utilização'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
