import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../auth/auth_service.dart';
import '../auth/user_model.dart';
import '../auth/farm_access_policy.dart';
import '../licensing/licensing_service.dart';
import 'app_database.dart';
import 'sync_service.dart';
import 'sync_outbox_queue.dart';
import 'collection_changes.dart';
import 'local_write_batch.dart';
import 'farm_api_client.dart';
import 'local_record_validation.dart';
import '../local_activation/local_activation_service.dart';

class LocalSyncCollectionStore<T> {
  const LocalSyncCollectionStore(
      {required this.module, required this.legacyKey});

  static const standaloneFarmId = 'standalone-local-v1';

  final String module;
  final String legacyKey;

  Future<List<T>> getAll(
      {required T Function(Map<String, dynamic>) fromJson,
      List<T> Function()? fallback}) async {
    await LocalActivationService.instance.requireValid();
    final user = AuthService().currentUser;
    if (FarmApiClient.standaloneLocalMode && user == null) return const [];
    final farmId =
        FarmApiClient.standaloneLocalMode ? standaloneFarmId : user?.farmId;
    if (farmId != null && user!.role != UserRole.admin) return const [];
    if (farmId == null || kIsWeb) return _readLegacy(fromJson, fallback);
    if (user == null || !FarmAccessPolicy.canRead(user.role, module)) {
      return const [];
    }
    final db = await appDatabase.database;
    if (FarmApiClient.standaloneLocalMode) {
      final batch = LocalWriteBatch.current;
      if (batch != null) {
        await _importStandalone(batch, fromJson);
      } else {
        await db.transaction((tx) => _importStandalone(tx, fromJson));
      }
    }
    final rows = await (LocalWriteBatch.current ?? db).query('local_records',
        where: 'farm_id=? AND module=? AND is_deleted=0',
        whereArgs: [farmId, module]);
    if (rows.isEmpty) return const [];
    return rows
        .map((row) => fromJson(
            jsonDecode(row['payload']! as String) as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveAll({
    required List<T> records,
    required List<T> previousRecords,
    required String Function(T) idOf,
    required Map<String, Object?> Function(T) toJson,
    required T Function(Map<String, dynamic>) fromJson,
  }) async {
    await LocalActivationService.instance.requireValid();
    final user = AuthService().currentUser;
    if (user?.farmId != null && user!.role != UserRole.admin) {
      throw const FarmAccessDenied(
          'Utilize a área de operações e as propriedades autorizadas.');
    }
    if (user == null || !FarmAccessPolicy.canWrite(user.role, module)) {
      throw const FarmAccessDenied(
          'Seu perfil não pode alterar registros deste módulo.');
    }
    final previous = _index(previousRecords, idOf, toJson);
    final incoming = _index(records, idOf, toJson);
    final farmId =
        FarmApiClient.standaloneLocalMode ? standaloneFarmId : user.farmId;
    if (farmId == null || kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final currentItems = await _readLegacy(fromJson, null);
      final current = _index(currentItems, idOf, toJson);
      // Demo seed records have not yet been persisted in preferences.
      if (!prefs.containsKey(legacyKey)) current.addAll(previous);
      final changes = CollectionChanges.plan(
        previous: previous,
        incoming: incoming,
        current: current,
      );
      for (final id in changes.deletes) {
        current.remove(id);
      }
      current.addAll(changes.upserts);
      await prefs.setString(legacyKey, jsonEncode(current.values.toList()));
      return;
    }
    if (!FarmApiClient.standaloneLocalMode) {
      await LicensingService().requireWriteAccess(farmId);
    }
    final db = await appDatabase.database;
    if (AuthService().currentUser?.id != user.id ||
        AuthService().currentUser?.farmId != user.farmId) {
      throw const FarmAccessDenied('A sessão mudou. Abra esta tela novamente.');
    }
    Future<void> persist(Transaction tx) async {
      if (FarmApiClient.standaloneLocalMode) {
        await _importStandalone(tx, fromJson);
      }
      final rows = await tx.query('local_records',
          where: 'farm_id=? AND module=?', whereArgs: [farmId, module]);
      final existing = {
        for (final row in rows) row['record_id']! as String: row
      };
      final current = <String, Map<String, Object?>>{};
      for (final row in rows.where((row) => !dbBool(row['is_deleted']))) {
        current[row['record_id']! as String] = toJson(fromJson(
          Map<String, dynamic>.from(
              jsonDecode(row['payload']! as String) as Map),
        ));
        if (module == 'machines') {
          current[row['record_id']! as String]!.remove('photoAttachmentId');
        }
      }
      final changes = CollectionChanges.plan(
        previous: previous,
        incoming: incoming,
        current: current,
        conflicts: rows
            .where((row) => row['sync_state'] == 'conflict')
            .map((row) => row['record_id']! as String)
            .toSet(),
        tombstones: rows
            .where((row) => dbBool(row['is_deleted']))
            .map((row) => row['record_id']! as String)
            .toSet(),
      );
      if (FarmApiClient.standaloneLocalMode) {
        await _protectHistory(tx, changes, existing);
      }
      final now = DateTime.now().toUtc().toIso8601String();
      for (final entry in changes.upserts.entries) {
        final oldRow = existing[entry.key];
        final payload = Map<String, Object?>.from(entry.value);
        if (!FarmApiClient.standaloneLocalMode &&
            module == 'machines' &&
            payload['photoPath'] is String) {
          final oldPayload = oldRow == null
              ? null
              : Map<String, dynamic>.from(
                  jsonDecode(oldRow['payload']! as String) as Map);
          final samePhoto = oldPayload?['photoPath'] == payload['photoPath'];
          payload['photoAttachmentId'] = samePhoto
              ? (oldPayload?['photoAttachmentId'] ?? const Uuid().v4())
              : const Uuid().v4();
        }
        final encoded = jsonEncode(payload);
        if (FarmApiClient.standaloneLocalMode) {
          await tx.insert('local_audit', {
            'id': const Uuid().v4(),
            'actor_id': user.id,
            'changed_at': now,
            'module': module,
            'record_id': entry.key,
            'operation': 'upsert',
            'previous_payload': oldRow?['payload'],
            'payload': encoded
          });
        }
        final baseVersion = (oldRow?['server_version'] as int?) ?? 0;
        if (!FarmApiClient.standaloneLocalMode) {
          await SyncOutboxQueue.enqueue(
            tx,
            farmId: farmId,
            module: module,
            recordId: entry.key,
            operation: 'upsert',
            payload: encoded,
            baseVersion: baseVersion,
            createdAt: now,
          );
        }
        await tx.insert(
            'local_records',
            {
              'farm_id': farmId,
              'module': module,
              'record_id': entry.key,
              'payload': encoded,
              'server_version': baseVersion,
              'sync_state':
                  FarmApiClient.standaloneLocalMode ? 'local' : 'pending',
              'sync_error': null,
              'remote_payload': null,
              'remote_deleted': 0,
              'is_deleted': 0,
              'changed_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final id in changes.deletes) {
        if (FarmApiClient.standaloneLocalMode) {
          await tx.insert('local_audit', {
            'id': const Uuid().v4(),
            'actor_id': user.id,
            'changed_at': now,
            'module': module,
            'record_id': id,
            'operation': 'delete',
            'previous_payload': existing[id]?['payload'],
            'payload': null
          });
        }
        final baseVersion = existing[id]!['server_version']! as int;
        if (!FarmApiClient.standaloneLocalMode) {
          await SyncOutboxQueue.enqueue(
            tx,
            farmId: farmId,
            module: module,
            recordId: id,
            operation: 'delete',
            payload: null,
            baseVersion: baseVersion,
            createdAt: now,
          );
        }
        await tx.update(
            'local_records',
            {
              'sync_state':
                  FarmApiClient.standaloneLocalMode ? 'local' : 'pending',
              'sync_error': null,
              'is_deleted': 1,
              'remote_payload': null,
              'remote_deleted': 0,
              'changed_at': now,
            },
            where: 'farm_id=? AND module=? AND record_id=?',
            whereArgs: [farmId, module, id]);
      }
    }

    final batch = LocalWriteBatch.current;
    if (batch == null) {
      await db.transaction(persist);
      if (!FarmApiClient.standaloneLocalMode) SyncService().notifyLocalChange();
    } else {
      await persist(batch);
    }
  }

  Future<void> _importStandalone(
      Transaction tx, T Function(Map<String, dynamic>) fromJson) async {
    final marker = await tx.query('sync_metadata',
        where: 'farm_id=? AND key=?',
        whereArgs: [standaloneFarmId, 'local-import:$module']);
    if (marker.isNotEmpty) return;
    final raw = (await SharedPreferences.getInstance()).getString(legacyKey);
    if (raw != null) {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) {
        throw const FormatException(
            'O cadastro local antigo esta danificado. Preserve os dados e restaure um backup.');
      }
      final ids = <String>{};
      for (final value in decoded) {
        final data = Map<String, dynamic>.from(value as Map);
        fromJson(data); // Validate before committing any migrated record.
        final id = data['id'];
        if (id is! String || id.isEmpty || !ids.add(id)) {
          throw const FormatException(
              'Identificador local invalido ou repetido.');
        }
        await tx.insert(
            'local_records',
            {
              'farm_id': standaloneFarmId,
              'module': module,
              'record_id': id,
              'payload': jsonEncode(data),
              'sync_state': 'local',
              'changed_at': DateTime.now().toUtc().toIso8601String(),
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }
    await tx.insert('sync_metadata', {
      'farm_id': standaloneFarmId,
      'key': 'local-import:$module',
      'value': 'done'
    });
  }

  Future<void> _protectHistory(Transaction tx, CollectionChanges changes,
      Map<String, Map<String, Object?>> existing) async {
    if (module == 'services') {
      if (changes.deletes.isNotEmpty) {
        throw const FormatException(
            'Operacoes registradas compoem o historico e nao podem ser apagadas.');
      }
      for (final entry in changes.upserts.entries) {
        final old = existing[entry.key];
        if (old != null &&
            ((jsonDecode(old['payload'] as String) as Map)['endMeter'] !=
                    null ||
                (jsonDecode(old['payload'] as String) as Map)['cancelledAt'] !=
                    null)) {
          throw const FormatException(
              'Esta operacao ja foi finalizada. Atualize a tela; o consumo nao sera repetido.');
        }
      }
    }
    if (module == 'machines' ||
        module == 'products' ||
        module == 'implements') {
      final related = await tx.query('local_records',
          where: 'farm_id=? AND is_deleted=0', whereArgs: [standaloneFarmId]);
      if (module == 'products') {
        for (final entry in changes.upserts.entries) {
          final old = existing[entry.key];
          if (old != null &&
              (jsonDecode(old['payload'] as String) as Map)['unit'] !=
                  entry.value['unit'] &&
              related.any((r) =>
                  r['module'] == 'productUsage' &&
                  (jsonDecode(r['payload'] as String) as Map)['productId'] ==
                      entry.key)) {
            throw const FormatException(
                'Este produto ja possui consumo. Crie outro cadastro para utilizar outra unidade.');
          }
        }
      }
      for (final id in changes.deletes) {
        for (final row in related) {
          final data = jsonDecode(row['payload'] as String) as Map;
          if (module == 'machines' && data['machineId'] == id ||
              module == 'products' && data['productId'] == id ||
              module == 'implements' && data['implementId'] == id) {
            throw const FormatException(
                'Este cadastro possui historico. Preserve-o; para maquinas, utilize o status Inativa.');
          }
        }
      }
    }
    if (module == 'services') {
      for (final entry in changes.upserts.entries
          .where((e) => !existing.containsKey(e.key))) {
        final data = entry.value;
        final machines = await tx.query('local_records',
            where: 'farm_id=? AND module=? AND record_id=? AND is_deleted=0',
            whereArgs: [standaloneFarmId, 'machines', data['machineId']]);
        if (machines.isEmpty) {
          throw const FormatException(
              'Cadastre a maquina antes de iniciar a operacao.');
        }
        final machine = jsonDecode(machines.single['payload'] as String) as Map;
        if ((data['startMeter'] as num) < (machine['hourMeter'] as num) ||
            ['emManutencao', 'parada', 'inativa'].contains(machine['status'])) {
          throw const FormatException(
              'Confira o horimetro e a disponibilidade da maquina.');
        }
      }
    }
    if (module == 'services') {
      final active = <String, String>{};
      final activeImplements = <String>{};
      final projected = <String, Map<String, dynamic>>{
        for (final row in existing.entries)
          if (!dbBool(row.value['is_deleted']))
            row.key: Map<String, dynamic>.from(
                jsonDecode(row.value['payload'] as String) as Map)
      };
      for (final entry in changes.upserts.entries) {
        projected[entry.key] = entry.value;
      }
      for (final entry in projected.entries) {
        final data = entry.value;
        if (data['endMeter'] == null && data['cancelledAt'] == null) {
          final machine = data['machineId'] as String;
          if (active.containsKey(machine)) {
            throw const FormatException(
                'A maquina ja possui uma operacao em andamento.');
          }
          active[machine] = entry.key;
          final implement = data['implementId'];
          if (implement is String &&
              implement.isNotEmpty &&
              !activeImplements.add(implement)) {
            throw const FormatException(
                'Este implemento já está em outra operação.');
          }
        }
      }
    }
    for (final data in changes.upserts.values) {
      validateLocalRecord(module, Map<String, dynamic>.from(data));
      void validate(Object? value) {
        if (value is num && !value.isFinite) {
          throw const FormatException('Informe numeros finitos e validos.');
        }
        if (value is Map) {
          for (final item in value.values) {
            validate(item);
          }
        }
        if (value is List) {
          for (final item in value) {
            validate(item);
          }
        }
      }

      validate(data);
      if (module == 'products' && (data['quantity'] as num) < 0) {
        throw const FormatException('O estoque nao pode ficar negativo.');
      }
      if (module == 'productUsage' && (data['quantity'] as num) <= 0) {
        throw const FormatException('O consumo precisa ser maior que zero.');
      }
      if (module == 'services') {
        final start = data['startMeter'] as num;
        final end = data['endMeter'] as num?;
        if (start < 0 || end != null && end < start) {
          throw const FormatException('Confira os horimetros da operacao.');
        }
        if ((data['fuelLiters'] as num? ?? 0) < 0 ||
            (data['areaHectares'] as num? ?? 0) < 0) {
          throw const FormatException(
              'Area e combustivel nao podem ser negativos.');
        }
      }
      if (module == 'fuel' &&
          ((data['liters'] as num) <= 0 ||
              (data['pricePerLiter'] as num? ?? 0) < 0 ||
              (data['hourMeter'] as num) < 0)) {
        throw const FormatException(
            'Confira os litros, o preco e o horimetro do abastecimento.');
      }
    }
  }

  Map<String, Map<String, Object?>> _index(
    List<T> records,
    String Function(T) idOf,
    Map<String, Object?> Function(T) toJson,
  ) {
    final result = <String, Map<String, Object?>>{};
    for (final record in records) {
      final id = idOf(record);
      if (id.isEmpty || result.containsKey(id)) {
        throw const FormatException(
            'Identificador de registro vazio ou repetido.');
      }
      result[id] = Map<String, Object?>.from(toJson(record));
      void finite(Object? value) {
        if (value is num && !value.isFinite) {
          throw const FormatException('Informe numeros finitos e validos.');
        }
        if (value is Map) {
          for (final item in value.values) {
            finite(item);
          }
        }
        if (value is List) {
          for (final item in value) {
            finite(item);
          }
        }
      }

      finite(result[id]);
      if (module == 'machines') result[id]!.remove('photoAttachmentId');
    }
    return result;
  }

  Future<List<T>> _readLegacy(T Function(Map<String, dynamic>) fromJson,
      List<T> Function()? fallback) async {
    final raw = (await SharedPreferences.getInstance()).getString(legacyKey);
    if (raw == null) return fallback?.call() ?? const [];
    try {
      return (jsonDecode(raw) as List<dynamic>)
          .map((item) => fromJson(Map<String, dynamic>.from(item as Map)))
          .toList();
    } on FormatException {
      return fallback?.call() ?? const [];
    } on TypeError {
      return fallback?.call() ?? const [];
    }
  }
}
