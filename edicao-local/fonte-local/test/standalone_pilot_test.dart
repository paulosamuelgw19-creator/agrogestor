import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:agrogestao/features/auth/auth_service.dart';
import 'package:agrogestao/features/machines/machine_repository.dart';
import 'package:agrogestao/features/machines/machine.dart';
import 'package:agrogestao/features/properties/catalog_store.dart';
import 'package:agrogestao/features/services/services_screen.dart';
import 'package:agrogestao/features/services/service_repository.dart';
import 'package:agrogestao/features/sync/app_database.dart';
import 'package:agrogestao/features/sync/farm_api_client.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('agro-local-pilot-');
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    PathProviderPlatform.instance = _Paths(dir.path);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    expect(FarmApiClient.standaloneLocalMode, isTrue,
        reason: 'Execute with --dart-define=AGRO_STANDALONE_LOCAL=true');
    expect(await AuthService().enterStandaloneLocalMode(), isTrue);
    final catalog = await CatalogStore.open();
    for (final table in ['local_records', 'sync_metadata', 'local_audit']) {
      await catalog.db.delete(table);
    }
    for (final table in ['catalog_records', 'catalog_outbox', 'catalog_meta']) {
      await catalog.db.delete(table);
    }
  });
  tearDownAll(() async {
    await appDatabase.close();
    debugDefaultTargetPlatformOverride = null;
    await dir.delete(recursive: true);
  });

  Future<void> farm() async {
    final store = await CatalogStore.open();
    await store.save('POST', '/properties', {
      'id': 'farm',
      'name': 'Cadastro de teste automatizado',
      'area_ha': null,
      'plots': [
        for (var i = 1; i <= 3; i++)
          {'id': 'plot-$i', 'name': 'Talhao $i', 'area_ha': null, 'notes': ''}
      ],
    });
  }

  test('new local installation is empty and does not use a configured server',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('agro_farm_server_url_v1', 'https://example.invalid');
    expect(await FarmApiClient.instance.baseUrl, isNull);
    expect(await MachineRepository().getAll(), isEmpty);
    expect(await ServiceRepository().getAll(), isEmpty);
    final catalog = await CatalogStore.open();
    expect(await catalog.records('properties'), isEmpty);
    expect(await catalog.records('plots'), isEmpty);
    expect(AuthService().currentUser?.farmId, isNull);
  });

  test('farm and three plots survive reopening without a pending server queue',
      () async {
    await farm();
    await appDatabase.close();
    final reopened = await CatalogStore.open();
    expect(await reopened.records('properties'), hasLength(1));
    expect(await reopened.records('plots'), hasLength(3));
    expect(
        (await reopened.records('plots'))
            .every((p) => p['property_id'] == 'farm'),
        isTrue);
    expect((await reopened.records('properties')).single['area_ha'], isNull);
    expect(await reopened.db.query('catalog_outbox'), isEmpty);
    expect(await reopened.notice(), contains('Salvar backup'));
    expect(await reopened.notice(), isNot(contains('PC gestor')));
  });

  testWidgets(
      'start local operation selects farm and plot and persists stable links',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Future<void> settle() async {
      for (var i = 0; i < 150; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 30));
        if (!tester.binding.hasScheduledFrame &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty) {
          break;
        }
      }
      await tester.pumpAndSettle(const Duration(milliseconds: 20),
          EnginePhase.sendSemanticsUpdate, const Duration(seconds: 5));
    }

    await tester.runAsync(farm);
    const machine = Machine(
        id: 'tractor',
        name: 'Trator de teste',
        brand: 'Marca',
        model: 'Modelo',
        year: 2020,
        hourMeter: 100,
        fuelType: 'Diesel',
        status: MachineStatus.disponivel);
    await tester
        .runAsync(() => MachineRepository().saveAll([machine], previous: []));
    await tester.pumpWidget(const MaterialApp(home: ServicesScreen()));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settle();
    await tester.tap(find.text('Iniciar operação').first);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settle();
    for (var attempt = 0;
        attempt < 100 &&
            find.byType(DropdownButtonFormField<String>).evaluate().isEmpty;
        attempt++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
    expect(find.byType(DropdownButtonFormField<String>), findsNWidgets(2));
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settle();
    await tester.tap(find.text('Cadastro de teste automatizado').last);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).last);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settle();
    await tester.tap(find.text('Talhao 2').last);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settle();
    await tester.tap(find.text('Iniciar').last);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settle();
    final operation =
        (await tester.runAsync(() => ServiceRepository().getAll()))!.single;
    expect(operation.propertyId, 'farm');
    expect(operation.fieldId, 'plot-2');
    expect(operation.fieldName, 'Talhao 2');
    expect(operation.machineId, 'tractor');
    final finished = operation.finishWith(
        endMeter: 102,
        fuelLiters: 0,
        areaHectares: 0,
        notes: 'Sem medicao de area');
    await tester.runAsync(
        () => ServiceRepository().saveAll([finished], previous: [operation]));
    final saved =
        (await tester.runAsync(() => ServiceRepository().getAll()))!.single;
    expect(saved.fieldId, 'plot-2');
    expect(saved.workedHours, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await settle();
    debugDefaultTargetPlatformOverride = null;
  });
}
