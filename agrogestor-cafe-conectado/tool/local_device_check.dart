// Native Android integration check. Never the distributed APK entry point.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:agrogestao/features/auth/auth_service.dart';
import 'package:agrogestao/features/local_backup/local_backup_service.dart';
import 'package:agrogestao/features/machines/machine.dart';
import 'package:agrogestao/features/machines/machine_repository.dart';
import 'package:agrogestao/features/implements/farm_implement.dart';
import 'package:agrogestao/features/implements/implement_repository.dart';
import 'package:agrogestao/features/products/product_record.dart';
import 'package:agrogestao/features/products/product_repository.dart';
import 'package:agrogestao/features/properties/catalog_store.dart';
import 'package:agrogestao/features/services/farm_service.dart';
import 'package:agrogestao/features/services/service_repository.dart';
import 'package:agrogestao/features/services/local_operation_actions.dart';
import 'package:agrogestao/features/fuel/fuel_record.dart';
import 'package:agrogestao/features/fuel/fuel_repository.dart';
import 'package:agrogestao/features/fuel/local_fuel_actions.dart';
import 'package:agrogestao/features/sync/app_database.dart';
import 'package:agrogestao/features/sync/farm_api_client.dart';

void require(bool ok, String label) {
  if (!ok) throw StateError(label);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  String result;
  try {
    require(FarmApiClient.standaloneLocalMode, 'Local flag required');
    require(await AuthService().enterStandaloneLocalMode(), 'Local login');
    final machines = MachineRepository();
    final products = ProductRepository();
    final services = ServiceRepository();
    final catalog = await CatalogStore.open();
    require(
        (await machines.getAll()).isEmpty &&
            (await catalog.records('properties')).isEmpty,
        'Fresh installation required; no data replaced');
    require(await FarmApiClient.instance.baseUrl == null, 'No server');
    final root = await getApplicationSupportDirectory();
    final photo = File('${root.path}/attachments/device-test.png');
    await photo.parent.create(recursive: true);
    await photo.writeAsBytes(base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jWZkAAAAASUVORK5CYII='));
    await catalog.save('POST', '/properties', {
      'id': 'device-farm',
      'name': 'Fazenda TESTE - sem dados reais',
      'plots': [
        for (var i = 1; i <= 3; i++)
          {
            'id': 'device-plot-$i',
            'name': 'Talhao TESTE $i',
            'area_ha': null,
            'notes': 'Teste automatizado'
          }
      ]
    });
    await machines.saveAll([
      Machine(
          id: 'device-machine',
          name: 'Trator TESTE',
          brand: 'Marca TESTE',
          model: 'Modelo TESTE',
          year: 2020,
          hourMeter: 100,
          fuelType: 'Diesel',
          status: MachineStatus.emOperacao,
          photoPath: photo.path)
    ], previous: []);
    await ImplementRepository().saveAll([
      FarmImplement(
          id: 'device-implement',
          name: 'Implemento TESTE',
          type: 'Adubadora',
          brand: 'TESTE',
          model: 'TESTE',
          hours: 10,
          compatibleMachine: '',
          active: true,
          photoPath: photo.path)
    ], previous: []);
    await products.saveProducts([
      const FarmProduct(
          id: 'device-product',
          name: 'Insumo TESTE',
          category: 'Adubo',
          unit: 'kg',
          quantity: 10,
          lot: '')
    ], previous: []);
    final op = FarmService(
        id: 'device-operation',
        machineId: 'device-machine',
        machineName: 'Trator TESTE',
        operatorName: 'Gestor TESTE',
        customer: '',
        property: 'Fazenda TESTE - sem dados reais',
        propertyId: 'device-farm',
        fieldName: 'Talhao TESTE 1',
        fieldId: 'device-plot-1',
        jobType: 'Adubacao',
        startedAt: DateTime.now(),
        startMeter: 100,
        implementId: 'device-implement',
        implementName: 'Implemento TESTE');
    await services.saveAll([op], previous: []);
    final fuel = FuelRecord(
        id: 'device-fuel',
        machineId: 'device-machine',
        machineName: 'Trator TESTE',
        operatorName: 'Gestor TESTE',
        date: DateTime.now(),
        hourMeter: 101,
        liters: 20,
        pricePerLiter: 6,
        location: 'Posto TESTE');
    await LocalFuelActions.add(fuel);
    await LocalFuelActions.add(fuel);
    require(
        (await FuelRepository().getAll()).length == 1, 'Refueling idempotency');
    final finished = op.finishWith(
        endMeter: 102,
        fuelLiters: null,
        areaHectares: null,
        notes: 'Teste automatizado no Android; consumo nao medido');
    final usage = ProductUsage(
        id: 'device-usage',
        productId: 'device-product',
        serviceId: op.id,
        productName: 'Insumo TESTE',
        quantity: 2,
        unit: 'kg',
        date: DateTime.now(),
        machine: 'Trator TESTE',
        field: 'Talhao TESTE 1',
        operatorName: 'Gestor TESTE');
    await LocalOperationActions.finish(finished, [usage]);
    bool duplicateRejected = false;
    try {
      await LocalOperationActions.finish(finished, [usage]);
    } on FormatException {
      duplicateRejected = true;
    }
    require(
        duplicateRejected &&
            (await products.getProducts()).single.quantity == 8,
        'No duplicate stock deduction');
    require((await machines.getAll()).single.hourMeter == 102, 'Machine meter');
    require((await ImplementRepository().getAll()).single.hours == 12,
        'Implement hours');
    require((await services.getAll()).single.fuelLiters == null,
        'Refueled is not consumed');
    final backup = LocalBackupService();
    final bytes = await backup.create();
    await File('${root.path}/device-tested.agrobackup')
        .writeAsBytes(bytes, flush: true);
    final previous = await products.getProducts();
    await products.saveProducts([previous.single.copyWith(quantity: 99)],
        previous: previous);
    final preserved = await backup.restore(bytes);
    require(await File(preserved).exists(), 'Pre-restore safety copy');
    require(
        (await products.getProducts()).single.quantity == 8, 'Restore stock');
    final restored = (await machines.getAll()).single;
    require(
        restored.photoPath != photo.path &&
            await File(restored.photoPath!).exists(),
        'Rebased photo restore');
    require((await catalog.records('plots')).length == 3, 'Restore plot links');
    await appDatabase.close();
    require(
        (await products.getProducts()).single.quantity == 8 &&
            (await services.getAll()).single.isFinished,
        'SQLite persisted after reopening');
    result =
        'PASS: Android local login, empty install, farm/3 plots, machine/photo, implement, operation, refuel replay, stock 10-2=8, meter 102, implement 12h, unknown consumption, backup file, restore, safety copy, photo rebasing and SQLite reopen.';
    await File('${root.path}/device-check-result.json').writeAsString(
        jsonEncode({
          'passed': true,
          'result': result,
          'platform': Platform.operatingSystem,
          'timestamp': DateTime.now().toIso8601String()
        }),
        flush: true);
  } catch (e, st) {
    result = 'FAIL: $e\n$st';
    final root = await getApplicationSupportDirectory();
    await File('${root.path}/device-check-result.json').writeAsString(
        jsonEncode({'passed': false, 'result': result}),
        flush: true);
  }
  debugPrint('AGRO_DEVICE_CHECK $result');
  runApp(MaterialApp(
      home: Scaffold(
          appBar: AppBar(title: const Text('AgroGestor - verificacao Android')),
          body: SingleChildScrollView(
              padding: const EdgeInsets.all(20), child: Text(result)))));
}
