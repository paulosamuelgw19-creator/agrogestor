import '../sync/local_sync_collection_store.dart';
import 'maintenance_record.dart';

class MaintenanceRepository {
  static const _store = LocalSyncCollectionStore<MaintenanceRecord>(
    module: 'maintenance',
    legacyKey: 'campo_gestor_maintenance_v1',
  );

  Future<List<MaintenanceRecord>> getAll() =>
      _store.getAll(fromJson: MaintenanceRecord.fromJson);

  Future<void> saveAll(List<MaintenanceRecord> records,
          {required List<MaintenanceRecord> previous}) =>
      _store.saveAll(
        records: records,
        previousRecords: previous,
        fromJson: MaintenanceRecord.fromJson,
        idOf: (record) => record.id,
        toJson: (record) => record.toJson(),
      );
}
