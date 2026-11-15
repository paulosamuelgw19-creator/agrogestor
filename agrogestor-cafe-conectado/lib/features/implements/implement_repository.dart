import '../sync/local_sync_collection_store.dart';
import 'farm_implement.dart';

class ImplementRepository {
  static const _store = LocalSyncCollectionStore<FarmImplement>(
    module: 'implements',
    legacyKey: 'campo_gestor_implements_v1',
  );

  Future<List<FarmImplement>> getAll() =>
      _store.getAll(fromJson: FarmImplement.fromJson);

  Future<void> saveAll(List<FarmImplement> items,
          {required List<FarmImplement> previous}) =>
      _store.saveAll(
        records: items,
        previousRecords: previous,
        fromJson: FarmImplement.fromJson,
        idOf: (item) => item.id,
        toJson: (item) => item.toJson(),
      );
}
