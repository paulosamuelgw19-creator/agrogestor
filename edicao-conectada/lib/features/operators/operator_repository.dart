import '../sync/local_sync_collection_store.dart';
import 'operator.dart';

class OperatorRepository {
  static const _store = LocalSyncCollectionStore<Operator>(
    module: 'operators',
    legacyKey: 'campo_gestor_operators_v1',
  );

  Future<List<Operator>> getAll() => _store.getAll(fromJson: Operator.fromJson);

  Future<void> saveAll(List<Operator> operators,
          {required List<Operator> previous}) =>
      _store.saveAll(
        records: operators,
        previousRecords: previous,
        fromJson: Operator.fromJson,
        idOf: (operator) => operator.id,
        toJson: (operator) => operator.toJson(),
      );
}
