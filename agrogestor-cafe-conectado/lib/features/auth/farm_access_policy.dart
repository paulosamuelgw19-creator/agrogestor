import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../sync/farm_api_client.dart';
import 'auth_service.dart';
import 'user_model.dart';

/// Client-side mirror of the module policy enforced by the farm API.
/// The server remains the authority; this prevents hidden modules from being
/// read or queued by a different role on the same installation.
class FarmAccessPolicy {
  const FarmAccessPolicy._();
  static const plotNotebookModule = 'plotNotebook';
  static const coffeeReceiptModule = 'coffeeHarvestReceipts';
  static const coffeeLotModule = 'coffeeProcessingLots';
  static const coffeeSaleReceiptModule = 'coffeeSaleReceipts';
  static const coffeeHarvestModules = {
    'coffeeHarvestEntries',
    'coffeePlotProduction',
    coffeeReceiptModule,
    coffeeLotModule,
    coffeeSaleReceiptModule,
  };

  static String? contractModuleFor(String module) {
    if (coffeeHarvestModules.contains(module) || module == plotNotebookModule) {
      return 'properties';
    }
    return switch (module) {
      'machines' || 'implements' => 'fleet',
      'services' => 'tasks',
      'maintenance' => 'workshop',
      'fuel' => 'fuel',
      'operators' || 'clients' => 'properties',
      'products' => 'inventory',
      'productUsage' => 'operations',
      _ => null,
    };
  }

  static const _adminModules = {
    'machines',
    'services',
    'maintenance',
    'fuel',
    'operators',
    'implements',
    'clients',
    'products',
    'productUsage',
    plotNotebookModule,
    ...coffeeHarvestModules,
  };
  static const _operatorModules = {
    'machines',
    'services',
    'implements',
    'fuel',
    'products',
    'productUsage',
  };
  static const _mechanicModules = {'machines', 'maintenance'};
  static const coffeeLocalModules = {
    plotNotebookModule: 'campo_gestor_plot_notebook_v1',
    'coffeeHarvestEntries': 'campo_gestor_coffee_harvest_entries_v1',
    'coffeeHarvestPayments': 'campo_gestor_coffee_harvest_payments_v1',
    ...coffeeProductionModules,
    ...coffeeProcessingModules,
    ...coffeeFieldWorkModules,
  };
  static const coffeeFieldWorkModules = {
    'coffeeTools': 'campo_gestor_coffee_tools_v1',
    'coffeeManualLaborPayments': 'campo_gestor_coffee_manual_labor_payments_v1',
  };
  static const coffeeProcessingModules = {
    'coffeeProcessingLots': 'campo_gestor_coffee_processing_lots_v1',
    'coffeeSeasonChecks': 'campo_gestor_coffee_season_checks_v1',
    'coffeeFinanceChecks': 'campo_gestor_coffee_finance_checks_v1',
    'coffeeFinanceEntries': 'campo_gestor_coffee_finance_entries_v1',
    'coffeeSaleReceipts': 'campo_gestor_coffee_sale_receipts_v1',
  };
  static const coffeeProductionModules = {
    'coffeePlotProduction': 'campo_gestor_coffee_plot_production_v1',
    'coffeeAnalyses': 'campo_gestor_coffee_analyses_v1',
  };

  static void requireCoffeeManager() {
    final user = AuthService().currentUser;
    if (!FarmApiClient.standaloneLocalMode ||
        kIsWeb ||
        user?.id != 'usr_local_admin' ||
        user?.role != UserRole.admin ||
        user?.farmId != null) {
      throw const FarmAccessDenied(
        'Esta área exige a sessão do gestor no AgroGestor local.',
      );
    }
  }

  static bool get canUsePlotNotebook {
    final auth = AuthService();
    final user = auth.currentUser;
    if (kIsWeb || user?.role != UserRole.admin) return false;
    if (FarmApiClient.standaloneLocalMode) {
      return user?.id == 'usr_local_admin' && user?.farmId == null;
    }
    final token = auth.accessToken;
    if (user?.farmId == null || token == null) return false;
    try {
      final claims = jsonDecode(utf8.decode(
        base64Url.decode(base64Url.normalize(token.split('.')[1])),
      )) as Map;
      final expiry = (claims['exp'] as num).toInt();
      return claims['farm_id'] == user!.farmId &&
          claims['sub'] == user.id &&
          DateTime.now().millisecondsSinceEpoch ~/ 1000 < expiry;
    } on Object {
      return false;
    }
  }

  static void requirePlotNotebook() {
    if (!canUsePlotNotebook) {
      throw const FarmAccessDenied(
        'Entre com uma sessão válida de gestor para consultar o caderno.',
      );
    }
  }

  static bool get canUseCoffeeHarvest => canUsePlotNotebook;

  static void requireCoffeeHarvest() {
    if (!canUseCoffeeHarvest) {
      throw const FarmAccessDenied(
        'Entre com uma sessão válida de gestor para consultar a colheita.',
      );
    }
  }

  static bool canRead(UserRole role, String module, {bool local = false}) =>
      (_modulesFor(role).contains(module) &&
          (!coffeeHarvestModules.contains(module) || canUseCoffeeHarvest)) ||
      (local &&
          FarmApiClient.standaloneLocalMode &&
          !kIsWeb &&
          role == UserRole.admin &&
          coffeeLocalModules.containsKey(module));

  static bool canWrite(UserRole role, String module, {bool local = false}) =>
      canRead(role, module, local: local);

  static Set<String> readableModules(UserRole role) {
    final modules = _modulesFor(role);
    return canUseCoffeeHarvest
        ? modules
        : modules.difference(coffeeHarvestModules);
  }

  static Set<String> _modulesFor(UserRole role) => switch (role) {
        UserRole.admin => _adminModules,
        UserRole.operator => _operatorModules,
        UserRole.mechanic => _mechanicModules,
      };
}

class FarmAccessDenied implements Exception {
  const FarmAccessDenied(this.message);
  final String message;

  @override
  String toString() => message;
}
