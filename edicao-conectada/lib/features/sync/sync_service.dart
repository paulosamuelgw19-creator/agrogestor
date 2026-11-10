import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:workmanager/workmanager.dart';

import '../auth/auth_service.dart';
import '../auth/user_model.dart';
import '../auth/farm_access_policy.dart';
import '../licensing/licensing_service.dart';
import 'app_database.dart';
import 'farm_api_client.dart';
import 'background_sync.dart';
import 'sync_outbox_queue.dart';
import '../operations_v2/v2_store.dart';
import '../properties/catalog_store.dart';
import '../properties/geography_store.dart';
import '../machines/catalog_photos.dart';
import '../work/work_store.dart';

enum SyncState {
  idle,
  pending,
  syncing,
  offline,
  needsAttention,
  notConfigured
}

class SyncSnapshot {
  const SyncSnapshot(
      {required this.state,
      required this.pending,
      required this.errors,
      required this.conflicts,
      required this.lastSyncedAt,
      this.message});
  final SyncState state;
  final int pending;
  final int errors;
  final int conflicts;
  final DateTime? lastSyncedAt;
  final String? message;
}

class SyncService extends ChangeNotifier with WidgetsBindingObserver {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal();

  bool _running = false;
  bool _started = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  Timer? _retryTimer;
  SyncState _state = SyncState.notConfigured;
  String? _message;

  SyncState get state => _state;
  String? get message => _message;

  Future<void> start() async {
    if (_started) {
      unawaited(syncNow());
      return;
    }
    _started = true;
    WidgetsBinding.instance.addObserver(this);
    if (defaultTargetPlatform == TargetPlatform.android) {
      await Workmanager().registerPeriodicTask(
        backgroundSyncUniqueName,
        backgroundSyncTaskName,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
    }
    _connectivity ??= Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((value) => value != ConnectivityResult.none)) {
        unawaited(syncNow());
      } else {
        _setState(SyncState.offline,
            'Sem internet. As alterações permanecem salvas neste aparelho.');
      }
    });
    _retryTimer ??=
        Timer.periodic(const Duration(minutes: 2), (_) => unawaited(syncNow()));
    await syncNow();
  }

  void stop() {
    _started = false;
    _retryTimer?.cancel();
    _retryTimer = null;
    unawaited(_connectivity?.cancel());
    _connectivity = null;
    WidgetsBinding.instance.removeObserver(this);
    if (defaultTargetPlatform == TargetPlatform.android) {
      unawaited(Workmanager().cancelByUniqueName(backgroundSyncUniqueName));
    }
    _setState(SyncState.notConfigured, null);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(syncNow());
  }

  void notifyLocalChange() {
    notifyListeners();
    unawaited(syncNow());
  }

  Future<void> syncNow() async {
    final user = AuthService().currentUser;
    final token = AuthService().accessToken;
    if (user?.farmId == null || token == null) {
      await _summaryState(SyncState.notConfigured, null);
      return;
    }
    if (_running) return;
    final base = await FarmApiClient.instance.baseUrl;
    if (base == null || base.isEmpty) {
      await _summaryState(
          SyncState.notConfigured, 'Configure o endereço do PC gestor.');
      return;
    }
    if (_running ||
        AuthService().accessToken != token ||
        AuthService().currentUser?.id != user!.id) {
      return;
    }
    final client = FarmApiClient.forSession(
        baseUrl: base, token: token, farmId: user.farmId!);
    _running = true;
    _setState(SyncState.syncing, null);
    try {
      final entitlement =
          await LicensingService().refresh(user.farmId!, client: client);
      if (AuthService().accessToken != token ||
          AuthService().currentUser?.id != user.id) {
        return;
      }
      final writeAllowed = entitlement?.canWriteAt(DateTime.now()) ?? false;
      if (writeAllowed && user.role == UserRole.admin) {
        await _push(user.farmId!, user.role, client);
      }
      if (user.role == UserRole.admin) await _pull(user.farmId!, client);
      final catalog = await CatalogStore.open();
      await catalog.sync(writeAllowed: writeAllowed);
      final catalogPending = (await catalog.pending()).length;
      var workPending = 0;
      var mapPending = 0;
      if (writeAllowed &&
          (user.role == UserRole.admin || user.role == UserRole.operator)) {
        final maps = await GeographyStore.open();
        await maps.sync();
        mapPending = (await maps.pending())
            .where((r) => r['state'] != 'reviewed')
            .length;
        final photos = await CatalogPhotoStore.open();
        await photos.sync();
        mapPending += (await photos.pending()).length;
      }
      if (writeAllowed) {
        try {
          final work = await WorkStore.open();
          await work.sync();
          workPending = (await work.pending()).length;
        } on DioException catch (error) {
          if (![404, 503].contains(error.response?.statusCode)) rethrow;
        }
      }
      if (writeAllowed &&
          AuthService().accessToken == token &&
          AuthService().currentUser?.id == user.id) {
        final operations = await V2Store.open(
            baseUrl: base, farmId: user.farmId!, userId: user.id, token: token);
        await operations.sync();
      }
      if (user.role != UserRole.admin) {
        _setState(
            !writeAllowed
                ? SyncState.needsAttention
                : workPending + mapPending > 0
                    ? SyncState.pending
                    : SyncState.idle,
            writeAllowed
                ? workPending + mapPending > 0
                    ? 'Tarefas/oficina: $workPending; demarcações: $mapPending aguardando conferência.'
                    : 'Tarefas, oficina e operações sincronizadas.'
                : entitlement?.notice);
        return;
      }
      await _putMetadata(user.farmId!, 'last_sync_at',
          DateTime.now().toUtc().toIso8601String());
      if (catalogPending > 0 || workPending > 0 || mapPending > 0) {
        await _summaryState(
            SyncState.pending,
            workPending + mapPending > 0
                ? 'Tarefas/oficina: $workPending; demarcações: $mapPending pendente(s).'
                : await catalog.notice());
        return;
      }
      if (writeAllowed) {
        await _summaryState(SyncState.idle, 'Sincronização concluída.');
      } else {
        await _summaryState(SyncState.needsAttention,
            entitlement?.notice ?? 'Não foi possível validar a licença.');
      }
    } on DioException catch (error) {
      final message = _errorMessage(error);
      await _sendingToError(user.farmId!, message);
      await _summaryState(SyncState.offline, message);
    } catch (error) {
      await _sendingToError(user.farmId!, error.toString());
      await _summaryState(SyncState.needsAttention, error.toString());
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<void> _push(String farmId, UserRole role, FarmApiClient client) async {
    final modules = FarmAccessPolicy.readableModules(role).toList()..sort();
    if (modules.isEmpty) return;
    final db = await appDatabase.database;
    // Claim the oldest event for each record atomically. Local writes then see
    // it as sending and create a follow-up event instead of mutating the
    // payload while this batch is being serialized and sent.
    final rows = await db.transaction((tx) async {
      final candidates = await tx.query(
        'sync_outbox',
        where:
            "farm_id=? AND module IN (${List.filled(modules.length, '?').join(',')}) AND state IN ('pending','error','sending')",
        whereArgs: [farmId, ...modules],
        orderBy: 'created_at ASC,rowid ASC',
        limit: 500,
      );
      final selected = SyncOutboxQueue.oldestPerRecord(candidates);
      for (final row in selected) {
        await tx.update(
          'sync_outbox',
          {'state': 'sending', 'attempts': (row['attempts']! as int) + 1},
          where: 'event_id=?',
          whereArgs: [row['event_id']],
        );
      }
      return selected;
    });
    if (rows.isEmpty) return;
    final events = rows.map((row) => SyncOutboxEntry(values: row)).toList();
    final wireEvents = <Map<String, dynamic>>[];
    for (final event in events) {
      wireEvents.add({
        'eventId': event.eventId,
        'module': event.module,
        'recordId': event.recordId,
        'operation': event.operation,
        'payload': await _wirePayload(event, client),
        'baseVersion': event.baseVersion,
      });
    }
    final response =
        await client.post('/sync/push', data: {'events': wireEvents});
    for (final raw in response['acknowledged'] as List<dynamic>? ?? const []) {
      await _acknowledge(Map<String, dynamic>.from(raw as Map), farmId);
    }
    for (final raw in response['conflicts'] as List<dynamic>? ?? const []) {
      await _markConflict(
          Map<String, dynamic>.from(raw as Map), farmId, client);
    }
    for (final raw in response['rejected'] as List<dynamic>? ?? const []) {
      final item = Map<String, dynamic>.from(raw as Map);
      await _markRejected(item['eventId'] as String,
          item['message'] as String? ?? 'Servidor recusou este registro.');
    }
  }

  Future<Map<String, dynamic>?> _wirePayload(
      SyncOutboxEntry event, FarmApiClient client) async {
    if (event.payload == null) return null;
    final decoded = jsonDecode(event.payload!);
    if (decoded is! Map) {
      throw const FormatException('Registro local inválido na fila.');
    }
    final payload = Map<String, dynamic>.from(decoded);
    if (event.module == 'machines') {
      final path = payload['photoPath'] as String?;
      final attachmentId = payload['photoAttachmentId'] as String?;
      if (path != null && attachmentId != null && await File(path).exists()) {
        await client.uploadAttachment(attachmentId, path);
      }
      // Local paths belong to one phone. Other devices retrieve the attachment by ID.
      payload.remove('photoPath');
    }
    return payload;
  }

  Future<void> _acknowledge(Map<String, dynamic> item, String farmId) async {
    final db = await appDatabase.database;
    await db.transaction((tx) => SyncOutboxQueue.acknowledge(
          tx,
          eventId: item['eventId'] as String,
          farmId: farmId,
          version: (item['version'] as num).toInt(),
        ));
  }

  Future<void> _markConflict(
      Map<String, dynamic> item, String farmId, FarmApiClient client) async {
    final db = await appDatabase.database;
    const message = 'O mesmo registro mudou em outro aparelho.';
    final module = item['module'] as String;
    final id = item['recordId'] as String;
    final remotePayload =
        await _remotePayloadJson(module, item['serverPayload'], client);
    await db.transaction((tx) async {
      await tx.update(
          'sync_outbox', {'state': 'conflict', 'last_error': message},
          where: 'farm_id=? AND module=? AND record_id=?',
          whereArgs: [farmId, module, id]);
      await tx.update(
          'local_records',
          {
            'sync_state': 'conflict',
            'sync_error': message,
            'server_version': (item['serverVersion'] as num).toInt(),
            'remote_payload': remotePayload,
            'remote_deleted': item['serverDeleted'] == true ? 1 : 0,
          },
          where: 'farm_id=? AND module=? AND record_id=?',
          whereArgs: [farmId, module, id]);
    });
  }

  Future<void> _markRejected(String eventId, String message) async {
    final db = await appDatabase.database;
    final found = await db.query('sync_outbox',
        where: 'event_id=?', whereArgs: [eventId], limit: 1);
    if (found.isEmpty) return;
    final event = SyncOutboxEntry(values: found.first);
    await db.transaction((tx) async {
      await tx.update('sync_outbox', {'state': 'error', 'last_error': message},
          where: 'event_id=?', whereArgs: [eventId]);
      await tx.update(
          'local_records', {'sync_state': 'error', 'sync_error': message},
          where: 'farm_id=? AND module=? AND record_id=?',
          whereArgs: [event.farmId, event.module, event.recordId]);
    });
  }

  Future<void> _pull(String farmId, FarmApiClient client) async {
    final db = await appDatabase.database;
    final metadata = await db.query('sync_metadata',
        where: 'farm_id=? AND key=?',
        whereArgs: [farmId, 'pull_cursor'],
        limit: 1);
    var cursor =
        int.tryParse(metadata.firstOrNull?['value'] as String? ?? '') ?? 0;
    for (var page = 0; page < 20; page++) {
      final response = await client
          .get('/sync/pull', query: {'cursor': cursor, 'limit': 500});
      final changes = response['changes'] as List<dynamic>? ?? const [];
      for (final raw in changes) {
        final item = Map<String, dynamic>.from(raw as Map);
        await _applyRemote(item, farmId, client);
        cursor = (item['cursor'] as num).toInt();
      }
      final next = (response['nextCursor'] as num?)?.toInt() ?? cursor;
      if (changes.isEmpty && next > cursor) cursor = next;
      await _putMetadata(farmId, 'pull_cursor', '$cursor');
      if (response['hasMore'] != true || changes.isEmpty) break;
    }
  }

  Future<void> _applyRemote(
      Map<String, dynamic> item, String farmId, FarmApiClient client) async {
    final db = await appDatabase.database;
    final module = item['module'] as String;
    final id = item['recordId'] as String;
    final version = (item['version'] as num).toInt();
    final pending = await db.query('sync_outbox',
        where:
            "farm_id=? AND module=? AND record_id=? AND state IN ('pending','error','sending','conflict')",
        whereArgs: [farmId, module, id]);
    final rows = await db.query('local_records',
        where: 'farm_id=? AND module=? AND record_id=?',
        whereArgs: [farmId, module, id],
        limit: 1);
    final current = rows.firstOrNull;
    if (pending.isNotEmpty &&
        current != null &&
        version > (current['server_version'] as int)) {
      final remotePayload =
          await _remotePayloadJson(module, item['payload'], client);
      await db.transaction((tx) async {
        await tx.update(
            'local_records',
            {
              'sync_state': 'conflict',
              'sync_error': 'O mesmo registro mudou em outro aparelho.',
              'server_version': version,
              'remote_payload': remotePayload,
              'remote_deleted': item['deleted'] == true ? 1 : 0,
            },
            where: 'farm_id=? AND module=? AND record_id=?',
            whereArgs: [farmId, module, id]);
        await tx.update(
            'sync_outbox',
            {
              'state': 'conflict',
              'last_error': 'O mesmo registro mudou em outro aparelho.'
            },
            where: 'farm_id=? AND module=? AND record_id=?',
            whereArgs: [farmId, module, id]);
      });
      return;
    }
    if (pending.isNotEmpty &&
        current != null &&
        version <= (current['server_version'] as int)) {
      // Keep the newest local payload while its queued write is being delivered.
      return;
    }
    Map<String, dynamic>? payload;
    if (item['payload'] is Map) {
      payload = Map<String, dynamic>.from(item['payload'] as Map);
      final attachmentId = payload['photoAttachmentId'] as String?;
      if (module == 'machines' && attachmentId != null) {
        payload['photoPath'] = await client.downloadAttachment(attachmentId);
      }
    }
    await db.insert(
        'local_records',
        {
          'farm_id': farmId,
          'module': module,
          'record_id': id,
          'payload': payload == null ? '{}' : jsonEncode(payload),
          'server_version': version,
          'sync_state': 'synced',
          'sync_error': null,
          'remote_payload': null,
          'remote_deleted': 0,
          'is_deleted': item['deleted'] == true ? 1 : 0,
          'changed_at': item['updatedAt'] as String? ??
              DateTime.now().toUtc().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> _remotePayloadJson(
      String module, Object? raw, FarmApiClient client) async {
    if (raw is! Map) return null;
    final payload = Map<String, dynamic>.from(raw);
    final attachmentId = payload['photoAttachmentId'] as String?;
    if (module == 'machines' && attachmentId != null) {
      payload['photoPath'] = await client.downloadAttachment(attachmentId);
    }
    return jsonEncode(payload);
  }

  Future<void> _sendingToError(String farmId, String message) async {
    final db = await appDatabase.database;
    final rows = await db.query('sync_outbox',
        where: "farm_id=? AND state='sending'", whereArgs: [farmId]);
    for (final raw in rows) {
      final event = SyncOutboxEntry(values: raw);
      await db.transaction((tx) async {
        await tx.update(
            'sync_outbox', {'state': 'error', 'last_error': message},
            where: 'event_id=?', whereArgs: [event.eventId]);
        await tx.update(
            'local_records', {'sync_state': 'error', 'sync_error': message},
            where: 'farm_id=? AND module=? AND record_id=?',
            whereArgs: [farmId, event.module, event.recordId]);
      });
    }
  }

  Future<SyncSnapshot> snapshot() async {
    final user = AuthService().currentUser;
    final farmId = user?.farmId;
    if (farmId == null || user == null) {
      return SyncSnapshot(
          state: _state,
          pending: 0,
          errors: 0,
          conflicts: 0,
          lastSyncedAt: null,
          message: _message);
    }
    final modules = FarmAccessPolicy.readableModules(user.role).toList()
      ..sort();
    final db = await appDatabase.database;
    final rows = await db.query('sync_outbox',
        where:
            'farm_id=? AND module IN (${List.filled(modules.length, '?').join(',')})',
        whereArgs: [farmId, ...modules]);
    final pending = rows
        .where((row) => row['state'] == 'pending' || row['state'] == 'sending')
        .length;
    final errors = rows.where((row) => row['state'] == 'error').length;
    final conflicts = rows.where((row) => row['state'] == 'conflict').length;
    final lastRows = await db.query('sync_metadata',
        where: 'farm_id=? AND key=?',
        whereArgs: [farmId, 'last_sync_at'],
        limit: 1);
    final date =
        DateTime.tryParse(lastRows.firstOrNull?['value'] as String? ?? '')
            ?.toLocal();
    final state = conflicts + errors > 0
        ? SyncState.needsAttention
        : (_state == SyncState.idle && pending > 0
            ? SyncState.pending
            : _state);
    return SyncSnapshot(
        state: state,
        pending: pending,
        errors: errors,
        conflicts: conflicts,
        lastSyncedAt: date,
        message: _message);
  }

  Future<List<LocalRecord>> conflicts() async {
    final user = AuthService().currentUser;
    final farmId = user?.farmId;
    if (farmId == null || user == null) return const [];
    final modules = FarmAccessPolicy.readableModules(user.role).toList()
      ..sort();
    final db = await appDatabase.database;
    final rows = await db.query('local_records',
        where:
            "farm_id=? AND module IN (${List.filled(modules.length, '?').join(',')}) AND sync_state='conflict'",
        whereArgs: [farmId, ...modules],
        orderBy: 'changed_at DESC');
    return rows.map((row) => LocalRecord(values: row)).toList();
  }

  Future<List<SyncOutboxEntry>> outboxEntries() async {
    final user = AuthService().currentUser;
    if (user?.farmId != null && user!.role != UserRole.admin) return const [];
    final farmId = user?.farmId;
    if (farmId == null || user == null) return const [];
    final modules = FarmAccessPolicy.readableModules(user.role).toList()
      ..sort();
    final db = await appDatabase.database;
    final rows = await db.query('sync_outbox',
        where:
            'farm_id=? AND module IN (${List.filled(modules.length, '?').join(',')})',
        whereArgs: [farmId, ...modules],
        orderBy: 'created_at ASC');
    return rows.map((row) => SyncOutboxEntry(values: row)).toList();
  }

  Future<String?> recordState(String module, String recordId) async {
    final user = AuthService().currentUser;
    final farmId = user?.farmId;
    if (farmId == null ||
        user == null ||
        !FarmAccessPolicy.canRead(user.role, module)) {
      return null;
    }
    final db = await appDatabase.database;
    final rows = await db.query('local_records',
        columns: ['sync_state'],
        where: 'farm_id=? AND module=? AND record_id=?',
        whereArgs: [farmId, module, recordId],
        limit: 1);
    return rows.firstOrNull?['sync_state'] as String?;
  }

  Future<void> resolveConflict(LocalRecord row,
      {required bool useServerVersion}) async {
    final user = AuthService().currentUser;
    final farmId = user?.farmId;
    if (farmId == null || user == null) {
      throw StateError('Entre na fazenda para resolver o conflito.');
    }
    if (!FarmAccessPolicy.canWrite(user.role, row.module)) {
      throw const FarmAccessDenied(
          'Seu perfil não pode resolver conflitos deste módulo.');
    }
    final db = await appDatabase.database;
    await db.transaction((tx) async {
      final found = await tx.query('local_records',
          where: 'farm_id=? AND module=? AND record_id=?',
          whereArgs: [farmId, row.module, row.recordId],
          limit: 1);
      if (found.isEmpty) return;
      final current = LocalRecord(values: found.first);
      await tx.delete('sync_outbox',
          where: 'farm_id=? AND module=? AND record_id=?',
          whereArgs: [farmId, row.module, row.recordId]);
      if (useServerVersion) {
        await tx.update(
            'local_records',
            {
              'payload': current.remotePayload ?? '{}',
              'is_deleted': current.remoteDeleted ? 1 : 0,
              'sync_state': 'synced',
              'sync_error': null,
              'remote_payload': null,
              'remote_deleted': 0,
            },
            where: 'farm_id=? AND module=? AND record_id=?',
            whereArgs: [farmId, row.module, row.recordId]);
      } else {
        final now = DateTime.now().toUtc().toIso8601String();
        await tx.insert('sync_outbox', {
          'event_id': const Uuid().v4(),
          'farm_id': farmId,
          'module': row.module,
          'record_id': row.recordId,
          'operation': current.isDeleted ? 'delete' : 'upsert',
          'payload': current.isDeleted ? null : current.payload,
          'base_version': current.serverVersion,
          'created_at': now,
          'attempts': 0,
          'state': 'pending',
          'last_error': null,
        });
        await tx.update(
            'local_records',
            {
              'sync_state': 'pending',
              'sync_error': null,
              'remote_payload': null,
              'remote_deleted': 0
            },
            where: 'farm_id=? AND module=? AND record_id=?',
            whereArgs: [farmId, row.module, row.recordId]);
      }
    });
    notifyListeners();
    unawaited(syncNow());
  }

  Future<String> inviteUser(String email, String role) async =>
      (await FarmApiClient.instance.post('/auth/invitations', data: {
        'email': email.trim().toLowerCase(),
        'role': role
      }))['code'] as String;

  Future<List<Map<String, dynamic>>> users() async {
    final response = await FarmApiClient.instance.get('/auth/users');
    final rows = response['users'];
    if (rows is! List) {
      throw const FormatException(
          'Resposta inválida ao consultar os usuários.');
    }
    return rows.map((row) => Map<String, dynamic>.from(row as Map)).toList();
  }

  Future<void> setUserActive(String userId, bool active) async {
    await FarmApiClient.instance
        .patch('/auth/users/$userId/access', data: {'active': active});
  }

  Future<void> _putMetadata(String farmId, String key, String value) async {
    final db = await appDatabase.database;
    await db.insert(
        'sync_metadata', {'farm_id': farmId, 'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _summaryState(SyncState state, String? message) async {
    final summary = await snapshot();
    final resolved = summary.conflicts + summary.errors > 0
        ? SyncState.needsAttention
        : (state == SyncState.idle && summary.pending > 0
            ? SyncState.pending
            : state);
    _setState(resolved, message);
  }

  void _setState(SyncState state, String? message) {
    _state = state;
    _message = message;
    notifyListeners();
  }

  String _errorMessage(DioException error) {
    final data = error.response?.data;
    if (data is Map && data['detail'] is String) {
      return data['detail'] as String;
    }
    if (error.response?.statusCode == 401) {
      return 'Sessão expirada. Entre novamente para enviar as alterações pendentes.';
    }
    return 'PC gestor ou VPN indisponível. A fila está salva e tentará novamente.';
  }
}
