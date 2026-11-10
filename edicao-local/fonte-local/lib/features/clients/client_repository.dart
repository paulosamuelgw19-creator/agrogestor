import '../sync/local_sync_collection_store.dart';
import 'client_record.dart';

class ClientRepository {
  static const _store = LocalSyncCollectionStore<RuralClient>(
    module: 'clients',
    legacyKey: 'campo_gestor_clients_v1',
  );

  Future<List<RuralClient>> getAll() =>
      _store.getAll(fromJson: RuralClient.fromJson);

  Future<void> saveAll(List<RuralClient> clients,
          {required List<RuralClient> previous}) =>
      _store.saveAll(
        records: clients,
        previousRecords: previous,
        fromJson: RuralClient.fromJson,
        idOf: (client) => client.id,
        toJson: (client) => client.toJson(),
      );
}
