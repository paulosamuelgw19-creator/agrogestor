import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

class LocalActivationException implements Exception {
  const LocalActivationException(this.message);
  final String message;
  @override
  String toString() => message;
}

class LocalActivationService extends ChangeNotifier {
  LocalActivationService({bool? enforce, Dio? transport, String? endpoint})
      : enforced = enforce ??
            (!kIsWeb &&
                Platform.isAndroid &&
                const bool.fromEnvironment('AGRO_STANDALONE_LOCAL')),
        _dio = transport ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 15),
              followRedirects: false,
            )),
        _endpoint = endpoint ??
            const String.fromEnvironment('AGRO_LOCAL_ACTIVATION_URL');
  static final instance = LocalActivationService();
  static const channel = MethodChannel('agrogestor/local_activation');
  static const storage = FlutterSecureStorage();
  final bool enforced;
  final Dio _dio;
  final String _endpoint;
  bool _valid = false;
  bool _activating = false;
  Map<String, dynamic> _status = {};
  bool get isValid => !enforced || _valid;
  String? get licenseId => _status['licenseId'] as String?;
  String? get fingerprint => _status['fingerprint'] as String?;
  String get reason => _status['reason'] as String? ?? 'not_activated';

  Future<bool> refresh() async {
    if (!enforced) return true;
    final previous = jsonEncode(_status);
    try {
      final result = await channel.invokeMapMethod<String, dynamic>('status');
      _status = result ?? {};
      _valid = _status['valid'] == true;
    } catch (_) {
      _valid = false;
      _status = {'reason': 'storage_error'};
    }
    if (previous != jsonEncode(_status)) notifyListeners();
    return _valid;
  }

  void requireCached() {
    if (!isValid) {
      throw const LocalActivationException(
          'Ative o AgroGestor Local neste aparelho. Seus dados foram preservados.');
    }
  }

  Future<void> requireValid() async {
    if (enforced && !await refresh()) {
      throw const LocalActivationException(
          'A autorização deste aparelho não pôde ser validada. Seus dados foram preservados.');
    }
  }

  Uri _base() {
    final uri = Uri.tryParse(_endpoint);
    final testLoopback = kDebugMode &&
        const bool.fromEnvironment('AGRO_LOCAL_ACTIVATION_LOOPBACK_TEST') &&
        uri?.host == '127.0.0.1' &&
        uri?.scheme == 'http';
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !['', '/'].contains(uri.path) ||
        (uri.scheme != 'https' && !testLoopback)) {
      throw const LocalActivationException(
          'O endereço seguro de ativação ainda não foi configurado nesta edição. Solicite o APK preparado ao responsável.');
    }
    return uri;
  }

  Future<Map<String, dynamic>> _post(Uri url, Map<String, dynamic> body) async {
    try {
      final response = await _dio.postUri(url, data: body);
      if (response.data is! Map) {
        throw const LocalActivationException(
            'Resposta de ativação inválida. Tente novamente.');
      }
      return Map<String, dynamic>.from(response.data as Map);
    } on DioException catch (error) {
      final data = error.response?.data;
      final code = data is Map ? data['error'] : null;
      const messages = {
        'invalid_code': 'Código inválido. Confira o código recebido.',
        'code_used': 'Este código já foi utilizado em outra instalação.',
        'cancelled_code':
            'Este código foi cancelado. Solicite outro ao responsável.',
        'rate_limited': 'Muitas tentativas. Aguarde e tente novamente.',
        'challenge_expired':
            'A solicitação expirou. Tente novamente com o mesmo código.',
        'installation_active':
            'Esta instalação já foi autorizada. Utilize o código original para recuperar a licença.',
      };
      if (messages.containsKey(code)) {
        throw LocalActivationException(messages[code]!);
      }
      if (error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        throw const LocalActivationException(
            'Falha de conexão. Confira a internet e se o responsável iniciou o servidor. O código continua preenchido.');
      }
      throw const LocalActivationException(
          'Servidor de ativação indisponível. Tente novamente mais tarde.');
    }
  }

  Future<void> activate(String enteredCode) async {
    if (_activating) {
      throw const LocalActivationException('Aguarde a ativação em andamento.');
    }
    _activating = true;
    try {
      final code = enteredCode.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
      if (!RegExp(r'^AGRO[A-Z2-7]{32}$').hasMatch(code)) {
        throw const LocalActivationException(
            'Código inválido. Copie o código completo recebido.');
      }
      final base = _base();
      final identity =
          await channel.invokeMapMethod<String, dynamic>('identity');
      if (identity == null ||
          identity['appId'] != 'com.campo.agrogestao.localpilot' ||
          identity['nonExportable'] != true) {
        throw const LocalActivationException(
            'Não foi possível proteger a chave desta instalação.');
      }
      var requestId =
          await storage.read(key: 'agro_local_activation_request_v1');
      if (requestId == null) {
        requestId = const Uuid().v4();
        await storage.write(
            key: 'agro_local_activation_request_v1', value: requestId);
      }
      final codeHash = sha256.convert(utf8.encode(code)).toString();
      final challenge = await _post(base.resolve('/activation/v1/challenge'), {
        'appId': identity['appId'],
        'schemaVersion': 1,
        'requestId': requestId,
        'codeHash': codeHash,
        'publicKey': identity['publicKey'],
      });
      if (challenge['challengeId'] is! String ||
          challenge['nonce'] is! String) {
        throw const LocalActivationException('Resposta de ativação inválida.');
      }
      final proof = [
        'AGROGESTOR-ACTIVATE-V1',
        challenge['challengeId'],
        challenge['nonce'],
        requestId,
        codeHash,
        identity['fingerprint'],
        identity['appId']
      ].join('\n');
      final signature =
          await channel.invokeMethod<String>('sign', {'message': proof});
      final response = await _post(base.resolve('/activation/v1/activate'), {
        'challengeId': challenge['challengeId'],
        'nonce': challenge['nonce'],
        'code': code,
        'signature': signature,
      });
      if (response['license'] is! Map) {
        throw const LocalActivationException(
            'Autorização inválida recebida do servidor.');
      }
      final document = jsonEncode(response['license']);
      final checked = await channel
          .invokeMapMethod<String, dynamic>('verify', {'license': document});
      if (checked?['valid'] != true) {
        throw const LocalActivationException(
            'A assinatura ou o vínculo da autorização não pôde ser validado.');
      }
      try {
        await channel.invokeMethod('accept', {'license': document});
        if (!await refresh()) {
          throw const LocalActivationException(
              'Falha ao conferir a autorização salva.');
        }
      } catch (_) {
        throw const LocalActivationException(
            'Falha ao guardar a autorização. Seus dados foram preservados. Tente novamente com o mesmo código para recuperar a ativação.');
      }
    } on PlatformException {
      throw const LocalActivationException(
          'Não foi possível acessar a chave protegida ou guardar a autorização neste aparelho.');
    } finally {
      _activating = false;
    }
  }
}
