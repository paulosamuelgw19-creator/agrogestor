import 'dart:convert';
import 'dart:io';

import 'package:agrogestao/features/auth/auth_service.dart';
import 'package:agrogestao/features/harvest/coffee_harvest_repository.dart';
import 'package:agrogestao/features/local_backup/local_backup_service.dart';
import 'package:agrogestao/features/maintenance/maintenance_record.dart';
import 'package:agrogestao/features/maintenance/maintenance_repository.dart';
import 'package:agrogestao/features/operators/operator.dart';
import 'package:agrogestao/features/operators/operator_repository.dart';
import 'package:agrogestao/features/properties/catalog_store.dart';
import 'package:agrogestao/features/properties/plot_notebook_repository.dart';
import 'package:agrogestao/features/sync/app_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

const firstWorker = Operator(
  id: 'first',
  name: 'Ana Teste',
  phone: '',
  role: 'Colhedora',
  active: true,
);
const secondWorker = Operator(
  id: 'second',
  name: 'João Teste',
  phone: '',
  role: 'Colhedor',
  active: true,
);

Future<void> seedCoffeeFarm() async {
  final catalog = await CatalogStore.open();
  await catalog.save('POST', '/properties', {
    'id': 'farm',
    'name': 'Fazenda teste',
    'plots': [
      {'id': 'plot-a', 'name': 'Talhão A', 'area_ha': 2},
      {'id': 'plot-b', 'name': 'Talhão B', 'area_ha': 2},
    ],
  });
  await catalog.save('POST', '/properties', {
    'id': 'other-farm',
    'name': 'Outra fazenda',
    'plots': [
      {'id': 'other-plot', 'name': 'Talhão externo', 'area_ha': 3},
    ],
  });
  await OperatorRepository().saveAll([firstWorker, secondWorker], previous: []);
}

void useCoffeeDatabase() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late PathProviderPlatform originalPaths;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('agro-coffee-notebook-');
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(dir.path);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    expect(await AuthService().enterStandaloneLocalMode(), isTrue);
    await seedCoffeeFarm();
  });
  tearDown(() async {
    await appDatabase.close();
    debugDefaultTargetPlatformOverride = null;
    PathProviderPlatform.instance = originalPaths;
    await dir.delete(recursive: true);
  });
}

CoffeeHarvestEntry _entry(
  String id, {
  String farm = 'farm',
  String plot = 'plot-a',
  String worker = 'first',
  int season = 2026,
  int day = 10,
  CoffeeHarvestUnit unit = CoffeeHarvestUnit.measures,
  double quantity = 80,
  double? cartCapacity,
  int? rate = 3000,
}) =>
    CoffeeHarvestEntry(
      id: id,
      propertyId: farm,
      plotId: plot,
      workerId: worker,
      date: DateTime(2026, 6, day),
      seasonYear: season,
      unit: unit,
      quantity: quantity,
      cartCapacityLiters: cartCapacity,
      ratePerMeasureCents: rate,
    );

CoffeeHarvestPayment _payment(CoffeeHarvestPaymentKind kind, int cents) =>
    CoffeeHarvestPayment(
      id: kind.name,
      propertyId: 'farm',
      workerId: 'first',
      date: DateTime(2026, 6, 11),
      seasonYear: 2026,
      kind: kind,
      amountCents: cents,
    );

void main() {
  useCoffeeDatabase();

  test('nota, foto e pendência são isoladas por talhão e voltam no backup v4',
      () async {
    final repo = PlotNotebookRepository();
    final day = DateTime(2026, 6, 10);
    final photo = File(
        '${await PathProviderPlatform.instance.getApplicationSupportPath()}/photo.png');
    final pixels = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aF0AAAAASUVORK5CYII=');
    await photo.writeAsBytes(pixels);
    await repo.save(PlotNote(
        id: 'note',
        propertyId: 'farm',
        plotId: 'plot-a',
        date: day,
        text: '  Nota da lavoura  '));
    await repo.save(PlotNote(
        id: 'photo',
        propertyId: 'farm',
        plotId: 'plot-a',
        date: day,
        text: '',
        photoPath: photo.path));
    await repo.save(PlotNote(
        id: 'pending',
        propertyId: 'farm',
        plotId: 'plot-b',
        date: day,
        text: 'Verificar cerca',
        status: PlotNoteStatus.open));
    Future<List<PlotNote>> notes(String plot) =>
        repo.list(propertyId: 'farm', plotId: plot);
    Future<void> changeStatus(String plot, PlotNoteStatus status) =>
        repo.setStatus(
            propertyId: 'farm', plotId: plot, id: 'pending', status: status);
    await expectLater(
      changeStatus('plot-a', PlotNoteStatus.resolved),
      throwsFormatException,
    );
    await expectLater(
      repo.save(PlotNote(
          id: 'wrong',
          propertyId: 'farm',
          plotId: 'other-plot',
          date: day,
          text: 'Vínculo cruzado')),
      throwsFormatException,
    );
    await changeStatus('plot-b', PlotNoteStatus.resolved);
    await changeStatus('plot-b', PlotNoteStatus.resolved);
    expect((await notes('plot-b')).single.status, PlotNoteStatus.resolved);
    await changeStatus('plot-b', PlotNoteStatus.open);

    await photo.delete();
    await appDatabase.close();
    final before = {for (final note in await notes('plot-a')) note.id: note};
    expect(before.keys, unorderedEquals(['note', 'photo']));
    expect(before['note']!.text, 'Nota da lavoura');
    final privatePhoto = File(before['photo']!.photoPath!);
    expect(privatePhoto.parent.path, endsWith('attachments'));
    expect(await privatePhoto.readAsBytes(), pixels);
    final backup = LocalBackupService();
    final bytes = await backup.create();
    expect(jsonDecode(utf8.decode(bytes))['schemaVersion'], 4);
    await repo.save(PlotNote(
        id: 'local-only',
        propertyId: 'farm',
        plotId: 'plot-a',
        date: day,
        text: 'Registro local posterior'));
    await privatePhoto.delete();
    await expectLater(backup.create(), throwsFormatException);
    final safety = await backup.restore(bytes);
    final restored = {for (final note in await notes('plot-a')) note.id: note};
    expect(restored.keys, unorderedEquals(['note', 'photo']));
    expect(restored['note']!.text, 'Nota da lavoura');
    expect(await File(restored['photo']!.photoPath!).readAsBytes(), pixels);
    expect((await notes('plot-b')).single.status, PlotNoteStatus.open);

    final safetyBytes = await File(safety).readAsBytes();
    final safetyPayload = backup.inspect(safetyBytes);
    expect(safetyPayload['photos'], isEmpty);
    await backup.restore(safetyBytes);
    final rolledBack = {for (final note in await notes('plot-a')) note.id: note};
    expect(rolledBack['local-only']!.text, 'Registro local posterior');
    expect(rolledBack['photo']!.photoPath, isNull);
    expect(rolledBack['photo']!.text, 'Foto indisponível no aparelho.');
  });

  test('colheita separa unidade, pessoa, dia e safra com baixas idempotentes',
      () async {
    final repo = CoffeeHarvestRepository();
    final measured = _entry('measured');
    final advance = _payment(CoffeeHarvestPaymentKind.advance, 30000);
    final paid = _payment(CoffeeHarvestPaymentKind.payment, 50000);
    for (var retry = 0; retry < 2; retry++) {
      await repo.saveEntry(measured);
      await repo.savePayment(advance);
      await repo.savePayment(paid);
    }
    await expectLater(
      repo.saveEntry(_entry('measured', quantity: 81)),
      throwsFormatException,
    );
    await expectLater(
      repo.savePayment(_payment(CoffeeHarvestPaymentKind.advance, 50000)),
      throwsFormatException,
    );
    await expectLater(
      repo.saveEntry(_entry('bad-link', plot: 'other-plot')),
      throwsFormatException,
    );
    await repo.saveEntry(_entry('liters',
        unit: CoffeeHarvestUnit.liters,
        quantity: 60,
        rate: null,
        day: 11,
        plot: 'plot-b'));
    await repo.saveEntry(_entry('cart',
        unit: CoffeeHarvestUnit.carts,
        quantity: 2,
        cartCapacity: 120,
        worker: 'second'));
    await repo.saveEntry(_entry('prior-season', season: 2025));
    await repo.saveEntry(
        _entry('other-farm-record', farm: 'other-farm', plot: 'other-plot'));
    Future<CoffeeHarvestSummary> individual() =>
        repo.summary(propertyId: 'farm', seasonYear: 2026, workerId: 'first');

    final unknown = await individual();
    expect(unknown.entries, hasLength(2));
    expect(unknown.payments, hasLength(2));
    expect(unknown.entries.map((e) => e.workerName).toSet(), {'Ana Teste'});
    expect(unknown.litersByDay, {
      DateTime(2026, 6, 10): 4800,
      DateTime(2026, 6, 11): 60,
    });
    expect(unknown.knownEarnedCents, 240000);
    expect(unknown.earnedCents, isNull);
    expect(unknown.balanceCents, isNull);
    expect(unknown.advancesCents, 30000);
    expect(unknown.paymentsCents, 50000);
    final group = await repo.summary(propertyId: 'farm', seasonYear: 2026);
    expect(group.litersByWorker, {'first': 4860, 'second': 240});
    expect(
        (await repo.entries(
                propertyId: 'farm', seasonYear: 2026, plotId: 'plot-a'))
            .map((entry) => entry.id),
        unorderedEquals(['measured', 'cart']));

    Future<void> setRate(String plot, int? rate) => repo.setEntryRate(
        propertyId: 'farm',
        plotId: plot,
        id: 'liters',
        ratePerMeasureCents: rate);
    await expectLater(setRate('plot-a', 0), throwsFormatException);
    await setRate('plot-b', 0);
    final known = await individual();
    expect(known.earnedCents, 240000);
    expect(known.balanceCents, 160000);
    expect(known.entries, hasLength(2));
    expect(known.payments, hasLength(2));
    final entry = known.entries.singleWhere((entry) => entry.id == 'liters');
    expect(entry.toJson(), {
      ...unknown.entries.singleWhere((entry) => entry.id == 'liters').toJson(),
      'ratePerMeasureCents': 0,
    });
    await setRate('plot-b', 3000);
    expect((await individual()).balanceCents, 163000);
    await setRate('plot-b', null);
    expect((await individual()).balanceCents, isNull);

    final backup = LocalBackupService();
    final bytes = await backup.create();
    expect(jsonDecode(utf8.decode(bytes))['schemaVersion'], 4);
    await (await CatalogStore.open()).db.delete(
      'local_records',
      where: 'module IN (?, ?)',
      whereArgs: ['coffeeHarvestEntries', 'coffeeHarvestPayments'],
    );
    await appDatabase.close();
    expect((await individual()).entries, isEmpty);
    await backup.restore(bytes);
    expect((await individual()).entries, hasLength(2));
    expect((await individual()).balanceCents, isNull);
  });

  test('revisão apenas por data e revisão legada por horímetro sobrevivem',
      () async {
    final repo = MaintenanceRepository();
    final date = DateTime(2026, 7, 20);
    final due = DateTime(2026, 10, 20);
    final byDate = MaintenanceRecord(
      id: 'date',
      machineId: 'machine',
      machineName: 'Trator fictício',
      date: date,
      hourMeter: 120,
      type: 'Revisão',
      description: '',
      parts: '',
      cost: null,
      intervalHours: null,
      nextDueDate: due,
    );
    final legacy = MaintenanceRecord.fromJson({
      ...byDate.toJson(),
      'id': 'legacy',
      'intervalHours': 200,
    }..remove('nextDueDate'));
    await repo.saveAll([byDate, legacy], previous: []);
    await appDatabase.close();
    final records = {
      for (final record in await repo.getAll()) record.id: record
    };
    expect(records['date']!.nextDueDate, due);
    expect(records['date']!.nextDueMeter, isNull);
    expect(records['legacy']!.nextDueDate, isNull);
    expect(records['legacy']!.nextDueMeter, 320);
  });
}
