import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../auth/auth_service.dart';
import '../auth/farm_access_policy.dart';
import '../sync/app_database.dart';
import '../sync/farm_api_client.dart';
import '../sync/local_sync_collection_store.dart';
import '../sync/local_write_batch.dart';
import 'coffee_harvest_repository.dart';

String _day(DateTime date) =>
    coffeeCivilDate(date).toIso8601String().split('T').first;

class CoffeeReceiptSource {
  const CoffeeReceiptSource._({
    required this.propertyId,
    required this.plotId,
    required this.seasonYear,
    required this.harvestDate,
    required this.fieldLiters,
    required this.sourceRevision,
    required (String, String, String) session,
  }) : _session = session;

  final String propertyId, plotId, sourceRevision;
  final int seasonYear;
  final DateTime harvestDate;
  final double fieldLiters;
  final (String, String, String) _session;
}

class CoffeeHarvestReceipt {
  CoffeeHarvestReceipt.fromJson(Map<String, dynamic> json)
      : id = json['id'] as String,
        propertyId = json['propertyId'] as String,
        plotId = json['plotId'] as String,
        seasonYear = json['seasonYear'] as int,
        harvestDate = DateTime.parse(json['harvestDate'] as String),
        receivedDate = DateTime.parse(json['receivedDate'] as String),
        receivedLiters = (json['receivedLiters'] as num).toDouble(),
        fieldLiters = (json['fieldLiters'] as num).toDouble(),
        sourceRevision = json['sourceRevision'] as String,
        notes = json['notes'] as String?;

  final String id, propertyId, plotId, sourceRevision;
  final int seasonYear;
  final DateTime harvestDate, receivedDate;
  final double receivedLiters, fieldLiters;
  final String? notes;

  double get differenceLiters => receivedLiters - fieldLiters;

  Map<String, Object?> toJson() => {
        'id': id,
        'propertyId': propertyId,
        'plotId': plotId,
        'seasonYear': seasonYear,
        'harvestDate': _day(harvestDate),
        'receivedDate': _day(receivedDate),
        'receivedLiters': receivedLiters,
        'fieldLiters': fieldLiters,
        'sourceRevision': sourceRevision,
        if (notes != null) 'notes': notes,
      };
}

class CoffeeReceiptRepository {
  static const module = FarmAccessPolicy.coffeeReceiptModule;
  static const _store = LocalSyncCollectionStore<CoffeeHarvestReceipt>(
    module: module,
    legacyKey: 'campo_gestor_coffee_harvest_receipts_v1',
  );

  Future<List<CoffeeHarvestReceipt>> list({
    required String propertyId,
    String? plotId,
    required int seasonYear,
    bool confirmedOnly = false,
  }) async {
    final session = _session();
    final receipts =
        await _store.getAll(fromJson: CoffeeHarvestReceipt.fromJson);
    Set<String>? confirmed;
    if (confirmedOnly) {
      final db = LocalWriteBatch.current ?? await appDatabase.database;
      final rows = await db.query('local_records',
          columns: ['record_id'],
          where:
              "farm_id=? AND module=? AND sync_state='synced' AND is_deleted=0",
          whereArgs: [session.$2, module]);
      confirmed = rows.map((row) => row['record_id']! as String).toSet();
    }
    _checkSession(session);
    return [
      for (final receipt in receipts)
        if (receipt.propertyId == propertyId &&
            (plotId == null || receipt.plotId == plotId) &&
            receipt.seasonYear == seasonYear &&
            (confirmed == null || confirmed.contains(receipt.id)))
          receipt,
    ];
  }

  Future<CoffeeReceiptSource> source({
    required String propertyId,
    required String plotId,
    required int seasonYear,
    required DateTime harvestDate,
  }) async {
    final session = _session();
    final baseUrl = await FarmApiClient.instance.baseUrl;
    _checkSession(session);
    if (baseUrl == null) throw StateError('Configure o endereço do PC gestor.');
    final client = FarmApiClient.forSession(
        baseUrl: baseUrl, token: session.$3, farmId: session.$2);
    final result = await client.get('/coffee/harvest-source', query: {
      'propertyId': propertyId,
      'plotId': plotId,
      'seasonYear': seasonYear,
      'harvestDate': _day(harvestDate),
    });
    _checkSession(session);
    final fieldLiters = (result['fieldLiters'] as num).toDouble();
    final revision = result['sourceRevision'] as String;
    if (!_validVolume(fieldLiters) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(revision)) {
      throw const FormatException(
          'O PC gestor devolveu uma colheita inválida.');
    }
    return CoffeeReceiptSource._(
      propertyId: propertyId,
      plotId: plotId,
      seasonYear: seasonYear,
      harvestDate: coffeeCivilDate(harvestDate),
      fieldLiters: fieldLiters,
      sourceRevision: revision,
      session: session,
    );
  }

  Future<void> save({
    required CoffeeReceiptSource source,
    required DateTime receivedDate,
    required double receivedLiters,
    String? notes,
  }) async {
    _checkSession(source._session);
    final observation = notes?.trim();
    if (!_validVolume(receivedLiters) ||
        coffeeCivilDate(receivedDate).isBefore(source.harvestDate) ||
        (observation != null && observation.length > 1000)) {
      throw const FormatException('Confira a data, o volume e a observação.');
    }
    final id = const Uuid().v5(
      Namespace.url.value,
      'agrogestor:$module:${jsonEncode([
            source.propertyId,
            source.plotId,
            source.seasonYear,
            _day(source.harvestDate),
          ])}',
    );
    await LocalWriteBatch.run(() async {
      _checkSession(source._session);
      final state = await LocalWriteBatch.current!.query(
        'local_records',
        columns: ['sync_state'],
        where: 'farm_id=? AND module=? AND record_id=?',
        whereArgs: [source._session.$2, module, id],
        limit: 1,
      );
      if (state.isNotEmpty && state.single['sync_state'] != 'error') {
        throw const FormatException('Já existe um recebimento para este dia.');
      }
      final previous =
          await _store.getAll(fromJson: CoffeeHarvestReceipt.fromJson);
      _checkSession(source._session);
      final receipt = CoffeeHarvestReceipt.fromJson({
        'id': id,
        'propertyId': source.propertyId,
        'plotId': source.plotId,
        'seasonYear': source.seasonYear,
        'harvestDate': _day(source.harvestDate),
        'receivedDate': _day(receivedDate),
        'receivedLiters': receivedLiters,
        'fieldLiters': source.fieldLiters,
        'sourceRevision': source.sourceRevision,
        if (observation?.isNotEmpty == true) 'notes': observation,
      });
      await _store.saveAll(
        records: [...previous.where((item) => item.id != id), receipt],
        previousRecords: previous,
        idOf: (item) => item.id,
        toJson: (item) => item.toJson(),
        fromJson: CoffeeHarvestReceipt.fromJson,
      );
    });
  }

  bool _validVolume(double value) =>
      value.isFinite && value >= 0 && value <= 1e12;

  (String, String, String) _session() {
    FarmAccessPolicy.requireCoffeeHarvest();
    if (FarmApiClient.standaloneLocalMode) {
      throw const FarmAccessDenied(
          'O recebimento exige conexão com o PC gestor.');
    }
    final auth = AuthService();
    final user = auth.currentUser!;
    return (user.id, user.farmId!, auth.accessToken!);
  }

  void _checkSession((String, String, String) previous) {
    if (_session() != previous) {
      throw const FarmAccessDenied(
          'A sessão mudou. Abra a colheita novamente.');
    }
  }
}
