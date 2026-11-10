import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';
import '../auth/auth_service.dart';
import '../operations_v2/v2_store.dart';
import '../sync/farm_api_client.dart';

class WorkStore {
  WorkStore(this.core, {this.sessionValid});
  final V2Store core;
  final bool Function()? sessionValid;
  static final Map<String, Future<void>> _syncs = {};
  static Future<WorkStore> open() async {
    final auth = AuthService();
    final user = auth.currentUser;
    final base = await FarmApiClient.instance.baseUrl;
    final token = auth.accessToken;
    if (user?.farmId == null || base == null || token == null) {
      throw StateError(
          'Entre na conta do PC gestor para acessar tarefas e oficina.');
    }
    final core = await V2Store.open(
        baseUrl: base, farmId: user!.farmId!, userId: user.id, token: token);
    await initialize(core);
    return WorkStore(core,
        sessionValid: () =>
            auth.currentUser?.id == user.id && auth.accessToken == token);
  }

  static Future<void> initialize(V2Store core) async {
    await core.db.execute('''CREATE TABLE IF NOT EXISTS work_mobile_outbox (
      seq INTEGER PRIMARY KEY AUTOINCREMENT,scope TEXT NOT NULL,id TEXT NOT NULL,path TEXT NOT NULL,
      payload TEXT NOT NULL,files_json TEXT NOT NULL,state TEXT NOT NULL,error TEXT,created_at TEXT NOT NULL,
      UNIQUE(scope,id))''');
    await core.db.execute('''CREATE TABLE IF NOT EXISTS work_conflict_history (
      scope TEXT NOT NULL,id TEXT NOT NULL,path TEXT NOT NULL,payload TEXT NOT NULL,files_json TEXT NOT NULL,
      error TEXT,created_at TEXT NOT NULL,replacement_id TEXT NOT NULL,PRIMARY KEY(scope,id))''');
  }

  Future<List<Json>> pending() async =>
      (await core.db.query('work_mobile_outbox',
              where: 'scope=?', whereArgs: [core.scope], orderBy: 'seq'))
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
  Future<Json> refresh() async {
    try {
      final result = await core.client.v2('GET', '/work/workspace');
      await core.cache('work', result);
      return result;
    } on DioException catch (error) {
      if ([401, 403, 404].contains(error.response?.statusCode)) {
        await core.db.delete('v2_mobile_cache',
            where: 'scope=?', whereArgs: [core.scope]);
      }
      rethrow;
    }
  }

  Future<Json?> workspace() async {
    final raw = await core.cached('work');
    if (raw == null) return null;
    final result =
        Map<String, dynamic>.from(jsonDecode(jsonEncode(raw)) as Map);
    final queue = await pending();
    for (final row in queue) {
      try {
        _authorize(
            result,
            row['path'] as String,
            Map<String, dynamic>.from(
                jsonDecode(row['payload'] as String) as Map));
        if (row['state'] == 'pending') _project(result, row);
      } on StateError {
        // A revoked role/assignment never exposes previously cached drafts.
      }
    }
    final pendingTasks = {
      for (final operation in await core.pending())
        (jsonDecode(operation['payload'] as String) as Map)['task_id']
    }..remove(null);
    result['tasks'] = [
      for (final task in items(result, 'tasks'))
        {
          ...task,
          if (pendingTasks.contains(task['id'])) '_operation_pending': true
        }
    ];
    result['_pending'] = queue.length;
    result['_conflicts'] = queue.where((q) => q['state'] == 'conflict').length;
    return result;
  }

  void _authorize(Json root, String path, Json body) {
    if (path == '/admin/stock-items' && root['role'] == 'admin') return;
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length < 2 || parts.first != 'work') {
      throw StateError('Caminho inválido.');
    }
    final role = root['role'];
    final user = root['user_id'];
    if (role == 'admin') return;
    if (parts[1] == 'tasks' &&
        parts.length == 4 &&
        parts.last == 'progress' &&
        role == 'operator') {
      final task = items(root, 'tasks')
          .where((t) => t['id'] == parts[2] && t['assignee_id'] == user)
          .firstOrNull;
      if (task != null && body['status'] != 'cancelled') return;
    }
    if (parts[1] == 'orders' &&
        parts.length == 2 &&
        role == 'operator' &&
        body['mechanic_id'] == null &&
        body['due_on'] == null &&
        items(root, 'properties').any((p) => p['id'] == body['property_id'])) {
      return;
    }
    if (parts[1] == 'orders' &&
        parts.length == 4 &&
        parts.last == 'progress' &&
        role == 'mechanic') {
      if (items(root, 'orders')
              .any((o) => o['id'] == parts[2] && o['mechanic_id'] == user) &&
          body['status'] != 'cancelled') {
        return;
      }
    }
    if (parts[1] == 'checklists' &&
        parts.length == 2 &&
        ['operator', 'mechanic'].contains(role) &&
        items(root, 'machines').any((m) =>
            m['id'] == body['machine_id'] &&
            (m['property_ids'] as List).contains(body['property_id']))) {
      return;
    }
    throw StateError('Seu perfil não permite esta alteração.');
  }

  Future<void> queue(String path, Json body,
      {List<String> photoPaths = const []}) async {
    if (sessionValid?.call() == false) {
      throw StateError('Sua sessão mudou. Abra a área novamente.');
    }
    final root = await workspace();
    if (root == null) {
      throw StateError(
          'Conecte ao PC gestor para renovar o acesso offline (até 8 horas).');
    }
    _authorize(root, path, body);
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    String? conflict;
    if (parts.length == 4 && ['orders', 'tasks'].contains(parts[1])) {
      final source =
          items(root, parts[1]).where((e) => e['id'] == parts[2]).firstOrNull;
      if (source == null || source['version'] != body['expected_version']) {
        conflict =
            'O registro mudou. Seu texto foi preservado para conferência.';
      }
    }
    final files = <Map<String, String>>[];
    final folder = Directory(
        '${File(core.db.path).parent.path}/work-photos/${const Uuid().v5("6ba7b811-9dad-11d1-80b4-00c04fd430c8", core.scope)}');
    if (photoPaths.isNotEmpty) await folder.create(recursive: true);
    for (final path in photoPaths) {
      final source = File(path);
      if (!await source.exists() || await source.length() > 8 * 1024 * 1024) {
        throw StateError('Selecione uma foto disponível com até 8 MB.');
      }
      final id = const Uuid().v4();
      final target = '${folder.path}/$id.jpg';
      await source.copy(target);
      files.add({'id': id, 'path': target});
    }
    if (parts.last == 'progress' && parts[1] == 'orders') {
      body = {
        ...body,
        'photos': [for (final f in files) f['id']]
      };
    }
    final previous = await core.db.query('work_mobile_outbox',
        where: 'scope=? AND id=?', whereArgs: [core.scope, body['id']]);
    if (previous.isNotEmpty) {
      if (previous.first['payload'] != jsonEncode(body)) {
        throw StateError('Este identificador já possui outros dados.');
      }
      return;
    }
    await core.db.insert('work_mobile_outbox', {
      'scope': core.scope,
      'id': body['id'],
      'path': path,
      'payload': jsonEncode(body),
      'files_json': jsonEncode(files),
      'state': conflict == null ? 'pending' : 'conflict',
      'error': conflict,
      'created_at': core.now().toUtc().toIso8601String()
    });
  }

  Future<void> saveDraft(String path, Json body,
      {List<String> photoPaths = const []}) async {
    if (sessionValid?.call() == false) return;
    final existing = await core.db.query('work_mobile_outbox',
        where: 'scope=? AND id=?', whereArgs: [core.scope, body['id']]);
    if (existing.isNotEmpty) return;
    final files = <Map<String, String>>[];
    final folder = Directory(
        '${File(core.db.path).parent.path}/work-photos/${const Uuid().v5("6ba7b811-9dad-11d1-80b4-00c04fd430c8", core.scope)}');
    if (photoPaths.isNotEmpty) await folder.create(recursive: true);
    for (final path in photoPaths) {
      final source = File(path);
      if (!await source.exists() || await source.length() > 8 * 1024 * 1024) {
        continue;
      }
      final id = const Uuid().v4(), target = '${folder.path}/$id.jpg';
      await source.copy(target);
      files.add({'id': id, 'path': target});
    }
    if (path.contains('/orders/') && path.endsWith('/progress')) {
      body = {
        ...body,
        'photos': [for (final file in files) file['id']]
      };
    }
    await core.db.insert('work_mobile_outbox', {
      'scope': core.scope,
      'id': body['id'],
      'path': path,
      'payload': jsonEncode(body),
      'files_json': jsonEncode(files),
      'state': 'draft',
      'error': 'Rascunho salvo. Renove o acesso e confira antes de enviar.',
      'created_at': core.now().toUtc().toIso8601String()
    });
  }

  void _project(Json root, Json row) {
    final body =
        Map<String, dynamic>.from(jsonDecode(row['payload'] as String) as Map);
    final parts =
        (row['path'] as String).split('/').where((s) => s.isNotEmpty).toList();
    if (row['path'] == '/admin/stock-items') return;
    final kind = parts[1];
    final target = parts.length == 2 ? body['id'] : parts[2];
    if (!['tasks', 'orders', 'checklists'].contains(kind)) return;
    final collection = List<dynamic>.from(root[kind] as List? ?? []);
    final index = collection.indexWhere((r) => r['id'] == target);
    if (parts.length == 2) {
      final cycle = items(root, 'cycles')
          .where((c) => c['id'] == body['cycle_id'])
          .firstOrNull;
      if (kind == 'tasks' && cycle != null) {
        body.addAll({
          'property_id': cycle['property_id'],
          'plot_name': cycle['plot_name'],
          'cycle_name': cycle['name'],
          'crop_name': cycle['crop_name']
        });
      }
      final value = {
        ...body,
        'version': 1,
        'actor_id': root['user_id'],
        'created_at': row['created_at'],
        '_pending': true,
        'status': kind == 'tasks'
            ? 'assigned'
            : body['mechanic_id'] == null
                ? 'reported'
                : 'analysis',
        'machine_released': body['stop_machine'] == false ? 1 : 0,
        'progress': <Json>[],
        'reservations': <Json>[],
        'property_name': items(root, 'properties')
            .where((p) => p['id'] == body['property_id'])
            .firstOrNull?['name'],
        'machine_name': items(root, 'machines')
            .where((m) => m['id'] == body['machine_id'])
            .firstOrNull?['name']
      };
      if (index < 0) collection.add(value);
    } else if (index >= 0) {
      final old = Map<String, dynamic>.from(collection[index] as Map);
      final next = {
        ...old,
        'version': (old['version'] as int) + 1,
        '_pending': true
      };
      if (parts.last == 'assign') {
        next.addAll({
          'mechanic_id': body['mechanic_id'],
          'priority': body['priority'],
          'due_on': body['due_on'],
          if (old['status'] == 'reported') 'status': 'analysis'
        });
      }
      if (parts.last == 'progress') {
        next['status'] = body['status'];
        if (kind == 'orders') {
          next['progress'] = [
            ...items(old, 'progress'),
            {
              ...body,
              'actor_id': root['user_id'],
              'created_at': row['created_at'],
              '_pending': true,
              'local_photos': jsonDecode(row['files_json'] as String)
            }
          ];
          if (body['machine_released'] != null) {
            next['machine_released'] = body['machine_released'] == true ? 1 : 0;
          }
        }
      }
      if (parts.last == 'reserve') {
        next['reservations'] = [
          ...items(old, 'reservations')
              .where((r) => r['input_id'] != body['input_id']),
          {
            'input_id': body['input_id'],
            'quantity': body['quantity'],
            'name': items(root, 'inputs')
                .where((p) => p['id'] == body['input_id'])
                .firstOrNull?['name']
          }
        ];
      }
      collection[index] = next;
    }
    root[kind] = collection;
  }

  Future<void> sync() => _syncs[core.scope] ??= _drain().whenComplete(() {
        _syncs.remove(core.scope);
      });
  Future<void> _drain() async {
    await refresh();
    for (final row in await pending()) {
      if (sessionValid?.call() == false) return;
      if (row['state'] == 'draft') continue;
      if (row['state'] == 'conflict') break;
      try {
        final body = Map<String, dynamic>.from(
            jsonDecode(row['payload'] as String) as Map);
        final path = row['path'] as String;
        final authorized = await refresh();
        _authorize(authorized, path, body);
        final parts = path.split('/').where((s) => s.isNotEmpty).toList();
        final before = parts.last == 'progress';
        final files =
            (jsonDecode(row['files_json'] as String) as List).cast<Map>();
        final target = parts.length == 2 ? body['id'] as String : parts[2];
        final kind = parts[1] == 'checklists' ? 'checklist' : 'order';
        if (before) {
          for (final file in files) {
            await core.client.uploadWorkPhoto(
                kind, target, file['id'] as String, file['path'] as String);
          }
        }
        await core.client.v2('POST', path, data: body);
        if (!before) {
          for (final file in files) {
            await core.client.uploadWorkPhoto(
                kind, target, file['id'] as String, file['path'] as String);
          }
        }
        await core.db.delete('work_mobile_outbox',
            where: 'scope=? AND id=?', whereArgs: [core.scope, row['id']]);
        for (final photo in files) {
          final local = File(photo['path'] as String);
          if (await local.exists()) await local.delete();
        }
      } on StateError catch (error) {
        await core.db.update('work_mobile_outbox',
            {'state': 'conflict', 'error': v2Error(error)},
            where: 'scope=? AND id=?', whereArgs: [core.scope, row['id']]);
        break;
      } on DioException catch (error) {
        final permanent =
            [403, 404, 409, 422].contains(error.response?.statusCode);
        await core.db.update(
            'work_mobile_outbox',
            {
              'state': permanent ? 'conflict' : 'pending',
              'error': v2Error(error)
            },
            where: 'scope=? AND id=?',
            whereArgs: [core.scope, row['id']]);
        if (!permanent) rethrow;
        break;
      }
    }
    await refresh();
  }

  Future<void> retry(String id) async {
    await core.db.update(
        'work_mobile_outbox', {'state': 'pending', 'error': null},
        where: 'scope=? AND id=?', whereArgs: [core.scope, id]);
    await sync();
  }

  Future<void> resubmit(Json row) async {
    if (sessionValid?.call() == false) {
      throw StateError('Sua sessão mudou. Abra a área novamente.');
    }
    final current = await refresh();
    final path = row['path'] as String;
    final body =
        Map<String, dynamic>.from(jsonDecode(row['payload'] as String) as Map);
    _authorize(current, path, body);
    try {
      await core.client.v2('GET', '/work/receipts/${row['id']}');
      await core.db.delete('work_mobile_outbox',
          where: 'scope=? AND id=?', whereArgs: [core.scope, row['id']]);
      await refresh();
      return;
    } on DioException catch (error) {
      if (error.response?.statusCode != 404) rethrow;
    }
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    if (parts.length != 2 &&
        (parts.length != 4 || body['expected_version'] == null)) {
      throw StateError(
          'Este cadastro precisa ser conferido pelo gestor antes de reenviar.');
    }
    final target = parts.length == 4
        ? items(current, parts[1]).where((r) => r['id'] == parts[2]).firstOrNull
        : null;
    if (parts.length == 4 && target == null) {
      throw StateError(
          'Este registro não está mais disponível para esta conta.');
    }
    final replacement = const Uuid().v4();
    final rebased = {
      ...body,
      'id': replacement,
      if (target != null) 'expected_version': target['version']
    };
    await core.db.transaction((tx) async {
      final old = await tx.query('work_mobile_outbox',
          where: 'scope=? AND id=?', whereArgs: [core.scope, row['id']]);
      if (old.isEmpty || old.first['payload'] != row['payload']) {
        throw StateError('A fila mudou. Atualize antes de conferir.');
      }
      await tx.insert('work_conflict_history', {
        'scope': core.scope,
        'id': row['id'],
        'path': path,
        'payload': row['payload'],
        'files_json': row['files_json'],
        'error': row['error'],
        'created_at': row['created_at'],
        'replacement_id': replacement
      });
      await tx.update(
          'work_mobile_outbox',
          {
            'id': replacement,
            'payload': jsonEncode(rebased),
            'state': 'pending',
            'error': null
          },
          where: 'scope=? AND id=?',
          whereArgs: [core.scope, row['id']]);
    });
    await sync();
  }

  Future<void> validateForReview(Json row) async {
    final current = await refresh();
    _authorize(current, row['path'] as String,
        Map<String, dynamic>.from(jsonDecode(row['payload'] as String) as Map));
  }
}
