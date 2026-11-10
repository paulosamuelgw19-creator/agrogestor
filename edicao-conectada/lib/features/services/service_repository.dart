import '../sync/local_sync_collection_store.dart';
import 'farm_service.dart';

class ServiceRepository {
  static const _store = LocalSyncCollectionStore<FarmService>(
    module: 'services',
    legacyKey: 'campo_gestor_services_v1',
  );

  Future<List<FarmService>> getAll() =>
      _store.getAll(fromJson: FarmService.fromJson);

  Future<void> saveAll(List<FarmService> items,
          {required List<FarmService> previous}) =>
      _store.saveAll(
        records: items,
        previousRecords: previous,
        fromJson: FarmService.fromJson,
        idOf: (item) => item.id,
        toJson: (item) => item.toJson(),
      );
}
