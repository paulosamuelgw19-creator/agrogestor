import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:agrogestao/features/analyses/coffee_analysis_repository.dart';
import 'package:agrogestao/features/harvest/coffee_harvest_repository.dart';
import 'package:agrogestao/features/local_backup/local_backup_service.dart';
import 'package:agrogestao/features/services/farm_service.dart';
import 'package:agrogestao/features/services/service_repository.dart';
import 'package:agrogestao/features/sync/app_database.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;

import 'coffee_notebook_harvest_test.dart' show useCoffeeDatabase;

Future<Uint8List> buildAnalysisPdf() {
  final pdf = pw.Document();
  pdf.addPage(pw.Page(build: (_) => pw.Text('Laudo ficticio para testes')));
  return pdf.save();
}

CoffeePlotProduction _production(
  String id,
  int day,
  double quantity, {
  String plot = 'plot-a',
  int season = 2026,
  int hour = 0,
  CoffeeHarvestUnit unit = CoffeeHarvestUnit.liters,
  double? remainder,
  double? capacity,
}) =>
    CoffeePlotProduction(
      id: id,
      propertyId: 'farm',
      plotId: plot,
      date: DateTime(2026, 6, day, hour),
      seasonYear: season,
      unit: unit,
      quantity: quantity,
      remainderLiters: remainder,
      cartCapacityLiters: capacity,
    );

CoffeeHarvestEntry _workerEntry(String id, int day, double quantity) =>
    CoffeeHarvestEntry(
      id: id,
      propertyId: 'farm',
      plotId: 'plot-a',
      workerId: 'first',
      date: DateTime(2026, 6, day, 17),
      seasonYear: 2026,
      unit: CoffeeHarvestUnit.measures,
      quantity: quantity,
      ratePerMeasureCents: 3000,
    );

CoffeeAnalysis _analysis(
  String id, {
  String plot = 'plot-a',
  CoffeeAnalysisType type = CoffeeAnalysisType.soil,
  String context = '0 a 20 cm',
  String unit = 'mg/dm3',
  String method = 'Mehlich 1',
  double value = 12,
  int day = 10,
  String? operationId,
}) =>
    CoffeeAnalysis(
      id: id,
      propertyId: 'farm',
      plotId: plot,
      type: type,
      collectedAt: DateTime(2026, 6, day),
      laboratory: 'Laboratório fictício',
      sampleId: id,
      context: context,
      operationId: operationId,
      agronomistGuidance: 'Registro fictício do agrônomo',
      results: [
        CoffeeAnalysisResult(
            indicator: 'Fósforo', unit: unit, value: value, method: method)
      ],
    );

FarmService _operation(String id, String plot, {bool completed = true}) {
  final date = DateTime(2026, 6, 9);
  return FarmService(
    id: id,
    machineId: '',
    machineName: '',
    operatorName: '',
    customer: '',
    property: 'Fazenda teste',
    propertyId: 'farm',
    fieldName: plot,
    fieldId: plot,
    jobType: 'Calagem',
    startedAt: date,
    endedAt: completed ? date : null,
    startMeter: null,
    isManual: true,
    people: 1,
  );
}

void main() {
  useCoffeeDatabase();

  test('total do talhão não duplica colheita por pessoa ou pagamentos',
      () async {
    final repo = CoffeeHarvestRepository();
    await repo.saveEntry(_workerEntry('person-540', 10, 9));
    await repo.saveEntry(_workerEntry('person-only', 11, 2));
    await repo.savePayment(CoffeeHarvestPayment(
      id: 'payment',
      propertyId: 'farm',
      workerId: 'first',
      date: DateTime(2026, 6, 10),
      seasonYear: 2026,
      kind: CoffeeHarvestPaymentKind.payment,
      amountCents: 5000,
    ));
    final personBefore = await repo.summary(
        propertyId: 'farm', seasonYear: 2026, workerId: 'first');
    await repo.saveProduction(_production('declared', 10, 600));
    await repo.saveProduction(_production('measures', 12, 7,
        unit: CoffeeHarvestUnit.measures, remainder: 40));
    await repo.saveProduction(_production('cart', 13, 1.5,
        unit: CoffeeHarvestUnit.carts, capacity: 200));
    await repo
        .saveProduction(_production('other-plot', 10, 400, plot: 'plot-b'));
    await repo
        .saveProduction(_production('other-season', 10, 500, season: 2025));
    Future<CoffeePlotProductionSummary> total(
            {String plot = 'plot-a', int season = 2026}) =>
        repo.production(propertyId: 'farm', plotId: plot, seasonYear: season);
    final first = await total();
    expect(first.days.map((day) => day.totalLiters), [300, 460, 120, 600]);
    final declared = first.days.last;
    expect(declared.workerLiters, 540);
    expect(declared.differenceLiters, 60);
    expect(first.days[2].declared, isNull);
    expect(first.days[1].workerLiters, isNull);
    expect(first.days[1].differenceLiters, isNull);
    expect(first.totalLiters, 1480);
    expect((await total(plot: 'plot-b')).totalLiters, 400);
    expect((await total(season: 2025)).totalLiters, 500);

    await repo
        .saveProduction(_production('new-id-same-day', 10, 630, hour: 19));
    await expectLater(repo.saveProduction(_production('declared', 14, 20)),
        throwsFormatException);
    await expectLater(
        repo.saveProduction(
            _production('cross-link', 14, 1, plot: 'other-plot')),
        throwsFormatException);
    await expectLater(
        repo.saveProduction(_production('invalid-rest', 14, 1,
            unit: CoffeeHarvestUnit.measures, remainder: 60)),
        throwsFormatException);
    await appDatabase.close();
    final updated = await total();
    expect(updated.days, hasLength(4));
    expect(updated.days.last.declared?.id, 'declared');
    expect(updated.days.last.differenceLiters, 90);
    expect(updated.totalLiters, 1510);
    final personAfter = await repo.summary(
        propertyId: 'farm', seasonYear: 2026, workerId: 'first');
    expect(personAfter.entries.map((entry) => entry.toJson()),
        personBefore.entries.map((entry) => entry.toJson()));
    expect(personAfter.payments.map((payment) => payment.toJson()),
        personBefore.payments.map((payment) => payment.toJson()));
    expect(personAfter.balanceCents, personBefore.balanceCents);
  });

  test('conferência persiste, reabre ao mudar o detalhe e preserva lançamentos',
      () async {
    final repo = CoffeeHarvestRepository();
    await repo.saveEntry(_workerEntry('first-entry', 10, 9));
    await repo.saveProduction(_production('declared', 10, 600));
    Future<CoffeePlotProductionDay> day() async => (await repo.production(
          propertyId: 'farm',
          plotId: 'plot-a',
          seasonYear: 2026,
        ))
            .days
            .single;
    final pending = await day();
    expect(pending.needsReview, isTrue);
    await repo.reviewProduction(pending, keepDeclared: true);
    await appDatabase.close();
    expect((await day()).needsReview, isFalse);
    expect((await day()).totalLiters, 600);
    await repo.saveEntry(_workerEntry('second-entry', 10, 2));
    final changed = await day();
    expect(changed.needsReview, isTrue);
    await expectLater(repo.reviewProduction(pending, keepDeclared: false),
        throwsFormatException);
    await repo.reviewProduction(changed, keepDeclared: false);
    final verified = await day();
    expect(verified.totalLiters, 660);
    expect(verified.needsReview, isFalse);
    expect(verified.declared?.id, 'declared');
    expect((await repo.summary(propertyId: 'farm', seasonYear: 2026)).entries,
        hasLength(2));
  });

  test('comparação só calcula diferença com contexto, unidade e método iguais',
      () {
    final first = _analysis('first');
    final compatible = compareCoffeeAnalyses(
        first,
        _analysis('next',
            value: 15, context: ' 0  A  20 cm ', method: 'mehlich 1'));
    expect(compatible.contextsCompatible, isTrue);
    expect(compatible.rows.single.difference, 3);
    for (final other in [
      _analysis('leaf', type: CoffeeAnalysisType.leaf),
      _analysis('deep', context: '20 a 40 cm'),
      _analysis('unknown', context: ''),
      _analysis('other-plot', plot: 'plot-b'),
    ]) {
      final comparison = compareCoffeeAnalyses(first, other);
      expect(comparison.contextsCompatible, isFalse);
      expect(comparison.rows.single.difference, isNull);
    }
    for (final other in [
      _analysis('method', method: 'Resina'),
      _analysis('no-method', method: ''),
      _analysis('unit', unit: 'g/dm3'),
    ]) {
      final comparison = compareCoffeeAnalyses(first, other);
      expect(comparison.contextsCompatible, isTrue);
      expect(comparison.rows.single.difference, isNull);
    }
  });

  test('PDF real e vínculo da análise são preservados no backup v5', () async {
    final repo = CoffeeAnalysisRepository();
    final pdf = await buildAnalysisPdf();
    await ServiceRepository().saveAll([
      _operation('complete', 'plot-a'),
      _operation('unfinished', 'plot-a', completed: false),
      _operation('other-plot', 'plot-b'),
    ], previous: []);
    expect(
        (await repo.completedOperations(propertyId: 'farm', plotId: 'plot-a'))
            .map((item) => item.id),
        ['complete']);
    for (final id in ['unfinished', 'other-plot']) {
      await expectLater(repo.save(_analysis('invalid', operationId: id)),
          throwsFormatException);
    }
    await expectLater(repo.save(_analysis('cross-link', plot: 'other-plot')),
        throwsFormatException);
    await expectLater(
        repo.save(_analysis('wrong-ext'),
            pickedPdf: pdf, pickedPdfName: 'x.txt'),
        throwsFormatException);
    await expectLater(
        repo.save(_analysis('wrong-content'),
            pickedPdf: Uint8List.fromList(utf8.encode('falso PDF')),
            pickedPdfName: 'x.pdf'),
        throwsFormatException);

    await repo.save(_analysis('soil', operationId: 'complete'),
        pickedPdf: pdf, pickedPdfName: 'laudo.PDF');
    await repo.save(_analysis('leaf', type: CoffeeAnalysisType.leaf, day: 12));
    await repo.save(_analysis('other', plot: 'plot-b'));
    await CoffeeHarvestRepository()
        .saveProduction(_production('prod', 10, 600));
    await appDatabase.close();
    Future<List<CoffeeAnalysis>> all({CoffeeAnalysisType? type}) =>
        repo.list(propertyId: 'farm', plotId: 'plot-a', type: type);
    expect((await all()).map((item) => item.id), ['leaf', 'soil']);
    final soil = (await all(type: CoffeeAnalysisType.soil)).single;
    expect(soil.operationId, 'complete');
    expect(soil.agronomistGuidance, 'Registro fictício do agrônomo');
    final file = File(soil.pdfPath!);
    expect(file.parent.path, endsWith('coffee-analyses'));
    expect(await readCoffeeAnalysisPdf(file), pdf);

    final backup = LocalBackupService();
    final bytes = await backup.create();
    final doc = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    expect(doc['schemaVersion'], 5);
    final payload = doc['payload'] as Map<String, dynamic>;
    final digest = sha256.convert(pdf).toString();
    expect(payload['pdfs'], {digest: base64Encode(pdf)});
    expect(utf8.decode(bytes), contains('agropdf:$digest'));
    expect(utf8.decode(bytes), isNot(contains(jsonEncode(file.path))));
    Uint8List tampered(Map<String, Object?> changes) {
      final changed = {...payload, ...changes};
      return Uint8List.fromList(utf8.encode(jsonEncode({
        ...doc,
        'payload': changed,
        'sha256': sha256.convert(utf8.encode(jsonEncode(changed))).toString(),
      })));
    }

    expect(() => backup.inspect(tampered({'pdfs': {}})), throwsFormatException);
    expect(
        () => backup.inspect(tampered({
              'pdfs': {
                digest: base64Encode([1, 2, 3])
              }
            })),
        throwsFormatException);
    final records = (payload['records'] as List).cast<Map<String, dynamic>>();
    final production = records.singleWhere((row) => row['id'] == 'prod');
    expect(
        () => backup.inspect(tampered({
              'records': [
                ...records,
                {
                  ...production,
                  'id': 'duplicated',
                  'data': {
                    ...production['data'] as Map<String, dynamic>,
                    'id': 'duplicated',
                  },
                }
              ]
            })),
        throwsFormatException);
    expect(
        () => backup.inspect(tampered({
              'records': [
                for (final row in records)
                  if (row['id'] == 'soil')
                    {
                      ...row,
                      'data': {
                        ...row['data'] as Map<String, dynamic>,
                        'operationId': 'other-plot',
                      },
                    }
                  else
                    row,
              ]
            })),
        throwsFormatException);
    await repo.save(_analysis('local-only', type: CoffeeAnalysisType.leaf));
    await file.delete();
    await expectLater(backup.create(),
        throwsA(anyOf(isA<FormatException>(), isA<FileSystemException>())));
    final safety = await backup.restore(bytes);
    final restored = (await all(type: CoffeeAnalysisType.soil)).single;
    expect(restored.operationId, 'complete');
    expect(restored.results.single.value, 12);
    expect(await readCoffeeAnalysisPdf(File(restored.pdfPath!)), pdf);
    expect(
        (await CoffeeHarvestRepository().production(
                propertyId: 'farm', plotId: 'plot-a', seasonYear: 2026))
            .totalLiters,
        600);
    final safetyBytes = await File(safety).readAsBytes();
    expect(backup.inspect(safetyBytes)['pdfs'], isEmpty);
    await backup.restore(safetyBytes);
    expect((await all()).map((item) => item.id),
        unorderedEquals(['leaf', 'soil', 'local-only']));
    final withoutPdf = (await all(type: CoffeeAnalysisType.soil)).single;
    expect(withoutPdf.pdfPath, isNull);
    expect(withoutPdf.operationId, 'complete');
  });
}
