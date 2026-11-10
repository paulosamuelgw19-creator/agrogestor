import '../sync/local_sync_collection_store.dart';
import 'fuel_record.dart';

class FuelRepository {
  static const _store = LocalSyncCollectionStore<FuelRecord>(
    module: 'fuel',
    legacyKey: 'campo_gestor_fuel_v1',
  );

  Future<List<FuelRecord>> getAll() =>
      _store.getAll(fromJson: FuelRecord.fromJson);

  Future<void> saveAll(List<FuelRecord> items,
          {required List<FuelRecord> previous}) =>
      _store.saveAll(
        records: items,
        previousRecords: previous,
        fromJson: FuelRecord.fromJson,
        idOf: (item) => item.id,
        toJson: (item) => item.toJson(),
      );
}
