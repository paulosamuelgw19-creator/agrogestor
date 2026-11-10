import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:agrogestao/features/local_activation/local_activation_service.dart';
import 'package:agrogestao/features/local_activation/activation_gate.dart';

class _Transport implements HttpClientAdapter {
  int requests = 0;
  String? serverError;
  bool disconnect = false;
  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests++;
    if (disconnect) {
      throw DioException(
          requestOptions: options, type: DioExceptionType.connectionError);
    }
    final challenge = options.path.endsWith('/challenge');
    final body = serverError != null
        ? {'error': serverError, 'message': 'DO NOT REFLECT RAW SERVER MESSAGE'}
        : challenge
            ? {
                'challengeId': '00000000-0000-4000-8000-000000000001',
                'nonce': 'n' * 43
              }
            : {
                'license': {
                  'payload': 'test',
                  'signature': 'test',
                  'keyId': 'test'
                }
              };
    return ResponseBody.fromString(
        jsonEncode(body), serverError != null ? 409 : 200,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType]
        });
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const code = 'AGRO-AAAAAAAA-AAAAAAAA-AAAAAAAA-AAAAAAAA';
  late _Transport transport;
  late LocalActivationService license;
  bool nativeValid = false, verifyValid = true, failSave = false;
  final calls = <String>[];
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    transport = _Transport();
    license = LocalActivationService(
        enforce: true,
        transport: Dio()..httpClientAdapter = transport,
        endpoint: 'https://activation.test');
    nativeValid = false;
    verifyValid = true;
    failSave = false;
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LocalActivationService.channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'status':
          return {
            'valid': nativeValid,
            if (!nativeValid) 'reason': 'not_activated'
          };
        case 'identity':
          return {
            'publicKey': 'test-key',
            'fingerprint': 'f' * 64,
            'appId': 'com.campo.agrogestao.localpilot',
            'nonExportable': true
          };
        case 'sign':
          return 'test-proof';
        case 'verify':
          return {'valid': verifyValid};
        case 'accept':
          if (failSave) throw PlatformException(code: 'storage');
          nativeValid = true;
          return {'valid': true};
      }
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LocalActivationService.channel, null);
    license.dispose();
  });
  test('missing authorization blocks local access without a network request',
      () async {
    expect(await license.refresh(), false);
    expect(license.isValid, false);
    expect(license.requireCached, throwsA(isA<LocalActivationException>()));
    expect(transport.requests, 0);
  });
  test(
      'valid local authorization is checked offline and never expires with server availability',
      () async {
    nativeValid = true;
    transport.disconnect = true;
    expect(await license.refresh(), true);
    await license.requireValid();
    expect(transport.requests, 0);
  });
  test('invalid code does not reach the server', () async {
    await expectLater(license.activate('incomplete'),
        throwsA(isA<LocalActivationException>()));
    expect(transport.requests, 0);
  });
  test('external cleartext HTTP configuration is rejected', () async {
    final insecure = LocalActivationService(
        enforce: true,
        transport: Dio()..httpClientAdapter = transport,
        endpoint: 'http://192.0.2.20');
    await expectLater(
        insecure.activate(code), throwsA(isA<LocalActivationException>()));
    expect(transport.requests, 0);
    insecure.dispose();
  });
  test('a signed license must be validated and saved before access', () async {
    await license.activate(code);
    expect(license.isValid, true);
    expect(calls,
        containsAllInOrder(['identity', 'sign', 'verify', 'accept', 'status']));
    expect(transport.requests, 2);
  });
  test('untrusted license is never saved', () async {
    verifyValid = false;
    await expectLater(
        license.activate(code), throwsA(isA<LocalActivationException>()));
    expect(calls, isNot(contains('accept')));
    expect(license.isValid, false);
  });
  test('storage failure permits a retry with the same request id', () async {
    failSave = true;
    await expectLater(
        license.activate(code), throwsA(isA<LocalActivationException>()));
    final requestId = await LocalActivationService.storage
        .read(key: 'agro_local_activation_request_v1');
    failSave = false;
    await license.activate(code);
    expect(license.isValid, true);
    expect(
        await LocalActivationService.storage
            .read(key: 'agro_local_activation_request_v1'),
        requestId);
  });
  for (final error in [
    'invalid_code',
    'code_used',
    'cancelled_code',
    'rate_limited'
  ]) {
    test('maps $error without reflecting server content', () async {
      transport.serverError = error;
      try {
        await license.activate(code);
        fail('Expected error');
      } on LocalActivationException catch (e) {
        expect(e.message, isNot(contains('DO NOT REFLECT')));
      }
      expect(license.isValid, false);
    });
  }
  testWidgets(
      'activation is readable at 320px and preserves entered code after network failure',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    transport.disconnect = true;
    await tester.pumpWidget(MaterialApp(
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!),
        home:
            ActivationGate(service: license, child: const Text('Local app'))));
    expect(find.text('Ativar AgroGestor Local'), findsOneWidget);
    expect(find.text('Ativado neste aparelho'), findsNothing);
    await tester.enterText(find.byType(TextField), code);
    await tester.ensureVisible(find.text('Ativar neste aparelho'));
    await tester.tap(find.text('Ativar neste aparelho'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField).evaluate().single.widget, isA<TextField>());
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        code);
    expect(find.textContaining('Falha de conexão'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
