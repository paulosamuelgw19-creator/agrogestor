import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../auth/auth_service.dart';
import '../sync/farm_api_client.dart';

/// A remembered choice is isolated by server, organization and account.
/// Connection failures never select a different inventory automatically.
Future<bool> usesUnifiedProductCatalog({bool refresh = false}) async {
  final user = AuthService().currentUser;
  if (user?.farmId == null) return false;
  final token = AuthService().accessToken;
  final base = await FarmApiClient.instance.baseUrl;
  if (token == null || base == null) throw StateError('Entre no PC gestor.');
  final key =
      'product_catalog_mode:${jsonEncode([base, user!.farmId, user.id])}';
  final prefs = await SharedPreferences.getInstance();
  final remembered = prefs.getBool(key);
  if (!refresh && remembered != null) return remembered;
  final client = FarmApiClient.forSession(
      baseUrl: base, token: token, farmId: user.farmId!);
  bool unified;
  try {
    final capabilities = await client.v2('GET', '/capabilities');
    if ((capabilities['schemaVersion'] as num? ?? 0) < 3) {
      throw StateError('Atualize o servidor v2 para usar Produtos e insumos.');
    }
    unified = true;
  } on DioException catch (error) {
    final detail = error.response?.data;
    if (error.response?.statusCode == 404 ||
        (error.response?.statusCode == 503 &&
            detail is Map &&
            detail['detail'] ==
                'O piloto v2 não está habilitado nesta instalação.')) {
      unified = false;
    } else if (error.response == null && remembered != null) {
      return remembered;
    } else {
      rethrow;
    }
  }
  if (AuthService().currentUser?.id != user.id ||
      AuthService().accessToken != token ||
      await FarmApiClient.instance.baseUrl != base) {
    throw StateError('A sessão mudou. Abra Produtos e insumos novamente.');
  }
  await prefs.setBool(key, unified);
  return unified;
}
