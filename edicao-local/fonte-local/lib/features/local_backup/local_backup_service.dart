import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../auth/auth_service.dart';
import '../auth/user_model.dart';
import '../machines/machine.dart';
import '../machines/machine_repository.dart';
import '../services/farm_service.dart';
import '../services/service_repository.dart';
import '../maintenance/maintenance_record.dart';
import '../maintenance/maintenance_repository.dart';
import '../fuel/fuel_record.dart';
import '../fuel/fuel_repository.dart';
import '../operators/operator.dart';
import '../operators/operator_repository.dart';
import '../implements/farm_implement.dart';
import '../implements/implement_repository.dart';
import '../clients/client_record.dart';
import '../clients/client_repository.dart';
import '../products/product_record.dart';
import '../products/product_repository.dart';
import '../properties/catalog_store.dart';
import '../sync/farm_api_client.dart';
import '../sync/local_sync_collection_store.dart';
import '../sync/local_record_validation.dart';
import '../local_activation/local_activation_service.dart';

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
  };
  static const kinds = {
    'clients',
    'properties',
    'plots',
    'crops',
    'cycles',
    'machines',
    'responsibles'
  };
  static const farm = LocalSyncCollectionStore.standaloneFarmId;

  void _authorize() {
    LocalActivationService.instance.requireCached();
    final user = AuthService().currentUser;
    if (!FarmApiClient.standaloneLocalMode ||
        user?.id != 'usr_local_admin' ||
        user?.role != UserRole.admin ||
        user?.farmId != null) {
      throw const FormatException(
          'O backup local exige a sessao do gestor neste aparelho.');
    }
  }

  Future<Uint8List> create() async {
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
    final snapshot =
        await catalog.db.transaction((tx) async => <String, dynamic>{
              'createdAt': DateTime.now().toUtc().toIso8601String(),
              'appVersion': '2.1.8+2018',
              'records': [
                for (final row in await tx.query('local_records',
                    where: 'farm_id=? AND is_deleted=0', whereArgs: [farm]))
                  {
                    'module': row['module'],
                    'id': row['record_id'],
                    'data': jsonDecode(row['payload'] as String)
                  }
              ],
              'catalog': [
                for (final row in await tx.query('catalog_records',
                    where: 'scope=?', whereArgs: [catalog.scope]))
                  {
                    'kind': row['kind'],
                    'id': row['id'],
                    'data': jsonDecode(row['payload'] as String)
                  }
              ],
              'audit': await tx.query('local_audit'),
            });
    final directory = await getApplicationSupportDirectory();
    final attachmentRoot =
        Directory('${directory.path}${Platform.pathSeparator}attachments');
    final photos = <String, String>{};
    Future<Object?> media(Object? value) async {
      if (value is Map) {
        final result = <String, dynamic>{};
        for (final entry in value.entries) {
          if (entry.key == 'photoPath' &&
              entry.value is String &&
              (entry.value as String).isNotEmpty) {
            final file = File(entry.value as String);
            if (!await file.exists()) {
              throw const FormatException(
                  'Uma foto cadastrada nao foi encontrada. Confira as fotos antes de gerar o backup.');
            }
            final resolved = await file.resolveSymbolicLinks();
            final allowedRoot = await attachmentRoot.resolveSymbolicLinks();
            if (!resolved.startsWith('$allowedRoot${Platform.pathSeparator}')) {
              throw const FormatException(
                  'A foto precisa estar na pasta privada de anexos do aplicativo.');
            }
            if (await file.length() > 8 * 1024 * 1024) {
              throw const FormatException(
                  'Uma foto excede 8 MB. Utilize uma imagem menor.');
            }
            final bytes = await file.readAsBytes();
            final id = sha256.convert(bytes).toString();
            photos[id] = base64Encode(bytes);
            result[entry.key] = 'agrophoto:$id';
          } else {
            result[entry.key as String] = await media(entry.value);
          }
        }
        return result;
      }
      if (value is List) return [for (final item in value) await media(item)];
      return value;
    }

    final payload = Map<String, dynamic>.from(await media(snapshot) as Map);
    payload['photos'] = photos;
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode({
      'format': 'agrogestor-local-backup',
      'schemaVersion': 1,
      'payload': payload,
      'sha256': sha256.convert(utf8.encode(jsonEncode(payload))).toString(),
    })));
    if (bytes.length > maxBytes) {
      throw const FormatException(
          'O backup excede 64 MB. Solicite uma revisao antes de continuar.');
    }
    inspect(bytes);
    return bytes;
  }

  BackupJson inspect(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('O arquivo esta vazio ou excede 64 MB.');
    }
    try {
      final document = jsonDecode(utf8.decode(bytes)) as Map;
      if (document['format'] != 'agrogestor-local-backup' ||
          document['schemaVersion'] != 1) {
        throw const FormatException(
            'Este arquivo nao e um backup local compativel do AgroGestor.');
      }
      final payload = Map<String, dynamic>.from(document['payload'] as Map);
      if (sha256.convert(utf8.encode(jsonEncode(payload))).toString() !=
          document['sha256']) {
        throw const FormatException(
            'O arquivo foi alterado ou esta danificado. Nada foi restaurado.');
      }
      DateTime.parse(payload['createdAt'] as String);
      final records = payload['records'] as List;
      final catalog = payload['catalog'] as List;
      final audit = payload['audit'] as List;
      final photos = payload['photos'] as Map;
      if (records.length + catalog.length > 50000 ||
          audit.length > 200000 ||
          photos.length > 200) {
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
              'O backup possui cadastros invalidos ou repetidos.');
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
              'O backup possui propriedades ou talhoes invalidos.');
        }
        if (row['kind'] == 'properties') properties.add(row['id'] as String);
        if (row['kind'] == 'plots') {
          plots[row['id'] as String] = data['property_id'] as String;
        }
      }
      if (plots.values.any((id) => !properties.contains(id))) {
        throw const FormatException('O backup possui um talhao sem fazenda.');
      }
      final machines = {
        for (final raw in records)
          if ((raw as Map)['module'] == 'machines') raw['id']
      };
      final products = {
        for (final raw in records)
          if ((raw as Map)['module'] == 'products') raw['id']
      };
      final services = {
        for (final raw in records)
          if ((raw as Map)['module'] == 'services') raw['id']
      };
      final activeMachines = <String>{};
      for (final raw in records) {
        final row = raw as Map;
        final data = row['data'] as Map;
        if (['services', 'fuel', 'maintenance'].contains(row['module']) &&
            !machines.contains(data['machineId'])) {
          throw const FormatException(
              'Um lancamento possui maquina ausente no backup.');
        }
        if (row['module'] == 'productUsage' &&
            (!products.contains(data['productId']) ||
                data['serviceId'] != null &&
                    data['serviceId'] != '' &&
                    !services.contains(data['serviceId']))) {
          throw const FormatException(
              'Um consumo perdeu seu produto ou operacao de origem.');
        }
        if (row['module'] == 'services') {
          if (data['propertyId'] != null &&
              data['propertyId'] != '' &&
              !properties.contains(data['propertyId'])) {
            throw const FormatException(
                'Uma operacao perdeu sua fazenda de origem.');
          }
          if (data['fieldId'] != null &&
              data['fieldId'] != '' &&
              plots[data['fieldId']] != data['propertyId']) {
            throw const FormatException(
                'Uma operacao possui talhao de outra fazenda.');
          }
          if (data['endMeter'] == null &&
              data['cancelledAt'] == null &&
              !activeMachines.add(data['machineId'] as String)) {
            throw const FormatException(
                'Uma maquina possui duas operacoes em andamento.');
          }
        }
      }
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
            jsonDecode(row[key] as String);
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
      return payload;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException(
          'O arquivo nao possui a estrutura esperada. Nada foi restaurado.');
    }
  }

  Future<String> restore(Uint8List bytes) async {
    _authorize();
    final payload = inspect(
        bytes); // Validate every row, attachment and checksum before changing data.
    final current = await create();
    final root = await getApplicationSupportDirectory();
    final safety =
        Directory('${root.path}${Platform.pathSeparator}local_backups');
    await safety.create(recursive: true);
    final previous = File(
        '${safety.path}${Platform.pathSeparator}pre-restore-${DateTime.now().microsecondsSinceEpoch}.agrobackup');
    await previous.writeAsBytes(current, flush: true);
    final catalog = await CatalogStore.open();
    final restored = Directory(
        '${root.path}${Platform.pathSeparator}attachments${Platform.pathSeparator}restore-${const Uuid().v4()}');
    await restored.create(recursive: true);
    final paths = <String, String>{};
    for (final entry in (payload['photos'] as Map).entries) {
      final file =
          File('${restored.path}${Platform.pathSeparator}${entry.key}.img');
      await file.writeAsBytes(base64Decode(entry.value as String), flush: true);
      paths['agrophoto:${entry.key}'] = file.path;
    }
    Object? remap(Object? value) {
      if (value is Map) {
        return {
          for (final entry in value.entries)
            entry.key: entry.key == 'photoPath' && entry.value is String
                ? paths[entry.value]
                : remap(entry.value)
        };
      }
      if (value is List) return value.map(remap).toList();
      return value;
    }

    _authorize();
    try {
      await catalog.db.transaction((tx) async {
        await tx.delete('local_records', where: 'farm_id=?', whereArgs: [farm]);
        await tx.delete('sync_metadata', where: 'farm_id=?', whereArgs: [farm]);
        await tx.delete('catalog_records',
            where: 'scope=?', whereArgs: [catalog.scope]);
        await tx.delete('catalog_outbox',
            where: 'scope=?', whereArgs: [catalog.scope]);
        await tx.delete('local_audit');
        for (final raw in payload['records'] as List) {
          final row = raw as Map;
          await tx.insert('local_records', {
            'farm_id': farm,
            'module': row['module'],
            'record_id': row['id'],
            'payload': jsonEncode(remap(row['data'])),
            'sync_state': 'local',
            'changed_at': DateTime.now().toUtc().toIso8601String()
          });
        }
        for (final module in modules.keys) {
          await tx.insert('sync_metadata', {
            'farm_id': farm,
            'key': 'local-import:$module',
            'value': 'done'
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
            'state': 'local'
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
              'payload'
            ])
              key: row[key]
          });
        }
        await tx.insert('local_audit', {
          'id': const Uuid().v4(),
          'actor_id': AuthService().currentUser!.id,
          'changed_at': DateTime.now().toUtc().toIso8601String(),
          'module': 'services',
          'record_id': 'backup-restoration',
          'operation': 'restore',
          'payload': jsonEncode(
              {'restoredAt': DateTime.now().toUtc().toIso8601String()})
        });
      });
    } catch (_) {
      final expected =
          '${root.path}${Platform.pathSeparator}attachments${Platform.pathSeparator}restore-';
      if (restored.path.startsWith(expected) && await restored.exists()) {
        await restored.delete(recursive: true);
      }
      rethrow;
    }
    return previous.path;
  }

  Future<List<File>> previousCopies() async {
    _authorize();
    final root = await getApplicationSupportDirectory();
    final folder =
        Directory('${root.path}${Platform.pathSeparator}local_backups');
    if (!await folder.exists()) return [];
    final files = (await folder.list().toList())
        .whereType<File>()
        .where((f) => f.path.endsWith('.agrobackup'))
        .toList();
    files.sort((a, b) => b.path.compareTo(a.path));
    return files;
  }
}
