import 'dart:convert';
import 'dart:io';

import 'package:agrogestao/features/auth/auth_service.dart';
import 'package:agrogestao/features/local_backup/local_backup_service.dart';
import 'package:agrogestao/features/products/product_record.dart';
import 'package:agrogestao/features/products/product_repository.dart';
import 'package:agrogestao/features/properties/catalog_store.dart';
import 'package:agrogestao/features/services/coffee_input_plan.dart';
import 'package:agrogestao/features/services/farm_service.dart';
import 'package:agrogestao/features/services/local_operation_actions.dart';
import 'package:agrogestao/features/services/service_repository.dart';
import 'package:agrogestao/features/shell/app_shell.dart';
import 'package:agrogestao/features/sync/app_database.dart';
import 'package:agrogestao/features/sync/local_write_batch.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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

const _product = FarmProduct(
  id: 'test-input',
  name: 'Produto fictício',
  category: 'Insumos',
  unit: 'L',
  quantity: 5,
  lot: '',
);

const _spray = CoffeeInputPlan(
  productId: 'test-input',
  productName: 'Produto fictício',
  stockUnit: 'L',
  kind: CoffeeInputKind.spray,
  quantity: 1,
  inputUnit: 'L',
  capacityLiters: 200,
  appliedLiters: 80,
  coveredHectares: 2,
);

const _applied = CoffeeInputPlan(
  productId: 'test-input',
  productName: 'Produto fictício',
  stockUnit: 'L',
  kind: CoffeeInputKind.spray,
  quantity: .8,
  inputUnit: 'L',
  capacityLiters: 200,
  appliedLiters: 60,
  coveredHectares: 1,
);

Future<void> _seed({double stock = 5}) async {
  final catalog = await CatalogStore.open();
  await catalog.save('POST', '/properties', {
    'id': 'farm',
    'name': 'Fazenda fictícia',
    'area_ha': null,
    'plots': [
      {'id': 'plot', 'name': 'Talhão fictício', 'area_ha': 2, 'notes': ''}
    ],
  });
  await ProductRepository().saveProducts(
    [_product.copyWith(quantity: stock)],
    previous: [],
  );
}

FarmService _service() => FarmService(
      id: 'test-service',
      machineId: '',
      machineName: '',
      operatorName: '',
      customer: '',
      property: 'Fazenda fictícia',
      propertyId: 'farm',
      fieldName: 'Talhão fictício',
      fieldId: 'plot',
      jobType: 'Pulverização',
      startedAt: DateTime.now(),
      startMeter: null,
      isManual: true,
      people: 1,
      plannedInputs: [_spray],
    );

ProductUsage _usage(String id, double quantity, {String unit = 'L'}) =>
    ProductUsage(
      id: id,
      productId: _product.id,
      serviceId: 'test-service',
      productName: _product.name,
      quantity: quantity,
      unit: unit,
      date: DateTime.now(),
      machine: '',
      field: 'Talhão fictício',
      operatorName: '',
    );

Future<void> _start(FarmService service) => LocalWriteBatch.run(() async {
      await LocalOperationActions.validatePlannedInputs(service);
      await ServiceRepository().saveAll([service], previous: []);
    });

Future<void> _checkStock(double quantity, int usages) async {
  final repo = ProductRepository();
  expect((await repo.getProducts()).single.quantity, closeTo(quantity, 1e-12));
  expect(await repo.getUsage(), hasLength(usages));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late PathProviderPlatform originalPaths;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('agro-coffee-input-');
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    originalPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(dir.path);
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    expect(await AuthService().enterStandaloneLocalMode(), isTrue);
  });

  tearDown(() async {
    await appDatabase.close();
    debugDefaultTargetPlatformOverride = null;
    PathProviderPlatform.instance = originalPaths;
    await dir.delete(recursive: true);
  });

  test('plano persiste em pausa, reabertura e backup sem baixar estoque',
      () async {
    await _seed();
    final service = _service();
    await _start(service);
    await _checkStock(5, 0);
    await LocalOperationActions.pause(
      service,
      ServiceDay(date: service.startedAt, areaHectares: 1),
    );
    await _checkStock(5, 0);
    await appDatabase.close();

    final repo = ServiceRepository();
    final paused = (await repo.getAll()).single;
    expect(paused.isPaused, isTrue);
    expect(paused.plannedInputs.single.toJson(), _spray.toJson());
    final backup = LocalBackupService();
    final bytes = await backup.create();
    expect(jsonDecode(utf8.decode(bytes))['schemaVersion'], 3);
    await (await CatalogStore.open()).db.delete(
      'local_records',
      where: 'record_id = ?',
      whereArgs: [paused.id],
    );
    expect(await repo.getAll(), isEmpty);
    await backup.restore(bytes);
    final restored = (await repo.getAll()).single;
    expect(restored.isPaused, isTrue);
    expect(restored.plannedInputs.single.toJson(), _spray.toJson());
    await LocalOperationActions.resume(restored, DateTime.now());
    await _checkStock(5, 0);

    final resumed = (await repo.getAll()).single;
    final lastDay = ServiceDay(date: DateTime.now(), areaHectares: 1);
    final used = [_usage('actual', .8)];
    await expectLater(
      LocalOperationActions.finish(service, used, day: lastDay),
      throwsFormatException,
    );
    await _checkStock(5, 0);
    final measured = resumed.copyWith(appliedSprayInputs: [_applied]);
    await expectLater(
      LocalOperationActions.finish(measured, [_usage('too-low', .7)],
          day: lastDay),
      throwsFormatException,
    );
    await _checkStock(5, 0);
    await LocalOperationActions.finish(measured, used, day: lastDay);
    await _checkStock(4.2, 1);
    expect((await repo.getAll()).single.isFinished, isTrue);
    await expectLater(
      LocalOperationActions.finish(resumed, used, day: lastDay),
      throwsFormatException,
    );
    await _checkStock(4.2, 1);
    final completedBytes = await backup.create();
    await appDatabase.close();
    await backup.restore(completedBytes);
    final complete = (await repo.getAll()).single;
    expect(complete.plannedInputs.single.toJson(), _spray.toJson());
    final applied = complete.appliedSprayInputs.single;
    expect(applied.toJson(), _applied.toJson());
    expect(applied.productPerHectare, .8);
    expect(applied.sprayLitersPerHectare, 60);
    await _checkStock(4.2, 1);
  });

  test('consumo repetido não baixa estoque nem sobrescreve histórico',
      () async {
    await _seed();
    final service = _service();
    await _start(service);
    final day = ServiceDay(date: service.startedAt);
    await expectLater(
      LocalOperationActions.finish(
        service,
        [_usage('repetido', .8), _usage('repetido', .8)],
        day: day,
      ),
      throwsFormatException,
    );
    await _checkStock(5, 0);
    final previous = _usage('existente', .8);
    await ProductRepository().saveUsage([previous], previous: []);
    await expectLater(
      LocalOperationActions.finish(service, [previous], day: day),
      throwsFormatException,
    );
    await _checkStock(5, 1);
    expect((await ServiceRepository().getAll()).single.isFinished, isFalse);
  });

  test('produto de uma receita ativa mantém cadastro e unidade até a conclusão',
      () async {
    await _seed();
    final service = _service();
    await _start(service);
    final repo = ProductRepository();
    final original = (await repo.getProducts()).single;
    await expectLater(
        repo.saveProducts([], previous: [original]), throwsFormatException);
    await expectLater(
      repo.saveProducts([original.copyWith(unit: 'kg')], previous: [original]),
      throwsFormatException,
    );
    await LocalOperationActions.finish(service, [_usage('consumo', .8)],
        day: ServiceDay(date: service.startedAt));
    await _checkStock(4.2, 1);
  });

  test('unidade alterada impede plano e consumos inválidos não baixam estoque',
      () async {
    await _seed(stock: .3);
    final service = _service();
    final products = ProductRepository();
    final original = (await products.getProducts()).single;
    final changed = original.copyWith(unit: 'kg');
    await products.saveProducts([changed], previous: [original]);
    await expectLater(_start(service), throwsFormatException);
    expect(await ServiceRepository().getAll(), isEmpty);
    await products.saveProducts([original], previous: [changed]);
    await _start(service);
    final lastDay = ServiceDay(date: service.startedAt);
    for (final invalid in [
      _usage('unit', .1, unit: 'kg'),
      _usage('short', .31)
    ]) {
      await expectLater(
        LocalOperationActions.finish(service, [invalid], day: lastDay),
        throwsFormatException,
      );
      await _checkStock(.3, 0);
      expect((await ServiceRepository().getAll()).single.isFinished, isFalse);
    }
    await LocalOperationActions.finish(
      service,
      [_usage('first', .1), _usage('second', .2)],
      day: lastDay,
    );
    expect((await products.getProducts()).single.quantity, 0);
    expect(await products.getUsage(), hasLength(2));
  });

  testWidgets('talhão abre serviço e conclusão confirma o consumo real',
      (tester) async {
    tester.view.physicalSize = const Size(390, 1280);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    Future<void> waitFor(Finder finder) async {
      for (var attempt = 0;
          attempt < 150 && finder.evaluate().isEmpty;
          attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
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

    Finder field(String label) => find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == label,
          description: 'campo $label',
        );

    Future<void> enter(String label, String value) async {
      final target = field(label);
      await waitFor(target);
      await tester.ensureVisible(target);
      await tester.enterText(target, value);
      await tester.pump();
    }

    await tester.runAsync(_seed);
    try {
      await tester.pumpWidget(const MaterialApp(home: AppShell()));
      await tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Propriedades'),
      ));
      await tap(find.widgetWithText(ListTile, 'Fazenda fictícia'));
      await tap(find.text('Operações deste talhão'));
      await tap(find.byType(FloatingActionButton));
      expect(find.text('Fazenda fictícia · Talhão fictício'), findsWidgets);
      await tap(find.text('Planejar insumo'));
      await enter('Buscar produto pelo começo do nome', 'Pro');
      await tap(find.widgetWithText(ListTile, _product.name));
      await tap(find.byType(DropdownButtonFormField<CoffeeInputKind>));
      await tap(find.text('Pulverização por carga').last);
      await enter('Produto na carga (L)', '1');
      await enter('Capacidade da carga (L)', '200');
      await enter('Calda da carga (L)', '80');
      expect(
          find.textContaining('Produto por hectare: Pendente'), findsWidgets);
      await enter('Área coberta (ha)', '2');
      expect(
          find.textContaining('Produto por hectare: 0,5 L/ha'), findsWidgets);
      expect(find.textContaining('Calda por hectare: 40 L/ha'), findsWidgets);
      await tap(find.text('Salvar insumo'));
      await tap(find.text('Iniciar'));
      await waitFor(find.text('Serviço manual · 1 pessoa'));
      await tester.runAsync(() => _checkStock(5, 0));
      final products = ProductRepository();
      final emptyStock = _product.copyWith(quantity: 0);
      await tester.runAsync(
          () => products.saveProducts([emptyStock], previous: [_product]));
      await tap(find.text('Finalizar'));
      await waitFor(find.textContaining('Nenhum produto com saldo em estoque'));
      expect(find.textContaining('módulo v2'), findsNothing);
      await tap(find.text('Cancelar'));
      await tester.runAsync(
          () => products.saveProducts([_product], previous: [emptyStock]));
      await tap(find.text('Finalizar'));
      final used = field('Quantidade utilizada (L)');
      await waitFor(used);
      final suggested = tester.widget<TextField>(used).controller!.text;
      expect(double.parse(suggested.replaceAll(',', '.')), 1);
      await tap(find.text('Registrar cargas aplicadas'));
      await tap(find.text('Copiar carga planejada 1 · Produto fictício'));
      await enter('Produto na carga (L)', '0,8');
      await enter('Calda da carga (L)', '60');
      await enter('Área coberta (ha)', '1');
      await tap(find.text('Salvar carga aplicada'));
      await enter('Quantidade utilizada (L)', '0,7');
      await tap(find.text('Concluir'));
      expect(
          find.textContaining('Informe ao menos o total das cargas aplicadas'),
          findsOneWidget);
      await tester.runAsync(() => _checkStock(5, 0));
      await enter('Quantidade utilizada (L)', '0,8');
      await tap(find.text('Concluir'));
      await tap(find.text('Ver insumos usados'));
      await waitFor(find.text('Cargas aplicadas'));
      await tester.runAsync(() async {
        final saved = (await ServiceRepository().getAll()).single;
        expect(saved.propertyId, 'farm');
        expect(saved.fieldId, 'plot');
        expect(saved.isFinished, isTrue);
        expect(saved.plannedInputs.single.toJson(), _spray.toJson());
        expect(saved.appliedSprayInputs.single.toJson(), _applied.toJson());
        expect((await ProductRepository().getUsage()).single.quantity, .8);
        await _checkStock(4.2, 1);
      });
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
