import 'dart:convert';
import 'dart:io';

import 'package:agrogestao/features/analyses/coffee_analysis_repository.dart';
import 'package:agrogestao/features/coffee_finance/coffee_finance_repository.dart';
import 'package:agrogestao/features/coffee_finance/coffee_finance_check_repository.dart';
import 'package:agrogestao/features/coffee_finance/coffee_finance_screen.dart';
import 'package:agrogestao/features/harvest/coffee_harvest_repository.dart';
import 'package:agrogestao/features/local_backup/local_backup_service.dart';
import 'package:agrogestao/features/maintenance/maintenance_record.dart';
import 'package:agrogestao/features/maintenance/maintenance_repository.dart';
import 'package:agrogestao/features/processing/coffee_processing_repository.dart';
import 'package:agrogestao/features/properties/catalog_store.dart';
import 'package:agrogestao/features/sync/app_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'coffee_notebook_harvest_test.dart' show useCoffeeDatabase;
import 'coffee_production_analysis_test.dart' show buildAnalysisPdf;

final _day = DateTime(2026, 6, 10);
final _sold = DateTime(2026, 12, 15);
final _paid = DateTime(2027, 1, 10);

CoffeeFinanceEntry _entry(
  String id, {
  required CoffeeFinanceKind kind,
  String? plot,
  int? price,
  DateTime? settledAt,
  double? quantity,
  CoffeeFinancePriceMode priceMode = CoffeeFinancePriceMode.total,
  CoffeeFinanceFreightMode freightMode = CoffeeFinanceFreightMode.included,
  int? freight,
  CoffeeFinanceOriginKind? originKind,
  String? originId,
  String? analysisId,
}) =>
    CoffeeFinanceEntry(
      id: id,
      propertyId: 'farm',
      plotId: plot,
      seasonYear: 2026,
      date: _day,
      settledAt: settledAt,
      kind: kind,
      stage: CoffeeFinanceStage.management,
      category: 'Teste',
      description: 'Lançamento fictício $id',
      quantity: quantity,
      unit: quantity == null ? '' : 'kg',
      priceMode: priceMode,
      priceCents: price,
      freightMode: freightMode,
      freightCents: freight,
      originKind: originKind,
      originId: originId,
      analysisId: analysisId,
    );

Future<void> _createSale() async {
  await CoffeeHarvestRepository().saveProduction(CoffeePlotProduction(
    id: 'production',
    propertyId: 'farm',
    plotId: 'plot-a',
    date: _day,
    seasonYear: 2026,
    unit: CoffeeHarvestUnit.liters,
    quantity: 100,
  ));
  final processing = CoffeeProcessingRepository();
  await processing.saveLot(CoffeeLot(
    id: 'lot',
    propertyId: 'farm',
    seasonYear: 2026,
    code: 'L-001',
    date: _day,
    inputs: [
      CoffeeLotInput(
        id: 'source',
        kind: CoffeeLotSourceKind.picked,
        origin: CoffeeLotOrigin.confirmed,
        plotId: 'plot-a',
        harvestDate: _day,
        volumeLiters: 100,
        linkedLiters: 100,
      ),
    ],
  ));
  await processing.addCleaning(
    propertyId: 'farm',
    lotId: 'lot',
    cleaning: CoffeeLotCleaning(
      id: 'cleaning',
      date: _day,
      unit: CoffeeProcessedUnit.kilograms,
      quantity: 50,
    ),
  );
  await processing.addSale(
    propertyId: 'farm',
    lotId: 'lot',
    sale: CoffeeLotSale(
      id: 'sale',
      date: _sold,
      unit: CoffeeProcessedUnit.kilograms,
      quantity: 30,
      totalPriceCents: 80000,
    ),
  );
}

CoffeeSaleReceipt _receipt(String id, int amount, {DateTime? date}) =>
    CoffeeSaleReceipt(
      id: id,
      propertyId: 'farm',
      lotId: 'lot',
      saleId: 'sale',
      date: date ?? _paid,
      amountCents: amount,
    );

void main() {
  useCoffeeDatabase();

  test(
      'um laudo consulta a mesma despesa e o backup restaura vínculos e subtotais',
      () async {
    final analysis = CoffeeAnalysis(
      id: 'soil',
      propertyId: 'farm',
      plotId: 'plot-a',
      type: CoffeeAnalysisType.soil,
      collectedAt: _day,
      laboratory: 'Laboratório fictício',
      sampleId: 'Solo-A',
    );
    await CoffeeAnalysisRepository().save(analysis);
    final repository = CoffeeFinanceRepository();
    await repository.saveEntry(_entry('lab',
        kind: CoffeeFinanceKind.expense,
        plot: 'plot-a',
        price: 4200,
        analysisId: 'soil'));
    await expectLater(
        repository.saveEntry(_entry('wrong',
            kind: CoffeeFinanceKind.expense,
            plot: 'plot-b',
            price: 4200,
            analysisId: 'soil')),
        throwsFormatException);
    final withFreight = _entry('fertilizer',
        kind: CoffeeFinanceKind.purchase,
        plot: 'plot-a',
        price: 125000,
        quantity: 7,
        freightMode: CoffeeFinanceFreightMode.separate,
        freight: 3500);
    await repository.saveEntry(withFreight);
    expect(withFreight.totalCents, 128500);
    await repository.saveEntry(_entry('other',
        kind: CoffeeFinanceKind.expense, plot: 'plot-b', price: 60946));
    const check = CoffeeFinanceCheck(
        propertyId: 'farm',
        plotId: 'plot-b',
        seasonYear: 2026,
        stage: CoffeeFinanceStage.management,
        category: 'Teste',
        cents: 73988);
    final checks = CoffeeFinanceCheckRepository();
    await checks.save(check);
    final backup = LocalBackupService();
    final bytes = await backup.create();
    expect((jsonDecode(utf8.decode(bytes)) as Map)['schemaVersion'], 8);
    await backup.restore(bytes);
    await appDatabase.close();
    expect((await checks.get(check))?.cents, 73988);
    expect((await repository.expensesForAnalysis(analysis)).single.id, 'lab');
    final summary =
        await repository.summary(propertyId: 'farm', seasonYear: 2026);
    expect(summary.knownExpenseCents, 4200 + 128500 + 60946);
    expect(
        check.cents - summary.entries.where(check.matches).single.totalCents!,
        13042);
  });

  test('financeiro distingue competência, caixa e parcelas a receber',
      () async {
    final repo = CoffeeFinanceRepository();
    await _createSale();
    final receipt = _receipt('partial', 30000);
    await repo.saveReceipt(receipt);
    await repo.saveReceipt(receipt);
    for (final invalid in [
      _receipt('overpayment', 51000),
      _receipt('partial', 31000),
      _receipt('before-sale', 500, date: _day),
    ]) {
      await expectLater(repo.saveReceipt(invalid), throwsFormatException);
    }
    final purchase = _entry('purchase',
        kind: CoffeeFinanceKind.purchase,
        plot: 'plot-a',
        price: 1250,
        quantity: 10,
        priceMode: CoffeeFinancePriceMode.unit,
        freightMode: CoffeeFinanceFreightMode.separate,
        freight: 3000,
        settledAt: _day);
    expect(purchase.totalCents, 15500);
    await repo.saveEntry(purchase);
    await repo.saveEntry(purchase);
    await repo.saveEntry(_entry('service',
        kind: CoffeeFinanceKind.contractedService,
        price: 10000,
        settledAt: _paid));
    final missingFreight = _entry('unknown-freight',
        kind: CoffeeFinanceKind.purchase,
        price: 700,
        freightMode: CoffeeFinanceFreightMode.separate);
    expect(missingFreight.totalCents, isNull);
    await repo.saveEntry(missingFreight);
    await repo.saveEntry(_entry('income',
        kind: CoffeeFinanceKind.income, price: 4000, settledAt: _paid));
    await repo
        .saveEntry(_entry('unknown-income', kind: CoffeeFinanceKind.income));
    await expectLater(
        repo.saveEntry(_entry('wrong-plot',
            kind: CoffeeFinanceKind.purchase, plot: 'other-plot')),
        throwsFormatException);

    final harvest = CoffeeHarvestRepository();
    await harvest.saveEntry(CoffeeHarvestEntry(
      id: 'labor',
      propertyId: 'farm',
      plotId: 'plot-a',
      workerId: 'first',
      date: _day,
      seasonYear: 2026,
      unit: CoffeeHarvestUnit.measures,
      quantity: 2,
      ratePerMeasureCents: 3000,
    ));
    await harvest.savePayment(CoffeeHarvestPayment(
      id: 'advance',
      propertyId: 'farm',
      workerId: 'first',
      date: _day,
      seasonYear: 2026,
      kind: CoffeeHarvestPaymentKind.advance,
      amountCents: 2000,
    ));
    Future<CoffeeFinanceSummary> report(
            {DateTime? start, DateTime? end, String? plot}) =>
        repo.summary(
            propertyId: 'farm',
            seasonYear: 2026,
            start: start,
            end: end,
            plotId: plot);
    final all = await report();
    expect(all.entries, hasLength(5));
    expect(all.knownExpenseCents, 31500);
    expect(all.knownRevenueCents, 84000);
    expect(all.recognizedBalanceCents, 52500);
    expect(all.knownHarvestCostCents, 6000);
    expect(all.harvestCashPaidCents, 2000);
    expect(all.unknownExpenseCount, 1);
    expect(all.unknownRevenueCount, 1);
    expect(all.cashInCents, 34000);
    expect(all.cashOutCents, 27500);
    expect(all.cashBalanceCents, 6500);
    expect(all.outstandingSalesCents, 50000);
    expect(all.sales.single.receipts, hasLength(1));
    expect(all.sales.single.plotId, 'plot-a');
    final throughDecember = await report(end: DateTime(2026, 12, 31));
    expect(throughDecember.knownRevenueCents, 84000);
    expect(throughDecember.cashInCents, 0);
    expect(throughDecember.cashOutCents, 17500);
    expect(throughDecember.outstandingSalesCents, 80000);
    final january = await report(start: DateTime(2027, 1, 1), end: _paid);
    expect(january.entries, isEmpty);
    expect(january.knownRevenueCents, 0);
    expect(january.cashInCents, 34000);
    expect(january.cashOutCents, 10000);
    expect(january.outstandingSalesCents, 50000);
    final plot = await report(plot: 'plot-a');
    expect(plot.knownExpenseCents, 21500);
    expect(plot.knownRevenueCents, 80000);
    expect(plot.harvestCashPaidCents, 0);
    expect((await report(plot: 'plot-b')).entries, isEmpty);
  });

  test('custo de origem existente só pode entrar uma vez no financeiro',
      () async {
    final repo = CoffeeFinanceRepository();
    final maintenance = MaintenanceRepository();
    await maintenance.saveAll([
      MaintenanceRecord(
        id: 'maintenance',
        machineId: 'machine',
        machineName: 'Trator teste',
        date: _day,
        hourMeter: 10,
        type: 'Revisão',
        description: '',
        parts: '',
        cost: 12.5,
        intervalHours: 50,
      ),
    ], previous: []);
    final source =
        (await repo.legacySources(kind: CoffeeFinanceOriginKind.maintenance))
            .single;
    expect(source.amountCents, 1250);
    CoffeeFinanceEntry linked(String id, int amount) => _entry(id,
        kind: CoffeeFinanceKind.expense,
        price: amount,
        originKind: CoffeeFinanceOriginKind.maintenance,
        originId: source.id);
    await expectLater(
        repo.saveEntry(linked('wrong', 1249)), throwsFormatException);
    await repo.saveEntry(linked('first', 1250));
    await expectLater(
        repo.saveEntry(linked('second', 1250)), throwsFormatException);
    expect(await repo.legacySources(kind: CoffeeFinanceOriginKind.maintenance),
        isEmpty);
    expect(
        (await repo.summary(propertyId: 'farm', seasonYear: 2026))
            .knownExpenseCents,
        1250);
  });

  test('nota em PDF e recebimento continuam válidos após restauração',
      () async {
    final repo = CoffeeFinanceRepository();
    await _createSale();
    await repo.saveReceipt(_receipt('partial', 30000));
    final pdf = await buildAnalysisPdf();
    await repo.saveEntry(
      _entry('receipt-pdf', kind: CoffeeFinanceKind.purchase, price: 700),
      pickedPdf: pdf,
      pickedPdfName: 'nota.pdf',
    );
    Future<List<CoffeeFinanceEntry>> entries() =>
        repo.entries(propertyId: 'farm', seasonYear: 2026);
    final before = (await entries()).single;
    final file = File(before.pdfPath!);
    expect(await readCoffeeAnalysisPdf(file), pdf);
    final backup = LocalBackupService();
    final bytes = await backup.create();
    expect(jsonDecode(utf8.decode(bytes))['schemaVersion'], 6);
    final db = (await CatalogStore.open()).db;
    for (final table in ['local_records', 'local_audit']) {
      await db.delete(table,
          where: 'module IN (?, ?)',
          whereArgs: ['coffeeFinanceEntries', 'coffeeSaleReceipts']);
    }
    await file.delete();
    await appDatabase.close();
    expect(await entries(), isEmpty);
    await backup.restore(bytes);
    final restored = (await entries()).single;
    expect(restored.totalCents, 700);
    expect(await readCoffeeAnalysisPdf(File(restored.pdfPath!)), pdf);
    final sale =
        (await repo.sales(propertyId: 'farm', seasonYear: 2026)).single;
    expect(sale.receivedCents, 30000);
    expect(sale.outstandingCents, 50000);
  });

  testWidgets('compra sem baixa aparece como despesa no Financeiro em 320 px',
      (tester) async {
    tester.view.physicalSize = const Size(320, 860);
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

    Future<void> tap(Finder finder, {bool scroll = false}) async {
      if (scroll && finder.evaluate().isEmpty) {
        await tester.scrollUntilVisible(finder, 220,
            scrollable: find
                .descendant(
                    of: find.byType(ListView).last,
                    matching: find.byType(Scrollable))
                .first);
      }
      await waitFor(finder);
      await tester.ensureVisible(finder);
      if (scroll) {
        for (var i = 0; i < 8 && finder.hitTestable().evaluate().isEmpty; i++) {
          await tester.drag(find.byType(ListView).last, const Offset(0, -220));
          await tester.pump(const Duration(milliseconds: 350));
        }
      }
      await tester.tap(finder.hitTestable());
      await tester.pump(const Duration(milliseconds: 350));
    }

    Future<void> enter(String label, String value) async {
      final field = find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == label,
          description: 'campo $label');
      await waitFor(field);
      await tester.ensureVisible(field);
      await tester.enterText(field, value);
      await tester.pump();
    }

    try {
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: CoffeeFinanceScreen())));
      await tap(find.byWidgetPredicate((widget) =>
          widget is InputDecorator &&
          widget.decoration.labelText == 'Fazenda'));
      await waitFor(find.text('Fazenda teste'));
      await tap(find.text('Fazenda teste').last);
      await tap(find.text('Novo lançamento'));
      await enter('Categoria', 'Insumos');
      await enter('Descrição', 'Compra fictícia');
      await enter('Preço total (R\$)', '120,50');
      await tap(find.text('Salvar lançamento'), scroll: true);
      await waitFor(find.text('Despesas por etapa e categoria'));
      await tap(find.text('Manejo'), scroll: true);
      await tap(find.text('Insumos'), scroll: true);
      final category = find.byWidgetPredicate(
        (widget) =>
            widget is ExpansionTile &&
            widget.title is Text &&
            (widget.title as Text).data == 'Insumos',
      );
      expect(
          find.descendant(
            of: category,
            matching: find.text('Compra fictícia'),
          ),
          findsOneWidget);
      expect(
          find.descendant(
            of: category,
            matching: find.textContaining('120,50'),
          ),
          findsWidgets);
      final summary = await tester.runAsync(() => CoffeeFinanceRepository()
          .summary(propertyId: 'farm', seasonYear: DateTime.now().year));
      expect(summary!.entries.single.description, 'Compra fictícia');
      expect(summary.knownExpenseCents, 12050);
      expect(summary.cashOutCents, 0);
      await tap(find.text('Conferir subtotal do caderno'), scroll: true);
      await tap(find.byWidgetPredicate((widget) =>
          widget is InputDecorator &&
          widget.decoration.labelText == 'Etapa e categoria'));
      await tap(find.text('Manejo · Insumos').last);
      await waitFor(find.byWidgetPredicate((widget) =>
          widget is TextField &&
          widget.enabled == true &&
          widget.decoration?.labelText == 'Subtotal anotado (R\$)'));
      await enter('Subtotal anotado (R\$)', '250,92');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump(const Duration(milliseconds: 350));
      await tap(find.text('Salvar subtotal'));
      await waitFor(find.textContaining('130,42'));
      await tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Compra fictícia'),
      ));
      await waitFor(find.text('Lançamento financeiro'));

      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
