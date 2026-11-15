import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agrogestao/features/products/product_record.dart';
import 'package:agrogestao/features/products/product_details_dialog.dart';
import 'package:agrogestao/features/products/product_classification_fields.dart';

void main() {
  test('registro antigo mantém identidade, categoria livre, lote e saldo', () {
    final old = {
      'id': 'old-1',
      'name': 'Produto antigo',
      'category': 'Categoria própria',
      'unit': 'L',
      'quantity': 27.5,
      'lot': 'ABC'
    };
    final product = FarmProduct.fromJson(old);
    expect(product.productType, '');
    expect(product.toJson(), {...old, 'productType': ''});
    final updated = product.copyWith(productType: 'Óleos lubrificantes');
    expect(FarmProduct.fromJson(updated.toJson()).productType,
        'Óleos lubrificantes');
    expect(updated.quantity, 27.5);
    expect(updated.id, 'old-1');
  });

  testWidgets('trocar categoria remove tipo incompatível', (tester) async {
    String? selectedType;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Form(
                child: ProductClassificationFields(
                    category: 'Químicos e minerais',
                    type: 'Herbicidas',
                    onChanged: (category, type) => selectedType = type)))));
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Combustíveis e lubrificantes').last);
    await tester.pumpAndSettle();
    expect(selectedType, '');
    expect(find.text('Herbicidas'), findsNothing);
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Diesel').last);
    await tester.pumpAndSettle();
    expect(selectedType, 'Diesel');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'editar classificação antiga preserva unidade e fecha com campo focado',
      (tester) async {
    Map<String, dynamic>? saved;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () async {
                      saved = await showDialog<Map<String, dynamic>>(
                          context: context,
                          builder: (_) => const ProductDetailsDialog(product: {
                                'name': 'Produto antigo',
                                'unit': 'L',
                                'category': 'Categoria própria',
                                'product_type': 'Tipo próprio'
                              }));
                    },
                    child: const Text('Editar'))))));
    await tester.tap(find.text('Editar'));
    await tester.pumpAndSettle();
    expect(find.text('Categoria própria'), findsOneWidget);
    expect(find.text('Tipo próprio'), findsOneWidget);
    final unit = tester.widget<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>).last);
    expect(unit.onChanged, isNull);
    await tester.enterText(find.byType(TextFormField), 'Produto revisado');
    await tester.ensureVisible(find.text('Salvar'));
    await tester.tap(find.text('Salvar'));
    await tester.pumpAndSettle();
    expect(saved, {
      'name': 'Produto revisado',
      'unit': 'L',
      'category': 'Categoria própria',
      'product_type': 'Tipo próprio'
    });
    expect(tester.takeException(), isNull);
  });
}
