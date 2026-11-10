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

class LocalSyncCollectionStore<T> {
  const LocalSyncCollectionStore(
      {required this.module, required this.legacyKey});

  final String module;
  final String legacyKey;

  Future<List<T>> getAll(
      {required T Function(Map<String, dynamic>) fromJson,
      List<T> Function()? fallback}) async {
    final user = AuthService().currentUser;
    final farmId = user?.farmId;
    if (farmId != null && user!.role != UserRole.admin) return const [];
    if (farmId == null || kIsWeb) return _readLegacy(fromJson, fallback);
    if (user == null || !FarmAccessPolicy.canRead(user.role, module)) {
      return const [];
    }
    final db = await appDatabase.database;
    final rows = await db.query('local_records',
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
    final farmId = user.farmId;
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
    await LicensingService().requireWriteAccess(farmId);
    final db = await appDatabase.database;
    if (AuthService().currentUser?.id != user.id ||
        AuthService().currentUser?.farmId != farmId) {
      throw const FarmAccessDenied('A sessão mudou. Abra esta tela novamente.');
    }
    Future<void> persist(Transaction tx) async {
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
      final now = DateTime.now().toUtc().toIso8601String();
      for (final entry in changes.upserts.entries) {
        final oldRow = existing[entry.key];
        final payload = Map<String, Object?>.from(entry.value);
        if (module == 'machines' && payload['photoPath'] is String) {
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
        final baseVersion = (oldRow?['server_version'] as int?) ?? 0;
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
        await tx.insert(
            'local_records',
            {
              'farm_id': farmId,
              'module': module,
              'record_id': entry.key,
              'payload': encoded,
              'server_version': baseVersion,
              'sync_state': 'pending',
              'sync_error': null,
              'remote_payload': null,
              'remote_deleted': 0,
              'is_deleted': 0,
              'changed_at': now,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final id in changes.deletes) {
        final baseVersion = existing[id]!['server_version']! as int;
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
        await tx.update(
            'local_records',
            {
              'sync_state': 'pending',
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
      SyncService().notifyLocalChange();
    } else {
      await persist(batch);
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
