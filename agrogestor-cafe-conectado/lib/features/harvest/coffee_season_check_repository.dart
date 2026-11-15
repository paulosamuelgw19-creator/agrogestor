import '../auth/farm_access_policy.dart';
import '../properties/catalog_store.dart';
import '../properties/plot_notebook_repository.dart';
import '../sync/local_sync_collection_store.dart';
import '../sync/local_write_batch.dart';

class CoffeeSeasonCheck {
  const CoffeeSeasonCheck({
    required this.id,
    required this.propertyId,
    required this.plotId,
    required this.seasonYear,
    required this.liters,
  });

  static const module = 'coffeeSeasonChecks';
  static const legacyKey = 'campo_gestor_coffee_season_checks_v1';

  final String id, propertyId, plotId;
  final int seasonYear;
  final double liters;

  (String, String, int) get scope => (propertyId, plotId, seasonYear);

  factory CoffeeSeasonCheck.fromJson(Map<String, dynamic> json) =>
      CoffeeSeasonCheck(
        id: json['id'] as String,
        propertyId: json['propertyId'] as String,
        plotId: json['plotId'] as String,
        seasonYear: json['seasonYear'] as int,
        liters: (json['liters'] as num).toDouble(),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'propertyId': propertyId,
        'plotId': plotId,
        'seasonYear': seasonYear,
        'liters': liters,
      };

  void validate() {
    if ([id, propertyId, plotId]
            .any((key) => key.trim().isEmpty || key.length > 160) ||
        seasonYear < 1900 ||
        seasonYear > 9999 ||
        !liters.isFinite ||
        liters < 0 ||
        liters > 1e12) {
      throw const FormatException(
          'Confira a safra, o talhão e o subtotal em litros.');
    }
  }
}

class CoffeeSeasonCheckRepository {
  static const _store = LocalSyncCollectionStore<CoffeeSeasonCheck>(
    module: CoffeeSeasonCheck.module,
    legacyKey: CoffeeSeasonCheck.legacyKey,
  );

  Future<CoffeeSeasonCheck?> get({
    required String propertyId,
    required String plotId,
    required int seasonYear,
  }) async {
    FarmAccessPolicy.requireCoffeeManager();
    final checks = await _store.getAll(fromJson: CoffeeSeasonCheck.fromJson);
    return checks
        .where((check) => check.scope == (propertyId, plotId, seasonYear))
        .firstOrNull;
  }

  Future<void> save(CoffeeSeasonCheck check) async {
    FarmAccessPolicy.requireCoffeeManager();
    check.validate();
    final catalog = await CatalogStore.open();
    await LocalWriteBatch.run(() async {
      FarmAccessPolicy.requireCoffeeManager();
      await requireCoffeeCatalogLink(catalog.scope,
          propertyId: check.propertyId, plotId: check.plotId);
      final previous =
          await _store.getAll(fromJson: CoffeeSeasonCheck.fromJson);
      if (previous
          .any((item) => item.id == check.id && item.scope != check.scope)) {
        throw const FormatException(
            'Este subtotal pertence a outro talhão ou safra.');
      }
      final existing =
          previous.where((item) => item.scope == check.scope).firstOrNull;
      final updated = CoffeeSeasonCheck.fromJson({
        ...check.toJson(),
        'id': existing?.id ?? check.id,
      });
      await _store.saveAll(
        records: [
          ...previous.where((item) => item.scope != check.scope),
          updated
        ],
        previousRecords: previous,
        idOf: (item) => item.id,
        toJson: (item) => item.toJson(),
        fromJson: CoffeeSeasonCheck.fromJson,
      );
    });
  }
}
