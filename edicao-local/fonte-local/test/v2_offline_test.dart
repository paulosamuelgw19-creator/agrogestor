import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:agrogestao/features/operations_v2/v2_store.dart';
import 'package:agrogestao/features/sync/farm_api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late Directory folder;
  late HttpServer server;
  late V2Store store;
  late String url;
  late DateTime time;
  late int status, uploads;
  late bool committed;
  late Json snapshot;
  Json operation(String id) => {
        'id': id,
        'cycle_id': 'cycle-a',
        'kind': 'management',
        'performed_on': '2026-10-14',
        'machines': [],
        'inputs': []
      };
  V2Store other(String scope) => V2Store(
      db: db,
      client: FarmApiClient.forSession(
          baseUrl: url, token: 'test', farmId: 'farm-a'),
      scope: scope,
      tokenExpiry: time.add(const Duration(days: 1)),
      clock: () => time);
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    HttpOverrides.global = null;
    folder = await Directory.systemTemp.createTemp('agro-v2-offline-');
    db = await databaseFactoryFfi.openDatabase('${folder.path}/test.sqlite');
    await V2Store.initialize(db);
    time = DateTime.utc(2026, 10, 14, 12);
    status = 200;
    uploads = 0;
    committed = false;
    snapshot = {
      'properties': [
        {'id': 'property-a', 'access_role': 'employee'}
      ],
      'cycles': [
        {'id': 'cycle-a'}
      ],
      'generated_at': time.toIso8601String()
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path.endsWith('/workspace')) {
        request.response.statusCode =
            status == 401 || status == 403 ? status : 200;
        request.response.write(jsonEncode(request.response.statusCode == 200
            ? snapshot
            : {'detail': 'Acesso revogado'}));
      } else if (request.method == 'POST') {
        await utf8.decoder.bind(request).join();
        uploads++;
        request.response.statusCode = status;
        request.response.write(jsonEncode(status == 200
            ? {'confirmed': true}
            : {'detail': 'Saldo mudou; confira o estoque.'}));
      } else {
        request.response.statusCode = committed ? 200 : 404;
        request.response.write('{}');
      }
      await request.response.close();
    });
    store = other('server/farm-a/user-a');
    await store.refresh('property-a');
  });
  test(
      'dois envios simultâneos da mesma tarefa não duplicam realizado ou abastecimento',
      () async {
    final first = {
      ...operation('first'),
      'task_id': 'task-a',
      'task_expected_version': 1,
      'refuelings': [
        {'id': 'fuel-first', 'source': 'external', 'liters': '10'}
      ]
    };
    final second = {...first, 'id': 'second'};
    final attempts = await Future.wait([
      store
          .queueOperation('property-a', first)
          .then((_) => true, onError: (_) => false),
      store
          .queueOperation('property-a', second)
          .then((_) => true, onError: (_) => false)
    ]);
    expect(attempts.where((accepted) => accepted), hasLength(1));
    expect(await store.pending(), hasLength(1));
    expect(uploads, 0);
  });
  tearDown(() async {
    await server.close(force: true);
    await db.close();
    await folder.delete(recursive: true);
  });

  test('fila persiste em SQLite e mantém um único UUID por operação', () async {
    await store.queueOperation('property-a', operation('one'));
    await store.queueOperation('property-a', operation('one'));
    expect((await store.pending()).length, 1);
    await db.close();
    db = await databaseFactoryFfi.openDatabase('${folder.path}/test.sqlite');
    store = other('server/farm-a/user-a');
    expect((await store.pending()).single['id'], 'one');
    await store.sync();
    expect(await store.pending(), isEmpty);
    expect(uploads, 1);
  });
  test('contas, organizações e servidores não compartilham cache ou fila',
      () async {
    await store.queueOperation('property-a', operation('one'));
    for (final key in [
      'server/farm-a/user-b',
      'server/farm-b/user-a',
      'other-server/farm-a/user-a'
    ]) {
      final isolated = other(key);
      expect(await isolated.cached('property-a'), isNull);
      expect(await isolated.pending(), isEmpty);
    }
  });
  test('reenvio alterado nunca sobrescreve o lançamento salvo', () async {
    await store.queueOperation('property-a', operation('one'));
    await expectLater(
        store.queueOperation(
            'property-a', {...operation('one'), 'notes': 'alterado'}),
        throwsStateError);
  });
  test('conflito bloqueia próximos consumos da propriedade até conferência',
      () async {
    await store.queueOperation('property-a', operation('one'));
    time = time.add(const Duration(seconds: 1));
    await store.queueOperation('property-a', operation('two'));
    status = 409;
    await store.sync();
    expect(uploads, 1);
    final rows = await store.pending();
    expect(rows.first['state'], 'conflict');
    expect(rows.last['state'], 'pending');
    status = 200;
    await store.retry('one');
    expect(await store.pending(), isEmpty);
    expect(uploads, 3);
  });
  test('revogação online limpa cache e conserva o lançamento para conferência',
      () async {
    await store.queueOperation('property-a', operation('one'));
    status = 403;
    await store.sync();
    expect(await store.cached('property-a'), isNull);
    expect((await store.pending()).single['state'], 'conflict');
    expect(uploads, 0);
  });
  test('acesso offline vence em oito horas e não renova sem servidor',
      () async {
    time = time.add(const Duration(hours: 8));
    expect(await store.cached('property-a'), isNull);
    await expectLater(
        store.queueOperation('property-a', operation('one')), throwsStateError);
  });
  test('consulta ao servidor antes de retirar pedido evita perder confirmação',
      () async {
    await store.queueOperation('property-a', operation('one'));
    committed = true;
    await store.discardUnconfirmed((await store.pending()).single);
    expect(await store.pending(), isEmpty);
    expect(uploads, 0);
  });
  test('sincronizações simultâneas não enviam duas vezes a mesma fila',
      () async {
    await store.queueOperation('property-a', operation('one'));
    await Future.wait([store.sync(), store.sync()]);
    expect(uploads, 1);
  });
}
