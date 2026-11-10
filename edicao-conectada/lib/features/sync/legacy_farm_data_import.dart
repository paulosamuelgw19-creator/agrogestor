import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../auth/auth_service.dart';
import '../auth/farm_access_policy.dart';
import '../auth/user_model.dart';
import '../licensing/licensing_service.dart';
import '../clients/client_record.dart';
import '../fuel/fuel_record.dart';
import '../implements/farm_implement.dart';
import '../machines/machine.dart';
import '../maintenance/maintenance_record.dart';
import '../operators/operator.dart';
import '../products/product_record.dart';
import '../services/farm_service.dart';
import 'app_database.dart';
import 'sync_outbox_queue.dart';
import 'sync_service.dart';

class LegacyFarmDataPreview {
  const LegacyFarmDataPreview({
    required this.counts,
    required this.canImport,
    this.reason,
  });

  final Map<String, int> counts;
  final bool canImport;
  final String? reason;
  int get total => counts.values.fold(0, (sum, count) => sum + count);
}

class LegacyFarmDataImport {
  static const _sources = <String, String>{
    'machines': 'campo_gestor_machines_v1',
    'services': 'campo_gestor_services_v1',
    'maintenance': 'campo_gestor_maintenance_v1',
    'fuel': 'campo_gestor_fuel_v1',
    'operators': 'campo_gestor_operators_v1',
    'implements': 'campo_gestor_implements_v1',
    'clients': 'campo_gestor_clients_v1',
    'products': 'campo_gestor_products_v1',
    'productUsage': 'campo_gestor_product_usage_v1',
  };

  Future<LegacyFarmDataPreview> preview() async {
    final user = AuthService().currentUser;
    if (user?.farmId == null || user?.role != UserRole.admin || kIsWeb) {
      return const LegacyFarmDataPreview(counts: {}, canImport: false);
    }

    final prefs = await SharedPreferences.getInstance();
    final data = <String, List<Map<String, dynamic>>>{};
    for (final source in _sources.entries) {
      data[source.key] = parseLegacyRecords(prefs.getString(source.value), source.key);
    }
    final counts = {for (final entry in data.entries) entry.key: entry.value.length}
      ..removeWhere((_, count) => count == 0);
    if (counts.isEmpty) return LegacyFarmDataPreview(counts: counts, canImport: false);

    final db = await appDatabase.database;
    final synced = await db.query('sync_metadata',
      columns: ['value'], where: 'farm_id=? AND key=?',
      whereArgs: [user!.farmId, 'last_sync_at'], limit: 1);
    if (synced.isEmpty) {
      return LegacyFarmDataPreview(
        counts: counts,
        canImport: false,
        reason: 'Faça uma sincronização inicial para confirmar que a fazenda está vazia.',
      );
    }
    final existing = await db.query('local_records',
      columns: ['record_id'], where: 'farm_id=?', whereArgs: [user.farmId], limit: 1);
    if (existing.isNotEmpty) {
      return LegacyFarmDataPreview(
        counts: counts,
        canImport: false,
        reason: 'Esta fazenda já tem registros. A importação foi bloqueada para evitar misturar ou substituir dados.',
      );
    }
    return LegacyFarmDataPreview(counts: counts, canImport: true);
  }

  Future<int> importToCurrentFarm() async {
    final user = AuthService().currentUser;
    final farmId = user?.farmId;
    if (farmId == null || user?.role != UserRole.admin) {
      throw const FarmAccessDenied('Somente o administrador da fazenda pode importar os dados antigos.');
    }
    if (kIsWeb) throw UnsupportedError('A importação local está disponível no Android e Windows.');
    await LicensingService().requireWriteAccess(farmId);

    final prefs = await SharedPreferences.getInstance();
    final recordsByModule = <String, List<Map<String, dynamic>>>{};
    for (final source in _sources.entries) {
      recordsByModule[source.key] = parseLegacyRecords(prefs.getString(source.value), source.key);
    }
    final total = recordsByModule.values.fold<int>(0, (sum, rows) => sum + rows.length);
    if (total == 0) throw StateError('Não há cadastros antigos para importar neste aparelho.');

    final db = await appDatabase.database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.transaction((tx) async {
      final synced = await tx.query('sync_metadata',
        columns: ['value'], where: 'farm_id=? AND key=?',
        whereArgs: [farmId, 'last_sync_at'], limit: 1);
      if (synced.isEmpty) {
        throw StateError('Sincronize esta fazenda primeiro para confirmar que ela está vazia.');
      }
      final existing = await tx.query('local_records',
        columns: ['record_id'], where: 'farm_id=?', whereArgs: [farmId], limit: 1);
      if (existing.isNotEmpty) {
        throw StateError('A fazenda já contém dados. A importação foi bloqueada para evitar misturar ou substituir registros.');
      }

      for (final moduleEntry in recordsByModule.entries) {
        if (!FarmAccessPolicy.canWrite(user!.role, moduleEntry.key)) continue;
        for (final legacy in moduleEntry.value) {
          final id = legacy['id'];
          if (id is! String || id.isEmpty || id.length > 160 ||
              !RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(id)) {
            throw FormatException('Um cadastro antigo de ${moduleEntry.key} tem identificador inválido.');
          }
          final payload = Map<String, dynamic>.from(legacy);
          if (moduleEntry.key == 'machines' && payload['photoPath'] is String &&
              (payload['photoAttachmentId'] == null || (payload['photoAttachmentId'] as String).isEmpty)) {
            payload['photoAttachmentId'] = const Uuid().v4();
          }
          final encoded = jsonEncode(payload);
          await tx.insert('local_records', {
            'farm_id': farmId,
            'module': moduleEntry.key,
            'record_id': id,
            'payload': encoded,
            'server_version': 0,
            'sync_state': 'pending',
            'sync_error': null,
            'remote_payload': null,
            'remote_deleted': 0,
            'is_deleted': 0,
            'changed_at': now,
          });
          await SyncOutboxQueue.enqueue(
            tx,
            farmId: farmId,
            module: moduleEntry.key,
            recordId: id,
            operation: 'upsert',
            payload: encoded,
            baseVersion: 0,
            createdAt: now,
          );
        }
      }
    });
    SyncService().notifyLocalChange();
    return total;
  }

  @visibleForTesting
  static List<Map<String, dynamic>> parseLegacyRecords(String? raw, String module) {
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) throw const FormatException('O conteúdo não é uma lista.');
      final records = decoded.map((item) {
        if (item is! Map) throw const FormatException('Um cadastro não é um objeto.');
        return Map<String, dynamic>.from(item);
      }).toList();
      final ids = <String>{};
      return records.map((record) {
        final id = record['id'];
        if (id is! String || id.isEmpty || id.length > 160 ||
            !RegExp(r'^[-A-Za-z0-9_.:]+$').hasMatch(id) || !ids.add(id)) {
          throw const FormatException('Há identificador inválido, ausente ou duplicado.');
        }
        return _normalizeRecord(module, record);
      }).toList();
    } catch (error) {
      throw FormatException('Não foi possível ler os cadastros antigos de $module: $error');
    }
  }

  static Map<String, dynamic> _normalizeRecord(String module, Map<String, dynamic> record) {
    final normalized = switch (module) {
      'machines' => Machine.fromJson(record).toJson(),
      'services' => FarmService.fromJson(record).toJson(),
      'maintenance' => MaintenanceRecord.fromJson(record).toJson(),
      'fuel' => FuelRecord.fromJson(record).toJson(),
      'operators' => Operator.fromJson(record).toJson(),
      'implements' => FarmImplement.fromJson(record).toJson(),
      'clients' => RuralClient.fromJson(record).toJson(),
      'products' => FarmProduct.fromJson(record).toJson(),
      'productUsage' => ProductUsage.fromJson(record).toJson(),
      _ => throw FormatException('Módulo antigo desconhecido: $module.'),
    };
    return Map<String, dynamic>.from(normalized);
  }
}
