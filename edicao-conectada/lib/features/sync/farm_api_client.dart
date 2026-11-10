import 'dart:io';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../auth/auth_service.dart';

class FarmApiClient {
  static const standaloneLocalMode =
      bool.fromEnvironment('AGRO_STANDALONE_LOCAL', defaultValue: false);
  static const showServerConfiguration =
      !bool.fromEnvironment('AGRO_HIDE_MANAGER_CONFIG', defaultValue: false);
  static const _defaultBaseUrl =
      String.fromEnvironment('AGRO_FARM_SERVER_URL', defaultValue: '');
  static const _urlKey = 'agro_farm_server_url_v1';
  static final FarmApiClient instance = FarmApiClient._();
  FarmApiClient._({String? baseUrl, String? token, String? farmId})
      : _sessionBaseUrl = baseUrl,
        _sessionToken = token,
        _sessionFarmId = farmId;

  static FarmApiClient forSession(
          {required String baseUrl,
          required String token,
          required String farmId}) =>
      FarmApiClient._(baseUrl: baseUrl, token: token, farmId: farmId);

  final String? _sessionBaseUrl;
  final String? _sessionToken;
  final String? _sessionFarmId;

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    sendTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 20),
    headers: const {'Content-Type': 'application/json'},
    followRedirects: false,
  ));

  Future<String?> get baseUrl async =>
      _sessionBaseUrl ??
      (await SharedPreferences.getInstance()).getString(_urlKey) ??
      (_defaultBaseUrl.isEmpty ? null : _defaultBaseUrl);

  Future<void> configure(String rawUrl) async {
    final value = rawUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        !{'http', 'https'}.contains(uri.scheme)) {
      throw const FormatException(
          'Informe um endereço http:// ou https:// válido.');
    }
    final isLocal = uri.host == 'localhost' ||
        uri.host == '127.0.0.1' ||
        (Platform.isAndroid && uri.host == '10.0.2.2');
    if (uri.scheme != 'https' && !isLocal) {
      throw const FormatException(
          'Conexões fora deste PC exigem HTTPS. Use a URL privada com certificado do servidor.');
    }
    final previous = await baseUrl;
    if (previous != value && AuthService().isAuthenticated) {
      await AuthService().logout();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_urlKey, value);
  }

  Future<void> clearConfiguration() async =>
      (await SharedPreferences.getInstance()).remove(_urlKey);

  Future<Map<String, dynamic>> get(String path,
          {Map<String, dynamic>? query}) async =>
      _map(await _dio.get(await _url(path),
          queryParameters: query, options: await _options()));

  Future<Map<String, dynamic>> post(String path, {Object? data}) async => _map(
      await _dio.post(await _url(path), data: data, options: await _options()));

  Future<Map<String, dynamic>> patch(String path, {Object? data}) async =>
      _map(await _dio.patch(await _url(path),
          data: data, options: await _options()));

  Future<Map<String, dynamic>> delete(String path) async =>
      _map(await _dio.delete(await _url(path), options: await _options()));

  Future<Map<String, dynamic>> v2(String method, String path,
      {Object? data, Map<String, dynamic>? query}) async {
    if (!path.startsWith('/') || path.contains('..') || path.contains('?')) {
      throw const FormatException('Caminho inválido.');
    }
    final base = await baseUrl;
    if (base == null || base.isEmpty) {
      throw StateError('Configure o PC gestor.');
    }
    return _map(await _dio.request('$base/api/v2$path',
        data: data,
        queryParameters: query,
        options: (await _options()).copyWith(method: method)));
  }

  Future<void> uploadAttachment(String attachmentId, String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw StateError('A foto local não está disponível para sincronização.');
    }
    if (await file.length() > 10 * 1024 * 1024) {
      throw StateError('A foto excede o limite de 10 MB.');
    }
    final form = FormData.fromMap({
      'file':
          await MultipartFile.fromFile(filePath, filename: '$attachmentId.bin'),
    });
    await _dio.put(await _url('/attachments/$attachmentId'),
        data: form,
        options: await _options().then(
            (options) => options.copyWith(contentType: 'multipart/form-data')));
  }

  Future<void> uploadWorkPhoto(
      String kind, String target, String id, String path) async {
    final photo = File(path);
    if (!await photo.exists()) {
      throw StateError(
          'A foto local não está disponível. O lançamento continua salvo.');
    }
    if (await photo.length() > 8 * 1024 * 1024) {
      throw StateError('A foto excede 8 MB.');
    }
    final base = await baseUrl;
    final form = FormData.fromMap(
        {'file': await MultipartFile.fromFile(path, filename: 'photo.jpg')});
    await _dio.put('$base/api/v2/work/$kind/$target/photos/$id',
        data: form,
        options:
            (await _options()).copyWith(contentType: 'multipart/form-data'));
  }

  Future<List<int>> workPhoto(String kind, String target, String id) async {
    final base = await baseUrl;
    final response = await _dio.get<List<int>>(
        '$base/api/v2/work/$kind/$target/photos/$id',
        options: (await _options()).copyWith(responseType: ResponseType.bytes));
    return response.data ?? [];
  }

  Future<String> downloadAttachment(String attachmentId) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{16,80}$').hasMatch(attachmentId)) {
      throw const FormatException('Identificador de anexo inválido.');
    }
    final response = await _dio.get<List<int>>(
      await _url('/attachments/$attachmentId'),
      options: await _options().then(
          (options) => options.copyWith(responseType: ResponseType.bytes)),
    );
    final directory = await getApplicationSupportDirectory();
    final farm = _sessionFarmId ?? AuthService().currentUser?.farmId ?? 'local';
    final namespace = base64Url.encode(utf8.encode(farm));
    final folder = Directory(
        '${directory.path}${Platform.pathSeparator}attachments${Platform.pathSeparator}$namespace');
    await folder.create(recursive: true);
    final path = '${folder.path}${Platform.pathSeparator}$attachmentId.bin';
    await File(path).writeAsBytes(response.data ?? const <int>[], flush: true);
    return path;
  }

  Future<String> _url(String path) async {
    final base = await baseUrl;
    if (base == null || base.isEmpty) {
      throw StateError(
          'Configure o endereço do PC gestor nas opções de sincronização.');
    }
    return '$base/api/v1$path';
  }

  Future<Options> _options() async {
    final token = _sessionToken ?? AuthService().accessToken;
    return Options(
        headers: token == null ? const {} : {'Authorization': 'Bearer $token'});
  }

  Map<String, dynamic> _map(Response<dynamic> response) {
    final data = response.data;
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw const FormatException('Resposta inválida do servidor da fazenda.');
  }
}
