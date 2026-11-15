import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../auth/farm_access_policy.dart';
import '../properties/catalog_store.dart';
import '../properties/plot_notebook_repository.dart';
import '../sync/local_sync_collection_store.dart';
import '../sync/local_write_batch.dart';
import 'coffee_finance_repository.dart';

class CoffeeFinanceCheck {
  const CoffeeFinanceCheck({
    required this.propertyId,
    required this.seasonYear,
    required this.stage,
    required this.category,
    required this.cents,
    this.plotId,
    this.start,
    this.end,
  });

  static const module = 'coffeeFinanceChecks';
  static const legacyKey = 'campo_gestor_coffee_finance_checks_v1';

  final String propertyId, category;
  final String? plotId, start, end;
  final int seasonYear, cents;
  final CoffeeFinanceStage stage;

  String get id => sha256
      .convert(utf8.encode(jsonEncode(
          [propertyId, plotId, seasonYear, start, end, stage.name, category])))
      .toString();

  bool matches(CoffeeFinanceEntry entry) =>
      !entry.isIncome &&
      entry.propertyId == propertyId &&
      (plotId == null || entry.plotId == plotId) &&
      entry.seasonYear == seasonYear &&
      entry.stage == stage &&
      entry.category == category &&
      (start == null || entry.date.toIso8601String().compareTo(start!) >= 0) &&
      (end == null || entry.date.toIso8601String().compareTo(end!) <= 0);

  Map<String, Object?> toJson() => {
        'id': id,
        'propertyId': propertyId,
        'plotId': plotId,
        'seasonYear': seasonYear,
        'start': start,
        'end': end,
        'stage': stage.name,
        'category': category,
        'cents': cents,
      };

  factory CoffeeFinanceCheck.fromJson(Map<String, dynamic> json) {
    final check = CoffeeFinanceCheck(
      propertyId: json['propertyId'] as String,
      plotId: json['plotId'] as String?,
      seasonYear: json['seasonYear'] as int,
      start: json['start'] as String?,
      end: json['end'] as String?,
      stage: CoffeeFinanceStage.values.byName(json['stage'] as String),
      category: json['category'] as String,
      cents: json['cents'] as int,
    );
    check.validate();
    if (check.id != json['id']) {
      throw const FormatException('A conferência pertence a outro filtro.');
    }
    return check;
  }

  void validate() {
    bool validDate(String? raw) =>
        raw == null ||
        (DateTime.tryParse(raw)?.toIso8601String() == raw &&
            raw.endsWith('T00:00:00.000'));
    if (propertyId.trim().isEmpty ||
        propertyId.length > 160 ||
        (plotId != null && (plotId!.trim().isEmpty || plotId!.length > 160)) ||
        seasonYear < 1900 ||
        seasonYear > 9999 ||
        category.trim().isEmpty ||
        category.length > 160 ||
        (start == null) != (end == null) ||
        !validDate(start) ||
        !validDate(end) ||
        (start != null && start!.compareTo(end!) > 0) ||
        cents < 0 ||
        cents > 1000000000000) {
      throw const FormatException('Confira o filtro e o valor anotado.');
    }
  }
}

class CoffeeFinanceCheckRepository {
  static const _store = LocalSyncCollectionStore<CoffeeFinanceCheck>(
      module: CoffeeFinanceCheck.module,
      legacyKey: CoffeeFinanceCheck.legacyKey);

  Future<CoffeeFinanceCheck?> get(CoffeeFinanceCheck scope) async {
    FarmAccessPolicy.requireCoffeeManager();
    return (await _store.getAll(fromJson: CoffeeFinanceCheck.fromJson))
        .where((item) => item.id == scope.id)
        .firstOrNull;
  }

  Future<void> save(CoffeeFinanceCheck check) async {
    FarmAccessPolicy.requireCoffeeManager();
    check.validate();
    final catalog = await CatalogStore.open();
    await LocalWriteBatch.run(() async {
      await requireCoffeeCatalogLink(catalog.scope,
          propertyId: check.propertyId, plotId: check.plotId);
      final previous =
          await _store.getAll(fromJson: CoffeeFinanceCheck.fromJson);
      await _store.saveAll(
        records: [...previous.where((item) => item.id != check.id), check],
        previousRecords: previous,
        idOf: (item) => item.id,
        toJson: (item) => item.toJson(),
        fromJson: CoffeeFinanceCheck.fromJson,
      );
    });
  }
}
