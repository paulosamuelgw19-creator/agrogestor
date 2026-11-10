import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:agrogestao/features/sync/farm_api_client.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late HttpServer first;
  late HttpServer second;
  late Directory directory;
  late String firstUrl;
  late String secondUrl;
  late int secondRequests;

  setUp(() async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('agrogestor-api-client-');
    PathProviderPlatform.instance = _Paths(directory.path);
    first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    second = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    firstUrl = 'http://127.0.0.1:${first.port}';
    secondUrl = 'http://127.0.0.1:${second.port}';
    secondRequests = 0;
    first.listen((request) async {
      if (request.uri.path.endsWith('/redirect')) {
        request.response.statusCode = 302;
        request.response.headers.set('Location', '$secondUrl/api/v1/test');
      } else if (request.uri.path.contains('/attachments/')) {
        request.response.add([1, 2, 3]);
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'server': 'first',
          'authorization': request.headers.value('Authorization'),
        }));
      }
      await request.response.close();
    });
    second.listen((request) async {
      secondRequests++;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"server":"second"}');
      await request.response.close();
    });
  });

  tearDown(() async {
    await first.close(force: true);
    await second.close(force: true);
    await directory.delete(recursive: true);
  });

  test('sincronização conserva servidor e token após mudar configuração global',
      () async {
    final client = FarmApiClient.forSession(
        baseUrl: firstUrl, token: 'test-token', farmId: 'farm-a');
    await FarmApiClient.instance.configure(secondUrl);
    final response = await client.get('/test');
    expect(response['server'], 'first');
    expect(response['authorization'], 'Bearer test-token');
    expect(secondRequests, 0);
  });

  test('não segue redirecionamentos com a sessão autenticada', () async {
    final client = FarmApiClient.forSession(
        baseUrl: firstUrl, token: 'test-token', farmId: 'farm-a');
    await expectLater(client.get('/redirect'), throwsA(isA<DioException>()));
    expect(secondRequests, 0);
  });

  test('recusa URL com credenciais, parâmetros ou fragmentos', () async {
    for (final url in [
      'https://user:secret@example.invalid',
      'https://example.invalid?key=abc',
      'https://example.invalid#abc',
      'http://example.invalid'
    ]) {
      await expectLater(
          FarmApiClient.instance.configure(url), throwsFormatException);
    }
  });

  test('fotos com mesmo identificador ficam separadas por fazenda', () async {
    final a = FarmApiClient.forSession(
        baseUrl: firstUrl, token: 'test-a', farmId: 'farm-a');
    final b = FarmApiClient.forSession(
        baseUrl: firstUrl, token: 'test-b', farmId: 'farm-b');
    final firstPath = await a.downloadAttachment('attachment-test-0001');
    final secondPath = await b.downloadAttachment('attachment-test-0001');
    expect(firstPath, isNot(secondPath));
    expect(await File(firstPath).readAsBytes(), [1, 2, 3]);
    expect(await File(secondPath).readAsBytes(), [1, 2, 3]);
  });
}
