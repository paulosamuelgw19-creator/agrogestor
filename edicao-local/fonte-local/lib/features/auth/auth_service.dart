import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../sync/farm_api_client.dart';
import '../sync/sync_service.dart';
import '../licensing/licensing_service.dart';
import '../local_activation/local_activation_service.dart';
import 'user_model.dart';

class AuthService extends ChangeNotifier {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  static const _storage = FlutterSecureStorage();
  static const _keyUser = 'agro_current_user_v2';
  static const _keyToken = 'agro_access_token_v1';

  AppUser? _currentUser;
  String? _accessToken;
  bool _initialized = false;
  String? _lastError;

  AppUser? get currentUser => _currentUser;
  String? get accessToken => _accessToken;
  String? get lastError => _lastError;
  bool get isAuthenticated =>
      _currentUser != null && LocalActivationService.instance.isValid;
  bool get isInitialized => _initialized;
  bool get isServerConnectedAccount => _currentUser?.farmId != null;
  bool get isAwaitingFarmSetup => false;

  static const demoUsers = <AppUser>[
    AppUser(
        id: 'usr_admin',
        name: 'Carlos Fazendeiro (Admin)',
        email: 'admin@agrogestor.com',
        role: UserRole.admin),
    AppUser(
        id: 'usr_operator',
        name: 'João Silva (Operador)',
        email: 'operador@agrogestor.com',
        role: UserRole.operator),
    AppUser(
        id: 'usr_mechanic',
        name: 'Marcos Oficina (Mecânico)',
        email: 'mecanico@agrogestor.com',
        role: UserRole.mechanic),
  ];

  Future<void> init({bool startSync = true}) async {
    if (_initialized) return;
    await LocalActivationService.instance.refresh();
    try {
      final userJson = await _storage.read(key: _keyUser);
      final token = await _storage.read(key: _keyToken);
      if (userJson != null &&
          (token != null || FarmApiClient.standaloneLocalMode)) {
        _currentUser = AppUser.fromJson(jsonDecode(userJson));
        _accessToken = token;
        if (FarmApiClient.standaloneLocalMode) {
          if (_currentUser?.id != 'usr_local_admin' ||
              _currentUser?.farmId != null) {
            _currentUser = null;
          }
          _accessToken = null;
        }
      }
    } catch (_) {
      _currentUser = null;
      _accessToken = null;
    }
    _initialized = true;
    if (LocalActivationService.instance.enforced &&
        !LocalActivationService.instance.isValid) {
      _currentUser = null;
      _accessToken = null;
    }
    if (_currentUser?.farmId != null) {
      await LicensingService().load(_currentUser!.farmId!);
      if (startSync) SyncService().start();
    }
    notifyListeners();
  }

  Future<bool> login(String email, String password) async {
    _lastError = null;
    final cleanEmail = email.trim().toLowerCase();
    final serverUrl = await FarmApiClient.instance.baseUrl;
    if (serverUrl == null || serverUrl.isEmpty) {
      return _fail('Configure o endereço do PC gestor antes de entrar.');
    }
    if (kIsWeb) {
      return _fail(
          'A sincronização privada está disponível no aplicativo Android.');
    }
    try {
      final response = await FarmApiClient.instance.post('/auth/login', data: {
        'email': cleanEmail,
        'password': password,
        'deviceId': await LicensingService().deviceId(),
        'deviceName': defaultTargetPlatform.name,
      });
      final userData = Map<String, dynamic>.from(response['user'] as Map);
      final role = UserRole.values
          .where((value) => value.name == userData['role'])
          .firstOrNull;
      if (role == null || userData['farmId'] is! String) {
        return _fail('O servidor retornou um perfil de usuário inválido.');
      }
      final token = response['token'];
      if (token is! String || token.trim().isEmpty) {
        return _fail('O servidor não retornou uma sessão válida.');
      }
      final authenticatedUser = AppUser(
        id: userData['id'] as String,
        name: userData['displayName'] as String? ?? 'Usuário',
        email: userData['email'] as String? ?? cleanEmail,
        role: role,
        farmId: userData['farmId'] as String,
      );
      final entitlement = response['entitlement'];
      if (entitlement is Map) {
        await LicensingService().cache(
            authenticatedUser.farmId!, Map<String, dynamic>.from(entitlement));
      }
      _currentUser = authenticatedUser;
      _accessToken = token;
      await _persistSession();
      notifyListeners();
      await SyncService().start();
      return true;
    } on DioException catch (error) {
      return _fail(_serverError(error));
    } catch (error) {
      return _fail('Não foi possível entrar: $error');
    }
  }

  Future<bool> acceptInvitation({
    required String email,
    required String code,
    required String name,
    required String password,
  }) async {
    try {
      await FarmApiClient.instance.post('/auth/accept-invitation', data: {
        'email': email.trim().toLowerCase(),
        'code': code.trim(),
        'displayName': name.trim(),
        'password': password,
      });
      _lastError = null;
      return true;
    } on DioException catch (error) {
      return _fail(_serverError(error));
    } catch (error) {
      return _fail('Não foi possível aceitar o convite: $error');
    }
  }

  Future<bool> selectDemoUser(AppUser user) async {
    if (!kDebugMode) {
      return _fail(
          'Perfis de demonstração só existem na versão de desenvolvimento.');
    }
    _currentUser = user;
    _accessToken = null;
    await _storage.delete(key: _keyToken);
    await _storage.write(key: _keyUser, value: jsonEncode(user.toJson()));
    _lastError = null;
    notifyListeners();
    return true;
  }

  Future<bool> enterStandaloneLocalMode() async {
    if (!FarmApiClient.standaloneLocalMode) {
      return _fail(
          'O modo local independente não está habilitado nesta versão.');
    }
    try {
      await LocalActivationService.instance.requireValid();
    } on LocalActivationException catch (error) {
      return _fail(error.message);
    }
    _currentUser = const AppUser(
      id: 'usr_local_admin',
      name: 'Gestor local',
      email: 'gestor@agrogestor.local',
      role: UserRole.admin,
    );
    _accessToken = null;
    await _storage.delete(key: _keyToken);
    await _persistSession();
    _lastError = null;
    notifyListeners();
    return true;
  }

  Future<void> logout() async {
    _currentUser = null;
    _accessToken = null;
    await _storage.delete(key: _keyUser);
    await _storage.delete(key: _keyToken);
    SyncService().stop();
    notifyListeners();
  }

  Future<void> _persistSession() async {
    await _storage.write(
        key: _keyUser, value: jsonEncode(_currentUser!.toJson()));
    await _storage.write(key: _keyToken, value: _accessToken);
  }

  String _serverError(DioException error) {
    final detail = error.response?.data;
    if (detail is Map && detail['detail'] is String) {
      return detail['detail'] as String;
    }
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.connectionError ||
        error.type == DioExceptionType.receiveTimeout) {
      return 'PC gestor indisponível. Confira a VPN. Se você já entrou antes, os cadastros offline continuam salvos neste aparelho.';
    }
    return error.message ?? 'Erro de comunicação com o PC gestor.';
  }

  bool _fail(String message) {
    _lastError = message;
    notifyListeners();
    return false;
  }
}
