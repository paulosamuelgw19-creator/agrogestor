import 'package:agrogestao/features/analyses/coffee_analysis_repository.dart';
import 'package:agrogestao/features/harvest/coffee_harvest_repository.dart';
import 'package:agrogestao/features/harvest/coffee_season_check_card.dart';
import 'package:agrogestao/features/harvest/coffee_season_check_repository.dart';
import 'package:agrogestao/features/local_backup/local_backup_service.dart';
import 'package:agrogestao/features/products/product_record.dart';
import 'package:agrogestao/features/products/product_repository.dart';
import 'package:agrogestao/features/properties/plot_notebook_repository.dart';
import 'package:agrogestao/features/properties/plot_notebook_screen.dart';
import 'package:agrogestao/features/services/coffee_input_plan.dart';
import 'package:agrogestao/features/services/farm_service.dart';
import 'package:agrogestao/features/services/local_operation_actions.dart';
import 'package:agrogestao/features/services/service_repository.dart';
import 'package:agrogestao/features/sync/app_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'coffee_notebook_harvest_test.dart' show useCoffeeDatabase;

final _start = DateTime(2026, 6, 10);
final _end = DateTime(2026, 6, 11);
final _followUp = DateTime(2026, 6, 20);

const _spray = CoffeeInputPlan(
  productId: 'spray',
  productName: 'Insumo teste',
  stockUnit: 'L',
  kind: CoffeeInputKind.spray,
  quantity: .4,
  inputUnit: 'L',
  capacityLiters: 20,
  appliedLiters: 80,
  coveredHectares: 2,
  loadCount: 4,
  litersPerLoad: 20,
);

FarmService _service(String id, {String plot = 'plot-a'}) => FarmService(
      id: id,
      machineId: '',
      machineName: '',
      operatorName: '',
      customer: '',
      property: 'Fazenda teste',
      propertyId: 'farm',
      fieldName: 'Talhão teste',
      fieldId: plot,
      jobType: 'Pulverização',
      applicationNumber: 2,
      workSection: 'Trecho norte',
      workObjective: 'Vistoria de aplicação',
      startedAt: _start,
      startMeter: null,
      isManual: true,
      people: 1,
      plannedInputs: [_spray],
    );

PlotNote _inspection() => PlotNote(
      id: 'visit',
      propertyId: 'farm',
      plotId: 'plot-a',
      date: _start,
      text: 'Verificar trecho norte',
      status: PlotNoteStatus.open,
      followUpOn: _followUp,
      inspection: true,
    );

void main() {
  useCoffeeDatabase();

  test('manejo registra quatro cargas e dois dias e dá baixa só no produto',
      () async {
    expect(_spray.validationError, isNull);
    expect(_spray.sprayLitersPerHectare, 40);
    expect(_spray.productPerHectare, .2);
    expect(CoffeeInputPlan.fromJson(_spray.toJson()).toJson(), _spray.toJson());
    expect(
        CoffeeInputPlan.fromJson({..._spray.toJson(), 'appliedLiters': 20})
            .validationError,
        isNotNull);
    final operations = ServiceRepository();
    final products = ProductRepository();
    final active = _service('service');
    await operations
        .saveAll([active, _service('other', plot: 'plot-b')], previous: []);
    await products.saveProducts([
      const FarmProduct(
          id: 'spray',
          name: 'Insumo teste',
          category: 'Insumos',
          unit: 'L',
          quantity: 2,
          lot: ''),
    ], previous: []);
    await LocalOperationActions.pause(
        active, ServiceDay(date: _start, areaHectares: 1));
    final paused =
        (await operations.getAll()).singleWhere((s) => s.id == 'service');
    await LocalOperationActions.resume(paused, _end);
    final resumed =
        (await operations.getAll()).singleWhere((s) => s.id == 'service');
    await LocalOperationActions.finish(
      resumed.copyWith(appliedSprayInputs: [_spray]),
      [
        ProductUsage(
          id: 'real-product',
          productId: 'spray',
          serviceId: 'service',
          productName: 'Insumo teste',
          quantity: .4,
          unit: 'L',
          date: _end,
          machine: '',
          field: 'Talhão teste',
          operatorName: '',
        ),
      ],
      day: ServiceDay(date: _end, areaHectares: 1),
    );
    final notebook = PlotNotebookRepository();
    await notebook.save(_inspection());
    Future<void> resolve(String operationId) => notebook.setStatus(
          propertyId: 'farm',
          plotId: 'plot-a',
          id: 'visit',
          status: PlotNoteStatus.resolved,
          operationId: operationId,
        );
    await expectLater(resolve('other'), throwsFormatException);
    await resolve('service');
    await resolve('service');
    await appDatabase.close();
    final finished =
        (await operations.getAll()).singleWhere((s) => s.id == 'service');
    expect(finished.applicationNumber, 2);
    expect(finished.workSection, 'Trecho norte');
    expect(finished.workObjective, 'Vistoria de aplicação');
    expect(finished.days.map((day) => day.date), [_start, _end]);
    expect(finished.appliedSprayInputs.single.appliedLiters, 80);
    expect(finished.appliedSprayInputs.single.loadCount, 4);
    expect((await products.getProducts()).single.quantity, closeTo(1.6, 1e-12));
    expect(await products.getUsage(), hasLength(1));
    final note =
        (await notebook.list(propertyId: 'farm', plotId: 'plot-a')).single;
    expect(note.followUpOn, _followUp);
    expect(note.inspection, isTrue);
    expect(note.operationId, 'service');
    expect(note.status, PlotNoteStatus.resolved);
  });

  test('faixa informada inclui limites, exige fonte e retorna no backup',
      () async {
    CoffeeAnalysisResult range(double value,
            {String source = 'Laudo fictício'}) =>
        CoffeeAnalysisResult(
          indicator: 'Fósforo',
          unit: 'mg/dm3',
          value: value,
          referenceMin: 10,
          referenceMax: 20,
          referenceSource: source,
        );
    CoffeeAnalysis record(String id, CoffeeAnalysisResult result) =>
        CoffeeAnalysis(
          id: id,
          propertyId: 'farm',
          plotId: 'plot-a',
          type: CoffeeAnalysisType.soil,
          collectedAt: _start,
          laboratory: 'Laboratório Teste',
          sampleId: id,
          results: [result],
        );
    expect(range(9).referencePosition, 'Abaixo da faixa informada');
    for (final value in [10.0, 15.0, 20.0]) {
      expect(range(value).referencePosition, 'Dentro da faixa informada');
    }
    expect(range(21).referencePosition, 'Acima da faixa informada');
    const noReference =
        CoffeeAnalysisResult(indicator: 'Fósforo', unit: 'mg/dm3', value: 15);
    expect(noReference.referencePosition, isNull);
    expect(noReference.toJson().containsKey('referenceMin'), isFalse);
    final analyses = CoffeeAnalysisRepository();
    await expectLater(
        analyses.save(record('missing-source', range(10, source: ''))),
        throwsFormatException);
    await analyses.save(record('with-source', range(10)));
    await analyses.save(record('no-reference', noReference));
    final backup = LocalBackupService();
    await backup.restore(await backup.create());
    final records = await analyses.list(propertyId: 'farm', plotId: 'plot-a');
    final restored =
        records.singleWhere((item) => item.id == 'with-source').results.single;
    expect(restored.referenceSource, 'Laudo fictício');
    expect(restored.referenceMin, 10);
    expect(restored.referenceMax, 20);
    expect(restored.referencePosition, 'Dentro da faixa informada');
    expect(
        records
            .singleWhere((item) => item.id == 'no-reference')
            .results
            .single
            .referencePosition,
        isNull);
  });

  testWidgets('agenda exibe vistoria e caderno mostra diferença de 20 litros',
      (tester) async {
    tester.view.physicalSize = const Size(320, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final harvest = CoffeeHarvestRepository();
    await tester.runAsync(() async {
      await PlotNotebookRepository().save(_inspection());
      await harvest.saveProduction(CoffeePlotProduction(
        id: 'production',
        propertyId: 'farm',
        plotId: 'plot-a',
        date: _start,
        seasonYear: 2026,
        unit: CoffeeHarvestUnit.liters,
        quantity: 2930,
      ));
      await CoffeeSeasonCheckRepository().save(const CoffeeSeasonCheck(
        id: 'paper',
        propertyId: 'farm',
        plotId: 'plot-a',
        seasonYear: 2026,
        liters: 2950,
      ));
    });
    Future<void> waitFor(Finder finder) async {
      for (var i = 0; i < 150 && finder.evaluate().isEmpty; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(finder, findsWidgets);
    }

    try {
      await tester.pumpWidget(const MaterialApp(
          home: PlotNotebookScreen(
        property: {'id': 'farm', 'name': 'Fazenda teste'},
        plot: {'id': 'plot-a', 'name': 'Talhão A', 'area_ha': 2},
      )));
      await waitFor(find.text('Agenda, vistorias e notas'));
      await waitFor(find.text('Vistoria'));
      expect(find.text('Verificar trecho norte'), findsOneWidget);
      final dates = MaterialLocalizations.of(
          tester.element(find.byType(PlotNotebookScreen)));
      expect(
          find.text('Retorno previsto: ${dates.formatCompactDate(_followUp)}'),
          findsOneWidget);
      await tester.pumpWidget(const MaterialApp(
        key: ValueKey('subtotal'),
        home: Scaffold(
            body: CoffeeSeasonCheckCard(
          propertyId: 'farm',
          plotId: 'plot-a',
          seasonYear: 2026,
          registeredLiters: 2930,
          canEdit: true,
        )),
      ));
      await waitFor(find.text('Diferença: 20 L a mais no caderno'));
      expect(find.text('Anotado: 2.950 L'), findsOneWidget);
      expect(find.text('Lançado no app: 2.930 L'), findsOneWidget);
      final production = await tester.runAsync(() => harvest.production(
            propertyId: 'farm',
            plotId: 'plot-a',
            seasonYear: 2026,
          ));
      expect(production!.totalLiters, 2930);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
