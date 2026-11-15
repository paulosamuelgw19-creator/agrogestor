import 'dart:convert';

import 'package:agrogestao/features/harvest/coffee_harvest_repository.dart';
import 'package:agrogestao/features/machines/machine.dart';
import 'package:agrogestao/features/machines/machine_repository.dart';
import 'package:agrogestao/features/maintenance/maintenance_repository.dart';
import 'package:agrogestao/features/maintenance/maintenance_record.dart';
import 'package:agrogestao/features/maintenance/maintenance_screen.dart';
import 'package:agrogestao/features/products/product_record.dart';
import 'package:agrogestao/features/products/product_repository.dart';
import 'package:agrogestao/features/properties/plot_notebook_repository.dart';
import 'package:agrogestao/features/properties/plot_notebook_screen.dart';
import 'package:agrogestao/features/services/coffee_input_plan.dart';
import 'package:agrogestao/features/services/farm_service.dart';
import 'package:agrogestao/features/services/service_repository.dart';
import 'package:agrogestao/features/shell/app_shell.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'coffee_notebook_harvest_test.dart' show useCoffeeDatabase;

class _Flow {
  _Flow(this.tester) {
    tester.view.physicalSize = const Size(390, 1260);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  final WidgetTester tester;

  Future<void> waitFor(Finder finder) async {
    for (var attempt = 0;
        attempt < 180 && finder.evaluate().isEmpty;
        attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsWidgets);
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> tap(Finder finder) async {
    await waitFor(finder);
    await tester.ensureVisible(finder);
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> enter(String label, String value) async {
    final field = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
      description: 'campo $label',
    );
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

const _notebook = PlotNotebookScreen(
  property: {'id': 'farm', 'name': 'Fazenda teste'},
  plot: {'id': 'plot-a', 'name': 'Talhão A', 'area_ha': 2},
);

const _product = FarmProduct(
  id: 'spray',
  name: 'Insumo fictício',
  category: 'Insumos',
  unit: 'L',
  quantity: 5,
  lot: '',
);

const _oldPlan = CoffeeInputPlan(
  productId: 'spray',
  productName: 'Insumo fictício',
  stockUnit: 'L',
  kind: CoffeeInputKind.spray,
  inputUnit: 'L',
  quantity: 1,
  appliedLiters: 80,
  coveredHectares: 2,
);

FarmService _service(String id, String job,
    {String farm = 'farm',
    String plot = 'plot-a',
    bool finished = false,
    bool paused = false}) {
  final priorDate = DateTime.now().subtract(const Duration(days: 12));
  return FarmService(
    id: id,
    machineId: '',
    machineName: '',
    operatorName: '',
    customer: '',
    property: 'Fazenda teste',
    propertyId: farm,
    fieldName: plot == 'plot-b' ? 'Talhão B' : 'Talhão A',
    fieldId: plot,
    jobType: job,
    startedAt: priorDate,
    startMeter: null,
    endedAt: finished ? priorDate : null,
    areaHectares: finished ? 2 : null,
    isManual: true,
    people: 1,
    isPaused: paused,
    days: paused ? [ServiceDay(date: priorDate, areaHectares: .5)] : const [],
    plannedInputs: finished ? [_oldPlan] : const [],
    appliedSprayInputs: finished ? [_oldPlan] : const [],
  );
}

void main() {
  useCoffeeDatabase();

  testWidgets('Início abre o serviço pausado e mantém revisão de outro tipo',
      (tester) async {
    final flow = _Flow(tester);
    await tester.runAsync(() async {
      await ServiceRepository().saveAll([
        _service('paused', 'Operação pausada de teste', paused: true),
      ], previous: []);
      const machine = Machine(
        id: 'dashboard-tractor',
        name: 'Trator de teste',
        fuelType: 'Diesel',
        status: MachineStatus.disponivel,
        brand: '',
        model: '',
        year: 2020,
        hourMeter: 100,
      );
      await MachineRepository().saveAll([machine], previous: []);
      final now = DateTime.now();
      MaintenanceRecord record(String id, String type, DateTime date,
              {DateTime? due}) =>
          MaintenanceRecord(
            id: id,
            machineId: machine.id,
            machineName: machine.name,
            date: date,
            hourMeter: 100,
            type: type,
            description: '',
            parts: '',
            cost: null,
            intervalHours: null,
            nextDueDate: due,
          );
      await MaintenanceRepository().saveAll([
        record('oil', 'Troca de óleo', now.subtract(const Duration(days: 10)),
            due: now.add(const Duration(days: 2))),
        record('repair', 'Reparo', now, due: now.add(const Duration(days: 90))),
      ], previous: []);
    });
    try {
      await tester.pumpWidget(const MaterialApp(home: AppShell()));
      await flow.waitFor(find.text('Serviços abertos'));
      expect(find.textContaining('Talhão A · Pausado'), findsOneWidget);
      expect(find.textContaining('Troca de óleo · prazo'), findsOneWidget);
      expect(find.textContaining('h em curso'), findsNothing);
      await flow.tap(find.byTooltip('Continuar serviço'));
      await flow.waitFor(find.text('Continuar'));
    } finally {
      await flow.close();
    }
  });

  testWidgets('caderno cria e reabre pendência e retoma o serviço escolhido',
      (tester) async {
    final flow = _Flow(tester);
    await tester.runAsync(() => ServiceRepository().saveAll([
          _service('paused', 'Serviço para retomar', paused: true),
          _service('different', 'Outro serviço em curso'),
        ], previous: []));
    try {
      await tester.pumpWidget(const MaterialApp(home: AppShell()));
      await flow.tap(find.descendant(
          of: find.byType(NavigationBar), matching: find.text('Propriedades')));
      await flow.tap(find.widgetWithText(ListTile, 'Fazenda teste'));
      final openPlot = find.text('Abrir talhão');
      await flow.waitFor(openPlot);
      await flow.tap(openPlot.first);
      await flow.waitFor(find.byType(PlotNotebookScreen));
      await flow.tap(find.text('Adicionar nota ou pendência'));
      await flow.tap(find.byType(DropdownButtonFormField<PlotNoteStatus>));
      await flow.tap(find.text('Pendência').last);
      await flow.enter('Anotação', 'Conferir a cerca');
      await flow.tap(find.text('Salvar'));
      await flow.waitFor(find.text('Conferir a cerca'));
      await flow.tap(find.text('Concluir pendência'));
      await flow.tap(find.text('Reabrir pendência'));
      await flow.waitFor(find.text('Concluir pendência'));
      await flow.tap(find.text('Continuar serviço'));
      await flow.waitFor(find.text('Serviço para retomar'));
      expect(find.text('Outro serviço em curso'), findsNothing);
      await flow.tap(find.text('Continuar'));
      await flow.tap(find.text('OK'));
      await flow.waitFor(find.text('Finalizar'));
      final services =
          await tester.runAsync(() => ServiceRepository().getAll());
      final resumed = services!.singleWhere((item) => item.id == 'paused');
      expect(resumed.isPaused, isFalse);
      expect(resumed.days.single.areaHectares, .5);
      expect(resumed.resumedAt, isNotNull);
      expect(tester.takeException(), isNull);
    } finally {
      await flow.close();
    }
  });

  testWidgets('cópia usa o talhão de destino e exige rever insumos',
      (tester) async {
    final flow = _Flow(tester);
    final old = _service('old', 'Pulverização', plot: 'plot-b', finished: true);
    await tester.runAsync(() async {
      await ProductRepository().saveProducts([_product], previous: []);
      await ServiceRepository().saveAll([
        old,
        _service('foreign', 'Serviço de outra fazenda',
            farm: 'other-farm', plot: 'other-plot', finished: true),
      ], previous: []);
    });
    try {
      await tester.pumpWidget(const MaterialApp(home: _notebook));
      await flow.tap(find.text('Operações deste talhão'));
      await flow.tap(find.text('Copiar serviço anterior'));
      expect(find.text('Serviço de outra fazenda'), findsNothing);
      await flow.tap(find.widgetWithText(ListTile, 'Pulverização'));
      await flow.waitFor(find.text('Fazenda teste · Talhão A'));
      await flow.tap(find.text('Iniciar'));
      await flow
          .waitFor(find.textContaining('Revise ou remova cada insumo copiado'));
      await flow.tap(find.text('Conferi o planejamento para este talhão'));
      await flow.tap(find.text('Iniciar'));
      await flow
          .waitFor(find.textContaining('Revise ou remova cada insumo copiado'));
      await flow.tap(find.text('Editar'));
      await flow.enter('Quantidade total planejada (L)', '0,5');
      await flow.tap(find.text('Salvar insumo'));
      await flow.tap(find.text('Conferi o planejamento para este talhão'));
      await flow.tap(find.text('Iniciar'));
      await flow.waitFor(find.text('Finalizar'));
      await tester.runAsync(() async {
        final services = await ServiceRepository().getAll();
        final copy = services.singleWhere((item) => item.fieldId == 'plot-a');
        expect(copy.propertyId, 'farm');
        expect(copy.jobType, old.jobType);
        expect(copy.id, isNot(old.id));
        expect(copy.startedAt.isAfter(old.startedAt), isTrue);
        expect(copy.endedAt, isNull);
        expect(copy.startMeter, isNull);
        expect(copy.endMeter, isNull);
        expect(copy.areaHectares, isNull);
        expect(copy.days, isEmpty);
        expect(copy.appliedSprayInputs, isEmpty);
        expect(copy.plannedInputs.single.quantity, .5);
        expect(copy.plannedInputs.single.appliedLiters, isNull);
        final products = ProductRepository();
        expect((await products.getProducts()).single.quantity, 5);
        expect(await products.getUsage(), isEmpty);
      });
      expect(tester.takeException(), isNull);
    } finally {
      await flow.close();
    }
  });

  testWidgets('colheita lança medidas e envia o PDF individual à plataforma',
      (tester) async {
    final flow = _Flow(tester);
    const printing = MethodChannel('net.nfet.printing');
    MethodCall? share;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(printing,
        (call) async {
      if (call.method == 'sharePdf') share = call;
      return 1;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(printing, null));
    try {
      await tester.pumpWidget(const MaterialApp(home: _notebook));
      await flow.tap(find.text('Colheita'));
      await flow.tap(find.text('Registrar colheita'));
      await flow.tap(find.byType(DropdownButtonFormField<String>));
      await flow.tap(find.text('Ana Teste').last);
      await flow.enter('Quantidade', '80');
      await flow.tap(find.text('Salvar'));
      await flow.waitFor(find.textContaining('Medida de 60 L · Pendente'));
      expect(find.textContaining('Não foi possível registrar a colheita'),
          findsNothing);
      await flow.tap(find.text('Editar valor por medida'));
      await flow.enter('Valor por medida (R\$, opcional)', '30');
      await flow.tap(find.text('Salvar'));
      await flow.waitFor(find.textContaining('2.400,00'));
      await flow.tap(find.text('Registrar vale ou pagamento'));
      await flow.tap(find.byType(DropdownButtonFormField<String>));
      await flow.tap(find.text('Ana Teste').last);
      await flow.enter('Valor (R\$)', '300');
      await flow.tap(find.text('Salvar'));
      await flow.waitFor(find.ancestor(
        of: find.text('Registrar vale ou pagamento'),
        matching: find.byWidgetPredicate(
          (widget) => widget is OutlinedButton && widget.onPressed != null,
        ),
      ));
      await flow.waitFor(find.textContaining('Acumulado na fazenda'));
      await flow.tap(find.ancestor(
          of: find.textContaining('Acumulado na fazenda'),
          matching: find.byType(ListTile)));
      await flow.waitFor(find.text('Resumo individual'));
      await flow.waitFor(find.textContaining('2.400,00'));
      await flow.waitFor(find.textContaining('2.100,00'));
      await flow.tap(find.text('Compartilhar resumo em PDF'));
      for (var attempt = 0; attempt < 120 && share == null; attempt++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      final args = share?.arguments as Map?;
      expect(args?['name'], 'colheita-${DateTime.now().year}.pdf');
      final bytes = args!['doc'] as Uint8List;
      expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
      expect(bytes.length, greaterThan(1000));
      final summary = await tester.runAsync(() => CoffeeHarvestRepository()
          .summary(propertyId: 'farm', seasonYear: DateTime.now().year));
      expect(summary!.entries.single.measureEquivalent, 80);
      expect(summary.earnedCents, 240000);
      expect(summary.advancesCents, 30000);
      expect(summary.balanceCents, 210000);
      expect(tester.takeException(), isNull);
    } finally {
      await flow.close();
    }
  });

  testWidgets('manutenção salva revisão por data com intervalo vazio',
      (tester) async {
    final flow = _Flow(tester);
    await tester.runAsync(() => MachineRepository().saveAll([
          const Machine(
            id: 'tractor',
            name: 'Trator fictício',
            brand: 'Marca',
            model: 'Modelo',
            year: 2020,
            hourMeter: 120,
            fuelType: 'Diesel',
            status: MachineStatus.disponivel,
          ),
        ], previous: []));
    try {
      await tester.pumpWidget(const MaterialApp(home: MaintenanceScreen()));
      final add = find.byType(FloatingActionButton);
      expect(tester.widget<FloatingActionButton>(add).onPressed, isNull);
      await flow.waitFor(find.text('Nenhuma manutenção registrada'));
      await flow.tap(add);
      await flow.enter('Intervalo até próxima manutenção (h)', '');
      await flow.tap(find.text('Data da próxima revisão (opcional)'));
      await flow.tap(find.text('OK'));
      await flow.waitFor(find.textContaining('Próxima revisão em'));
      await flow.tap(find.text('Salvar'));
      await flow.waitFor(find.textContaining('Trator fictício'));
      final records =
          await tester.runAsync(() => MaintenanceRepository().getAll());
      expect(records!.single.intervalHours, isNull);
      expect(records.single.nextDueDate, isNotNull);
      expect(tester.takeException(), isNull);
    } finally {
      await flow.close();
    }
  });
}
