import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agrogestao/features/operations_v2/operations_screen.dart';
import 'package:agrogestao/features/operations_v2/v2_store.dart';

void main() {
  Future<void> open(WidgetTester tester, ValueChanged<Json?> result) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => FilledButton(
                    onPressed: () async => result(await showDialog<Json>(
                        context: context,
                        builder: (_) =>
                            const OperationDialog(cycleId: 'cycle', data: {
                              'cycles': [
                                {
                                  'id': 'cycle',
                                  'name': 'Safra fictícia',
                                  'plot_id': 'plot'
                                }
                              ],
                              'plots': [
                                {'id': 'plot', 'name': 'Talhão fictício'}
                              ],
                              'machines': [
                                {
                                  'id': 'machine',
                                  'name': 'Trator fictício',
                                  'hour_meter': '100'
                                }
                              ],
                              'inputs': []
                            }))),
                    child: const Text('Abrir'))))));
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Adicionar abastecimento'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(
        DropdownButtonFormField<String>, 'Máquina abastecida'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Trator fictício').last);
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);
  testWidgets(
      'abastecimento em posto mantém preço ausente e não gera consumo duplicado',
      (tester) async {
    Json? result;
    await open(tester, (value) => result = value);
    await tester.enterText(field('Litros abastecidos'), '12,5');
    await tester.enterText(
        field('Local ou posto, se informado'), 'Posto FICTÍCIO');
    await tester.tap(find.text('Finalizar e salvar'));
    await tester.pumpAndSettle();
    expect(result!['inputs'], isEmpty);
    final fuel = items(result!, 'refuelings').single;
    expect(fuel['source'], 'external');
    expect(fuel['liters'], '12.5');
    expect(fuel['hour_meter'], '100');
    expect(fuel['unit_price_cents'], isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('litros devem ser positivos e preço informado vira centavos',
      (tester) async {
    Json? result;
    await open(tester, (value) => result = value);
    await tester.enterText(field('Litros abastecidos'), '0');
    await tester.tap(find.text('Finalizar e salvar'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('Informe um valor maior que zero.'), findsOneWidget);
    await tester.enterText(field('Litros abastecidos'), '10');
    await tester.enterText(
        field('Preço por litro (R\$), se conhecido'), '6,25');
    await tester.tap(find.text('Finalizar e salvar'));
    await tester.pumpAndSettle();
    expect(items(result!, 'refuelings').single['unit_price_cents'], 625);
    expect(tester.takeException(), isNull);
  });
  test('somente combustíveis em litros aparecem no seletor de abastecimento',
      () {
    expect(
        isFuelInput({
          'unit': 'L',
          'name': 'Diesel',
          'category': '',
          'product_type': ''
        }),
        isTrue);
    expect(
        isFuelInput({
          'unit': 'L',
          'name': 'Óleo',
          'product_type': 'Óleos lubrificantes'
        }),
        isFalse);
    expect(
        isFuelInput({'unit': 'kg', 'name': 'Diesel', 'product_type': 'Diesel'}),
        isFalse);
  });
}
