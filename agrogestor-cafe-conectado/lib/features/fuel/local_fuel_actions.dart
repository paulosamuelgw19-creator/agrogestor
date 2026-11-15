import 'dart:convert';
import '../machines/machine_repository.dart';
import '../sync/local_write_batch.dart';
import 'fuel_record.dart';
import 'fuel_repository.dart';

class LocalFuelActions {
  static Future<void> add(FuelRecord record) => LocalWriteBatch.run(() async {
        final repo = FuelRepository();
        final previous = await repo.getAll();
        final same = previous.where((r) => r.id == record.id).firstOrNull;
        if (same != null) {
          if (jsonEncode(same.toJson()) != jsonEncode(record.toJson())) {
            throw const FormatException(
                'Este abastecimento ja possui outros dados.');
          }
          return;
        }
        final machineRepo = MachineRepository();
        final machines = await machineRepo.getAll();
        final machine =
            machines.where((m) => m.id == record.machineId).firstOrNull;
        if (machine == null ||
            !record.hourMeter.isFinite ||
            record.hourMeter < machine.hourMeter) {
          throw const FormatException(
              'Confira a maquina e o horimetro. A leitura nao pode ser menor que a ultima registrada.');
        }
        await repo.saveAll([record, ...previous], previous: previous);
        await machineRepo.saveAll(
            machines
                .map((m) => m.id == record.machineId
                    ? m.copyWith(hourMeter: record.hourMeter)
                    : m)
                .toList(),
            previous: machines);
      });
}
