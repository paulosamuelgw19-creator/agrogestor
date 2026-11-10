import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:agrogestao/features/properties/catalog_store.dart';
import 'package:agrogestao/features/operations_v2/v2_store.dart';
import 'package:agrogestao/features/sync/farm_api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late Directory folder;
  late HttpServer server;
  late DateTime time;
  late Map<String, List<Json>> remote;
  late List<String> sent;
  late int status;
  late bool supported;
  CatalogStore store(
          {String scope = 'pc/org/gestor',
          bool manager = true,
          bool connected = false}) =>
      CatalogStore(
          db: db,
          scope: scope,
          manager: manager,
          tokenExpiry: DateTime.utc(2026, 10, 15),
          clock: () => time,
          client: connected
              ? FarmApiClient.forSession(
                  baseUrl: 'http://127.0.0.1:${server.port}',
                  token: 'synthetic',
                  farmId: 'org')
              : null);
  Future<void> create(CatalogStore s) async {
    await s
        .save('POST', '/clients', {'id': 'client', 'name': 'Cliente fictício'});
    await s.save('POST', '/properties', {
      'id': 'property',
      'name': 'Fazenda fictícia',
      'client_id': 'client',
      'area_ha': '10'
    });
    await s.save('POST', '/plots', {
      'id': 'plot',
      'name': 'Talhão fictício',
      'property_id': 'property',
      'area_ha': '5'
    });
  }

  setUpAll(sqfliteFfiInit);
  setUp(() async {
    HttpOverrides.global = null;
    time = DateTime.utc(2026, 10, 14, 12);
    folder = await Directory.systemTemp.createTemp('agro-catalog-test-');
    db = await databaseFactoryFfi.openDatabase('${folder.path}/catalog.sqlite');
    await CatalogStore.initialize(db);
    remote = {
      for (final kind in ['clients', 'properties', 'plots', 'crops', 'cycles'])
        kind: []
    };
    sent = [];
    status = 200;
    supported = true;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      r.response.headers.contentType = ContentType.json;
      final parts =
          r.uri.path.split('/').where((p) => p.isNotEmpty).skip(2).toList();
      final kind = parts.first;
      Object response = {};
      if (kind == 'capabilities') {
        response = {'offlineCatalog': supported};
      } else if (r.method == 'POST' || r.method == 'PATCH') {
        final body = jsonDecode(await utf8.decoder.bind(r).join()) as Json;
        sent.add('$kind:${body['id']}');
        r.response.statusCode = status;
        if (status == 200) {
          final id = r.method == 'POST' ? body['id'] : parts.last;
          final row = {
            ...body,
            'id': id,
            'version':
                r.method == 'POST' ? 1 : (body['expected_version'] as int) + 1,
            'archived': body['archived'] == true ? 1 : 0
          };
          remote[kind]!.removeWhere((p) => p['id'] == id);
          remote[kind]!.add(row);
          response = row;
        } else {
          response = {'detail': 'O cadastro mudou; confira antes de reenviar.'};
        }
      } else if (kind == 'workspace') {
        response = {
          'clients': remote['clients'],
          'crops': remote['crops'],
          'properties': remote['properties']!
              .map((p) => {...p, 'access_role': 'employee'})
              .toList()
        };
      } else {
        final collection = parts.length == 3 ? parts.last : kind;
        response = {'items': remote[collection] ?? []};
      }
      r.response.write(jsonEncode(response));
      await r.response.close();
    });
  });
  tearDown(() async {
    await server.close(force: true);
    await db.close();
    await folder.delete(recursive: true);
  });
  test(
      'cadastro offline persiste após reabrir SQLite e envia pais antes dos filhos',
      () async {
    await create(store());
    await db.close();
    db = await databaseFactoryFfi.openDatabase('${folder.path}/catalog.sqlite');
    final s = store(connected: true);
    expect((await s.workspace())['properties'], hasLength(1));
    expect(await s.pending(), hasLength(3));
    await s.sync();
    expect(sent, ['clients:client', 'properties:property', 'plots:plot']);
    expect(await s.pending(), isEmpty);
    expect(remote['properties']!.single['share_with_operators'], isTrue);
    expect((await s.records('plots')).single['name'], 'Talhão fictício');
  });
  test(
      'edições locais consecutivas preservam versões e não são sobrescritas por ACK anterior',
      () async {
    final s = store(connected: true);
    await create(s);
    await s.save('PATCH', '/plots/plot', {
      'id': 'edit1',
      'expected_version': 1,
      'name': 'Talhão revisado',
      'area_ha': '4',
      'notes': 'Primeira edição',
      'archived': false
    });
    await s.save('PATCH', '/plots/plot', {
      'id': 'edit2',
      'expected_version': 2,
      'name': 'Talhão final',
      'area_ha': '3',
      'notes': 'Segunda edição',
      'archived': false
    });
    await s.sync();
    expect(await s.pending(), isEmpty);
    final p = (await s.records('plots')).single;
    expect(p['version'], 3);
    expect(p['name'], 'Talhão final');
    expect(sent.sublist(3), ['plots:edit1', 'plots:edit2']);
  });
  test(
      'conflito conserva fila, interrompe filhos e impede sobrescrita silenciosa',
      () async {
    final s = store(connected: true);
    await create(s);
    status = 409;
    await s.sync();
    expect(sent, ['clients:client']);
    expect(await s.pending(), hasLength(3));
    expect((await s.pending()).first['state'], 'conflict');
    expect(await s.notice(), contains('conferir'));
    await s.sync();
    expect(sent, hasLength(1));
  });
  test('PC antigo mantém rascunhos e apresenta orientação em português',
      () async {
    final s = store(connected: true);
    await create(s);
    supported = false;
    await s.sync();
    expect(sent, isEmpty);
    expect(await s.pending(), hasLength(3));
    expect(await s.notice(), contains('Atualize o PC gestor'));
  });
  test(
      'perfil sem criação não cadastra e contas distintas não recebem rascunhos',
      () async {
    await create(store());
    final other = store(scope: 'pc/org/operator', manager: false);
    expect(await other.records('properties'), isEmpty);
    expect(await other.pending(), isEmpty);
    expect(other.save('POST', '/clients', {'id': 'x', 'name': 'x'}),
        throwsStateError);
    expect(await store(scope: 'other-pc/org/gestor').records('properties'),
        isEmpty);
  });
  test('operador cria propriedade e talhão offline sem compartilhar ou editar',
      () async {
    final operator = CatalogStore(
        db: db,
        scope: 'pc/org/operator',
        manager: false,
        operator: true,
        tokenExpiry: DateTime.utc(2026, 10, 15),
        clock: () => time);
    await create(operator);
    expect(await operator.pending(), hasLength(3));
    final property = (await operator.records('properties')).single;
    expect(property['share_with_operators'], false);
    expect((await operator.workspace())['can_create_catalog'], true);
    expect((await operator.workspace())['administrator'], false);
    expect(
        await store(scope: 'pc/org/other-operator', manager: false)
            .records('properties'),
        isEmpty);
    await expectLater(
        operator.save('PATCH', '/properties/property', {
          'id': 'edit',
          'name': 'Alteração não autorizada',
          'expected_version': 1,
        }),
        throwsStateError);
    await expectLater(
        operator.save('POST', '/crops', {
          'id': 'crop',
          'name': 'Café',
          'kind': 'coffee',
        }),
        throwsStateError);
    expect(await operator.pending(), hasLength(3));
  });
  test('expiração limita cache autorizado e revogação remove dados confirmados',
      () async {
    final s = store(connected: true);
    await create(s);
    await s.sync();
    final operator = CatalogStore(
        db: db,
        scope: s.scope,
        manager: false,
        client: s.client,
        tokenExpiry: s.tokenExpiry,
        clock: () => time);
    expect(await operator.records('properties'), hasLength(1));
    expect((await operator.records('properties')).single['access_role'],
        'employee');
    time = time.add(const Duration(hours: 9));
    expect(await operator.records('properties'), isEmpty);
    time = DateTime.utc(2026, 10, 14, 12);
    remote['properties'] = [];
    remote['plots'] = [];
    await s.pull();
    expect(await s.records('properties'), isEmpty);
  });
  test('área excedente e edição desatualizada não alteram cadastro nem fila',
      () async {
    final s = store();
    await create(s);
    expect(
        s.save('POST', '/plots', {
          'id': 'excess',
          'name': 'Excedente',
          'property_id': 'property',
          'area_ha': '6'
        }),
        throwsStateError);
    expect(await s.records('plots'), hasLength(1));
    expect(await s.pending(), hasLength(3));
    expect(
        s.save('PATCH', '/plots/plot', {
          'id': 'stale',
          'expected_version': 0,
          'name': 'Errado',
          'area_ha': '5',
          'archived': false
        }),
        throwsStateError);
    expect((await s.records('plots')).single['version'], 1);
  });
  test('quota rejection keeps machine draft, stops retries and requires review',
      () async {
    final s = store(connected: true);
    remote['machines'] = [];
    await create(s);
    await s.sync();
    status = 409;
    await s.save('POST', '/machines', {
      'id': 'draft-machine',
      'name': 'Máquina sem vaga',
      'hour_meter': '0',
      'property_ids': ['property']
    });
    await s.sync();
    final count = sent.length;
    expect((await s.pending()).single['state'], 'conflict');
    expect((await s.records('machines')).single['name'], 'Máquina sem vaga');
    await s.sync();
    expect(sent.length, count);
    await s.retryReviewedDrafts();
    status = 200;
    await s.sync();
    expect(await s.pending(), isEmpty);
    expect((await s.records('machines')).single['_sync_state'], 'synced');
  });
}
