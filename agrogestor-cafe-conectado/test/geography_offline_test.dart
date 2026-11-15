import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:agrogestao/features/machines/catalog_photos.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:agrogestao/features/operations_v2/v2_store.dart';
import 'package:agrogestao/features/properties/geography_store.dart';
import 'package:agrogestao/features/sync/farm_api_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  late Database db;
  late Directory folder;
  late HttpServer server;
  late GeographyStore store;
  late DateTime time;
  late int posts, status;
  late Json snapshot;
  GeographyStore scoped(String scope) => GeographyStore(V2Store(
      db: db,
      client: FarmApiClient.forSession(
          baseUrl: 'http://127.0.0.1:${server.port}',
          token: 'synthetic',
          farmId: 'org-a'),
      scope: scope,
      tokenExpiry: DateTime.utc(2030),
      clock: () => time));
  Json drawing(String id) => {
        'id': id,
        'expected_version': 0,
        'points': [
          [-46, -21],
          [-45.99, -21],
          [-45.99, -20.99]
        ],
        'reason': 'Teste',
        'color': '#26734D',
        'deleted': false
      };
  setUp(() async {
    HttpOverrides.global = null;
    time = DateTime.utc(2026, 10, 16);
    posts = 0;
    status = 200;
    folder = await Directory.systemTemp.createTemp('agro-geography-');
    db = await databaseFactoryFfi.openDatabase('${folder.path}/test.sqlite');
    await V2Store.initialize(db);
    snapshot = {
      'property': {'id': 'property-a', 'name': 'Teste'},
      'plots': [
        {'id': 'plot-a'}
      ],
      'boundaries': [],
      'can_edit': true,
      'administrator': true
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'GET') {
        request.response.statusCode = status == 403 ? 403 : 200;
        request.response.write(
            jsonEncode(status == 403 ? {'detail': 'Revogado'} : snapshot));
      } else {
        posts++;
        await request.drain<void>();
        request.response.statusCode = status;
        request.response.write(jsonEncode(status == 200
            ? {'confirmed': true}
            : {'detail': 'A demarcação mudou.'}));
      }
      await request.response.close();
    });
    store = scoped('server/org-a/gestor');
    await GeographyStore.initialize(store.core);
    await store.refresh('property-a');
  });
  tearDown(() async {
    await server.close(force: true);
    await db.close();
    await folder.delete(recursive: true);
  });
  test('desenho sobrevive ao fechamento e permanece isolado por conta',
      () async {
    await store.save('property-a', 'plot', 'plot-a', drawing('first'));
    await db.close();
    db = await databaseFactoryFfi.openDatabase('${folder.path}/test.sqlite');
    store = scoped('server/org-a/gestor');
    expect(await store.pending(), hasLength(1));
    expect(await scoped('server/org-a/outro').pending(), isEmpty);
    expect(
        jsonDecode(
            (await store.pending()).single['payload'] as String)['points'],
        hasLength(3));
  });
  test('conflito preserva desenho e nova revisão mantém original auditável',
      () async {
    await store.save('property-a', 'plot', 'plot-a', drawing('first'));
    status = 409;
    await store.sync();
    final old = (await store.pending()).single;
    expect(old['state'], 'conflict');
    await store.retryReviewed(old, 2,
        revised: {...drawing('review'), 'reason': 'Conferido'});
    expect((await store.pending()).where((r) => r['state'] == 'reviewed'),
        hasLength(1));
    final next =
        (await store.pending()).where((r) => r['state'] == 'pending').single;
    expect(jsonDecode(next['payload'] as String)['expected_version'], 2);
    status = 200;
    await store.sync();
    expect((await store.pending()).where((r) => r['state'] != 'reviewed'),
        isEmpty);
    expect(posts, 2);
  });
  test('reconexão concorrente envia somente uma vez e remove só confirmação',
      () async {
    await store.save('property-a', 'plot', 'plot-a', drawing('first'));
    await Future.wait([store.sync(), store.sync()]);
    expect(posts, 1);
    expect(await store.pending(), isEmpty);
  });
  test('revogação elimina acesso ao cache e preserva a pendência', () async {
    await store.save('property-a', 'plot', 'plot-a', drawing('first'));
    status = 403;
    await store.sync();
    expect(await store.core.cached('map:property-a'), isNull);
    expect((await store.pending()).single['state'], 'conflict');
    expect(posts, 0);
  });
  test('sem acesso confirmado ou com lease vencida não cria demarcação',
      () async {
    time = time.add(const Duration(hours: 8));
    await expectLater(
        store.save('property-a', 'plot', 'plot-a', drawing('first')),
        throwsStateError);
    expect(await store.pending(), isEmpty);
  });
  test('impede segundo desenho concorrente do mesmo alvo sem revisão',
      () async {
    await store.save('property-a', 'plot', 'plot-a', drawing('first'));
    await expectLater(
        store.save('property-a', 'plot', 'plot-a', drawing('second')),
        throwsStateError);
    expect(await store.pending(), hasLength(1));
  });
  test('foto persiste fora da câmera, reenvia uma vez e preserva conflito',
      () async {
    final photos = CatalogPhotoStore(store.core);
    await CatalogPhotoStore.initialize(store.core);
    await store.core
        .cache('photos:machine:machine-a', {'can_edit': true, 'items': []});
    final source = File('${folder.path}/camera.jpg');
    await source.writeAsBytes([255, 216, 255, 1, 2, 3]);
    await photos.add('machine', 'machine-a', XFile(source.path));
    await source.delete();
    final saved = (await photos.pending()).single;
    expect(await File(saved['path'] as String).readAsBytes(),
        [255, 216, 255, 1, 2, 3]);
    expect(await CatalogPhotoStore(scoped('other-account').core).pending(),
        isEmpty);
    status = 409;
    await photos.sync();
    expect((await photos.pending()).single['state'], 'conflict');
    expect(await File(saved['path'] as String).exists(), isTrue);
    await photos.archiveConflict((await photos.pending()).single);
    expect(await photos.pending(), isEmpty);
    expect(await File(saved['path'] as String).exists(), isTrue);
    expect(
        (await db.query('catalog_photo_outbox')).single['state'], 'archived');
  });
  test('fila de foto termina sem travar e confirmação não apaga arquivo local',
      () async {
    final photos = CatalogPhotoStore(store.core);
    await CatalogPhotoStore.initialize(store.core);
    await store.core
        .cache('photos:machine:machine-a', {'can_edit': true, 'items': []});
    final source = File('${folder.path}/camera.jpg');
    await source.writeAsBytes([255, 216, 255, 1, 2, 3]);
    await photos.add('machine', 'machine-a', XFile(source.path));
    final saved = (await photos.pending()).single;
    await Future.wait([photos.sync(), photos.sync()]);
    expect(posts, 1);
    expect(await photos.pending(), isEmpty);
    expect(await File(saved['path'] as String).exists(), isTrue);
  });
}
