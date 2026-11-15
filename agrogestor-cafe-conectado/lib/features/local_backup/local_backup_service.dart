import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../analyses/coffee_analysis_repository.dart';
import '../auth/auth_service.dart';
import '../auth/farm_access_policy.dart';
import '../auth/user_model.dart';
import '../coffee_finance/coffee_finance_repository.dart';
import '../coffee_finance/coffee_finance_check_repository.dart';
import '../machines/machine.dart';
import '../machines/machine_repository.dart';
import '../services/farm_service.dart';
import '../services/coffee_manual_labor_repository.dart';
import '../services/service_repository.dart';
import '../maintenance/maintenance_record.dart';
import '../maintenance/maintenance_repository.dart';
import '../fuel/fuel_record.dart';
import '../fuel/fuel_repository.dart';
import '../harvest/coffee_harvest_repository.dart';
import '../harvest/coffee_season_check_repository.dart';
import '../operators/operator.dart';
import '../operators/operator_repository.dart';
import '../processing/coffee_processing_repository.dart';
import '../implements/farm_implement.dart';
import '../implements/implement_repository.dart';
import '../clients/client_record.dart';
import '../clients/client_repository.dart';
import '../products/product_record.dart';
import '../products/product_repository.dart';
import '../properties/catalog_store.dart';
import '../properties/coffee_planting.dart';
import '../properties/plot_notebook_repository.dart';
import '../sync/farm_api_client.dart';
import '../sync/local_sync_collection_store.dart';
import '../sync/local_record_validation.dart';
import '../tools/coffee_tools_repository.dart';

typedef BackupJson = Map<String, dynamic>;

class LocalBackupService {
  static const maxBytes = 64 * 1024 * 1024;
  static const modules = <String, String>{
    'machines': 'campo_gestor_machines_v1',
    'services': 'campo_gestor_services_v1',
    'maintenance': 'campo_gestor_maintenance_v1',
    'fuel': 'campo_gestor_fuel_v1',
    'operators': 'campo_gestor_operators_v1',
    'implements': 'campo_gestor_implements_v1',
    'clients': 'campo_gestor_clients_v1',
    'products': 'campo_gestor_products_v1',
    'productUsage': 'campo_gestor_product_usage_v1',
    ...FarmAccessPolicy.coffeeLocalModules,
  };
  static const kinds = {
    'clients',
    'properties',
    'plots',
    'crops',
    'cycles',
    'machines',
    'responsibles',
  };
  static const farm = LocalSyncCollectionStore.standaloneFarmId;

  void _authorize() {
    final user = AuthService().currentUser;
    if (!FarmApiClient.standaloneLocalMode ||
        user?.id != 'usr_local_admin' ||
        user?.role != UserRole.admin ||
        user?.farmId != null) {
      throw const FormatException(
        'O backup local exige a sessao do gestor neste aparelho.',
      );
    }
  }

  Future<Uint8List> create() => _create();

  Future<Uint8List> _create({bool forRestore = false}) async {
    _authorize();
    // Migrate existing local collections before taking one consistent SQLite snapshot.
    await MachineRepository().getAll();
    await ServiceRepository().getAll();
    await MaintenanceRepository().getAll();
    await FuelRepository().getAll();
    await OperatorRepository().getAll();
    await ImplementRepository().getAll();
    await ClientRepository().getAll();
    final products = ProductRepository();
    await products.getProducts();
    await products.getUsage();
    final catalog = await CatalogStore.open();
    final snapshot = await catalog.db.transaction(
      (tx) async => <String, dynamic>{
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'appVersion': '2.1.7+2017',
        'records': [
          for (final row in await tx.query(
            'local_records',
            where: 'farm_id=? AND is_deleted=0',
            whereArgs: [farm],
          ))
            {
              'module': row['module'],
              'id': row['record_id'],
              'data': jsonDecode(row['payload'] as String),
            },
        ],
        'catalog': [
          for (final row in await tx.query(
            'catalog_records',
            where: 'scope=?',
            whereArgs: [catalog.scope],
          ))
            {
              'kind': row['kind'],
              'id': row['id'],
              'data': jsonDecode(row['payload'] as String),
            },
        ],
        'audit': await tx.query('local_audit'),
      },
    );
    final directory = await getApplicationSupportDirectory();
    final attachmentRoot = Directory(
      '${directory.path}${Platform.pathSeparator}attachments',
    );
    final privatePath =
        attachmentRoot.absolute.uri.normalizePath().toFilePath();
    final separator = Platform.pathSeparator;
    final privatePrefix = privatePath.endsWith(separator)
        ? privatePath
        : '$privatePath$separator';
    bool canOmitMissingPrivateMedia(File file) =>
        forRestore &&
        file.absolute.uri
            .normalizePath()
            .toFilePath()
            .startsWith(privatePrefix);

    final photos = <String, String>{};
    final pdfs = <String, String>{};
    Future<Object?> media(
      Object? value, {
      bool notebook = false,
      bool legacyPhotoHistory = false,
    }) async {
      if (value is Map) {
        final result = <String, dynamic>{};
        for (final entry in value.entries) {
          if (entry.key == 'photoPath' &&
              entry.value is String &&
              (entry.value as String).isNotEmpty) {
            final file = File(entry.value as String);
            if (!await file.exists()) {
              if (legacyPhotoHistory || canOmitMissingPrivateMedia(file)) {
                continue;
              }
              throw const FormatException(
                'Uma foto cadastrada nao foi encontrada. Confira as fotos antes de gerar o backup.',
              );
            }
            final resolved = await file.resolveSymbolicLinks();
            if (legacyPhotoHistory && !await attachmentRoot.exists()) continue;
            final allowedRoot = await attachmentRoot.resolveSymbolicLinks();
            if (!resolved.startsWith('$allowedRoot${Platform.pathSeparator}')) {
              if (legacyPhotoHistory) continue;
              throw const FormatException(
                'A foto precisa estar na pasta privada de anexos do aplicativo.',
              );
            }
            if (await file.length() > 8 * 1024 * 1024) {
              throw const FormatException(
                'Uma foto excede 8 MB. Utilize uma imagem menor.',
              );
            }
            final bytes = await file.readAsBytes();
            final id = sha256.convert(bytes).toString();
            photos[id] = base64Encode(bytes);
            result[entry.key] = 'agrophoto:$id';
          } else if (entry.key == 'pdfPath' && entry.value is String) {
            final file = File(entry.value as String);
            if (!await file.exists() && canOmitMissingPrivateMedia(file)) {
              continue;
            }
            final resolved = await file.resolveSymbolicLinks();
            final allowed = await attachmentRoot.resolveSymbolicLinks();
            if (!resolved.startsWith('$allowed${Platform.pathSeparator}')) {
              throw const FormatException(
                  'O PDF precisa estar na pasta privada do aplicativo.');
            }
            final bytes = await readCoffeeAnalysisPdf(File(resolved));
            final hash = sha256.convert(bytes).toString();
            if (!resolved.endsWith('${Platform.pathSeparator}$hash.pdf')) {
              throw const FormatException('O PDF privado está danificado.');
            }
            pdfs[hash] = base64Encode(bytes);
            result[entry.key] = 'agropdf:$hash';
          } else {
            result[entry.key as String] = await media(
              entry.value,
              notebook:
                  entry.key == 'data' && value['module'] == 'plotNotebook',
              legacyPhotoHistory: legacyPhotoHistory,
            );
          }
        }
        if (notebook &&
            value['photoPath'] is String &&
            !result.containsKey('photoPath') &&
            (value['text'] as String?)?.trim().isEmpty == true) {
          result['text'] = 'Foto indisponível no aparelho.';
        }
        return result;
      }
      if (value is List) {
        return [
          for (final item in value)
            await media(item, legacyPhotoHistory: legacyPhotoHistory),
        ];
      }
      return value;
    }

    final auditSnapshot = <Map<String, Object?>>[];
    for (final rawRow in snapshot['audit'] as List) {
      final row = Map<String, Object?>.from(rawRow as Map);
      auditSnapshot.add(row);
      if (!_hasAuditedMedia(row['module'])) continue;
      for (final key in ['payload', 'previous_payload']) {
        final raw = row[key] as String?;
        if (raw != null) {
          row[key] = jsonEncode(await media(
            jsonDecode(raw),
            notebook: row['module'] == 'plotNotebook',
            legacyPhotoHistory: _hasLegacyPhotoHistory(row['module']),
          ));
        }
      }
    }
    snapshot['audit'] = auditSnapshot;
    final payload = Map<String, dynamic>.from(await media(snapshot) as Map);
    payload['photos'] = photos;
    final records = payload['records'] as List;
    final schemaVersion = _requiresFormat8(records, auditSnapshot)
        ? 8
        : _hasFieldWork(
            records,
            payload['catalog'] as List,
            auditSnapshot,
          )
            ? 7
            : _hasProcessingWorkflow(records, auditSnapshot)
                ? 6
                : _hasProductionWorkflow(records, auditSnapshot)
                    ? 5
                    : _requiresCoffeeWorkflowFormat(records) ||
                            auditSnapshot.any((row) => FarmAccessPolicy
                                .coffeeLocalModules
                                .containsKey(row['module']))
                        ? 4
                        : _hasCoffeeInputs(records)
                            ? 3
                            : 2;
    if (schemaVersion >= 5) payload['pdfs'] = pdfs;
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'agrogestor-local-backup',
          'schemaVersion': schemaVersion,
          'payload': payload,
          'sha256': sha256.convert(utf8.encode(jsonEncode(payload))).toString(),
        }),
      ),
    );
    if (bytes.length > maxBytes) {
      throw const FormatException(
        'O backup excede 64 MB. Solicite uma revisao antes de continuar.',
      );
    }
    inspect(bytes);
    return bytes;
  }

  static bool _hasCoffeeInputs(List records) => records.any((record) {
        if (record is! Map || record['module'] != 'services') return false;
        final data = record['data'];
        if (data is! Map) return false;
        return [data['plannedInputs'], data['appliedSprayInputs']]
            .any((inputs) => inputs is List && inputs.isNotEmpty);
      });

  static bool _hasLegacyPhotoHistory(Object? module) => const {
        'operators',
        'products',
        'catalog.properties',
        'catalog.plots',
      }.contains(module);

  static bool _hasAuditedMedia(Object? module, {bool includeNew = true}) =>
      module == 'plotNotebook' ||
      module == 'coffeeAnalyses' ||
      module == CoffeeFinanceRepository.entriesModule ||
      (includeNew &&
          (_hasLegacyPhotoHistory(module) ||
              module == CoffeeToolsRepository.module));

  static bool _requiresFormat8(List records, List audit) {
    bool newData(Object? module, Object? data) {
      if (data is! Map) return false;
      return switch (module) {
        CoffeeFinanceRepository.entriesModule => data['analysisId'] != null,
        'coffeeProcessingLots' => data['cleanings'] is List &&
            (data['cleanings'] as List)
                .any((item) => item is Map && item['inputBase'] == 'washed'),
        _ => false,
      };
    }

    return records.any((row) =>
            row['module'] == CoffeeFinanceCheck.module ||
            newData(row['module'], row['data'])) ||
        audit.any((row) =>
            row['module'] == CoffeeFinanceCheck.module ||
            [row['previous_payload'], row['payload']].any((raw) =>
                raw is String &&
                (row['module'] == CoffeeFinanceRepository.entriesModule ||
                    row['module'] == 'coffeeProcessingLots') &&
                newData(row['module'], jsonDecode(raw))));
  }

  static bool _hasFieldWork(List records, List catalog, List audit) {
    bool hasNewFields(Object? module, Object? data, {bool historical = false}) {
      if (data is! Map) return false;
      final photo = data['photoPath'];
      if (_hasLegacyPhotoHistory(module) &&
          photo is String &&
          (historical ? photo.startsWith('agrophoto:') : photo.isNotEmpty)) {
        return true;
      }
      switch (module) {
        case 'operators':
          return data['dailyRateCents'] != null;
        case CoffeeFinanceRepository.entriesModule:
          return data['productId'] != null;
        case 'services':
          final days = data['days'];
          if (data.containsKey('manualWorkers') ||
              (days is List &&
                  days.any((day) =>
                      day is Map && day.containsKey('manualWorkers')))) {
            return true;
          }
          return [data['plannedInputs'], data['appliedSprayInputs']].any(
            (inputs) =>
                inputs is List &&
                inputs.any(
                  (input) =>
                      input is Map &&
                      (input.containsKey('doseQuantity') ||
                          input.containsKey('doseReference')),
                ),
          );
        default:
          return false;
      }
    }

    return records.any((row) =>
            row is Map &&
            (FarmAccessPolicy.coffeeFieldWorkModules
                    .containsKey(row['module']) ||
                hasNewFields(row['module'], row['data']))) ||
        catalog.any((row) =>
            row is Map &&
            hasNewFields('catalog.${row['kind']}', row['data'])) ||
        audit.any((row) {
          if (row is! Map) return false;
          final module = row['module'];
          if (FarmAccessPolicy.coffeeFieldWorkModules.containsKey(module)) {
            return true;
          }
          if (!_hasLegacyPhotoHistory(module) &&
              module != 'services' &&
              module != CoffeeFinanceRepository.entriesModule) {
            return false;
          }
          return [row['payload'], row['previous_payload']].any(
            (raw) =>
                raw is String &&
                hasNewFields(module, jsonDecode(raw), historical: true),
          );
        });
  }

  static bool _hasProductionWorkflow(List records, List audit) =>
      [...records, ...audit].any((row) =>
          row is Map &&
          FarmAccessPolicy.coffeeProductionModules.containsKey(row['module']));

  static bool _hasProcessingWorkflow(List records, List audit) {
    bool newFields(Object? module, Object? data) {
      if (data is! Map) return false;
      switch (module) {
        case 'plotNotebook':
          return ['followUpOn', 'inspection', 'operationId']
              .any(data.containsKey);
        case 'services':
          return ['applicationNumber', 'workSection', 'workObjective']
                  .any(data.containsKey) ||
              [data['plannedInputs'], data['appliedSprayInputs']].any(
                  (inputs) =>
                      inputs is List &&
                      inputs.any((input) =>
                          input is Map && input.containsKey('loadCount')));
        case 'coffeeAnalyses':
          final results = data['results'];
          return results is List &&
              results.any((result) =>
                  result is Map && result.containsKey('referenceMin'));
        default:
          return false;
      }
    }

    return [...records, ...audit].any((row) {
      if (row is! Map) return false;
      final module = row['module'];
      if (FarmAccessPolicy.coffeeProcessingModules.containsKey(module) ||
          newFields(module, row['data'])) {
        return true;
      }
      if (!['plotNotebook', 'services', 'coffeeAnalyses'].contains(module)) {
        return false;
      }
      return [
        row['payload'],
        row['previous_payload']
      ].any((value) => value is String && newFields(module, jsonDecode(value)));
    });
  }

  static bool _requiresCoffeeWorkflowFormat(List records) =>
      records.any((record) {
        if (record is! Map) return false;
        final module = record['module'];
        if (FarmAccessPolicy.coffeeLocalModules.containsKey(module)) {
          return true;
        }
        final data = record['data'];
        return module == 'maintenance' &&
            data is Map &&
            data['nextDueDate'] != null;
      });

  BackupJson inspect(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('O arquivo esta vazio ou excede 64 MB.');
    }
    try {
      final document = jsonDecode(utf8.decode(bytes)) as Map;
      final schemaVersion = document['schemaVersion'];
      if (document['format'] != 'agrogestor-local-backup' ||
          schemaVersion is! int ||
          ![1, 2, 3, 4, 5, 6, 7, 8].contains(schemaVersion)) {
        throw const FormatException(
          'Este arquivo nao e um backup local compativel do AgroGestor.',
        );
      }
      final payload = Map<String, dynamic>.from(document['payload'] as Map);
      if (sha256.convert(utf8.encode(jsonEncode(payload))).toString() !=
          document['sha256']) {
        throw const FormatException(
          'O arquivo foi alterado ou esta danificado. Nada foi restaurado.',
        );
      }
      DateTime.parse(payload['createdAt'] as String);
      final records = payload['records'] as List;
      if (schemaVersion < 3 && _hasCoffeeInputs(records)) {
        throw const FormatException(
          'O backup com planejamento de insumos ou cargas aplicadas precisa estar no formato 3.',
        );
      }
      final audit = payload['audit'] as List;
      final catalog = payload['catalog'] as List;
      if (schemaVersion < 8 && _requiresFormat8(records, audit)) {
        throw const FormatException(
            'A conferência financeira, os vínculos de laudos e as limpas de café lavado exigem o formato 8.');
      }
      if (schemaVersion < 7 && _hasFieldWork(records, catalog, audit)) {
        throw const FormatException(
          'O backup com ferramentas, diárias, compras de produtos ou fotos novas exige o formato 7.',
        );
      }
      if (schemaVersion < 6 && _hasProcessingWorkflow(records, audit)) {
        throw const FormatException(
          'O backup com lotes de beneficiamento exige o formato 6.',
        );
      }
      if (schemaVersion < 5 &&
          (_hasProductionWorkflow(records, audit) ||
              payload.containsKey('pdfs'))) {
        throw const FormatException(
          'O backup com produção diária ou análises exige o formato 5.',
        );
      }
      if (schemaVersion < 4 &&
          (_requiresCoffeeWorkflowFormat(records) ||
              audit.any((row) => FarmAccessPolicy.coffeeLocalModules
                  .containsKey(row['module'])))) {
        throw const FormatException(
          'O backup com caderno, colheita ou data da próxima revisão exige o formato 4.',
        );
      }
      final photos = payload['photos'] as Map;
      final pdfs = schemaVersion >= 5 ? payload['pdfs'] as Map : const {};
      if (records.length + catalog.length > 50000 ||
          audit.length > 200000 ||
          photos.length > 200 ||
          pdfs.length > 200) {
        throw const FormatException('O backup excede os limites desta edicao.');
      }
      final ids = <String>{};
      for (final raw in records) {
        final row = Map<String, dynamic>.from(raw as Map);
        final data = Map<String, dynamic>.from(row['data'] as Map);
        if (!modules.containsKey(row['module']) ||
            row['id'] is! String ||
            (row['id'] as String).isEmpty ||
            row['id'] != data['id'] ||
            !ids.add('${row['module']}/${row['id']}')) {
          throw const FormatException(
            'O backup possui cadastros invalidos ou repetidos.',
          );
        }
        validateLocalRecord(row['module'] as String, data);
        switch (row['module']) {
          case 'machines':
            Machine.fromJson(data);
          case 'services':
            FarmService.fromJson(data);
          case 'maintenance':
            MaintenanceRecord.fromJson(data);
          case 'fuel':
            FuelRecord.fromJson(data);
          case 'operators':
            Operator.fromJson(data);
          case 'implements':
            FarmImplement.fromJson(data);
          case 'clients':
            RuralClient.fromJson(data);
          case 'products':
            FarmProduct.fromJson(data);
          case 'productUsage':
            ProductUsage.fromJson(data);
        }
      }
      final catalogIds = <String>{};
      final properties = <String>{};
      final plots = <String, String>{};
      for (final raw in catalog) {
        final row = raw as Map;
        final data = row['data'] as Map;
        if (!kinds.contains(row['kind']) ||
            row['id'] is! String ||
            (row['id'] as String).isEmpty ||
            data['id'] != row['id'] ||
            data['name'] is! String ||
            (data['name'] as String).trim().isEmpty ||
            !catalogIds.add('${row['kind']}/${row['id']}')) {
          throw const FormatException(
            'O backup possui propriedades ou talhoes invalidos.',
          );
        }
        if (row['kind'] == 'properties') properties.add(row['id'] as String);
        if (row['kind'] == 'plots') {
          final plantingError =
              coffeePlantingError(Map<String, dynamic>.from(data));
          if (plantingError != null) throw FormatException(plantingError);
          plots[row['id'] as String] = data['property_id'] as String;
        }
      }
      if (plots.values.any((id) => !properties.contains(id))) {
        throw const FormatException('O backup possui um talhao sem fazenda.');
      }
      final machines = {
        for (final raw in records)
          if ((raw as Map)['module'] == 'machines') raw['id'],
      };
      final products = {
        for (final raw in records)
          if ((raw as Map)['module'] == 'products') raw['id'],
      };
      final services = <String, Map<String, dynamic>>{
        for (final raw in records)
          if ((raw as Map)['module'] == 'services')
            raw['id'] as String: Map<String, dynamic>.from(raw['data'] as Map),
      };
      final activeMachines = <String>{};
      final productionDays = <CoffeeHarvestDayKey>{};
      final seasonChecks = <(String, String, int)>{};
      final harvestEntries = <CoffeeHarvestEntry>[];
      final declarations = <CoffeePlotProduction>[];
      final coffeeLots = <CoffeeLot>[];
      final financeEntries = <CoffeeFinanceEntry>[];
      final analysesById = <String, CoffeeAnalysis>{
        for (final row in records.cast<Map>())
          if (row['module'] == 'coffeeAnalyses')
            row['id'] as String: CoffeeAnalysis.fromJson(
                Map<String, dynamic>.from(row['data'] as Map)),
      };
      final saleReceipts = <CoffeeSaleReceipt>[];
      final coffeeTools = <CoffeeTool>[];
      for (final raw in records) {
        final row = raw as Map;
        final data = row['data'] as Map;
        final module = row['module'];
        if (FarmAccessPolicy.coffeeLocalModules.containsKey(module) &&
            module != CoffeeToolsRepository.module &&
            (!properties.contains(data['propertyId']) ||
                (![
                      'coffeeHarvestPayments',
                      CoffeeFinanceCheck.module,
                      'coffeeProcessingLots',
                      CoffeeFinanceRepository.entriesModule,
                      CoffeeFinanceRepository.receiptsModule,
                      CoffeeManualLaborRepository.module,
                    ].contains(module) &&
                    plots[data['plotId']] != data['propertyId']))) {
          throw const FormatException(
            'Um lançamento do café perdeu a fazenda ou o talhão de origem.',
          );
        }
        if (module == CoffeeFinanceCheck.module &&
            data['plotId'] != null &&
            plots[data['plotId']] != data['propertyId']) {
          throw const FormatException(
              'Uma conferência perdeu o talhão de origem.');
        }
        if (module == 'coffeePlotProduction') {
          final declaration =
              CoffeePlotProduction.fromJson(Map<String, dynamic>.from(data));
          if (!productionDays.add(declaration.dayKey)) {
            throw const FormatException(
                'O backup tem mais de um total declarado para o mesmo dia e talhão.');
          }
          declarations.add(declaration);
        }
        if (module == 'coffeeHarvestEntries') {
          harvestEntries.add(
              CoffeeHarvestEntry.fromJson(Map<String, dynamic>.from(data)));
        }
        if (module == CoffeeSeasonCheck.module &&
            !seasonChecks.add(CoffeeSeasonCheck.fromJson(
              Map<String, dynamic>.from(data),
            ).scope)) {
          throw const FormatException(
              'O backup tem mais de um subtotal para o mesmo talhão e safra.');
        }
        if (module == 'plotNotebook') {
          final note = PlotNote.fromJson(Map<String, dynamic>.from(data));
          if (note.operationId != null) {
            final operation = services[note.operationId];
            final service =
                operation == null ? null : FarmService.fromJson(operation);
            if (service == null ||
                service.propertyId != note.propertyId ||
                service.fieldId != note.plotId ||
                !service.isFinished ||
                service.isCancelled) {
              throw const FormatException(
                  'Uma pendência está vinculada a um serviço inválido.');
            }
          }
        }
        if (module == 'coffeeProcessingLots') {
          final lot = CoffeeLot.fromJson(Map<String, dynamic>.from(data));
          if (lot.inputs.any((input) =>
              input.plotId != null && plots[input.plotId] != lot.propertyId)) {
            throw const FormatException(
                'Um lote possui origem vinculada a um talhão de outra fazenda.');
          }
          coffeeLots.add(lot);
        }
        if (module == CoffeeFinanceRepository.entriesModule) {
          financeEntries.add(
              CoffeeFinanceEntry.fromJson(Map<String, dynamic>.from(data)));
        }
        if (module == CoffeeFinanceRepository.receiptsModule) {
          saleReceipts
              .add(CoffeeSaleReceipt.fromJson(Map<String, dynamic>.from(data)));
        }
        if (module == CoffeeToolsRepository.module) {
          coffeeTools.add(CoffeeTool.fromJson(Map<String, dynamic>.from(data)));
        }
        if (module == 'coffeeAnalyses') {
          final analysis =
              CoffeeAnalysis.fromJson(Map<String, dynamic>.from(data));
          final operationId = analysis.operationId;
          if (operationId != null && operationId.isNotEmpty) {
            final operation = services[operationId];
            if (operation == null ||
                !analysis.canLinkOperation(FarmService.fromJson(operation))) {
              throw const FormatException(
                  'Uma análise está vinculada a uma operação inválida.');
            }
          }
        }
        if (['services', 'fuel', 'maintenance'].contains(row['module']) &&
            !(row['module'] == 'services' && data['isManual'] == true) &&
            !machines.contains(data['machineId'])) {
          throw const FormatException(
            'Um lancamento possui maquina ausente no backup.',
          );
        }
        if (row['module'] == 'productUsage' &&
            (!products.contains(data['productId']) ||
                data['serviceId'] != null &&
                    data['serviceId'] != '' &&
                    !services.containsKey(data['serviceId']))) {
          throw const FormatException(
            'Um consumo perdeu seu produto ou operacao de origem.',
          );
        }
        if (row['module'] == 'services') {
          if (data['propertyId'] != null &&
              data['propertyId'] != '' &&
              !properties.contains(data['propertyId'])) {
            throw const FormatException(
              'Uma operacao perdeu sua fazenda de origem.',
            );
          }
          if (data['fieldId'] != null &&
              data['fieldId'] != '' &&
              plots[data['fieldId']] != data['propertyId']) {
            throw const FormatException(
              'Uma operacao possui talhao de outra fazenda.',
            );
          }
          if (data['isManual'] != true &&
              data['endMeter'] == null &&
              data['endedAt'] == null &&
              data['cancelledAt'] == null &&
              !activeMachines.add(data['machineId'] as String)) {
            throw const FormatException(
              'Uma maquina possui duas operacoes em andamento.',
            );
          }
        }
      }
      if (coffeeLots.isNotEmpty) {
        validateCoffeeProcessingLots(coffeeLots);
        validateCoffeeProcessingAllocations(
          coffeeLotAllocations(coffeeLots),
          coffeeHarvestSourceTotals(harvestEntries, declarations),
        );
      }
      validateCoffeeFinanceLinks(
        entries: financeEntries,
        receipts: saleReceipts,
        lots: coffeeLots,
        properties: properties,
        plots: plots,
      );
      for (final entry in financeEntries) {
        if (entry.analysisId == null) continue;
        final analysis = analysesById[entry.analysisId];
        if (analysis == null ||
            analysis.propertyId != entry.propertyId ||
            analysis.plotId != entry.plotId) {
          throw const FormatException(
              'Uma despesa possui vínculo inválido com o laudo.');
        }
      }
      _validateToolLinks(coffeeTools, financeEntries);
      final auditIds = <String>{};
      for (final raw in audit) {
        final row = raw as Map;
        if (row['id'] is! String ||
            !auditIds.add(row['id'] as String) ||
            !(modules.containsKey(row['module']) ||
                (row['module'] is String &&
                    (row['module'] as String).startsWith('catalog.') &&
                    kinds.contains((row['module'] as String).substring(8)))) ||
            row['record_id'] is! String ||
            row['actor_id'] is! String ||
            !['upsert', 'delete', 'restore'].contains(row['operation'])) {
          throw const FormatException('Historico de alteracoes invalido.');
        }
        DateTime.parse(row['changed_at'] as String);
        for (final key in ['payload', 'previous_payload']) {
          if (row[key] != null) {
            final historical = jsonDecode(row[key] as String);
            if (row['module'] == 'coffeeProcessingLots' ||
                FarmAccessPolicy.coffeeFieldWorkModules
                    .containsKey(row['module'])) {
              final data = Map<String, dynamic>.from(historical as Map);
              validateLocalRecord(row['module'] as String, data);
              if (data['id'] != row['record_id']) {
                throw const FormatException(
                    'O histórico de alterações é inválido.');
              }
            }
          }
        }
      }
      for (final entry in photos.entries) {
        if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.key as String) ||
            entry.value is! String ||
            (entry.value as String).length > 12 * 1024 * 1024) {
          throw const FormatException('Foto invalida no backup.');
        }
        final decoded = base64Decode(entry.value as String);
        if (decoded.length > 8 * 1024 * 1024 ||
            sha256.convert(decoded).toString() != entry.key) {
          throw const FormatException('Uma foto esta danificada.');
        }
      }
      for (final entry in pdfs.entries) {
        final hash = entry.key;
        final content = entry.value;
        if (hash is! String ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
            content is! String ||
            content.length > 4 * ((coffeeAnalysisPdfMaxBytes + 2) ~/ 3)) {
          throw const FormatException('PDF inválido no backup.');
        }
        final decoded = base64Decode(content);
        validateCoffeeAnalysisPdf(decoded);
        if (sha256.convert(decoded).toString() != hash) {
          throw const FormatException('Um PDF está danificado.');
        }
      }
      void references(Object? value) {
        if (value is Map) {
          for (final entry in value.entries) {
            if (entry.key == 'photoPath' &&
                entry.value != null &&
                entry.value != '') {
              final ref = entry.value;
              if (ref is! String ||
                  !ref.startsWith('agrophoto:') ||
                  !photos.containsKey(ref.substring(10))) {
                throw const FormatException('Uma foto esta ausente no backup.');
              }
            } else if (entry.key == 'pdfPath' && entry.value != null) {
              final ref = entry.value;
              if (ref is! String ||
                  !ref.startsWith('agropdf:') ||
                  !pdfs.containsKey(ref.substring(8))) {
                throw const FormatException('Um PDF está ausente no backup.');
              }
            } else {
              references(entry.value);
            }
          }
        } else if (value is List) {
          for (final item in value) {
            references(item);
          }
        }
      }

      references(records);
      references(catalog);
      for (final row in audit) {
        if (!_hasAuditedMedia(row['module'], includeNew: schemaVersion >= 7)) {
          continue;
        }
        for (final key in ['payload', 'previous_payload']) {
          final raw = row[key] as String?;
          if (raw != null) references(jsonDecode(raw));
        }
      }
      return payload;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException(
        'O arquivo nao possui a estrutura esperada. Nada foi restaurado.',
      );
    }
  }

  static void _validateToolLinks(
    List<CoffeeTool> tools,
    List<CoffeeFinanceEntry> finance,
  ) {
    if (tools.isEmpty) return;
    final defaults = CoffeeTool.defaults.map((item) => item.id).toSet();
    final categories = {
      ...defaults,
      for (final tool in tools)
        if (tool.isCategory) tool.id,
    };
    final eligibleExpenses = {
      for (final entry in finance)
        if (!entry.isIncome &&
            entry.productId == null &&
            entry.originKey == null)
          entry.id,
    };
    final assignedExpenses = <String>{};
    for (final tool in tools) {
      if (defaults.contains(tool.id) ||
          (!tool.isCategory && !categories.contains(tool.categoryId))) {
        throw const FormatException(
            'Uma ferramenta possui categoria inválida.');
      }
      final expense = tool.expenseId;
      if (expense != null &&
          (!eligibleExpenses.contains(expense) ||
              !assignedExpenses.add(expense))) {
        throw const FormatException(
            'Uma ferramenta possui despesa inválida ou repetida.');
      }
    }
  }

  Future<String> restore(Uint8List bytes) async {
    _authorize();
    final payload = inspect(
      bytes,
    ); // Validate every row, attachment and checksum before changing data.
    final current = await _create(forRestore: true);
    final root = await getApplicationSupportDirectory();
    final safety = Directory(
      '${root.path}${Platform.pathSeparator}local_backups',
    );
    await safety.create(recursive: true);
    final previous = File(
      '${safety.path}${Platform.pathSeparator}pre-restore-${DateTime.now().microsecondsSinceEpoch}.agrobackup',
    );
    await previous.writeAsBytes(current, flush: true);
    final catalog = await CatalogStore.open();
    Directory? staging;
    final stagedFiles = <File>[];
    final paths = <String, String>{};
    Object? remap(Object? value) {
      if (value is Map) {
        return {
          for (final entry in value.entries)
            entry.key: (entry.key == 'photoPath' || entry.key == 'pdfPath') &&
                    entry.value is String
                ? paths[entry.value] ?? entry.value
                : remap(entry.value),
        };
      }
      if (value is List) return value.map(remap).toList();
      return value;
    }

    try {
      final restored = await openPrivateCoffeeAttachmentFolder(
        root,
        'restore-${const Uuid().v4()}',
      );
      staging = restored;
      final separator = Platform.pathSeparator;
      Future<void> restoreMedia(
          Map items, String prefix, String extension) async {
        for (final entry in items.entries) {
          final file =
              File('${restored.path}$separator${entry.key}.$extension');
          await file.create(exclusive: true);
          stagedFiles.add(file);
          await file.writeAsBytes(base64Decode(entry.value as String),
              flush: true);
          paths['$prefix:${entry.key}'] = file.path;
        }
      }

      await restoreMedia(payload['photos'] as Map, 'agrophoto', 'img');
      await restoreMedia(payload['pdfs'] as Map? ?? const {}, 'agropdf', 'pdf');
      _authorize();
      await catalog.db.transaction((tx) async {
        _authorize();
        await tx.delete('local_records', where: 'farm_id=?', whereArgs: [farm]);
        await tx.delete('sync_metadata', where: 'farm_id=?', whereArgs: [farm]);
        await tx.delete(
          'catalog_records',
          where: 'scope=?',
          whereArgs: [catalog.scope],
        );
        await tx.delete(
          'catalog_outbox',
          where: 'scope=?',
          whereArgs: [catalog.scope],
        );
        await tx.delete('local_audit');
        for (final raw in payload['records'] as List) {
          final row = raw as Map;
          await tx.insert('local_records', {
            'farm_id': farm,
            'module': row['module'],
            'record_id': row['id'],
            'payload': jsonEncode(remap(row['data'])),
            'sync_state': 'local',
            'changed_at': DateTime.now().toUtc().toIso8601String(),
          });
        }
        for (final module in modules.keys) {
          await tx.insert('sync_metadata', {
            'farm_id': farm,
            'key': 'local-import:$module',
            'value': 'done',
          });
        }
        for (final raw in payload['catalog'] as List) {
          final row = raw as Map;
          await tx.insert('catalog_records', {
            'scope': catalog.scope,
            'kind': row['kind'],
            'id': row['id'],
            'payload': jsonEncode(remap(row['data'])),
            'origin': 'draft',
            'state': 'local',
          });
        }
        for (final raw in payload['audit'] as List) {
          final row = raw as Map;
          await tx.insert('local_audit', {
            for (final key in [
              'id',
              'actor_id',
              'changed_at',
              'module',
              'record_id',
              'operation',
              'previous_payload',
              'payload',
            ])
              key: _hasAuditedMedia(row['module']) &&
                      (key == 'payload' || key == 'previous_payload') &&
                      row[key] != null
                  ? jsonEncode(remap(jsonDecode(row[key] as String)))
                  : row[key],
          });
        }
        await tx.insert('local_audit', {
          'id': const Uuid().v4(),
          'actor_id': AuthService().currentUser!.id,
          'changed_at': DateTime.now().toUtc().toIso8601String(),
          'module': 'services',
          'record_id': 'backup-restoration',
          'operation': 'restore',
          'payload': jsonEncode({
            'restoredAt': DateTime.now().toUtc().toIso8601String(),
          }),
        });
        _authorize();
      });
    } catch (_) {
      try {
        for (final file in stagedFiles) {
          if (await file.exists()) await file.delete();
        }
        if (staging != null && await staging.exists()) await staging.delete();
      } on FileSystemException {
        // Keep the original restore error and leave any unreachable files private.
      }
      rethrow;
    }
    return previous.path;
  }

  Future<List<File>> previousCopies() async {
    _authorize();
    final root = await getApplicationSupportDirectory();
    final folder = Directory(
      '${root.path}${Platform.pathSeparator}local_backups',
    );
    if (!await folder.exists()) return [];
    final files = (await folder.list().toList())
        .whereType<File>()
        .where((f) => f.path.endsWith('.agrobackup'))
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }
}
