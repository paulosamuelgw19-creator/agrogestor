import 'package:agrogestao/features/operations_v2/v2_export.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';
import 'package:agrogestao/features/operations_v2/v2_store.dart';
import 'package:agrogestao/features/sync/farm_api_client.dart';
import 'package:agrogestao/features/properties/catalog_store.dart';
import 'package:agrogestao/features/properties/geography_store.dart';
import 'package:agrogestao/features/machines/catalog_photos.dart';
import 'package:image_picker/image_picker.dart';
import 'package:agrogestao/features/work/work_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final configPath = Platform.environment['AGRO_V2_E2E_CONFIG'];
  test('cliente móvel → fila SQLite → API FastAPI real → estoque e relatório',
      () async {
    HttpOverrides.global = null;
    final config = jsonDecode(File(configPath!).readAsStringSync()) as Map;
    sqfliteFfiInit();
    final folder = await Directory.systemTemp.createTemp('agro-real-api-');
    final db =
        await databaseFactoryFfi.openDatabase('${folder.path}/mobile.sqlite3');
    try {
      await V2Store.initialize(db);
      final client = FarmApiClient.forSession(
          baseUrl: config['url'] as String,
          token: config['token'] as String,
          farmId: 'org-a');
      final store = V2Store(
          db: db,
          client: client,
          scope: 'e2e-synthetic',
          tokenExpiry: DateTime.now().add(const Duration(hours: 1)));
      final property = config['property'] as String;
      final capabilities = await client.v2('GET', '/capabilities');
      expect(capabilities['unifiedProducts'], isTrue);
      expect(capabilities['propertyCatalog'], isTrue);
      final root = await client.v2('GET', '/workspace');
      await CatalogStore.initialize(db);
      final offlineCatalog = CatalogStore(
          db: db,
          scope: jsonEncode(['synthetic-server', 'org-a', 'real-api-manager']),
          manager: true,
          tokenExpiry: DateTime.now().add(const Duration(hours: 1)));
      final sharedProperty = const Uuid().v4();
      final sharedPlot = const Uuid().v4();
      final sharedCrop = const Uuid().v4();
      final sharedCycle = const Uuid().v4();
      final responsible = const Uuid().v4();
      await offlineCatalog.save('POST', '/clients',
          {'id': responsible, 'name': 'Responsável fictício offline'});
      await offlineCatalog.save('POST', '/properties', {
        'id': sharedProperty,
        'client_id': responsible,
        'name': 'Fazenda fictícia criada offline',
        'area_ha': '8'
      });
      await offlineCatalog.save('POST', '/plots', {
        'id': sharedPlot,
        'property_id': sharedProperty,
        'name': 'Talhão fictício offline',
        'area_ha': '4'
      });
      await offlineCatalog.save('POST', '/crops',
          {'id': sharedCrop, 'name': 'Café offline', 'kind': 'coffee'});
      await offlineCatalog.save('POST', '/cycles', {
        'id': sharedCycle,
        'name': 'Safra fictícia offline',
        'plot_id': sharedPlot,
        'crop_id': sharedCrop,
        'area_ha': '4',
        'starts_on': '2026-01-01',
        'ends_on': '2026-12-31'
      });
      expect(await offlineCatalog.pending(), hasLength(5));
      final managerCatalog = CatalogStore(
          db: db,
          scope: offlineCatalog.scope,
          manager: true,
          client: client,
          tokenExpiry: offlineCatalog.tokenExpiry);
      await managerCatalog.sync();
      expect(await managerCatalog.pending(), isEmpty);
      final operatorClient = FarmApiClient.forSession(
          baseUrl: config['url'] as String,
          token: config['worker_token'] as String,
          farmId: 'org-a');
      final operatorCatalog = CatalogStore(
          db: db,
          scope: jsonEncode(['synthetic-server', 'org-a', 'real-api-operator']),
          manager: false,
          client: operatorClient,
          tokenExpiry: offlineCatalog.tokenExpiry);
      await operatorCatalog.sync();
      expect((await operatorCatalog.records('properties')).single['id'],
          sharedProperty);
      expect((await operatorCatalog.records('plots')).single['id'], sharedPlot);
      await client.v2('POST', '/properties/$sharedProperty/inventory', data: {
        'id': const Uuid().v4(),
        'input_id': config['input'],
        'kind': 'opening',
        'quantity': '10',
        'value_cents': 6000,
        'occurred_on': '2026-01-01'
      });
      final operatorStore = V2Store(
          db: db,
          client: operatorClient,
          scope: jsonEncode(['synthetic-server', 'org-a', 'real-api-operator']),
          tokenExpiry: offlineCatalog.tokenExpiry);
      await operatorStore.refresh(sharedProperty);
      await operatorStore.queueOperation(sharedProperty, {
        'id': const Uuid().v4(),
        'cycle_id': sharedCycle,
        'kind': 'application',
        'performed_on': '2026-01-03',
        'area_ha': '4',
        'machines': [],
        'inputs': [
          {'input_id': config['input'], 'quantity': '2'}
        ]
      });
      await operatorStore.sync();
      expect(await operatorStore.pending(), isEmpty);
      final sharedStock = await client.v2(
          'GET', '/properties/$sharedProperty/inventory/${config['input']}');
      expect(sharedStock['quantity'], '8');
      expect(sharedStock['value_cents'], 4800);
      final propertyId = const Uuid().v4();
      final plotId = const Uuid().v4();
      await client.v2('POST', '/properties', data: {
        'id': propertyId,
        'client_id': items(root, 'clients').first['id'],
        'name': 'Propriedade fictícia do teste móvel',
        'area_ha': '5',
        'location': 'Local fictício',
        'notes': 'Somente teste',
      });
      await client.v2('POST', '/plots', data: {
        'id': plotId,
        'property_id': propertyId,
        'name': 'Talhão teste',
        'area_ha': '2.5',
        'notes': 'Observação do teste',
      });
      await client.v2('PATCH', '/plots/$plotId', data: {
        'id': const Uuid().v4(),
        'expected_version': 1,
        'name': 'Talhão arquivado',
        'area_ha': '2.5',
        'notes': 'Histórico preservado',
        'archived': true,
      });
      expect(
          items(
              await client.v2('GET', '/properties/$propertyId/plots'), 'items'),
          isEmpty);
      final archived = items(
              await client.v2('GET', '/properties/$propertyId/plots',
                  query: {'include_archived': true}),
              'items')
          .single;
      expect(archived['id'], plotId);
      expect(archived['version'], 2);
      final before = await store.refresh(property);
      final product =
          items(before, 'inputs').firstWhere((p) => p['id'] == config['input']);
      await client.v2('PATCH', '/inputs/${config['input']}', data: {
        'id': const Uuid().v4(),
        'name': product['name'],
        'category': 'Combustíveis e lubrificantes',
        'product_type': 'Diesel',
        'expected_name': product['name'],
        'expected_category': product['category'],
        'expected_product_type': product['product_type'],
      });
      final operation = {
        'id': const Uuid().v4(),
        'cycle_id': config['cycle'],
        'kind': 'application',
        'performed_on': '2026-01-03',
        'area_ha': '10',
        'notes': 'Teste integrado fictício',
        'machines': [
          {
            'machine_id': config['machine'],
            'start_meter': '100',
            'end_meter': '103'
          }
        ],
        'inputs': [
          {'input_id': config['input'], 'quantity': '30'}
        ]
      };
      await store.queueOperation(property, operation);
      expect((await store.pending()).length, 1);
      await store.sync();
      expect(await store.pending(), isEmpty);
      final snapshot = await store.refresh(property);
      expect(
          items(snapshot, 'inputs')
              .firstWhere((p) => p['id'] == config['input'])['product_type'],
          'Diesel');
      expect(
          items(snapshot, 'inventory')
              .firstWhere((i) => i['input_id'] == config['input'])['quantity'],
          '70');
      final report =
          await client.v2('GET', '/cycles/${config['cycle']}/report');
      expect(report['metrics']['registered_cost']['value'], '54000');
      expect(report['metrics']['cost_per_cycle_ha']['value'], '5400');
      expect(report['operations'][0]['notes'], 'Teste integrado fictício');
      // A lost acknowledgement can be safely replayed with its original UUID.
      await client.v2('POST', '/operations', data: operation);
      final again = await client.v2('GET', '/cycles/${config['cycle']}/report');
      expect((again['operations'] as List).length, 1);
      await WorkStore.initialize(store);
      final managerWork = WorkStore(store);
      await managerWork.refresh();
      final taskId = const Uuid().v4();
      await managerWork.queue('/work/tasks', {
        'id': taskId,
        'cycle_id': sharedCycle,
        'assignee_id': 'worker',
        'title': 'Aplicação planejada fictícia',
        'kind': 'application',
        'due_on': '2026-10-14',
        'planned_area_ha': '1',
        'planned_cost_cents': 600,
        'planned_inputs': [
          {'input_id': config['input'], 'quantity': '1'}
        ]
      });
      await managerWork.sync();
      expect(await managerWork.pending(), isEmpty);
      final operatorWork = WorkStore(operatorStore);
      await operatorWork.refresh();
      final task = items((await operatorWork.workspace())!, 'tasks').single;
      expect(task['id'], taskId);
      expect(task.containsKey('planned_cost_cents'), isFalse);
      await operatorWork.queue('/work/tasks/$taskId/progress', {
        'id': const Uuid().v4(),
        'expected_version': 1,
        'status': 'in_progress',
        'description': 'Iniciei a tarefa fictícia'
      });
      await operatorWork.sync();
      await operatorStore.refresh(sharedProperty);
      await operatorStore.queueOperation(sharedProperty, {
        'id': const Uuid().v4(),
        'task_id': taskId,
        'task_expected_version': 2,
        'cycle_id': sharedCycle,
        'kind': 'application',
        'performed_on': '2026-10-14',
        'area_ha': '1',
        'machines': [],
        'inputs': [
          {'input_id': config['input'], 'quantity': '1'}
        ]
      });
      await operatorStore.sync();
      expect(await operatorStore.pending(), isEmpty);
      await managerWork.refresh();
      final done = items((await managerWork.workspace())!, 'tasks').single;
      expect(done['status'], 'completed');
      expect(done['actual']['registered_cost']['value'], '600');
      final workMachine = const Uuid().v4(), workPart = const Uuid().v4();
      await client.v2('POST', '/machines', data: {
        'id': workMachine,
        'name': 'Trator da oficina fictícia',
        'hour_meter': '100',
        'hourly_cost_cents': 12000,
        'property_ids': [sharedProperty]
      });
      await client.v2('POST', '/inputs',
          data: {'id': workPart, 'name': 'Peça fictícia', 'unit': 'un'});
      await client.v2('POST', '/properties/$sharedProperty/inventory', data: {
        'id': const Uuid().v4(),
        'input_id': workPart,
        'kind': 'opening',
        'quantity': '10',
        'value_cents': 10000,
        'occurred_on': '2026-01-01'
      });
      await operatorWork.refresh();
      final orderId = const Uuid().v4();
      await operatorWork.queue('/work/orders', {
        'id': orderId,
        'property_id': sharedProperty,
        'machine_id': workMachine,
        'title': 'Vazamento fictício',
        'description': 'Relato do operador, somente teste',
        'stop_machine': true
      });
      await operatorWork.sync();
      await managerWork.refresh();
      await managerWork.queue('/work/orders/$orderId/assign', {
        'id': const Uuid().v4(),
        'expected_version': 1,
        'mechanic_id': 'mechanic',
        'priority': 'high',
        'due_on': '2026-10-14'
      });
      await managerWork.sync();
      await managerWork.queue('/work/orders/$orderId/reserve', {
        'id': const Uuid().v4(),
        'expected_version': 2,
        'input_id': workPart,
        'quantity': '5'
      });
      await managerWork.sync();
      final mechanicClient = FarmApiClient.forSession(
          baseUrl: config['url'] as String,
          token: config['mechanic_token'] as String,
          farmId: 'org-a');
      final mechanicCore = V2Store(
          db: db,
          client: mechanicClient,
          scope: 'real-api-mechanic',
          tokenExpiry: offlineCatalog.tokenExpiry);
      final mechanicWork = WorkStore(mechanicCore);
      await mechanicWork.refresh();
      final notePhoto = File('${folder.path}/fictitious.png');
      await notePhoto.writeAsBytes(base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jr2kAAAAASUVORK5CYII='));
      await mechanicWork.queue('/work/orders/$orderId/progress', {
        'id': const Uuid().v4(),
        'expected_version': 3,
        'description': 'Desmontagem fictícia iniciada',
        'status': 'in_progress'
      }, photoPaths: [
        notePhoto.path
      ]);
      await mechanicWork.queue('/work/orders/$orderId/progress', {
        'id': const Uuid().v4(),
        'expected_version': 4,
        'description': 'Peça identificada, aguardando chegada',
        'status': 'waiting_parts'
      });
      await mechanicWork.sync();
      expect(await mechanicWork.pending(), isEmpty);
      final diary = items((await mechanicWork.workspace())!, 'orders').single;
      expect(items(diary, 'progress'), hasLength(2));
      expect(items(diary, 'photos'), hasLength(1));
      expect(
          await mechanicClient.workPhoto(
              'order', orderId, items(diary, 'photos').single['id'] as String),
          isNotEmpty);
      await mechanicWork.queue('/work/orders/$orderId/progress', {
        'id': const Uuid().v4(),
        'expected_version': 5,
        'description': 'Peça recebida; retomei o serviço',
        'status': 'in_progress'
      });
      await mechanicWork.sync();
      await mechanicWork.queue('/work/orders/$orderId/progress', {
        'id': const Uuid().v4(),
        'expected_version': 6,
        'description': 'Reparo fictício testado e concluído',
        'status': 'completed',
        'machine_released': true,
        'parts': [
          {'input_id': workPart, 'quantity': '2'}
        ],
        'labor_hours': '1',
        'labor_cost_cents': 5000,
        'next_due_meter': '150'
      });
      await mechanicWork.sync();
      expect(await mechanicWork.pending(), isEmpty);
      await managerWork.refresh();
      final completed =
          items((await managerWork.workspace())!, 'orders').single;
      expect(completed['status'], 'completed');
      expect(completed['machine_released'], 1);
      expect(completed['registered_cost']['value'], '7000');
      expect(completed['reservations'], isEmpty);
      expect(items(completed, 'progress'), hasLength(4));
      final partBalance = await client.v2(
          'GET', '/properties/$sharedProperty/inventory/$workPart');
      expect(partBalance['quantity'], '8');
      expect(partBalance['value_cents'], 8000);
      await operatorWork.refresh();
      await operatorWork.queue('/work/checklists', {
        'id': const Uuid().v4(),
        'property_id': sharedProperty,
        'machine_id': workMachine,
        'phase': 'after',
        'items': [
          {'label': 'Condição visual conferida', 'ok': true}
        ],
        'notes': 'Checklist fictício'
      });
      await operatorWork.sync();
      await managerWork.queue('/work/stock-limits', {
        'id': const Uuid().v4(),
        'property_id': sharedProperty,
        'input_id': workPart,
        'minimum_quantity': '9'
      });
      await managerWork.sync();
      final panel = (await managerWork.workspace())!;
      expect(items(panel, 'checklists'), hasLength(1));
      expect(
          items(panel, 'alerts').any((a) => a['kind'] == 'low_stock'), isTrue);
      // A daily completion can carry both stock and station refueling.
      final stockBefore = await client.v2(
          'GET', '/properties/$sharedProperty/inventory/${config['input']}');
      final reportBefore =
          await client.v2('GET', '/cycles/$sharedCycle/report');
      await operatorStore.refresh(sharedProperty);
      final fuelOperation = {
        'id': const Uuid().v4(),
        'cycle_id': sharedCycle,
        'kind': 'management',
        'performed_on': '2026-10-14',
        'machines': <Json>[],
        'inputs': <Json>[],
        'notes': 'Abastecimentos fictícios ao encerrar o serviço',
        'refuelings': [
          {
            'id': const Uuid().v4(),
            'machine_id': workMachine,
            'source': 'stock',
            'input_id': config['input'],
            'liters': '1',
            'hour_meter': '100'
          },
          {
            'id': const Uuid().v4(),
            'machine_id': workMachine,
            'source': 'external',
            'liters': '5',
            'hour_meter': '100',
            'unit_price_cents': 625,
            'location': 'Posto FICTÍCIO'
          }
        ]
      };
      await operatorStore.queueOperation(sharedProperty, fuelOperation);
      expect(await operatorStore.pending(), hasLength(1));
      await operatorStore.sync();
      expect(await operatorStore.pending(), isEmpty);
      await operatorClient.v2('POST', '/operations', data: fuelOperation);
      final fuelSaved =
          await client.v2('GET', '/operations/${fuelOperation['id']}');
      expect(items(fuelSaved, 'refuelings'), hasLength(2));
      final stockAfter = await client.v2(
          'GET', '/properties/$sharedProperty/inventory/${config['input']}');
      expect(num.parse('${stockAfter['quantity']}'),
          num.parse('${stockBefore['quantity']}') - 1);
      final reportAfter = await client.v2('GET', '/cycles/$sharedCycle/report');
      final stockValue =
          items(fuelSaved, 'refuelings').first['total_cost_cents'] as int;
      expect(
          num.parse(
              '${reportAfter['metrics']['registered_cost']['known_subtotal']}'),
          num.parse(
                  '${reportBefore['metrics']['registered_cost']['known_subtotal']}') +
              stockValue +
              3125);
      final fuelRows = reportRows(reportAfter);
      expect(fuelRows.any((row) => row.contains('Posto FICTÍCIO')), isTrue);
      // New operator drafts cross the real SQLite queue and API authorization.
      final fieldCatalog = CatalogStore(
          db: db,
          scope: jsonEncode(
              ['synthetic-server', 'org-a', 'real-api-operator-catalog']),
          manager: false,
          operator: true,
          client: operatorClient,
          tokenExpiry: DateTime.now().add(const Duration(hours: 1)));
      final newClient = const Uuid().v4(), newProperty = const Uuid().v4();
      await fieldCatalog.save('POST', '/clients',
          {'id': newClient, 'name': 'Responsável criado no campo - FICTÍCIO'});
      await fieldCatalog.save('POST', '/properties', {
        'id': newProperty,
        'client_id': newClient,
        'name': 'Propriedade criada pelo operador - FICTÍCIA',
        'area_ha': null,
      });
      await fieldCatalog.save('POST', '/plots', {
        'id': const Uuid().v4(),
        'property_id': newProperty,
        'name': 'Talhão sem área conferida - FICTÍCIO',
        'area_ha': null,
      });
      expect(await fieldCatalog.pending(), hasLength(3));
      await fieldCatalog.sync();
      expect(await fieldCatalog.pending(), isEmpty);
      final ownProperty = (await fieldCatalog.records('properties'))
          .singleWhere((p) => p['id'] == newProperty);
      expect(ownProperty['access_role'], 'employee');
      expect(ownProperty['area_ha'], isNull);
      final createdMachine =
          await operatorClient.v2('POST', '/machines', data: {
        'id': const Uuid().v4(),
        'name': 'Máquina criada pelo operador - FICTÍCIA',
        'hour_meter': '0',
        'property_ids': [newProperty],
      });
      expect(createdMachine.containsKey('hourly_cost_cents'), isFalse);
      expect(
          items(await client.v2('GET', '/properties'), 'items')
              .any((p) => p['id'] == newProperty),
          isTrue);
      final bundleStore = CatalogStore(
          db: db,
          scope: jsonEncode(['synthetic-server', 'org-a', 'real-bundle']),
          manager: true,
          client: client,
          tokenExpiry: DateTime.now().add(const Duration(hours: 1)));
      final farm = const Uuid().v4();
      await bundleStore.save('POST', '/properties', {
        'id': farm,
        'name': 'Fazenda FICTÍCIA com vários talhões',
        'area_ha': '100',
        'responsible_user_id': 'worker',
        'plots': [
          for (var i = 0; i < 4; i++)
            {
              'id': const Uuid().v4(),
              'name': 'Talhão FICTÍCIO ${i + 1}',
              'area_ha': ['20', '30', '25', '25'][i],
              'notes': ''
            }
        ]
      });
      expect(await bundleStore.pending(), hasLength(1));
      await bundleStore.sync();
      expect(await bundleStore.pending(), isEmpty);
      expect(
          (await bundleStore.records('plots'))
              .where((p) => p['property_id'] == farm),
          hasLength(4));
      expect(
          (await bundleStore.records('properties'))
              .singleWhere((p) => p['id'] == farm)['responsible_name'],
          'worker');
      final stockWork = WorkStore(store);
      await WorkStore.initialize(store);
      await stockWork.refresh();
      final item = const Uuid().v4();
      await stockWork.queue('/admin/stock-items', {
        'id': item,
        'name': 'Diesel FICTÍCIO novo',
        'unit': 'L',
        'category': 'Combustíveis e lubrificantes',
        'product_type': 'Diesel',
        'notes': 'Teste descartável',
        'property_id': farm,
        'quantity': '50',
        'minimum_quantity': '50',
        'value_cents': 30000,
        'occurred_on': '2026-01-01'
      });
      await stockWork.sync();
      expect(await stockWork.pending(), isEmpty);
      final stockReport = await client
          .v2('GET', '/admin/reports/stock', query: {'property_id': farm});
      expect(items(stockReport, 'stock').single['low_stock'], true);
      expect(ascii.decode((await reportPdf(stockReport)).take(4).toList()),
          '%PDF');
      expect(reportXlsx(stockReport), isNotEmpty);
      final geography = GeographyStore(store);
      await GeographyStore.initialize(store);
      await geography.refresh(farm);
      await geography.save(farm, 'property', farm, {
        'id': const Uuid().v4(),
        'expected_version': 0,
        'points': [
          [-46, -21],
          [-45.99, -21],
          [-45.99, -20.99],
          [-46, -20.99]
        ],
        'color': '#26734D',
        'deleted': false,
        'reason': 'Limite FICTÍCIO para teste descartável',
      });
      await geography.sync();
      expect(await geography.pending(), isEmpty);
      final map = await geography.refresh(farm);
      expect(double.parse('${items(map, 'boundaries').single['area_ha']}'),
          greaterThan(114));
      expect((map['property'] as Map)['area_ha'], '100');
      await client.v2('POST', '/operations', data: {
        'id': const Uuid().v4(),
        'cycle_id': config['cycle'],
        'kind': 'harvest',
        'performed_on': '2026-10-10',
        'notes': 'Produção FICTÍCIA: fixture descartável',
        'harvest_output': {
          'quantity': '25',
          'unit': 'saca',
          'kg_per_unit': '60'
        },
      });
      final production = await client.v2('GET', '/admin/reports/production',
          query: {'property_id': property});
      expect(items(production, 'harvest').single['production_kg']['value'],
          '1500');
      expect(
          items(production, 'harvest').single['production_per_registered_ha']
              ['value'],
          '150');
      final photos = CatalogPhotoStore(store);
      await CatalogPhotoStore.initialize(store);
      await photos.refresh('machine', config['machine'] as String);
      final png = base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/j18AAAAASUVORK5CYII=');
      final image = File('${folder.path}/foto-ficticia.png');
      await image.writeAsBytes(png);
      await photos.add(
          'machine', config['machine'] as String, XFile(image.path));
      await image.delete();
      await photos.sync();
      expect(await photos.pending(), isEmpty);
      final gallery =
          await photos.refresh('machine', config['machine'] as String);
      final photoId = items(gallery, 'items').single['id'] as String;
      expect(
          await client.workPhoto(
              'machine', config['machine'] as String, photoId),
          png);
      final qa = Platform.environment['AGRO_EXPORT_QA_DIR'];
      if (qa != null) {
        final output = Directory(qa);
        await output.create(recursive: true);
        await File('${output.path}/producao-ficticia-auditoria.pdf')
            .writeAsBytes(await reportPdf(production));
        await File('${output.path}/producao-ficticia-auditoria.xlsx')
            .writeAsBytes(reportXlsx(production));
      }
    } finally {
      await db.close();
      await folder.delete(recursive: true);
    }
  },
      timeout: const Timeout(Duration(minutes: 2)),
      skip: configPath == null
          ? 'Execute com a fixture local sintética e AGRO_V2_E2E_CONFIG.'
          : false);
}
