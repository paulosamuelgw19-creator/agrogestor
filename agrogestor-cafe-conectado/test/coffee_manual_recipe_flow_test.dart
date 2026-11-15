import 'package:agrogestao/features/coffee_finance/coffee_finance_repository.dart';
import 'package:agrogestao/features/local_backup/local_backup_service.dart';
import 'package:agrogestao/features/machines/machine.dart';
import 'package:agrogestao/features/machines/machine_repository.dart';
import 'package:agrogestao/features/operators/operator.dart';
import 'package:agrogestao/features/operators/operator_repository.dart';
import 'package:agrogestao/features/products/product_record.dart';
import 'package:agrogestao/features/products/product_repository.dart';
import 'package:agrogestao/features/services/coffee_manual_labor_repository.dart';
import 'package:agrogestao/features/services/farm_service.dart';
import 'package:agrogestao/features/services/local_operation_actions.dart';
import 'package:agrogestao/features/services/service_repository.dart';
import 'package:agrogestao/features/services/services_screen.dart';
import 'package:agrogestao/features/sync/app_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'coffee_notebook_harvest_test.dart' show useCoffeeDatabase;

class _Screen {
  _Screen(this.tester) {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  final WidgetTester tester;

  Future<void> wait(Finder finder) async {
    for (var i = 0; i < 170 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsWidgets);
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> tap(Finder finder) async {
    await wait(finder);
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 350));
  }

  Finder field(String label) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
      description: 'campo $label');

  Future<void> enter(String label, String value) async {
    final input = field(label);
    await wait(input);
    await tester.ensureVisible(input);
    await tester.enterText(input, value);
    await tester.pump();
  }

  Future<void> choose(String label, String value) async {
    await tap(find.byWidgetPredicate((widget) =>
        widget is InputDecorator && widget.decoration.labelText == label));
    await wait(find.text(value));
    await tap(find.text(value).last);
  }

  Future<void> close() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  }
}

const _scope = ServicesScreen(
    propertyId: 'farm',
    fieldId: 'plot-a',
    plotArea: 2,
    locationLabel: 'Fazenda teste · Talhão A');

void main() {
  useCoffeeDatabase();

  test(r'diária muda de R$100 para R$120 sem alterar a jornada anterior',
      () async {
    final first =
        DateUtils.dateOnly(DateTime.now()).subtract(const Duration(days: 3));
    final second = first.add(const Duration(days: 1));
    final operators = OperatorRepository();
    Future<void> setRate(int cents) async {
      final old = await operators.getAll();
      await operators.saveAll([
        for (final item in old)
          if (item.id == 'first')
            Operator.fromJson({...item.toJson(), 'dailyRateCents': cents})
          else
            item,
      ], previous: old);
    }

    await setRate(10000);
    final service = FarmService(
      id: 'manual',
      machineId: '',
      machineName: '',
      operatorName: '',
      customer: '',
      property: 'Fazenda teste',
      propertyId: 'farm',
      fieldName: 'Talhão A',
      fieldId: 'plot-a',
      jobType: 'Capina',
      startedAt: first,
      startMeter: null,
      isManual: true,
      people: 1,
      manualWorkers: const [
        ServiceWorkerRate(
            workerId: 'first', workerName: 'Ana Teste', dailyRateCents: 10000),
      ],
    );
    await LocalOperationActions.validateManualWorkers(service);
    final services = ServiceRepository();
    await services.saveAll([service], previous: []);
    await LocalOperationActions.pause(service, ServiceDay(date: first));
    final paused = (await services.getAll()).single;
    await setRate(12000);
    await LocalOperationActions.resume(paused, second);
    final resumed = (await services.getAll()).single;
    expect(resumed.days.single.manualWorkers.single.dailyRateCents, 10000);
    expect(resumed.manualWorkers.single.dailyRateCents, 12000);
    await LocalOperationActions.finish(resumed, [],
        day: ServiceDay(date: second));
    final labor = CoffeeManualLaborRepository();
    Future<CoffeeManualLaborSummary> summary() =>
        labor.summary(workerId: 'first', propertyId: 'farm');
    await appDatabase.close();
    expect((await summary()).days.map((day) => day.dailyRateCents),
        unorderedEquals([10000, 12000]));
    expect((await summary()).dueCents, 22000);
    final advance = CoffeeManualLaborPayment(
        id: 'manual-advance',
        propertyId: 'farm',
        workerId: 'first',
        date: second,
        kind: CoffeeManualLaborPaymentKind.advance,
        amountCents: 2000);
    await labor.savePayment(advance);
    await labor.savePayment(advance);
    await labor.savePayment(CoffeeManualLaborPayment(
        id: 'manual-payment',
        propertyId: 'farm',
        workerId: 'first',
        date: second,
        kind: CoffeeManualLaborPaymentKind.payment,
        amountCents: 5000));
    final backup = LocalBackupService();
    await backup.restore(await backup.create());
    final restored = await summary();
    expect(restored.dueCents, 22000);
    expect(restored.advancesCents, 2000);
    expect(restored.paymentsCents, 5000);
    expect(restored.balanceCents, 15000);
    expect(restored.payments, hasLength(2));
  });

  testWidgets('tratorizado guarda duas doses e baixa só os consumos reais',
      (tester) async {
    final flow = _Screen(tester);
    final products = ProductRepository();
    await tester.runAsync(() async {
      await MachineRepository().saveAll([
        const Machine(
            id: 'tractor',
            name: 'Trator Teste',
            brand: 'Marca',
            model: 'Modelo',
            year: 2020,
            hourMeter: 100,
            fuelType: 'Diesel',
            status: MachineStatus.disponivel),
      ], previous: []);
      await products.saveProducts([
        const FarmProduct(
            id: 'existing',
            name: 'Adjuvante Teste',
            category: 'Insumos',
            unit: 'kg',
            quantity: 10,
            lot: ''),
      ], previous: []);
    });
    try {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: _scope)));
      await flow.tap(find.byType(FloatingActionButton));
      await flow.wait(find.text('Serviço tratorizado'));
      await flow.choose('Operador (opcional)', 'Ana Teste');
      await flow.enter('Horímetro inicial', '101');
      await flow.tap(find.text('Adicionar tipo de serviço'));
      await flow.enter('Tipo de serviço', 'Aplicação Teste');
      await flow.wait(find.text('Receita da aplicação'));
      await flow.tap(find.text('Planejar insumo'));
      await flow.tap(find.text('Cadastrar produto'));
      await flow.enter('Produto', 'Insumo novo teste');
      await flow.choose('Categoria', 'Químicos e minerais');
      await flow.choose('Tipo de produto', 'Herbicidas');
      await flow.enter('Estoque atual', '5');
      await flow.enter('Valor pago (R\$, opcional)', '30');
      await flow.tap(find.text('Salvar'));
      await flow.enter('Quantidade por dose (L)', '0,2');
      await flow.enter('Referência da dose', 'Tanque');
      await flow.enter('Quantidade total planejada (L)', '1');
      await flow.tap(find.text('Salvar insumo'));
      expect(
          tester
              .widget<TextField>(flow.field('Horímetro inicial'))
              .controller!
              .text,
          '101');
      expect(
          tester
              .widget<TextField>(flow.field('Tipo de serviço'))
              .controller!
              .text,
          'Aplicação Teste');
      await flow.tap(find.text('Planejar insumo'));
      await flow.enter('Buscar produto pelo começo do nome', 'Adj');
      await flow.tap(find.widgetWithText(ListTile, 'Adjuvante Teste'));
      await flow.enter('Quantidade por dose (kg)', '0,5');
      await flow.enter('Referência da dose', 'Hectare');
      await flow.enter('Quantidade total planejada (kg)', '2');
      await flow.tap(find.text('Salvar insumo'));
      await flow.tap(find.text('Iniciar'));
      await flow.tap(find.text('Finalizar'));
      await flow.enter('Horímetro final', '103');
      await flow.enter('Quantidade utilizada (L)', '0,8');
      await flow.enter('Quantidade utilizada (kg)', '1,5');
      await flow.tap(find.text('Concluir'));
      await flow.tap(find.text('Ver insumos usados'));
      await tester.runAsync(() async {
        final service = (await ServiceRepository().getAll()).single;
        expect(service.isFinished, isTrue);
        expect(service.startMeter, 101);
        expect(service.endMeter, 103);
        expect(service.jobType, 'Aplicação Teste');
        expect(service.operatorName, 'Ana Teste');
        expect(service.propertyId, 'farm');
        expect(service.fieldId, 'plot-a');
        expect(service.plannedInputs.map((plan) => plan.doseQuantity),
            unorderedEquals([.2, .5]));
        expect(service.plannedInputs.map((plan) => plan.doseReference),
            unorderedEquals(['Tanque', 'Hectare']));
        final balances = {
          for (final item in await products.getProducts()) item.name: item
        };
        expect(balances['Insumo novo teste']!.quantity, closeTo(4.2, 1e-10));
        expect(balances['Adjuvante Teste']!.quantity, 8.5);
        expect((await products.getUsage()).map((usage) => usage.quantity),
            unorderedEquals([.8, 1.5]));
        expect(
            (await CoffeeFinanceRepository()
                    .productPurchases(balances['Insumo novo teste']!.id))
                .single
                .totalCents,
            3000);
      });
      expect(tester.takeException(), isNull);
    } finally {
      await flow.close();
    }
  });

  testWidgets('serviço manual permite ajustar a diária só naquela jornada',
      (tester) async {
    final flow = _Screen(tester);
    final operators = OperatorRepository();
    await tester.runAsync(() async {
      final old = await operators.getAll();
      await operators.saveAll([
        for (final item in old)
          if (item.id == 'first')
            Operator.fromJson({...item.toJson(), 'dailyRateCents': 10000})
          else
            item,
      ], previous: old);
    });
    try {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: _scope)));
      await flow.tap(find.byType(FloatingActionButton));
      await flow.tap(find.text('Selecionar pessoas'));
      await flow.tap(find.widgetWithText(CheckboxListTile, 'Ana Teste'));
      final dailyRate = flow.field('Diária (R\$)');
      await flow.wait(dailyRate);
      final prefilled = tester.widget<TextField>(dailyRate).controller!.text;
      expect(double.parse(prefilled.replaceAll(',', '.')), 100);
      await flow.enter('Diária (R\$)', '110');
      await flow.tap(find.text('Confirmar pessoas'));
      expect(flow.field('Horímetro inicial'), findsNothing);
      await flow.tap(find.text('Iniciar'));
      await flow.tap(find.text('Finalizar'));
      await flow.tap(find.text('Concluir'));
      await flow.wait(find.textContaining('Concluída em'));
      await tester.runAsync(() async {
        final labor =
            await CoffeeManualLaborRepository().summary(workerId: 'first');
        expect(labor.days.single.dailyRateCents, 11000);
        expect(labor.dueCents, 11000);
        expect(
            (await operators.getAll())
                .singleWhere((item) => item.id == 'first')
                .dailyRateCents,
            10000);
      });
      expect(tester.takeException(), isNull);
    } finally {
      await flow.close();
    }
  });
}
