import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:agrogestao/features/work/work_store.dart';
import 'package:agrogestao/features/operations_v2/v2_store.dart';
import 'package:agrogestao/features/sync/farm_api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late Directory folder;
  late HttpServer server;
  late DateTime time;
  late Json root;
  late WorkStore store;
  late int status, posts;
  late Map<String, Json> accepted;
  WorkStore scoped(String scope) => WorkStore(V2Store(
      db: db,
      scope: scope,
      client: FarmApiClient.forSession(
          baseUrl: 'http://127.0.0.1:${server.port}',
          token: 'synthetic',
          farmId: 'org-a'),
      tokenExpiry: DateTime.utc(2026, 10, 15),
      clock: () => time));
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    HttpOverrides.global = null;
    time = DateTime.utc(2026, 10, 14, 12);
    status = 200;
    posts = 0;
    accepted = {};
    folder = await Directory.systemTemp.createTemp('agro-work-offline-');
    db = await databaseFactoryFfi.openDatabase('${folder.path}/offline.sqlite');
    await V2Store.initialize(db);
    await WorkStore.initialize(scopedBeforeServer(db));
    root = {
      'role': 'mechanic',
      'user_id': 'mechanic-a',
      'properties': [],
      'cycles': [],
      'tasks': [],
      'orders': [
        {
          'id': 'order-a',
          'mechanic_id': 'mechanic-a',
          'property_id': 'property-a',
          'machine_id': 'machine-a',
          'title': 'Ordem fictícia',
          'status': 'analysis',
          'version': 1,
          'progress': []
        }
      ],
      'machines': [
        {
          'id': 'machine-a',
          'name': 'Trator fictício',
          'property_ids': ['property-a']
        }
      ],
      'inputs': [],
      'stock': [],
      'checklists': [],
      'alerts': []
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      r.response.headers.contentType = ContentType.json;
      if (r.method == 'GET') {
        if (r.uri.path.contains('/receipts/')) {
          final exists = accepted.containsKey(r.uri.pathSegments.last);
          r.response.statusCode = exists ? 200 : 404;
          r.response.write(jsonEncode({'confirmed': exists}));
        } else {
          r.response.write(jsonEncode(root));
        }
      } else {
        final body = jsonDecode(await utf8.decoder.bind(r).join()) as Json;
        posts++;
        r.response.statusCode = status;
        if (status == 200) {
          final prior = accepted[body['id']];
          if (prior == null) {
            if (r.uri.path.contains('/orders/') &&
                r.uri.path.endsWith('/progress')) {
              final order = (root['orders'] as List).single as Json;
              if (order['version'] != body['expected_version']) {
                r.response.statusCode = 409;
              } else {
                order['version'] = (order['version'] as int) + 1;
                order['status'] = body['status'];
                (order['progress'] as List).add(body);
              }
            } else if (r.uri.path.endsWith('/checklists')) {
              (root['checklists'] as List).add(body);
            }
          }
          if (r.response.statusCode == 200) {
            accepted[body['id'] as String] = body;
          }
          r.response.write(jsonEncode(r.response.statusCode == 200
              ? {'saved': true}
              : {'detail': 'Versão alterada'}));
        } else {
          r.response
              .write(jsonEncode({'detail': 'Atualize e confira o andamento.'}));
        }
      }
      await r.response.close();
    });
    store = scoped('pc/org-a/mechanic-a');
    await store.refresh();
  });
  tearDown(() async {
    await server.close(force: true);
    await db.close();
    await folder.delete(recursive: true);
  });
  Json event(String id, int version, String description) => {
        'id': id,
        'expected_version': version,
        'description': description,
        'status': 'in_progress'
      };
  test(
      'diário e versões permanecem salvos após reabrir, sem contato com servidor',
      () async {
    await store.queue('/work/orders/order-a/progress',
        event('note-1', 1, 'Desmontagem iniciada'));
    await store.queue('/work/orders/order-a/progress',
        event('note-2', 2, 'Peça identificada'));
    expect(posts, 0);
    expect(items((await store.workspace())!, 'orders').single['progress'],
        hasLength(2));
    await db.close();
    db = await databaseFactoryFfi.openDatabase('${folder.path}/offline.sqlite');
    store = scoped('pc/org-a/mechanic-a');
    expect(await store.pending(), hasLength(2));
    await store.sync();
    expect(await store.pending(), isEmpty);
    expect(posts, 2);
    expect(items((await store.workspace())!, 'orders').single['version'], 3);
    expect((root['orders'] as List).single['progress'], hasLength(2));
  });
  test('conflito preserva texto e interrompe a fila para não apagar alterações',
      () async {
    await store.queue(
        '/work/orders/order-a/progress', event('note-1', 1, 'Aguardando peça'));
    await store.queue('/work/orders/order-a/progress',
        event('note-2', 2, 'Conferência posterior'));
    status = 409;
    await store.sync();
    expect(posts, 1);
    expect((await store.pending()).first['state'], 'conflict');
    expect(
        jsonDecode(
            (await store.pending()).first['payload'] as String)['description'],
        'Aguardando peça');
    await store.sync();
    expect(posts, 1);
    expect(await store.pending(), hasLength(2));
  });
  test(
      'contas diferentes não veem dados, e operador não escreve diário de mecânico',
      () async {
    await store.queue(
        '/work/orders/order-a/progress', event('note-1', 1, 'Nota privada'));
    expect(await scoped('pc/org-b/mechanic-a').workspace(), isNull);
    expect(await scoped('pc/org-a/other-mechanic').pending(), isEmpty);
    root['role'] = 'operator';
    root['user_id'] = 'operator-a';
    await store.refresh();
    expect(
        store.queue(
            '/work/orders/order-a/progress', event('note-2', 2, 'Proibida')),
        throwsStateError);
    expect(items((await store.workspace())!, 'orders').single['progress'],
        isEmpty);
  });
  test(
      'revogação de atribuição esconde diário pendente e cache vencido não autoriza escrita',
      () async {
    await store.queue(
        '/work/orders/order-a/progress', event('note-1', 1, 'Minha nota'));
    root['orders'] = [];
    root['machines'] = [];
    await store.refresh();
    expect(items((await store.workspace())!, 'orders'), isEmpty);
    expect(await store.pending(), hasLength(1));
    time = time.add(const Duration(hours: 9));
    expect(await store.workspace(), isNull);
    expect(store.queue('/work/checklists', {'id': 'check'}), throwsStateError);
  });
  test('foto é copiada para armazenamento persistente antes de entrar na fila',
      () async {
    final source = File('${folder.path}/camera.jpg');
    await source.writeAsBytes([255, 216, 255, 1, 2, 3]);
    await store.queue('/work/orders/order-a/progress',
        event('note-1', 1, 'Foto do andamento'),
        photoPaths: [source.path]);
    final row = (await store.pending()).single;
    final files = jsonDecode(row['files_json'] as String) as List;
    final persisted = File(files.single['path'] as String);
    expect(persisted.path, isNot(source.path));
    await source.delete();
    expect(await persisted.exists(), isTrue);
    final body = jsonDecode(row['payload'] as String) as Map;
    expect(body['photos'], [files.single['id']]);
  });
  test('edição desatualizada preserva texto sem alterar situação confirmada',
      () async {
    await store.queue(
        '/work/orders/order-a/progress', event('note-1', 1, 'Primeira'));
    await store.queue(
        '/work/orders/order-a/progress', event('note-2', 1, 'Desatualizada'));
    expect(await store.pending(), hasLength(2));
    expect((await store.pending()).last['state'], 'conflict');
    expect(items((await store.workspace())!, 'orders').single['version'], 2);
    await store.sync();
    expect(posts, 1);
    expect((await store.pending()).single['state'], 'conflict');
  });
  test('conferência reenvia texto com versão atual e mantém pedido original',
      () async {
    await store.queue(
        '/work/orders/order-a/progress', event('note-1', 1, 'Minha nota'));
    (root['orders'] as List).single['version'] = 2;
    await store.sync();
    expect((await store.pending()).single['state'], 'conflict');
    await store.resubmit((await store.pending()).single);
    expect(await store.pending(), isEmpty);
    expect((root['orders'] as List).single['progress'], hasLength(1));
    expect(await db.query('work_conflict_history'), hasLength(1));
  });
  test('confirmação perdida é reconhecida sem duplicar serviço', () async {
    await store.queue(
        '/work/orders/order-a/progress', event('note-1', 1, 'Já salva'));
    accepted['note-1'] = event('note-1', 1, 'Já salva');
    await store.resubmit((await store.pending()).single);
    expect(await store.pending(), isEmpty);
    expect(posts, 0);
  });
  test(
      'finalização pendente é exibida na tarefa sem alterar o retrato confirmado',
      () async {
    root['role'] = 'operator';
    root['user_id'] = 'worker';
    root['tasks'] = [
      {
        'id': 'task-a',
        'assignee_id': 'worker',
        'status': 'assigned',
        'version': 1
      }
    ];
    await store.refresh();
    await db.insert('v2_mobile_outbox', {
      'scope': store.core.scope,
      'id': 'operation-a',
      'property_id': 'property-a',
      'payload': jsonEncode({'id': 'operation-a', 'task_id': 'task-a'}),
      'state': 'pending',
      'created_at': time.toIso8601String(),
    });
    final shown = items((await store.workspace())!, 'tasks').single;
    expect(shown['_operation_pending'], isTrue);
    expect(shown['status'], 'assigned');
    expect(
        items((await store.core.cached('work'))!, 'tasks')
            .single
            .containsKey('_operation_pending'),
        isFalse);
    await db.delete('v2_mobile_outbox',
        where: 'scope=?', whereArgs: [store.core.scope]);
    expect(
        items((await store.workspace())!, 'tasks')
            .single
            .containsKey('_operation_pending'),
        isFalse);
    expect(posts, 0);
  });
  test('rascunho com acesso vencido não é enviado sem conferência', () async {
    time = time.add(const Duration(hours: 9));
    await store.saveDraft('/work/orders/order-a/progress',
        event('draft-1', 1, 'Texto preservado'));
    expect((await store.pending()).single['state'], 'draft');
    await store.sync();
    expect(posts, 0);
    await store.resubmit((await store.pending()).single);
    expect(posts, 1);
    expect(await store.pending(), isEmpty);
  });
}

V2Store scopedBeforeServer(Database db) => V2Store(
    db: db,
    scope: 'initialize-only',
    client: FarmApiClient.forSession(
        baseUrl: 'http://127.0.0.1:1', token: 'synthetic', farmId: 'org-a'),
    tokenExpiry: DateTime.utc(2026, 10, 15));
