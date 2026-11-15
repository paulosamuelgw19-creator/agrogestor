import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:agrogestao/features/auth/auth_service.dart';
import 'package:agrogestao/features/local_backup/local_backup_service.dart';
import 'package:agrogestao/features/machines/machine.dart';
import 'package:agrogestao/features/implements/farm_implement.dart';
import 'package:agrogestao/features/implements/implement_repository.dart';
import 'package:agrogestao/features/machines/machine_repository.dart';
import 'package:agrogestao/features/products/product_record.dart';
import 'package:agrogestao/features/products/product_repository.dart';
import 'package:agrogestao/features/properties/catalog_store.dart';
import 'package:agrogestao/features/properties/coffee_planting.dart';
import 'package:agrogestao/features/services/farm_service.dart';
import 'package:agrogestao/features/services/service_repository.dart';
import 'package:agrogestao/features/services/local_operation_actions.dart';
import 'package:agrogestao/features/fuel/fuel_record.dart';
import 'package:agrogestao/features/fuel/local_fuel_actions.dart';
import 'package:agrogestao/features/fuel/fuel_repository.dart';
import 'package:agrogestao/features/sync/app_database.dart';
import 'package:agrogestao/features/sync/farm_api_client.dart';
import 'package:agrogestao/features/sync/local_write_batch.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUp(() async {
    expect(FarmApiClient.standaloneLocalMode, isTrue);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    dir = await Directory.systemTemp.createTemp('agro-safety-');
    PathProviderPlatform.instance = _Paths(dir.path);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await AuthService().enterStandaloneLocalMode();
  });
  tearDown(() async {
    await appDatabase.close();
    debugDefaultTargetPlatformOverride = null;
    await dir.delete(recursive: true);
  });
  const product = FarmProduct(
      id: 'p',
      name: 'Produto TESTE',
      category: 'Adubo',
      unit: 'kg',
      quantity: 10,
      lot: '');
  FarmService operation(String id) => FarmService(
      id: id,
      machineId: 'm',
      machineName: 'Trator TESTE',
      operatorName: '',
      customer: '',
      property: 'Fazenda TESTE',
      propertyId: 'f',
      fieldName: 'Talhao 1',
      fieldId: 't1',
      jobType: 'Adubacao',
      startedAt: DateTime(2026, 11, 3),
      startMeter: 100);
  Future<void> seed({bool photo = false}) async {
    String? path;
    if (photo) {
      final folder = Directory('${dir.path}/attachments');
      await folder.create();
      path = '${folder.path}/photo.png';
      await File(path).writeAsBytes(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jWZkAAAAASUVORK5CYII='));
    }
    final machine = Machine(
        id: 'm',
        name: 'Trator TESTE',
        brand: 'Marca',
        model: 'Modelo',
        year: 2020,
        hourMeter: 100,
        fuelType: 'Diesel',
        status: MachineStatus.emOperacao,
        photoPath: path);
    await MachineRepository().saveAll([machine], previous: []);
    await ProductRepository().saveProducts([product], previous: []);
    final c = await CatalogStore.open();
    await c.save('POST', '/properties', {
      'id': 'f',
      'name': 'Fazenda TESTE',
      'plots': [
        for (var i = 1; i <= 3; i++)
          {'id': 't$i', 'name': 'Talhao $i', 'area_ha': null, 'notes': ''}
      ]
    });
  }

  Future<void> start() async =>
      ServiceRepository().saveAll([operation('s')], previous: []);
  ProductUsage usage(String id, double quantity) => ProductUsage(
      id: id,
      productId: 'p',
      serviceId: 's',
      productName: 'Produto TESTE',
      quantity: quantity,
      unit: 'kg',
      date: DateTime(2026, 11, 3),
      machine: 'Trator TESTE',
      field: 'Talhao 1',
      operatorName: 'Gestor');
  Future<String> state() async {
    final db = await appDatabase.database;
    return jsonEncode([
      await db.query('local_records', orderBy: 'module,record_id'),
      await db.query('local_audit', orderBy: 'id')
    ]);
  }

  Uint8List changed(Uint8List bytes, void Function(Map<String, dynamic>) edit) {
    final d = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    edit(d['payload'] as Map<String, dynamic>);
    d['sha256'] =
        sha256.convert(utf8.encode(jsonEncode(d['payload']))).toString();
    return Uint8List.fromList(utf8.encode(jsonEncode(d)));
  }

  test('all related writes and audit roll back after an injected failure',
      () async {
    await seed();
    final before = await state();
    await expectLater(LocalWriteBatch.run(() async {
      await ProductRepository()
          .saveProducts([product.copyWith(quantity: 3)], previous: [product]);
      await start();
      throw StateError('injected interruption');
    }), throwsStateError);
    expect(await state(), before);
  });

  test('pause and resume preserve each day and debit stock only on completion',
      () async {
    await seed();
    await start();
    final initial = (await ServiceRepository().getAll()).single;
    await LocalOperationActions.pause(
        initial,
        ServiceDay(
            date: initial.startedAt,
            startMeter: 100,
            endMeter: 102,
            areaHectares: 30));
    await expectLater(
        LocalOperationActions.pause(
            initial,
            ServiceDay(
                date: initial.startedAt, startMeter: 100, endMeter: 102)),
        throwsFormatException);
    expect((await ProductRepository().getProducts()).single.quantity, 10);
    await appDatabase.close();
    final paused = (await ServiceRepository().getAll()).single;
    expect(paused.isPaused, isTrue);
    expect((await MachineRepository().getAll()).single.hourMeter, 102);
    final nextDay = initial.startedAt.add(const Duration(days: 1));
    await LocalOperationActions.resume(paused, nextDay);
    final resumed = (await ServiceRepository().getAll()).single;
    expect(resumed.activeStartMeter, 102);
    await LocalOperationActions.finish(resumed, [usage('used', 2)],
        day: ServiceDay(
            date: nextDay, startMeter: 102, endMeter: 107, areaHectares: 30));
    final done = (await ServiceRepository().getAll()).single;
    expect(done.isFinished, isTrue);
    expect(done.workedHours, 7);
    expect(done.areaHectares, 60);
    expect(done.days.map((day) => day.hours), [2, 5]);
    expect((await ProductRepository().getProducts()).single.quantity, 8);
    expect((await MachineRepository().getAll()).single.status,
        MachineStatus.disponivel);
  });

  test('manual work and planting density survive backup and restore', () async {
    final catalog = await CatalogStore.open();
    await catalog.save('POST', '/properties', {
      'id': 'f',
      'name': 'Fazenda TESTE',
      'plots': [
        {
          'id': 't',
          'name': 'Café TESTE',
          'area_ha': '2',
          coffeePlantDensity: 2500
        },
      ],
    });
    final manual = FarmService(
        id: 'manual',
        machineId: '',
        machineName: '',
        operatorName: '',
        customer: '',
        property: 'Fazenda TESTE',
        propertyId: 'f',
        fieldName: 'Café TESTE',
        fieldId: 't',
        jobType: 'Capina',
        startedAt: DateTime(2026, 11, 3),
        startMeter: null,
        isManual: true,
        people: 3);
    final repo = ServiceRepository();
    await repo.saveAll([manual], previous: []);
    final end = manual.startedAt.add(const Duration(days: 2));
    await LocalOperationActions.finish(manual, [], day: ServiceDay(date: end));
    final backup = LocalBackupService();
    await backup.restore(await backup.create());
    final restored = (await repo.getAll()).single;
    expect(restored.isFinished, isTrue);
    expect(restored.endedAt, end);
    expect(restored.people, 3);
    expect(restored.workedHours, isNull);
    expect(restored.fieldId, 't');
    final plot = (await (await CatalogStore.open()).records('plots')).single;
    expect(plotCoffeePlants(plot), 5000);
    expect(coffeePlantingLabel(plot), contains('estimativa'));
    expect(coffeePlantingLabel({'area_ha': '2', coffeePlantCount: 5000}),
        contains('2500 pés/ha'));
  });

  test('equipment without a meter keeps fuel and area but no machine hours',
      () async {
    await seed();
    final base = operation('without-meter');
    final service = FarmService.fromJson(
        {...base.toJson(), 'startMeter': null, 'withoutMeter': true});
    final repo = ServiceRepository();
    await repo.saveAll([service], previous: []);
    await LocalOperationActions.finish(service, [],
        day: ServiceDay(
            date: service.startedAt, fuelLiters: 3, areaHectares: 2));
    final done = (await repo.getAll()).single;
    expect(done.isFinished, isTrue);
    expect(done.workedHours, isNull);
    expect(done.fuelLiters, 3);
    expect(done.areaHectares, 2);
    expect((await MachineRepository().getAll()).single.hourMeter, 100);
  });

  test('a format 1 backup restores a legacy operation without daily entries',
      () async {
    await seed();
    await start();
    final backup = LocalBackupService();
    final json =
        jsonDecode(utf8.decode(await backup.create())) as Map<String, dynamic>;
    json['schemaVersion'] = 1;
    await backup.restore(Uint8List.fromList(utf8.encode(jsonEncode(json))));
    final restored = (await ServiceRepository().getAll()).single;
    expect(restored.tracksMeter, isTrue);
    expect(restored.startMeter, 100);
    expect(restored.days, isEmpty);
    expect(restored.fieldId, 't1');
  });
  test(
      'completion consumes stock once and preserves machine, farm and plot links',
      () async {
    await seed();
    await start();
    final finished = operation('s').finishWith(
        endMeter: 102,
        fuelLiters: null,
        areaHectares: null,
        notes: 'Medidas nao informadas');
    await LocalOperationActions.finish(finished, [usage('u', 2)]);
    final before = await state();
    await expectLater(LocalOperationActions.finish(finished, [usage('u2', 2)]),
        throwsFormatException);
    expect(await state(), before);
    expect((await ProductRepository().getProducts()).single.quantity, 8);
    expect(await ProductRepository().getUsage(), hasLength(1));
    final service = (await ServiceRepository().getAll()).single;
    expect(service.fieldId, 't1');
    expect(service.areaHectares, isNull);
    expect(service.fuelLiters, isNull);
    expect((await MachineRepository().getAll()).single.hourMeter, 102);
    expect(await FuelRepository().getAll(), isEmpty);
  });
  test('insufficient stock cannot partially finish an operation', () async {
    await seed();
    await start();
    final before = await state();
    await expectLater(
        LocalOperationActions.finish(
            operation('s').finishWith(
                endMeter: 102, fuelLiters: null, areaHectares: null, notes: ''),
            [usage('u', 11)]),
        throwsFormatException);
    expect(await state(), before);
  });
  test('two active operations cannot use the same tractor', () async {
    await seed();
    await start();
    final before = await state();
    final previous = await ServiceRepository().getAll();
    await expectLater(
        ServiceRepository()
            .saveAll([...previous, operation('s2')], previous: previous),
        throwsFormatException);
    expect(await state(), before);
  });
  test('cancellation preserves history and releases the machine exactly once',
      () async {
    await seed();
    await start();
    await LocalOperationActions.cancel('s', 'Chuva');
    final record = (await ServiceRepository().getAll()).single;
    expect(record.isCancelled, isTrue);
    expect(record.cancellationReason, 'Chuva');
    expect((await MachineRepository().getAll()).single.status,
        MachineStatus.disponivel);
    await expectLater(LocalOperationActions.cancel('s', 'Outro motivo'),
        throwsFormatException);
    await expectLater(ServiceRepository().saveAll([], previous: [record]),
        throwsFormatException);
  });
  test('a machine with operations cannot be deleted', () async {
    await seed();
    await start();
    final machines = await MachineRepository().getAll();
    await expectLater(MachineRepository().saveAll([], previous: machines),
        throwsFormatException);
    expect(await MachineRepository().getAll(), hasLength(1));
  });
  test(
      'NaN, infinity and zero-liter refueling are rejected without changing data',
      () async {
    await seed();
    final before = await state();
    await expectLater(
        ProductRepository().saveProducts(
            [product.copyWith(quantity: double.nan)],
            previous: [product]),
        throwsFormatException);
    await expectLater(
        ProductRepository().saveProducts(
            [product.copyWith(quantity: double.infinity)],
            previous: [product]),
        throwsFormatException);
    await expectLater(
        FuelRepository().saveAll([
          FuelRecord(
              id: 'fuel',
              machineId: 'm',
              machineName: 'Trator',
              operatorName: '',
              date: DateTime.now(),
              hourMeter: 100,
              liters: 0,
              pricePerLiter: 0,
              location: '')
        ], previous: []),
        throwsFormatException);
    expect(await state(), before);
  });
  test('unknown price stays unknown and differs from an explicit zero',
      () async {
    final unknown = FuelRecord(
        id: 'u',
        machineId: 'm',
        machineName: 'Trator',
        operatorName: '',
        date: DateTime.now(),
        hourMeter: 100,
        liters: 10,
        pricePerLiter: null,
        location: '');
    expect(unknown.totalCost, isNull);
    expect(FuelRecord.fromJson(unknown.toJson()).pricePerLiter, isNull);
    expect(
        FuelRecord.fromJson({...unknown.toJson(), 'pricePerLiter': 0})
            .totalCost,
        0);
  });
  test(
      'backup restores records, plots and photo on reopening and keeps the previous state',
      () async {
    await seed(photo: true);
    final service = LocalBackupService();
    final bytes = await service.create();
    expect(service.inspect(bytes)['photos'], hasLength(1));
    await ProductRepository()
        .saveProducts([product.copyWith(quantity: 99)], previous: [product]);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('campo_gestor_products_v1',
        jsonEncode([product.copyWith(quantity: 999).toJson()]));
    await service.restore(bytes);
    await appDatabase.close();
    expect((await ProductRepository().getProducts()).single.quantity, 10);
    final c = await CatalogStore.open();
    expect(await c.records('plots'), hasLength(3));
    final path = (await MachineRepository().getAll()).single.photoPath;
    expect(path, isNotNull);
    expect(await File(path!).exists(), isTrue);
    final copies = await service.previousCopies();
    expect(copies, hasLength(1));
    final previous = service.inspect(await copies.single.readAsBytes());
    final rows = previous['records'] as List;
    expect(
        rows.where((r) => r['module'] == 'products').single['data']['quantity'],
        99);
  });
  test(
      'damaged, foreign and negative-stock backups cannot replace current data',
      () async {
    await seed();
    final service = LocalBackupService();
    final bytes = await service.create();
    final before = await state();
    final invalid = Uint8List.fromList(bytes);
    invalid[invalid.length - 8] ^= 1;
    await expectLater(service.restore(invalid), throwsFormatException);
    final foreign = changed(bytes, (p) {
      (p['records'] as List).first['module'] = 'secrets';
    });
    await expectLater(service.restore(foreign), throwsFormatException);
    final negative = changed(bytes, (p) {
      for (final r in p['records'] as List) {
        if (r['module'] == 'products') r['data']['quantity'] = -2;
      }
    });
    await expectLater(service.restore(negative), throwsFormatException);
    expect(await state(), before);
  });
  test('missing photos and cross-farm plot links are rejected before restoring',
      () async {
    await seed(photo: true);
    await start();
    final service = LocalBackupService();
    final bytes = await service.create();
    final before = await state();
    await expectLater(
        service.restore(changed(bytes, (p) {
          p['photos'] = {};
        })),
        throwsFormatException);
    await expectLater(
        service.restore(changed(bytes, (p) {
          for (final r in p['records'] as List) {
            if (r['module'] == 'services') r['data']['propertyId'] = 'other';
          }
        })),
        throwsFormatException);
    expect(await state(), before);
  });
  test(
      'SQL failure during restoration rolls back the current records and audit',
      () async {
    await seed();
    final service = LocalBackupService();
    final bytes = await service.create();
    await ProductRepository()
        .saveProducts([product.copyWith(quantity: 99)], previous: [product]);
    final before = await state();
    final db = await appDatabase.database;
    await db.execute(
        "CREATE TRIGGER deny_test_restore BEFORE INSERT ON local_records WHEN NEW.module='machines' BEGIN SELECT RAISE(ABORT,'injected restore error'); END");
    await expectLater(service.restore(bytes), throwsA(isA<Exception>()));
    expect(await state(), before);
    expect(await service.previousCopies(), hasLength(1));
  });
  test(
      'migrating old local preferences preserves data and does not insert demo machines',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'campo_gestor_products_v1', jsonEncode([product.toJson()]));
    expect((await ProductRepository().getProducts()).single.quantity, 10);
    await ProductRepository()
        .saveProducts([product.copyWith(quantity: 5)], previous: [product]);
    expect(prefs.getString('campo_gestor_products_v1'), contains('10'));
    await appDatabase.close();
    expect((await ProductRepository().getProducts()).single.quantity, 5);
    expect(await MachineRepository().getAll(), isEmpty);
  });
  test('backup restores photos after moving to a different device directory',
      () async {
    await seed(photo: true);
    final service = LocalBackupService();
    final bytes = await service.create();
    await appDatabase.close();
    final other = await Directory.systemTemp.createTemp('agro-other-device-');
    try {
      PathProviderPlatform.instance = _Paths(other.path);
      SharedPreferences.setMockInitialValues({});
      await service.restore(bytes);
      final machine = (await MachineRepository().getAll()).single;
      expect(machine.photoPath!.startsWith(other.path), isTrue);
      expect(await File(machine.photoPath!).exists(), isTrue);
      expect((await ProductRepository().getProducts()).single.quantity, 10);
      expect(await (await CatalogStore.open()).records('plots'), hasLength(3));
    } finally {
      await appDatabase.close();
      await other.delete(recursive: true);
      PathProviderPlatform.instance = _Paths(dir.path);
    }
  });
  test(
      'implement usage hours are updated once and linked implements cannot be deleted',
      () async {
    await seed();
    const item = FarmImplement(
        id: 'i',
        name: 'Rocadeira TESTE',
        type: 'Rocadeira',
        brand: '',
        model: '',
        hours: 40,
        compatibleMachine: '',
        active: true);
    await ImplementRepository().saveAll([item], previous: []);
    final linked = FarmService.fromJson({
      ...operation('s').toJson(),
      'implementId': 'i',
      'implementName': item.name
    });
    await ServiceRepository().saveAll([linked], previous: []);
    final result = linked.finishWith(
        endMeter: 102, fuelLiters: null, areaHectares: null, notes: '');
    await LocalOperationActions.finish(result, []);
    expect((await ImplementRepository().getAll()).single.hours, 42);
    await expectLater(
        LocalOperationActions.finish(result, []), throwsFormatException);
    expect((await ImplementRepository().getAll()).single.hours, 42);
    await expectLater(
        ImplementRepository()
            .saveAll([], previous: await ImplementRepository().getAll()),
        throwsFormatException);
  });
  test('implement photos and unknown usage hours survive backup and restore',
      () async {
    await seed(photo: true);
    final path = (await MachineRepository().getAll()).single.photoPath;
    final item = FarmImplement(
        id: 'i',
        name: 'Implemento TESTE',
        type: 'Grade',
        brand: '',
        model: '',
        hours: null,
        compatibleMachine: '',
        active: true,
        photoPath: path);
    await ImplementRepository().saveAll([item], previous: []);
    final backup = LocalBackupService();
    final bytes = await backup.create();
    await backup.restore(bytes);
    final restored = (await ImplementRepository().getAll()).single;
    expect(restored.hours, isNull);
    expect(await File(restored.photoPath!).exists(), isTrue);
  });
  test(
      'refueling updates the meter once, preserves unknown price and does not count as measured consumption',
      () async {
    await seed();
    final record = FuelRecord(
        id: 'fuel',
        machineId: 'm',
        machineName: 'Trator TESTE',
        operatorName: '',
        date: DateTime.now(),
        hourMeter: 101,
        liters: 20,
        pricePerLiter: null,
        location: '');
    await LocalFuelActions.add(record);
    await LocalFuelActions.add(record);
    expect(await FuelRepository().getAll(), hasLength(1));
    expect((await FuelRepository().getAll()).single.totalCost, isNull);
    expect((await MachineRepository().getAll()).single.hourMeter, 101);
    expect(await ServiceRepository().getAll(), isEmpty);
  });
  test('a start reading below the last recorded meter is refused', () async {
    await seed();
    final invalid =
        FarmService.fromJson({...operation('s').toJson(), 'startMeter': 99});
    final before = await state();
    await expectLater(ServiceRepository().saveAll([invalid], previous: []),
        throwsFormatException);
    expect(await state(), before);
  });
  test(
      'changing the unit of an already consumed product cannot reinterpret its stock',
      () async {
    await seed();
    await start();
    await LocalOperationActions.finish(
        operation('s').finishWith(
            endMeter: 102, fuelLiters: null, areaHectares: null, notes: ''),
        [usage('u', 2)]);
    final records = await ProductRepository().getProducts();
    final before = await state();
    await expectLater(
        ProductRepository().saveProducts([records.single.copyWith(unit: 'L')],
            previous: records),
        throwsFormatException);
    expect(await state(), before);
  });
}
