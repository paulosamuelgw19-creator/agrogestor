import 'package:agrogestao/features/services/coffee_input_plan.dart';
import 'package:flutter_test/flutter_test.dart';

CoffeeInputPlan _plan(
  CoffeeInputKind kind, {
  required double quantity,
  required String inputUnit,
  String stockUnit = 'kg',
  int? plants,
  bool estimated = false,
  double? bagWeight,
  double? capacity,
  double? applied,
  double? hectares,
}) =>
    CoffeeInputPlan(
      productId: 'produto-ficticio',
      productName: 'Produto fictício',
      stockUnit: stockUnit,
      kind: kind,
      quantity: quantity,
      inputUnit: inputUnit,
      treatedPlants: plants,
      estimatedPlants: estimated,
      bagWeightKg: bagWeight,
      capacityLiters: capacity,
      appliedLiters: applied,
      coveredHectares: hectares,
    );

void main() {
  test('adubação calcula massa pelo total ou pela estimativa de pés', () {
    final whole = _plan(CoffeeInputKind.fertilizer,
        quantity: 100, inputUnit: 'g por pé', plants: 5000);
    final partial = _plan(CoffeeInputKind.fertilizer,
        quantity: 100, inputUnit: 'g por pé', plants: 1250, estimated: true);
    expect(whole.quantityInStockUnit, 500);
    expect(partial.quantityInStockUnit, 125);
    expect(CoffeeInputPlan.fromJson(partial.toJson()).estimatedPlants, isTrue);
    final unknown =
        _plan(CoffeeInputKind.fertilizer, quantity: 100, inputUnit: 'g por pé');
    expect(unknown.validationError, isNull);
    expect(unknown.quantityInStockUnit, isNull);
  });

  test('peso por saco converte para a unidade do estoque', () {
    expect(
        _plan(CoffeeInputKind.bags,
                quantity: 2.5, inputUnit: 'sacos', bagWeight: 40)
            .quantityInStockUnit,
        100);
    final unknown =
        _plan(CoffeeInputKind.bags, quantity: 2.5, inputUnit: 'sacos');
    expect(unknown.validationError, isNull);
    expect(unknown.quantityInStockUnit, isNull);
  });

  test('pulverização separa produto, capacidade e calda efetiva por hectare',
      () {
    final spray = _plan(CoffeeInputKind.spray,
        quantity: 1,
        inputUnit: 'L',
        stockUnit: 'L',
        capacity: 200,
        applied: 80,
        hectares: 2);
    expect(spray.productPerHectare, .5);
    expect(spray.sprayLitersPerHectare, 40);
    expect(spray.quantityInStockUnit, 1);
    final unknownArea = _plan(CoffeeInputKind.spray,
        quantity: 1000,
        inputUnit: 'mL',
        stockUnit: 'L',
        capacity: 200,
        applied: 80);
    expect(unknownArea.validationError, isNull);
    expect(unknownArea.productPerHectare, isNull);
    expect(unknownArea.sprayLitersPerHectare, isNull);
    expect(unknownArea.quantityInStockUnit, 1);
  });

  test('unidade incompatível, carga acima da capacidade e área zero falham',
      () {
    final wrongUnit =
        _plan(CoffeeInputKind.direct, quantity: 1, inputUnit: 'L');
    expect(wrongUnit.validationError, contains('incompatível'));
    expect(wrongUnit.quantityInStockUnit, isNull);
    for (final invalid in [
      _plan(CoffeeInputKind.spray,
          quantity: 1, inputUnit: 'kg', capacity: 50, applied: 80),
      _plan(CoffeeInputKind.spray, quantity: 1, inputUnit: 'kg', hectares: 0),
    ]) {
      expect(invalid.validationError, isNotNull);
      expect(invalid.productPerHectare, isNull);
      expect(invalid.sprayLitersPerHectare, isNull);
    }
  });
}
