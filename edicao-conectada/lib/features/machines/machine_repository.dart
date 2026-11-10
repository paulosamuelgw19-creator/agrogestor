import 'machine.dart';
import '../sync/local_sync_collection_store.dart';

class MachineRepository {
  static const _store = LocalSyncCollectionStore<Machine>(
    module: 'machines',
    legacyKey: 'campo_gestor_machines_v1',
  );

  Future<List<Machine>> getAll() => _store.getAll(
        fromJson: Machine.fromJson,
        fallback: () => _sampleMachines,
      );

  Future<void> saveAll(List<Machine> machines,
          {required List<Machine> previous}) =>
      _store.saveAll(
        records: machines,
        previousRecords: previous,
        fromJson: Machine.fromJson,
        idOf: (machine) => machine.id,
        toJson: (machine) => machine.toJson(),
      );

  static const _sampleMachines = <Machine>[
    Machine(
      id: 'sample-1',
      name: 'Trator principal',
      brand: 'John Deere',
      model: '6110J',
      year: 2022,
      hourMeter: 1284.5,
      fuelType: 'Diesel',
      status: MachineStatus.emOperacao,
    ),
    Machine(
      id: 'sample-2',
      name: 'Trator de apoio',
      brand: 'Massey Ferguson',
      model: '4275',
      year: 2020,
      hourMeter: 932,
      fuelType: 'Diesel',
      status: MachineStatus.disponivel,
    ),
    Machine(
      id: 'sample-3',
      name: 'Pulverizador',
      brand: 'Jacto',
      model: 'Uniport 2030',
      year: 2019,
      hourMeter: 2140,
      fuelType: 'Diesel',
      status: MachineStatus.emManutencao,
    ),
  ];
}
