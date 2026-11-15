import 'dart:convert';

import 'package:agrogestao/features/harvest/coffee_harvest_repository.dart';
import 'package:agrogestao/features/harvest/coffee_harvest_screen.dart';
import 'package:agrogestao/features/local_backup/local_backup_service.dart';
import 'package:agrogestao/features/processing/coffee_processing_repository.dart';
import 'package:agrogestao/features/properties/catalog_store.dart';
import 'package:agrogestao/features/sync/app_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'coffee_notebook_harvest_test.dart' show useCoffeeDatabase;

final _harvestDay = DateTime(2026, 6, 10);
final _opened = DateTime(2026, 6, 11);
final _cleaningDay = DateTime(2026, 8, 20);
final _saleDay = DateTime(2027, 2, 3);

CoffeePlotProduction _harvest(String plot, double liters) =>
    CoffeePlotProduction(
      id: 'harvest-$plot',
      propertyId: 'farm',
      plotId: plot,
      date: _harvestDay,
      seasonYear: 2026,
      unit: CoffeeHarvestUnit.liters,
      quantity: liters,
    );

CoffeeLotInput _confirmed(String plot, double liters) => CoffeeLotInput(
      id: 'input-$plot',
      kind: CoffeeLotSourceKind.picked,
      origin: CoffeeLotOrigin.confirmed,
      plotId: plot,
      harvestDate: _harvestDay,
      volumeLiters: liters,
      linkedLiters: liters,
    );

CoffeeLot _lot(String id, List<CoffeeLotInput> inputs) => CoffeeLot(
      id: id,
      propertyId: 'farm',
      seasonYear: 2026,
      code: id.toUpperCase(),
      date: _opened,
      inputs: inputs,
    );

CoffeeLotSale _sale(String id, double quantity, DateTime date) => CoffeeLotSale(
      id: id,
      date: date,
      unit: CoffeeProcessedUnit.kilograms,
      quantity: quantity,
      totalPriceCents: 80000,
    );

void main() {
  useCoffeeDatabase();

  test('rendimento ponderado mantém as bases e os lotes mistos separados', () {
    CoffeeLot lot(String id, List<CoffeeLotInput> inputs, double liters,
            double kg, CoffeeCleaningInputBase base) =>
        CoffeeLot(
          id: id,
          propertyId: 'farm',
          seasonYear: 2026,
          code: id,
          date: _opened,
          inputs: inputs,
          cleanings: [
            CoffeeLotCleaning(
                id: id,
                date: _cleaningDay,
                unit: CoffeeProcessedUnit.kilograms,
                quantity: kg,
                inputLiters: liters,
                inputBase: base),
          ],
        );
    final a = _confirmed('plot-a', 300);
    final b = _confirmed('plot-b', 300);
    final first = lot('first', [a], 240, 60, CoffeeCleaningInputBase.ripe);
    expect(first.cleanings.single.litersPerSack60, 240);
    final yields = compareCoffeeYields([
      first,
      lot('second', [a], 360, 120, CoffeeCleaningInputBase.ripe),
      lot('washed', [a], 110, 60, CoffeeCleaningInputBase.washed),
      lot('mixed', [a, b], 400, 100, CoffeeCleaningInputBase.ripe),
    ]);
    final ripe = yields[('plot-a', false, CoffeeCleaningInputBase.ripe)]!;
    expect(ripe.liters / (ripe.outputKg / 60), 200);
    expect(
        yields[('plot-a', false, CoffeeCleaningInputBase.washed)]?.liters, 110);
    expect(yields[(null, true, CoffeeCleaningInputBase.ripe)]?.liters, 400);
    expect(yields.keys.any((key) => key.$1 == 'plot-b'), isFalse);
  });

  test('duas origens e vários lotes respeitam a produção disponível do dia',
      () async {
    final harvest = CoffeeHarvestRepository();
    final repo = CoffeeProcessingRepository();
    await harvest.saveProduction(_harvest('plot-a', 600));
    await harvest.saveProduction(_harvest('plot-b', 300));
    final partial = CoffeeLotInput(
      id: 'partial',
      kind: CoffeeLotSourceKind.raked,
      origin: CoffeeLotOrigin.partial,
      plotId: 'plot-b',
      harvestDate: _harvestDay,
      volumeLiters: 160,
      linkedLiters: 100,
    );
    const unknown = CoffeeLotInput(
      id: 'unknown',
      kind: CoffeeLotSourceKind.raked,
      origin: CoffeeLotOrigin.unknown,
      notes: 'Origem não anotada',
    );
    await repo.saveLot(_lot('first', [_confirmed('plot-a', 350), partial]));
    await repo.saveLot(_lot('second', [_confirmed('plot-a', 250), unknown]));
    Future<CoffeeLotHarvestSource> source(String plot,
            {String? excluding}) async =>
        (await repo.harvestSources(
          propertyId: 'farm',
          plotId: plot,
          seasonYear: 2026,
          excludingLotId: excluding,
        ))
            .single;
    expect((await source('plot-a')).availableLiters, 0);
    expect((await source('plot-a', excluding: 'second')).availableLiters, 250);
    expect((await source('plot-b')).allocatedLiters, 100);
    expect((await source('plot-b')).availableLiters, 200);
    await expectLater(
      repo.saveLot(_lot('excess', [_confirmed('plot-a', 1)])),
      throwsFormatException,
    );
    await expectLater(
      harvest.saveProduction(_harvest('plot-a', 599)),
      throwsFormatException,
    );
    await expectLater(
      repo.saveLot(_lot('wrong-farm', [_confirmed('other-plot', 1)])),
      throwsFormatException,
    );
    final lots = await repo.list(propertyId: 'farm', seasonYear: 2026);
    expect(lots, hasLength(2));
    expect(lots.singleWhere((lot) => lot.id == 'first').inputs.last.toJson(),
        partial.toJson());
    final untracked = lots.singleWhere((lot) => lot.id == 'second').inputs.last;
    expect(untracked.origin, CoffeeLotOrigin.unknown);
    expect(untracked.volumeLiters, isNull);
  });

  test('limpas parciais e venda posterior preservam saldo e backup v6',
      () async {
    final harvest = CoffeeHarvestRepository();
    final repo = CoffeeProcessingRepository();
    await harvest.saveProduction(_harvest('plot-a', 600));
    await repo.saveLot(_lot('lot', [_confirmed('plot-a', 600)]));
    Future<CoffeeLot> lot() => repo.getLot(propertyId: 'farm', lotId: 'lot');
    for (final (stage, liters) in [
      (CoffeeProcessingStage.reception, 600.0),
      (CoffeeProcessingStage.washed, 520.0),
      (CoffeeProcessingStage.dried, 250.0),
    ]) {
      await repo.addMeasurement(
        propertyId: 'farm',
        lotId: 'lot',
        measurement: CoffeeLotMeasurement(
          id: stage.name,
          date: _opened,
          stage: stage,
          volumeLiters: liters,
        ),
      );
    }
    expect((await lot()).producedKg, 0);
    final withBasis = CoffeeLotCleaning(
      id: 'partial-one',
      date: _cleaningDay,
      unit: CoffeeProcessedUnit.bags,
      quantity: 2,
      kgPerBag: 60,
      remainderKg: 15,
      inputLiters: 300,
      inputBase: CoffeeCleaningInputBase.ripe,
    );
    final withoutBasis = CoffeeLotCleaning(
      id: 'partial-two',
      date: _cleaningDay.add(const Duration(days: 3)),
      unit: CoffeeProcessedUnit.kilograms,
      quantity: 45,
      inputLiters: 90,
    );
    Future<void> addCleaning(CoffeeLotCleaning cleaning) =>
        repo.addCleaning(propertyId: 'farm', lotId: 'lot', cleaning: cleaning);
    await addCleaning(withBasis);
    await addCleaning(withoutBasis);
    await addCleaning(withBasis);
    expect(withBasis.outputKg, 135);
    expect(withBasis.yieldKgPerLiter, .45);
    expect(withoutBasis.yieldKgPerLiter, isNull);
    expect((await lot()).producedKg, 180);

    Future<void> addSale(CoffeeLotSale sale) =>
        repo.addSale(propertyId: 'farm', lotId: 'lot', sale: sale);
    await expectLater(
        addSale(_sale('too-soon', 1, _opened)), throwsFormatException);
    await expectLater(
        addSale(_sale('too-much', 181, _saleDay)), throwsFormatException);
    final sale = _sale('sale', 110, _saleDay);
    await addSale(sale);
    await addSale(sale);
    await expectLater(
        addSale(_sale('sale', 111, _saleDay)), throwsFormatException);
    await expectLater(addSale(_sale('exceeds-after-sale', 71, _saleDay)),
        throwsFormatException);
    await expectLater(
      repo.saveLot(_lot('lot', [_confirmed('plot-a', 500)])),
      throwsFormatException,
    );
    await appDatabase.close();
    final saved = await lot();
    expect(saved.seasonYear, 2026);
    expect(saved.sales.single.date.year, 2027);
    expect(saved.stockKg, 70);
    expect(saved.soldKg, 110);
    expect(
        saved.measurements.map((item) => item.volumeLiters), [600, 520, 250]);
    expect(saved.cleanings, hasLength(2));

    final backup = LocalBackupService();
    final bytes = await backup.create();
    expect(jsonDecode(utf8.decode(bytes))['schemaVersion'], 6);
    final db = (await CatalogStore.open()).db;
    for (final table in ['local_records', 'local_audit']) {
      await db.delete(table,
          where: 'module = ?', whereArgs: ['coffeeProcessingLots']);
    }
    expect(await repo.list(propertyId: 'farm'), isEmpty);
    await backup.restore(bytes);
    expect((await lot()).toJson(), saved.toJson());
  });

  testWidgets('Colheita abre beneficiamento e registra lote, limpa e venda',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Future<void> waitFor(Finder finder) async {
      for (var i = 0; i < 150 && finder.evaluate().isEmpty; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(finder, findsWidgets);
      await tester.pump(const Duration(milliseconds: 350));
    }

    Future<void> tap(String label) async {
      final finder = find.text(label);
      await waitFor(finder);
      await tester.ensureVisible(finder);
      await tester.tap(finder);
      await tester.pump(const Duration(milliseconds: 350));
    }

    Future<void> enter(String label, String value) async {
      final finder = find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == label,
          description: 'campo $label');
      await waitFor(finder);
      await tester.ensureVisible(finder);
      await tester.enterText(finder, value);
      await tester.pump();
    }

    try {
      await tester.pumpWidget(const MaterialApp(
          home: CoffeeHarvestScreen(
        property: {'id': 'farm', 'name': 'Fazenda teste'},
        plot: {'id': 'plot-a', 'name': 'Talhão A', 'area_ha': 2},
      )));
      await tap('Beneficiamento');
      await tap('Novo lote');
      await enter('Código do lote', 'LOTE TESTE');
      await tap('Adicionar entrada');
      await enter('Volume da entrada (L)', '300');
      await tap('Salvar entrada');
      await tap('Salvar lote');
      await tap('Registrar limpa');
      await enter('Peso (kg)', '100');
      await tap('Salvar');
      await waitFor(find.text('Saldo: 100 kg'));
      await tap('Registrar venda');
      await enter('Peso (kg)', '30');
      await enter('Valor total (R\$)', '700');
      await tap('Salvar');
      await waitFor(find.text('Saldo: 70 kg'));
      final lots = await tester.runAsync(
          () => CoffeeProcessingRepository().list(propertyId: 'farm'));
      final saved = lots!.single;
      expect(saved.inputs.single.plotId, 'plot-a');
      expect(saved.inputs.single.origin, CoffeeLotOrigin.partial);
      expect(saved.producedKg, 100);
      expect(saved.soldKg, 30);
      expect(saved.sales.single.totalPriceCents, 70000);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
