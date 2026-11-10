import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';

import '../sync/farm_api_client.dart';
import '../auth/auth_service.dart';

class FarmEntitlement {
  const FarmEntitlement({
    required this.status,
    required this.writeAllowed,
    required this.checkedAt,
    required this.offlineUntil,
    required this.activeDevices,
    required this.deviceLimit,
    this.trialEndsAt,
    this.licenseExpiresAt,
    this.daysRemaining,
  });

  final String status;
  final bool writeAllowed;
  final DateTime checkedAt;
  final DateTime offlineUntil;
  final DateTime? trialEndsAt;
  final DateTime? licenseExpiresAt;
  final int activeDevices;
  final int deviceLimit;
  final int? daysRemaining;

  String get effectiveStatus {
    final now = DateTime.now();
    if (status == 'trial' &&
        (trialEndsAt == null || !now.isBefore(trialEndsAt!))) {
      return 'expired';
    }
    if (status == 'licensed' &&
        licenseExpiresAt != null &&
        !now.isBefore(licenseExpiresAt!)) {
      return 'expired';
    }
    if ((status == 'trial' || status == 'licensed') &&
        !now.isBefore(offlineUntil)) {
      return 'validation_required';
    }
    return status;
  }

  int? get effectiveDaysRemaining {
    if (status != 'trial' || trialEndsAt == null) return daysRemaining;
    final remainingSeconds = trialEndsAt!.difference(DateTime.now()).inSeconds;
    if (remainingSeconds <= 0) return 0;
    return (remainingSeconds + const Duration(days: 1).inSeconds - 1) ~/
        const Duration(days: 1).inSeconds;
  }

  bool canWriteAt(DateTime now) {
    if (!writeAllowed ||
        now.isBefore(checkedAt.subtract(const Duration(minutes: 5))) ||
        !now.isBefore(offlineUntil)) {
      return false;
    }
    if (status == 'trial') {
      return trialEndsAt != null && now.isBefore(trialEndsAt!);
    }
    return status == 'licensed' &&
        (licenseExpiresAt == null || now.isBefore(licenseExpiresAt!));
  }

  String get notice => switch (effectiveStatus) {
        'trial' when (effectiveDaysRemaining ?? 30) <= 5 =>
          'Teste grátis: restam ${effectiveDaysRemaining ?? 0} dia(s).',
        'trial' => 'Teste grátis ativo até ${_date(trialEndsAt)}.',
        'licensed' => licenseExpiresAt == null
            ? 'Licença ativa. Consulte os limites em Meu plano.'
            : 'Licença ativa até ${_date(licenseExpiresAt)}. Consulte os limites em Meu plano.',
        'validation_required' =>
          'A validação venceu após sete dias sem conexão. Conecte o PC gestor à internet para validar novamente; os dados continuam disponíveis para consulta.',
        _ =>
          'Teste ou licença encerrados. Consulta liberada; licença válida necessária para novos registros.',
      };

  factory FarmEntitlement.fromJson(Map<String, dynamic> json) =>
      FarmEntitlement(
        status: json['status'] as String? ?? 'expired',
        writeAllowed: json['writeAllowed'] == true,
        checkedAt:
            DateTime.tryParse(json['checkedAt'] as String? ?? '')?.toLocal() ??
                DateTime.fromMillisecondsSinceEpoch(0),
        offlineUntil: DateTime.tryParse(json['offlineUntil'] as String? ?? '')
                ?.toLocal() ??
            DateTime.fromMillisecondsSinceEpoch(0),
        trialEndsAt:
            DateTime.tryParse(json['trialEndsAt'] as String? ?? '')?.toLocal(),
        licenseExpiresAt:
            DateTime.tryParse(json['licenseExpiresAt'] as String? ?? '')
                ?.toLocal(),
        activeDevices: (json['activeDevices'] as num?)?.toInt() ?? 0,
        deviceLimit: (json['deviceLimit'] as num?)?.toInt() ?? -1,
        daysRemaining: (json['daysRemaining'] as num?)?.toInt(),
      );

  static String _date(DateTime? value) => value == null
      ? '—'
      : '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year}';
}

class DeviceActivation {
  const DeviceActivation(
      {required this.id,
      required this.name,
      required this.lastSeenAt,
      required this.active});
  final String id;
  final String name;
  final String lastSeenAt;
  final bool active;

  factory DeviceActivation.fromJson(Map<String, dynamic> json) =>
      DeviceActivation(
        id: json['deviceId'] as String,
        name: json['name'] as String? ?? 'Aparelho',
        lastSeenAt: json['lastSeenAt'] as String? ?? '',
        active: json['active'] == true,
      );
}

class LicenseWriteBlocked implements Exception {
  const LicenseWriteBlocked(this.message);
  final String message;
  @override
  String toString() => message;
}

class LicensingService extends ChangeNotifier {
  static final LicensingService _instance = LicensingService._();
  factory LicensingService() => _instance;
  LicensingService._();

  static const _storage = FlutterSecureStorage();
  static const _deviceIdKey = 'agro_device_installation_id_v1';
  static const _entitlementKey = 'agro_farm_entitlement_v1';

  FarmEntitlement? _current;
  FarmEntitlement? get current => _current;

  Future<String> deviceId() async {
    var value = await _storage.read(key: _deviceIdKey);
    if (value == null || value.isEmpty) {
      value = const Uuid().v4();
      await _storage.write(key: _deviceIdKey, value: value);
    }
    return value;
  }

  Future<FarmEntitlement?> load(String farmId) async {
    try {
      final value = await _storage.read(key: _entitlementKey);
      if (value == null) {
        _current = null;
        return null;
      }
      final decoded = Map<String, dynamic>.from(jsonDecode(value) as Map);
      if (decoded['farmId'] != farmId) {
        _current = null;
        return null;
      }
      _current = FarmEntitlement.fromJson(
          Map<String, dynamic>.from(decoded['entitlement'] as Map));
      return _current;
    } catch (_) {
      _current = null;
      return null;
    }
  }

  Future<void> cache(String farmId, Map<String, dynamic> json) async {
    _current = FarmEntitlement.fromJson(json);
    await _storage.write(
        key: _entitlementKey,
        value: jsonEncode({'farmId': farmId, 'entitlement': json}));
    notifyListeners();
  }

  Future<FarmEntitlement?> refresh(String farmId,
      {FarmApiClient? client}) async {
    final response =
        await (client ?? FarmApiClient.instance).get('/licensing/status');
    if (AuthService().currentUser?.farmId != farmId) {
      return FarmEntitlement.fromJson(response);
    }
    await cache(farmId, response);
    return _current;
  }

  Future<FarmEntitlement?> activate(String farmId, String code) async {
    final response = await FarmApiClient.instance
        .post('/licensing/activate', data: {'licenseKey': code.trim()});
    await cache(farmId, response);
    return _current;
  }

  Future<List<DeviceActivation>> devices() async {
    final response = await FarmApiClient.instance.get('/licensing/devices');
    return (response['devices'] as List<dynamic>? ?? const [])
        .map((row) =>
            DeviceActivation.fromJson(Map<String, dynamic>.from(row as Map)))
        .toList();
  }

  Future<void> releaseDevice(String deviceId) async {
    await FarmApiClient.instance.delete('/licensing/devices/$deviceId');
    notifyListeners();
  }

  Future<FarmEntitlement> requireWriteAccess(String farmId) async {
    final entitlement = await load(farmId);
    if (entitlement == null) {
      throw const LicenseWriteBlocked(
          'Entre na fazenda com internet para validar o teste ou a licença antes de criar registros.');
    }
    if (!entitlement.canWriteAt(DateTime.now())) {
      throw LicenseWriteBlocked(entitlement.effectiveStatus == 'expired'
          ? 'Teste ou licença encerrados. Os dados podem ser consultados; ative uma licença válida para criar ou alterar registros.'
          : entitlement.effectiveStatus == 'validation_required'
              ? 'A validação offline venceu após 7 dias. Conecte-se ao PC gestor para validar a licença.'
              : 'Esta licença não permite novos registros. Consulte o administrador da fazenda.');
    }
    return entitlement;
  }
}
