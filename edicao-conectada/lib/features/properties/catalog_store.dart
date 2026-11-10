import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import '../auth/auth_service.dart';
import '../auth/user_model.dart';
import '../clients/client_repository.dart';
import '../operations_v2/v2_store.dart';
import '../sync/app_database.dart';
import '../sync/farm_api_client.dart';

/// Local drafts and a durable FIFO, partitioned by server, organization and user.
/// Operators cache only server-authorized records; a draft never grants access.
class CatalogStore {
  CatalogStore(
      {required this.db,
      required this.scope,
      required this.manager,
      this.operator = false,
      this.client,
      required this.tokenExpiry,
      DateTime Function()? clock})
      : now = clock ?? DateTime.now;
  final Database db;
  final String scope;
  final bool manager;
  final bool operator;
  bool get canCreate => manager || operator;
  final FarmApiClient? client;
  final DateTime tokenExpiry;
  final DateTime Function() now;
  static final Map<String, Future<void>> _syncs = {};

  static Future<void> initialize(Database db) async {
    await db.execute('''CREATE TABLE IF NOT EXISTS catalog_records (
      scope TEXT NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL,
      origin TEXT NOT NULL, state TEXT NOT NULL, expires_at TEXT,
      PRIMARY KEY(scope,kind,id))''');
    await db.execute('''CREATE TABLE IF NOT EXISTS catalog_outbox (
      seq INTEGER PRIMARY KEY AUTOINCREMENT, scope TEXT NOT NULL, id TEXT NOT NULL,
      method TEXT NOT NULL, path TEXT NOT NULL, kind TEXT NOT NULL, entity_id TEXT NOT NULL,
      payload TEXT NOT NULL, projected TEXT NOT NULL, state TEXT NOT NULL, error TEXT,
      UNIQUE(scope,id))''');
    await db.execute(
        'CREATE TABLE IF NOT EXISTS catalog_meta (scope TEXT PRIMARY KEY,message TEXT NOT NULL)');
  }

  static Future<CatalogStore> open() async {
    final user = AuthService().currentUser;
    if (user == null) {
      throw StateError('Entre no aplicativo para acessar os cadastros.');
    }
    final token = AuthService().accessToken;
    final base = await FarmApiClient.instance.baseUrl;
    final connected = user.farmId != null && token != null && base != null;
    var expiry = DateTime.fromMillisecondsSinceEpoch(0);
    if (token != null) {
      try {
        final claims = jsonDecode(utf8.decode(
            base64Url.decode(base64Url.normalize(token.split('.')[1])))) as Map;
        expiry = DateTime.fromMillisecondsSinceEpoch(
            (claims['exp'] as num).toInt() * 1000,
            isUtc: true);
      } catch (_) {
        /* No confirmed offline access without an expiring session. */
      }
    }
    final db = await appDatabase.database;
    await initialize(db);
    final store = CatalogStore(
        db: db,
        scope: jsonEncode(
            [connected ? base : 'local', user.farmId ?? 'local', user.id]),
        manager: user.role == UserRole.admin,
        operator: user.role == UserRole.operator,
        tokenExpiry: expiry,
        client: connected
            ? FarmApiClient.forSession(
                baseUrl: base, token: token, farmId: user.farmId!)
            : null);
    if (store.manager) {
      for (final existing in await ClientRepository().getAll()) {
        final id = const Uuid().v5('6ba7b811-9dad-11d1-80b4-00c04fd430c8',
            'agrogestor-v2/${user.farmId}/client/${existing.id}');
        await db.insert(
            'catalog_records',
            {
              'scope': store.scope,
              'kind': 'clients',
              'id': id,
              'payload': jsonEncode({'id': id, 'name': existing.name}),
              'origin': 'draft',
              'state': 'seed'
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    }
    return store;
  }

  Future<List<Json>> records(String kind, {bool archived = true}) async {
    final rows = await db.query('catalog_records',
        where: 'scope=? AND kind=?', whereArgs: [scope, kind]);
    final result = <Json>[];
    for (final row in rows) {
      final visible = row['origin'] == 'draft' && canCreate ||
          row['expires_at'] != null &&
              now().isBefore(tokenExpiry) &&
              now().isBefore(DateTime.parse(row['expires_at'] as String));
      if (!visible) continue;
      final data = Map<String, dynamic>.from(
          jsonDecode(row['payload'] as String) as Map);
      if (!archived && data['archived'] == 1) continue;
      data['_sync_state'] = row['state'];
      result.add(data);
    }
    result.sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
    return result;
  }

  Future<Json> workspace([String? propertyId]) async {
    final properties = await records('properties');
    final selected = propertyId == null
        ? properties
        : properties.where((p) => p['id'] == propertyId).toList();
    return {
      'administrator': manager,
      'can_create_catalog': canCreate,
      'properties': selected.where((p) => p['archived'] != 1).toList(),
      'clients': canCreate ? await records('clients') : [],
      'responsibles': canCreate ? await records('responsibles') : [],
      'crops': await records('crops'),
      'machines': (await records('machines'))
          .where((m) =>
              propertyId == null ||
              (m['property_ids'] as List? ?? []).contains(propertyId))
          .toList(),
      'plots': (await records('plots'))
          .where((p) =>
              p['archived'] != 1 &&
              (propertyId == null || p['property_id'] == propertyId))
          .toList(),
      'cycles': (await records('cycles'))
          .where(
              (c) => propertyId == null || '${c['property_id']}' == propertyId)
          .toList(),
      '_archived_count': properties.where((p) => p['archived'] == 1).length,
      '_pending': (await pending()).length,
      '_notice': await notice(),
      'generated_at': now().toUtc().toIso8601String()
    };
  }

  Future<void> invalidateServerCache() => db.delete('catalog_records',
      where: "scope=? AND origin='server'", whereArgs: [scope]);

  Future<List<Json>> pending() async => (await db.query('catalog_outbox',
          where: 'scope=?', whereArgs: [scope], orderBy: 'seq'))
      .map((r) => Map<String, dynamic>.from(r))
      .toList();

  Future<String> notice() async {
    final rows = await pending();
    final metadata =
        await db.query('catalog_meta', where: 'scope=?', whereArgs: [scope]);
    final status = metadata.isEmpty ? '' : ' ${metadata.first['message']}';
    if (rows.any((r) => r['state'] == 'conflict')) {
      return 'Há um cadastro para conferir: ${rows.firstWhere((r) => r['state'] == 'conflict')['error']}';
    }
    if (rows.isNotEmpty) {
      return '${rows.length} cadastro(s) salvo(s) no aparelho, aguardando confirmação de vaga e envio ao PC gestor.$status';
    }
    return client == null
        ? 'Dados locais deste perfil. Entre na conta do PC gestor para compartilhar.'
        : 'Cadastros salvos no aparelho. Sincronize para receber e compartilhar atualizações.$status';
  }

  Future<Json> save(String method, String path, Json body) async {
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (!manager &&
        !(operator &&
            method == 'POST' &&
            segments.isNotEmpty &&
            ['clients', 'properties', 'plots', 'machines']
                .contains(segments.first))) {
      throw StateError(
          'Este perfil não pode realizar essa alteração cadastral.');
    }
    const allowed = {
      'clients',
      'properties',
      'plots',
      'crops',
      'cycles',
      'machines'
    };
    if (!allowed.contains(segments.first) ||
        !['POST', 'PATCH'].contains(method) ||
        method == 'PATCH' &&
            !['properties', 'plots'].contains(segments.first)) {
      throw StateError('Tipo de cadastro inválido.');
    }
    final kind = segments.first;
    if (body['name'] is! String ||
        (body['name'] as String).trim().isEmpty ||
        (body['name'] as String).length > 160) {
      throw StateError('Informe um nome de até 160 caracteres.');
    }
    final id = method == 'POST' ? body['id'] as String : segments.last;
    final previous =
        (await records(kind)).where((r) => r['id'] == id).firstOrNull;
    if (method == 'PATCH' && previous == null) {
      throw StateError('Atualize o cadastro antes de editar.');
    }
    if (kind == 'properties' && method == 'POST') {
      body = {...body, 'share_with_operators': manager};
      final responsible = (await records('clients'))
          .where((c) => c['id'] == body['client_id'])
          .firstOrNull;
      if (body['client_id'] != null && responsible == null) {
        throw StateError('Cadastre ou selecione o responsável.');
      }
      if (responsible?['_sync_state'] == 'seed') {
        await save('POST', '/clients',
            {'id': responsible!['id'], 'name': responsible['name']});
      }
    }
    final projected = <String, dynamic>{...?previous, ...body, 'id': id};
    if (kind == 'properties' && body.containsKey('responsible_user_id')) {
      projected['responsible_name'] = (await records('responsibles'))
          .where((p) => p['id'] == body['responsible_user_id'])
          .firstOrNull?['name'];
    }
    projected.remove('expected_version');
    projected.remove('_sync_state');
    if (kind == 'properties' || kind == 'plots') {
      projected['archived'] = body['archived'] == true
          ? 1
          : body['archived'] == false
              ? 0
              : previous?['archived'] ?? 0;
      projected['version'] =
          method == 'PATCH' ? (body['expected_version'] as int) + 1 : 1;
      projected['notes'] ??= '';
      if (kind == 'properties') projected['location'] ??= '';
      final area =
          body['area_ha'] == null ? null : num.tryParse('${body['area_ha']}');
      if (body['area_ha'] != null &&
          (area == null || !area.isFinite || area <= 0)) {
        throw StateError('Informe uma área válida em hectares.');
      }
      if (kind == 'plots') {
        final property = (await records('properties'))
            .where((p) => p['id'] == projected['property_id'])
            .firstOrNull;
        if (property == null ||
            property['archived'] == 1 && projected['archived'] != 1) {
          throw StateError(
              'A propriedade não está disponível para este talhão.');
        }
      }
    }
    if (kind == 'cycles') {
      final plot = (await records('plots'))
          .where((p) => p['id'] == body['plot_id'] && p['archived'] != 1)
          .firstOrNull;
      if (plot == null) {
        throw StateError('Selecione um talhão ativo deste aparelho.');
      }
      projected['property_id'] = plot['property_id'];
      final crop = (await records('crops'))
          .where((c) => c['id'] == body['crop_id'])
          .firstOrNull;
      if (crop == null) throw StateError('Cadastre a cultura primeiro.');
      projected['crop_name'] = crop['name'];
    }
    final requestId = body['id'] as String;
    await db.transaction((tx) async {
      final old = await tx.query('catalog_outbox',
          where: 'scope=? AND id=?', whereArgs: [scope, requestId]);
      if (old.isNotEmpty) {
        if (old.first['payload'] != jsonEncode(body)) {
          throw StateError('O identificador já possui outros dados.');
        }
        return;
      }
      // Re-check local version inside the same transaction to avoid lost edits.
      final current = await tx.query('catalog_records',
          where: 'scope=? AND kind=? AND id=?', whereArgs: [scope, kind, id]);
      if (method == 'PATCH' &&
          (current.isEmpty ||
              (jsonDecode(current.first['payload'] as String)
                      as Map)['version'] !=
                  body['expected_version'])) {
        throw StateError(
            'O cadastro mudou neste aparelho. Atualize antes de salvar.');
      }
      if (method == 'POST' &&
          current.isNotEmpty &&
          current.first['state'] != 'seed') {
        throw StateError('Este cadastro já existe.');
      }
      if (kind == 'properties' && method == 'POST') {
        final children = items(body, 'plots');
        if (children.map((p) => p['id']).toSet().length != children.length) {
          throw StateError(
              'Os talhões precisam ter identificadores diferentes.');
        }
        for (final child in children) {
          if ('${child['name'] ?? ''}'.trim().isEmpty) {
            throw StateError('Informe o nome de cada talhão.');
          }
          await tx.insert('catalog_records', {
            'scope': scope,
            'kind': 'plots',
            'id': child['id'],
            'payload': jsonEncode(
                {...child, 'property_id': id, 'archived': 0, 'version': 1}),
            'origin': 'draft',
            'state': 'pending'
          });
        }
      }
      await _validateAreas(tx, kind, id, projected);
      await tx.insert('catalog_outbox', {
        'scope': scope,
        'id': requestId,
        'method': method,
        'path': path,
        'kind': kind,
        'entity_id': id,
        'payload': jsonEncode(body),
        'projected': jsonEncode(projected),
        'state': 'pending'
      });
      await tx.insert(
          'catalog_records',
          {
            'scope': scope,
            'kind': kind,
            'id': id,
            'payload': jsonEncode(projected),
            'origin': current.isEmpty ? 'draft' : current.first['origin'],
            'expires_at': current.isEmpty ? null : current.first['expires_at'],
            'state': 'pending'
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
    return projected;
  }

  Future<void> retryReviewedDrafts() async {
    await db.transaction((tx) async {
      await tx.update('catalog_outbox', {'state': 'pending', 'error': null},
          where: "scope=? AND state='conflict'", whereArgs: [scope]);
      await tx.update('catalog_records', {'state': 'pending'},
          where: "scope=? AND state='conflict'", whereArgs: [scope]);
    });
  }

  Future<void> sync({bool writeAllowed = true}) =>
      _syncs[scope] ??= _drain(writeAllowed).whenComplete(() {
        _syncs.remove(scope);
      });
  Future<void> _drain(bool writeAllowed) async {
    if (client == null) return;
    try {
      final caps = await client!.v2('GET', '/capabilities');
      if (caps['offlineCatalog'] != true) {
        await db.insert(
            'catalog_meta',
            {
              'scope': scope,
              'message': 'Atualize o PC gestor para receber estes cadastros.'
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        return;
      }
      if (writeAllowed) {
        for (final row in await pending()) {
          if (row['state'] == 'conflict') break;
          try {
            final response = await client!.v2(
                row['method'] as String, row['path'] as String,
                data: jsonDecode(row['payload'] as String));
            await db.transaction((tx) async {
              await tx.delete('catalog_outbox',
                  where: 'scope=? AND id=?', whereArgs: [scope, row['id']]);
              if (row['kind'] == 'properties' && row['method'] == 'POST') {
                final payload = jsonDecode(row['payload'] as String) as Json;
                for (final child in items(payload, 'plots')) {
                  final edits = await tx.query('catalog_outbox',
                      where: 'scope=? AND kind=? AND entity_id=?',
                      whereArgs: [scope, 'plots', child['id']],
                      orderBy: 'seq DESC',
                      limit: 1);
                  await tx.update(
                      'catalog_records',
                      {
                        'state':
                            edits.isEmpty ? 'synced' : edits.first['state'],
                        'origin': 'server',
                        'expires_at': tokenExpiry.toUtc().toIso8601String()
                      },
                      where: 'scope=? AND kind=? AND id=?',
                      whereArgs: [scope, 'plots', child['id']]);
                }
              }
              final remaining = await tx.query('catalog_outbox',
                  where: 'scope=? AND kind=? AND entity_id=?',
                  whereArgs: [scope, row['kind'], row['entity_id']],
                  orderBy: 'seq DESC',
                  limit: 1);
              final lease = now().add(const Duration(hours: 8));
              await tx.insert(
                  'catalog_records',
                  {
                    'scope': scope,
                    'kind': row['kind'],
                    'id': row['entity_id'],
                    'payload': remaining.isEmpty
                        ? jsonEncode({
                            ...response,
                            if (row['kind'] == 'machines')
                              'property_ids':
                                  (jsonDecode(row['payload'] as String)
                                      as Map)['property_ids']
                          })
                        : remaining.first['projected'],
                    'origin': 'server',
                    'state':
                        remaining.isEmpty ? 'synced' : remaining.first['state'],
                    'expires_at':
                        (lease.isBefore(tokenExpiry) ? lease : tokenExpiry)
                            .toUtc()
                            .toIso8601String()
                  },
                  conflictAlgorithm: ConflictAlgorithm.replace);
            });
          } on DioException catch (error) {
            final conflict =
                [403, 404, 409, 422].contains(error.response?.statusCode);
            await db.update(
                'catalog_outbox',
                {
                  'state': conflict ? 'conflict' : 'pending',
                  'error': v2Error(error)
                },
                where: 'scope=? AND id=?',
                whereArgs: [scope, row['id']]);
            if (conflict) {
              await db.update('catalog_records', {'state': 'conflict'},
                  where: 'scope=? AND kind=? AND id=?',
                  whereArgs: [scope, row['kind'], row['entity_id']]);
            }
            break;
          }
        }
      }
      await pull();
      await db.delete('catalog_meta', where: 'scope=?', whereArgs: [scope]);
    } on DioException catch (error) {
      await db.insert(
          'catalog_meta', {'scope': scope, 'message': v2Error(error)},
          conflictAlgorithm: ConflictAlgorithm.replace);
      if ([401, 403].contains(error.response?.statusCode)) {
        await db.delete('catalog_records',
            where: "scope=? AND origin='server'", whereArgs: [scope]);
      }
      // Unsupported server or unavailable network leaves drafts/queue intact.
    }
  }

  Future<void> _validateAreas(
      Transaction tx, String kind, String id, Json projected) async {
    if (!['properties', 'plots'].contains(kind)) return;
    BigInt? units(Object? value) {
      if (value == null) return null;
      final raw = '$value';
      if (!RegExp(r'^\d{1,12}(\.\d{1,6})?$').hasMatch(raw)) {
        throw StateError('Use área com até 6 casas decimais.');
      }
      final parts = raw.split('.');
      final amount = BigInt.parse(parts[0]) * BigInt.from(1000000) +
          BigInt.parse(parts.length == 1 ? '0' : parts[1].padRight(6, '0'));
      if (amount <= BigInt.zero) {
        throw StateError('Informe uma área maior que zero.');
      }
      return amount;
    }

    final propertyId = kind == 'properties' ? id : projected['property_id'];
    final propRows = await tx.query('catalog_records',
        where: "scope=? AND kind='properties' AND id=?",
        whereArgs: [scope, propertyId]);
    final prop = kind == 'properties'
        ? projected
        : propRows.isEmpty
            ? null
            : jsonDecode(propRows.first['payload'] as String) as Map;
    if (prop == null) {
      throw StateError('Propriedade não encontrada neste aparelho.');
    }
    final plots = await tx.query('catalog_records',
        where: "scope=? AND kind='plots'", whereArgs: [scope]);
    var sum = BigInt.zero;
    for (final row in plots) {
      final p = jsonDecode(row['payload'] as String) as Map;
      if (p['property_id'] == propertyId &&
          p['archived'] != 1 &&
          (kind == 'properties' || p['id'] != id)) {
        sum += units(p['area_ha']) ?? BigInt.zero;
      }
    }
    if (kind == 'plots' && projected['archived'] != 1) {
      sum += units(projected['area_ha']) ?? BigInt.zero;
    }
    final maximum = units(prop['area_ha']);
    if (maximum != null && sum > maximum) {
      throw StateError('A soma das áreas dos talhões excede a propriedade.');
    }
  }

  Future<void> pull() async {
    if (client == null) return;
    await V2Store.initialize(db);
    try {
      final features = await client!.get('/licensing/features');
      if (features.containsKey('farm_id')) {
        final org = (jsonDecode(scope) as List)[1];
        if (features['farm_id'] != org) {
          throw StateError('Organização da contratação inválida.');
        }
        await V2Store(
                db: db,
                client: client!,
                scope: scope,
                tokenExpiry: tokenExpiry,
                clock: now)
            .cache('commercial-features', features);
      }
    } on DioException catch (error) {
      if (![404, 503].contains(error.response?.statusCode)) rethrow;
    }
    final root = await client!.v2('GET', '/workspace');
    final receivedProperties = items(
        await client!
            .v2('GET', '/properties', query: {'include_archived': true}),
        'items');
    final permissions = {
      for (final p in items(root, 'properties')) p['id']: p['access_role']
    };
    final properties = receivedProperties
        .map((p) => {
              ...p,
              if (permissions[p['id']] != null)
                'access_role': permissions[p['id']],
            })
        .toList();
    final all = <String, List<Json>>{
      'properties': properties,
      'clients': items(root, 'clients'),
      'responsibles': canCreate ? items(root, 'responsibles') : [],
      'crops': items(root, 'crops'),
      'plots': [],
      'cycles': [],
      'machines': []
    };
    for (final property in properties) {
      all['machines']!.addAll(items(
          await client!.v2('GET', '/properties/${property['id']}/machines'),
          'items'));
      all['plots']!.addAll(items(
          await client!.v2('GET', '/properties/${property['id']}/plots',
              query: {'include_archived': true}),
          'items'));
      final cycles = items(
          await client!.v2('GET', '/properties/${property['id']}/cycles'),
          'items');
      all['cycles']!
          .addAll(cycles.map((c) => {...c, 'property_id': property['id']}));
    }
    final lease = now().add(const Duration(hours: 8));
    final expiry = (lease.isBefore(tokenExpiry) ? lease : tokenExpiry)
        .toUtc()
        .toIso8601String();
    await db.transaction((tx) async {
      // Permission revocation removes confirmed cache, while preserving unsent drafts.
      final existingServer = await tx.query('catalog_records',
          where: "scope=? AND origin='server'", whereArgs: [scope]);
      for (final row in existingServer) {
        final authorized =
            all[row['kind']]?.any((v) => v['id'] == row['id']) ?? false;
        if (!authorized || row['state'] == 'synced') {
          await tx.delete('catalog_records',
              where: 'scope=? AND kind=? AND id=?',
              whereArgs: [scope, row['kind'], row['id']]);
        } else {
          await tx.update('catalog_records', {'expires_at': expiry},
              where: 'scope=? AND kind=? AND id=?',
              whereArgs: [scope, row['kind'], row['id']]);
        }
      }
      for (final entry in all.entries) {
        for (final value in entry.value) {
          final existing = await tx.query('catalog_records',
              where: 'scope=? AND kind=? AND id=?',
              whereArgs: [scope, entry.key, value['id']]);
          if (existing.isNotEmpty &&
              ['pending', 'conflict'].contains(existing.first['state'])) {
            continue;
          }
          await tx.insert(
              'catalog_records',
              {
                'scope': scope,
                'kind': entry.key,
                'id': value['id'],
                'payload': jsonEncode(value),
                'origin': 'server',
                'state': 'synced',
                'expires_at': expiry
              },
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });
  }
}
