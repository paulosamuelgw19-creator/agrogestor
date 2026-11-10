import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agrogestao/features/properties/properties_screen.dart';

void main() {
  Future<void> open(WidgetTester tester, Widget dialog,
      void Function(Map<String, dynamic>?) result) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () async => result(
                        await showDialog<Map<String, dynamic>>(
                            context: context, builder: (_) => dialog)),
                    child: const Text('Abrir'))))));
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.widgetWithText(TextFormField, label);

  testWidgets('fazenda permite responsável opcional e área desconhecida',
      (tester) async {
    Map<String, dynamic>? saved;
    await open(tester, const CatalogEntityDialog(), (value) => saved = value);
    await tester.enterText(field('Nome ou identificação'), 'Fazenda teste');
    await tester.ensureVisible(find.text('Salvar'));
    await tester.tap(find.text('Salvar'));
    await tester.pumpAndSettle();
    expect(saved?['name'], 'Fazenda teste');
    expect(saved?['responsible_user_id'], isNull);
    expect(saved?['area_ha'], isNull);
    expect(saved?['plots'], isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('edição de talhão valida área e fecha com campo focado sem erro',
      (tester) async {
    Map<String, dynamic>? saved;
    await open(
        tester,
        const CatalogEntityDialog(plot: true, entity: {
          'id': 'plot-1',
          'name': 'Antigo',
          'area_ha': '2',
          'notes': 'Anterior',
          'property_id': 'prop-1',
          'version': 1
        }),
        (value) => saved = value);
    await tester.enterText(field('Área (ha)'), '0');
    await tester.ensureVisible(find.text('Salvar'));
    await tester.tap(find.text('Salvar'));
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(find.text('Informe um valor maior que zero.'), findsOneWidget);
    await tester.ensureVisible(field('Área (ha)'));
    await tester.enterText(field('Área (ha)'), '2,5');
    await tester.ensureVisible(field('Observações'));
    await tester.enterText(field('Observações'), 'Revisado');
    await tester.ensureVisible(find.text('Salvar'));
    await tester.tap(find.text('Salvar'));
    await tester.pumpAndSettle();
    expect(saved, {'name': 'Antigo', 'area_ha': '2.5', 'notes': 'Revisado'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancelar edição não altera o cadastro original', (tester) async {
    final original = {
      'id': 'prop-1',
      'name': 'Original',
      'area_ha': '10',
      'location': 'Local original',
      'notes': 'Nota original'
    };
    Map<String, dynamic>? saved;
    await open(tester, CatalogEntityDialog(entity: original),
        (value) => saved = value);
    await tester.enterText(field('Nome ou identificação'), 'Descartar');
    await tester.ensureVisible(find.text('Cancelar'));
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(saved, isNull);
    expect(original['name'], 'Original');
    expect(tester.takeException(), isNull);
  });
}
