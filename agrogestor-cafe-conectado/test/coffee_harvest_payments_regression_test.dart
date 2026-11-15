import 'package:agrogestao/features/coffee_finance/coffee_finance_repository.dart';
import 'package:agrogestao/features/coffee_finance/coffee_finance_screen.dart';
import 'package:agrogestao/features/harvest/coffee_harvest_repository.dart';
import 'package:agrogestao/features/harvest/coffee_harvest_screen.dart';
import 'package:agrogestao/features/reports/reports_screen.dart';
import 'package:agrogestao/features/sync/app_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'coffee_notebook_harvest_test.dart' show useCoffeeDatabase;

final _day = DateUtils.dateOnly(DateTime.now());
final _harvestDate = DateTime(_day.year, 1, 1);
final _year = _day.year;

CoffeeHarvestPayment _payment(
  String id,
  CoffeeHarvestPaymentKind kind,
  int cents, {
  String farm = 'farm',
  int? season,
}) =>
    CoffeeHarvestPayment(
      id: id,
      propertyId: farm,
      workerId: 'first',
      date: _day,
      seasonYear: season ?? _year,
      kind: kind,
      amountCents: cents,
      notes: id,
    );

Future<void> _savedBeforeUpdate(
    {bool otherScopes = true, bool includePayment = true}) async {
  final repo = CoffeeHarvestRepository();
  await repo.saveEntry(CoffeeHarvestEntry(
    id: 'harvest-legacy',
    propertyId: 'farm',
    plotId: 'plot-a',
    workerId: 'first',
    date: _harvestDate,
    seasonYear: _year,
    unit: CoffeeHarvestUnit.measures,
    quantity: 10,
    ratePerMeasureCents: 3000,
  ));
  await repo.savePayment(
      _payment('Vale anterior', CoffeeHarvestPaymentKind.advance, 10000));
  if (includePayment) {
    await repo.savePayment(
        _payment('Quitação anterior', CoffeeHarvestPaymentKind.payment, 5000));
  }
  if (otherScopes) {
    await repo.savePayment(_payment(
        'Outra fazenda', CoffeeHarvestPaymentKind.payment, 9900,
        farm: 'other-farm'));
    await repo.savePayment(_payment(
        'Outra safra', CoffeeHarvestPaymentKind.payment, 8800,
        season: _year - 1));
  }
  await appDatabase.close();
}

class _Screen {
  _Screen(this.tester) {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  final WidgetTester tester;

  Future<void> waitFor(Finder finder) async {
    for (var i = 0; i < 140 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsWidgets);
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> tap(Finder finder, {bool scroll = false}) async {
    if (scroll && finder.evaluate().isEmpty) {
      final page = find.byType(ListView).last;
      await tester.scrollUntilVisible(finder, 260,
          scrollable: find
              .descendant(of: page, matching: find.byType(Scrollable))
              .first);
    }
    await waitFor(finder);
    await tester.ensureVisible(finder);
    await tester.tap(finder);
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

  Future<void> close() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  }
}

Finder _moneyLabel(String label, String amount) => find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          (widget.data?.startsWith(label) ?? false) &&
          (widget.data?.contains(amount) ?? false),
      description: '$label com $amount',
    );

Finder get _farmMenu => find.byWidgetPredicate((widget) =>
    widget is InputDecorator && widget.decoration.labelText == 'Fazenda');

void main() {
  useCoffeeDatabase();

  test('vale e pagamento anteriores persistem e entram uma vez no caixa',
      () async {
    await _savedBeforeUpdate();
    final person = await CoffeeHarvestRepository()
        .summary(propertyId: 'farm', seasonYear: _year, workerId: 'first');
    expect(person.earnedCents, 30000);
    expect(person.advancesCents, 10000);
    expect(person.paymentsCents, 5000);
    expect(person.balanceCents, 15000);
    expect(person.payments, hasLength(2));
    final repo = CoffeeFinanceRepository();
    Future<CoffeeFinanceSummary> report(
            {String farm = 'farm',
            int? season,
            DateTime? start,
            DateTime? end}) =>
        repo.summary(
            propertyId: farm,
            seasonYear: season ?? _year,
            start: start,
            end: end);
    final all = await report();
    expect(all.knownHarvestCostCents, 30000);
    expect(all.harvestCashPaidCents, 15000);
    expect(all.cashOutCents, 15000);
    expect(all.harvestAdvanceCents, 10000);
    expect(all.harvestPaymentCents, 5000);
    expect(all.harvestPayments.map((entry) => entry.id),
        unorderedEquals(['Vale anterior', 'Quitação anterior']));
    final onePlot = await repo.summary(
        propertyId: 'farm', seasonYear: _year, plotId: 'plot-a');
    expect(onePlot.knownHarvestCostCents, 30000);
    expect(onePlot.cashOutCents, 0);
    expect(onePlot.hasUnallocatedHarvestPayments, isTrue);
    expect((await report(start: _day, end: _day)).cashOutCents, 15000);
    expect(
        (await report(end: _day.subtract(const Duration(days: 1))))
            .cashOutCents,
        0);
    expect((await report(farm: 'other-farm')).cashOutCents, 9900);
    expect((await report(season: _year - 1)).cashOutCents, 8800);
  });

  testWidgets('Colheita registra pagamento, e ficha e Financeiro o exibem',
      (tester) async {
    final screen = _Screen(tester);
    await tester.runAsync(
        () => _savedBeforeUpdate(otherScopes: false, includePayment: false));
    try {
      await tester.pumpWidget(const MaterialApp(
          home: CoffeeHarvestScreen(
        property: {'id': 'farm', 'name': 'Fazenda teste'},
        plot: {'id': 'plot-a', 'name': 'Talhão A', 'area_ha': 2},
      )));
      await screen.waitFor(find.text('Conferência com o caderno'));
      await screen.tap(find.text('Registrar vale ou pagamento'));
      await screen.tap(find.byType(DropdownButtonFormField<String>));
      await screen.waitFor(find.text('Ana Teste'));
      await screen.tap(find.text('Ana Teste').last);
      await screen
          .tap(find.byType(DropdownButtonFormField<CoffeeHarvestPaymentKind>));
      await screen.waitFor(find.text('Pagamento'));
      await screen.tap(find.text('Pagamento').last);
      await screen.enter('Valor (R\$)', '50');
      await screen.enter('Observações', 'Pagamento lançado pela Colheita');
      await screen.tap(find.text('Salvar'));
      await screen.waitFor(find.ancestor(
        of: find.text('Registrar colheita'),
        matching: find.byWidgetPredicate(
            (widget) => widget is FilledButton && widget.onPressed != null),
      ));
      await screen.waitFor(find.text('Conferência com o caderno'));
      final stored = await tester.runAsync(() => CoffeeHarvestRepository()
          .payments(propertyId: 'farm', seasonYear: _year, workerId: 'first'));
      expect(stored, hasLength(2));
      expect(
          stored!
              .singleWhere(
                  (item) => item.notes == 'Pagamento lançado pela Colheita')
              .kind,
          CoffeeHarvestPaymentKind.payment);
      final person = find.ancestor(
          of: find.textContaining('Acumulado na fazenda'),
          matching: find.byType(ListTile));
      await screen.tap(person, scroll: true);
      await screen.waitFor(find.text('Resumo individual'));
      await screen.waitFor(_moneyLabel('Saldo a pagar:', '150,00'));
      await screen.waitFor(find.textContaining('Vale anterior'));
      await screen
          .waitFor(find.textContaining('Pagamento lançado pela Colheita'));
      await tester.pumpWidget(const MaterialApp(
        key: ValueKey('finance'),
        home: Scaffold(body: CoffeeFinanceScreen()),
      ));
      await screen.tap(_farmMenu);
      await screen.waitFor(find.text('Fazenda teste'));
      await screen.tap(find.text('Fazenda teste').last);
      await screen
          .waitFor(_moneyLabel('Vales e pagamentos da colheita:', '150,00'));
      expect(_moneyLabel('Saídas:', '150,00'), findsOneWidget);
      await screen.tap(find.text('Consultar pagamentos da colheita'),
          scroll: true);
      await screen.waitFor(find.text('Pagamentos da colheita'));
      await screen.tap(find.textContaining(RegExp(r'^Pagamento ·.*50,00')));
      await screen.waitFor(find.text('Lançamento de colheita'));
      await screen.waitFor(find.text('Pagamento lançado pela Colheita'));
      await screen.tap(find.text('Abrir ficha do funcionário'));
      await screen.waitFor(_moneyLabel('Saldo a pagar:', '150,00'));
      expect(tester.takeException(), isNull);
    } finally {
      await screen.close();
    }
  });

  testWidgets('Relatórios inclui a saída da colheita já registrada',
      (tester) async {
    final screen = _Screen(tester);
    await tester.runAsync(_savedBeforeUpdate);
    try {
      await tester.pumpWidget(const MaterialApp(home: ReportsScreen()));
      await screen.waitFor(find.text('Relatórios'));
      await screen.waitFor(find.text('Despesas de colheita'));
      Future<void> selectFarm(String name) async {
        await screen.tap(_farmMenu);
        await screen.waitFor(find.text(name));
        await screen.tap(find.text(name).last);
      }

      await selectFarm('Fazenda teste');
      await screen.waitFor(_moneyLabel('Pago no período:', '150,00'));
      await screen.tap(find.text('Consultar pagamentos da colheita'));
      await screen.waitFor(find.text('Pagamentos da colheita'));
      await screen.tap(find.textContaining(RegExp(r'^Adiantamento ·.*100,00')));
      await screen.waitFor(find.text('Lançamento de colheita'));
      await screen.waitFor(find.text('Vale anterior'));
      await screen.tap(find.byType(BackButton));
      await screen.tap(find.byType(BackButton));
      await selectFarm('Outra fazenda');
      await screen.waitFor(_moneyLabel('Pago no período:', '99,00'));
      await selectFarm('Fazenda teste');
      await screen.enter('Ano da safra', '${_year - 1}');
      await screen.tap(find.text('Ver safra'));
      await screen.waitFor(_moneyLabel('Pago no período:', '88,00'));
      expect(tester.takeException(), isNull);
    } finally {
      await screen.close();
    }
  });
}
