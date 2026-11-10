import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:sqflite/sqflite.dart';
import '../sync/app_database.dart';
import '../sync/farm_api_client.dart';

typedef Json = Map<String, dynamic>;

List<Json> items(Json data, String key) => (data[key] as List? ?? [])
    .map((value) => Map<String, dynamic>.from(value as Map))
    .toList();

String v2Error(Object error) {
  if (error is DioException) {
    final data = error.response?.data;
    if (data is Map &&
        data['detail'] is String &&
        data['detail'] != 'Not Found') {
      return data['detail'] as String;
    }
    if (error.response?.statusCode == 422) {
      return 'Confira os campos, datas e unidades do lançamento.';
    }
    if (error.response?.statusCode == 404 ||
        error.response?.statusCode == 503) {
      return 'O PC gestor conectado ainda não oferece esta função. Atualize o servidor para compartilhar os novos cadastros.';
    }
    if (error.response?.statusCode == 401) {
      return 'Sua sessão venceu. Entre novamente.';
    }
    return 'Não foi possível alcançar o PC gestor. Seus lançamentos pendentes continuam salvos.';
  }
  return error
      .toString()
      .replaceFirst('Bad state: ', '')
      .replaceFirst('FormatException: ', '');
}

/// Partitioned by server, organization AND account. Confirmed snapshots are never
/// mixed with pending operations; the server remains authoritative for valuation.
class V2Store {
  V2Store(
      {required this.db,
      required this.client,
      required this.scope,
      required this.tokenExpiry,
      DateTime Function()? clock})
      : now = clock ?? DateTime.now;
  final Database db;
  final FarmApiClient client;
  final String scope;
  final DateTime tokenExpiry;
  final DateTime Function() now;
  static final Map<String, Future<void>> _syncs = {};

  static Future<V2Store> open(
      {required String baseUrl,
      required String farmId,
      required String userId,
      required String token}) async {
    final db = await appDatabase.database;
    await initialize(db);
    DateTime expiry = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      final claims = jsonDecode(utf8.decode(
          base64Url.decode(base64Url.normalize(token.split('.')[1])))) as Map;
      expiry = DateTime.fromMillisecondsSinceEpoch(
          (claims['exp'] as num).toInt() * 1000,
          isUtc: true);
    } catch (_) {
      /* No offline lease without an expiring authenticated session. */
    }
    return V2Store(
        db: db,
        client: FarmApiClient.forSession(
            baseUrl: baseUrl, token: token, farmId: farmId),
        scope: jsonEncode([baseUrl, farmId, userId]),
        tokenExpiry: expiry);
  }

  static Future<void> initialize(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS v2_mobile_cache (
      scope TEXT NOT NULL, cache_key TEXT NOT NULL, payload TEXT NOT NULL,
      expires_at TEXT NOT NULL, PRIMARY KEY(scope,cache_key))''');
    await db.execute('''CREATE TABLE IF NOT EXISTS v2_mobile_outbox (
      scope TEXT NOT NULL,id TEXT NOT NULL,property_id TEXT NOT NULL,
      payload TEXT NOT NULL,state TEXT NOT NULL,error TEXT,created_at TEXT NOT NULL,
      PRIMARY KEY(scope,id))''');
  }

  Future<Json?> cached(String key) async {
    final rows = await db.query('v2_mobile_cache',
        where: 'scope=? AND cache_key=?', whereArgs: [scope, key]);
    if (rows.isEmpty ||
        !now().isBefore(tokenExpiry) ||
        !now().isBefore(DateTime.parse(rows.first['expires_at'] as String))) {
      return null;
    }
    return Map<String, dynamic>.from(
        jsonDecode(rows.first['payload'] as String) as Map);
  }

  Future<void> cache(String key, Json value) async {
    final lease = now().add(const Duration(hours: 8));
    final expiry = lease.isBefore(tokenExpiry) ? lease : tokenExpiry;
    await db.insert(
        'v2_mobile_cache',
        {
          'scope': scope,
          'cache_key': key,
          'payload': jsonEncode(value),
          'expires_at': expiry.toUtc().toIso8601String()
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Json> refresh([String? propertyId]) async {
    try {
      final data = await client.v2('GET', '/workspace',
          query: propertyId == null ? null : {'property_id': propertyId});
      if (data['administrator'] == true ||
          data['legacy_role'] == 'operator' ||
          items(data, 'properties').any((p) => [
                'administrator',
                'owner',
                'manager',
                'employee'
              ].contains(p['access_role']))) {
        try {
          data['activity_plans'] =
              items(await client.v2('GET', '/activity-plans'), 'items');
        } on DioException catch (error) {
          if (error.response?.statusCode != 404) rethrow;
        }
      }
      await cache(propertyId ?? 'root', data);
      return data;
    } on DioException catch (error) {
      if ([401, 403, 404].contains(error.response?.statusCode)) {
        await db
            .delete('v2_mobile_cache', where: 'scope=?', whereArgs: [scope]);
      }
      rethrow;
    }
  }

  Future<void> queueOperation(String propertyId, Json body) async {
    final snapshot = await cached(propertyId);
    if (snapshot == null) {
      throw StateError(
          'Conecte ao PC gestor para renovar o acesso offline (até 8 horas).');
    }
    final property = items(snapshot, 'properties')
        .where((p) => p['id'] == propertyId)
        .firstOrNull;
    if (property == null ||
        !['administrator', 'owner', 'manager', 'employee']
            .contains(property['access_role'])) {
      throw StateError(
          'Seu acesso não permite registrar operações nesta propriedade.');
    }
    if (!items(snapshot, 'cycles').any((c) => c['id'] == body['cycle_id'])) {
      throw StateError('O ciclo não pertence à propriedade selecionada.');
    }
    await db.transaction((tx) async {
      final previous = await tx.query('v2_mobile_outbox',
          where: 'scope=? AND id=?', whereArgs: [scope, body['id']]);
      if (previous.isNotEmpty) {
        if (previous.first['payload'] != jsonEncode(body)) {
          throw StateError('Este lançamento já tem dados diferentes.');
        }
        return;
      }
      if (body['task_id'] != null) {
        final requests = await tx
            .query('v2_mobile_outbox', where: 'scope=?', whereArgs: [scope]);
        if (requests.any((row) =>
            (jsonDecode(row['payload'] as String) as Map)['task_id'] ==
            body['task_id'])) {
          throw StateError(
              'Esta tarefa já tem um realizado salvo. Confira a fila de operações antes de registrar novamente.');
        }
      }
      await tx.insert('v2_mobile_outbox', {
        'scope': scope,
        'id': body['id'],
        'property_id': propertyId,
        'payload': jsonEncode(body),
        'state': 'pending',
        'created_at': now().toUtc().toIso8601String()
      });
    });
  }

  Future<List<Json>> pending([String? propertyId]) async =>
      (await db.query('v2_mobile_outbox',
              where: 'scope=?${propertyId == null ? '' : ' AND property_id=?'}',
              whereArgs: [scope, if (propertyId != null) propertyId],
              orderBy: 'created_at,id'))
          .map((r) => Map<String, dynamic>.from(r))
          .toList();

  Future<void> sync() => _syncs[scope] ??= _drain().whenComplete(() {
        _syncs.remove(scope);
      });

  Future<void> _drain() async {
    final rows = await pending();
    final blockedProperties = <String>{};
    for (final row in rows) {
      final propertyId = row['property_id'] as String;
      if (row['state'] == 'conflict' ||
          blockedProperties.contains(propertyId)) {
        blockedProperties.add(propertyId);
        continue;
      }
      try {
        // Authorization is checked again online before every upload, even when
        // the phone holds an unexpired offline snapshot.
        await refresh(propertyId);
        await client.v2('POST', '/operations',
            data: jsonDecode(row['payload'] as String));
        await db.delete('v2_mobile_outbox',
            where: 'scope=? AND id=?', whereArgs: [scope, row['id']]);
      } on DioException catch (error) {
        final permanent =
            [403, 404, 409, 422].contains(error.response?.statusCode);
        await db.update(
            'v2_mobile_outbox',
            {
              'state': permanent ? 'conflict' : 'pending',
              'error': v2Error(error)
            },
            where: 'scope=? AND id=?',
            whereArgs: [scope, row['id']]);
        if (!permanent) rethrow;
        blockedProperties.add(propertyId);
      }
    }
  }

  /// Explicit retry preserves the exact body/UUID, never silently overwrites.
  Future<void> retry(String id) async {
    await db.update('v2_mobile_outbox', {'state': 'pending', 'error': null},
        where: 'scope=? AND id=?', whereArgs: [scope, id]);
    await sync();
  }

  Future<void> discardUnconfirmed(Json row) async {
    await refresh(row['property_id'] as String);
    try {
      await client.v2('GET', '/operations/${row['id']}');
      // A previous request may have committed before the connection dropped.
      await db.delete('v2_mobile_outbox',
          where: 'scope=? AND id=?', whereArgs: [scope, row['id']]);
      return;
    } on DioException catch (error) {
      if (error.response?.statusCode != 404) rethrow;
    }
    await db.delete('v2_mobile_outbox',
        where: 'scope=? AND id=?', whereArgs: [scope, row['id']]);
  }
}
