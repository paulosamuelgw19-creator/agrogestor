import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import '../operations_v2/v2_store.dart';
import '../work/work_store.dart';

/// Durable boundary edits partitioned by API, tenant and account, like operations.
class GeographyStore {
  GeographyStore(this.core, {this.sessionValid});
  final V2Store core;
  final bool Function()? sessionValid;
  void _checkSession() {
    if (sessionValid?.call() == false) {
      throw StateError('Sua sessão mudou. Abra os mapas novamente.');
    }
  }

  static final Map<String, Future<void>> _syncs = {};
  static Future<GeographyStore> open() async {
    final work = await WorkStore.open();
    final core = work.core;
    await initialize(core);
    return GeographyStore(core, sessionValid: work.sessionValid);
  }

  static Future<void> initialize(V2Store core) async {
    await core.db.execute('''CREATE TABLE IF NOT EXISTS geography_outbox (
      scope TEXT NOT NULL,id TEXT NOT NULL,property_id TEXT NOT NULL,path TEXT NOT NULL,
      payload TEXT NOT NULL,state TEXT NOT NULL,error TEXT,created_at TEXT NOT NULL,
      PRIMARY KEY(scope,id))''');
    await core.db.execute('''CREATE TABLE IF NOT EXISTS geography_editor (
      scope TEXT NOT NULL,property_id TEXT NOT NULL,payload TEXT NOT NULL,
      PRIMARY KEY(scope,property_id))''');
  }

  Future<List<Json>> pending([String? propertyId]) async =>
      (await core.db.query('geography_outbox',
              where: 'scope=?${propertyId == null ? '' : ' AND property_id=?'}',
              whereArgs: [core.scope, if (propertyId != null) propertyId],
              orderBy: 'created_at,id'))
          .map((r) => Map<String, dynamic>.from(r))
          .toList();

  Future<Json> refresh(String propertyId) async {
    _checkSession();
    try {
      final result = await core.client.v2('GET', '/properties/$propertyId/map');
      _checkSession();
      await core.cache('map:$propertyId', result);
      return result;
    } on DioException catch (error) {
      if ([401, 403, 404].contains(error.response?.statusCode)) {
        await core.db.delete('v2_mobile_cache',
            where: 'scope=? AND cache_key=?',
            whereArgs: [core.scope, 'map:$propertyId']);
      }
      rethrow;
    }
  }

  Future<void> save(
      String propertyId, String kind, String target, Json body) async {
    _checkSession();
    final cache = await core.cached('map:$propertyId');
    if (cache == null || cache['can_edit'] != true) {
      throw StateError(
          'Conecte ao PC gestor para confirmar acesso à demarcação.');
    }
    final exists = kind == 'property'
        ? (cache['property'] as Map)['id'] == target
        : items(cache, 'plots').any((p) => p['id'] == target);
    if (!exists) throw StateError('Cadastro indisponível nesta fazenda.');
    final path = '/maps/$kind/$target';
    if ((await pending())
        .any((r) => r['path'] == path && r['state'] != 'reviewed')) {
      throw StateError(
          'Já existe um desenho pendente para este cadastro. Revise-o primeiro.');
    }
    await core.db.insert('geography_outbox', {
      'scope': core.scope,
      'id': body['id'],
      'property_id': propertyId,
      'path': path,
      'payload': jsonEncode(body),
      'state': 'pending',
      'created_at': core.now().toUtc().toIso8601String()
    });
  }

  Future<void> retryReviewed(Json row, int version, {Json? revised}) async {
    _checkSession();
    if ((await core.cached('map:${row['property_id']}'))?['can_edit'] != true) {
      throw StateError(
          'Conecte ao PC gestor para renovar o acesso à demarcação.');
    }
    // Explicit review creates a new request. Preserve the original rejected drawing.
    final body = revised ??
        Map<String, dynamic>.from(jsonDecode(row['payload'] as String) as Map);
    body['id'] = const Uuid().v4();
    body['expected_version'] = version;
    await core.db.transaction((tx) async {
      final original = await tx.query('geography_outbox',
          where: 'scope=? AND id=? AND state=?',
          whereArgs: [core.scope, row['id'], 'conflict']);
      if (original.isEmpty) {
        throw StateError('A pendência mudou; atualize a lista.');
      }
      await tx.update('geography_outbox', {'state': 'reviewed'},
          where: 'scope=? AND id=?', whereArgs: [core.scope, row['id']]);
      await tx.insert('geography_outbox', {
        'scope': core.scope,
        'id': body['id'],
        'property_id': row['property_id'],
        'path': row['path'],
        'payload': jsonEncode(body),
        'state': 'pending',
        'created_at': core.now().toUtc().toIso8601String()
      });
    });
  }

  Future<void> sync() => _syncs[core.scope] ??= _drain().whenComplete(() {
        _syncs.remove(core.scope);
      });
  Future<void> _drain() async {
    for (final row in await pending()) {
      _checkSession();
      if (row['state'] != 'pending') continue;
      try {
        await refresh(row['property_id'] as String);
        await core.client.v2('POST', row['path'] as String,
            data: Map<String, dynamic>.from(
                jsonDecode(row['payload'] as String) as Map));
        await core.db.delete('geography_outbox',
            where: 'scope=? AND id=?', whereArgs: [core.scope, row['id']]);
        await refresh(row['property_id'] as String);
      } on DioException catch (error) {
        if ([401, 403, 404, 409, 422].contains(error.response?.statusCode)) {
          await core.db.update('geography_outbox',
              {'state': 'conflict', 'error': v2Error(error)},
              where: 'scope=? AND id=?', whereArgs: [core.scope, row['id']]);
          continue;
        }
        rethrow;
      }
    }
  }
}
