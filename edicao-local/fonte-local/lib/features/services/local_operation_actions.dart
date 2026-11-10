import '../machines/machine.dart';
import '../implements/implement_repository.dart';
import '../implements/farm_implement.dart';
import '../machines/machine_repository.dart';
import '../products/product_record.dart';
import '../products/product_repository.dart';
import '../sync/local_write_batch.dart';
import 'farm_service.dart';
import 'service_repository.dart';

/// Local completion is one transaction: stock, consumption, service and meter.
class LocalOperationActions {
  static Future<void> finish(FarmService result, List<ProductUsage> usages) =>
      LocalWriteBatch.run(() async {
        final serviceRepo = ServiceRepository();
        final services = await serviceRepo.getAll();
        final original = services.where((s) => s.id == result.id).firstOrNull;
        if (original == null || original.isFinished || original.isCancelled) {
          throw const FormatException(
              'A operacao nao esta mais em andamento. O consumo nao foi repetido.');
        }
        final end = result.endMeter;
        if (end == null || !end.isFinite || end < original.startMeter) {
          throw const FormatException('Confira o horimetro final.');
        }
        final machineRepo = MachineRepository();
        final machines = await machineRepo.getAll();
        final machine =
            machines.where((m) => m.id == original.machineId).firstOrNull;
        if (machine == null || end < machine.hourMeter) {
          throw const FormatException(
              'Confira o cadastro e o horimetro atual da maquina.');
        }
        final productRepo = ProductRepository();
        final products = await productRepo.getProducts();
        final quantities = <String, double>{};
        for (final usage in usages) {
          final product =
              products.where((p) => p.id == usage.productId).firstOrNull;
          if (usage.serviceId != original.id ||
              product == null ||
              product.unit != usage.unit ||
              !usage.quantity.isFinite ||
              usage.quantity <= 0) {
            throw const FormatException(
                'Confira os insumos, unidades e quantidades.');
          }
          quantities.update(product.id, (q) => q + usage.quantity,
              ifAbsent: () => usage.quantity);
        }
        for (final product in products) {
          if (product.quantity < (quantities[product.id] ?? 0)) {
            throw const FormatException(
                'Estoque insuficiente. Nenhum lancamento foi salvo.');
          }
        }
        if (usages.isNotEmpty) {
          await productRepo.saveProducts(
              products
                  .map((p) => p.copyWith(
                      quantity: p.quantity - (quantities[p.id] ?? 0)))
                  .toList(),
              previous: products);
          final previous = await productRepo.getUsage();
          await productRepo
              .saveUsage([...usages, ...previous], previous: previous);
        }
        if (original.implementId.isNotEmpty) {
          final repo = ImplementRepository();
          final all = await repo.getAll();
          final item =
              all.where((i) => i.id == original.implementId).firstOrNull;
          if (item == null) {
            throw const FormatException(
                'O implemento vinculado não foi encontrado. Nada foi salvo.');
          }
          if (item.hours != null) {
            await repo.saveAll(
                all
                    .map((i) => i.id == item.id
                        ? FarmImplement.fromJson({
                            ...i.toJson(),
                            'hours': i.hours! + end - original.startMeter
                          })
                        : i)
                    .toList(),
                previous: all);
          }
        }
        final finished = original.finishWith(
            endMeter: end,
            fuelLiters: result.fuelLiters,
            areaHectares: result.areaHectares,
            notes: result.notes);
        await serviceRepo.saveAll(
            services.map((s) => s.id == original.id ? finished : s).toList(),
            previous: services);
        await machineRepo.saveAll(
            machines
                .map((m) => m.id == original.machineId
                    ? m.copyWith(
                        hourMeter: end,
                        status: m.status == MachineStatus.emOperacao
                            ? MachineStatus.disponivel
                            : m.status)
                    : m)
                .toList(),
            previous: machines);
      });
  static Future<void> cancel(String id, String reason) =>
      LocalWriteBatch.run(() async {
        if (reason.trim().isEmpty || reason.length > 500) {
          throw const FormatException('Informe o motivo do cancelamento.');
        }
        final repo = ServiceRepository();
        final records = await repo.getAll();
        final current = records.where((s) => s.id == id).firstOrNull;
        if (current == null || current.isFinished || current.isCancelled) {
          throw const FormatException(
              'A operacao ja foi encerrada. Atualize a tela.');
        }
        final machinesRepo = MachineRepository();
        final machines = await machinesRepo.getAll();
        if (!machines.any((m) => m.id == current.machineId)) {
          throw const FormatException(
              'A maquina da operacao nao foi encontrada.');
        }
        await repo.saveAll(
            records
                .map((s) => s.id == id ? s.cancel(reason.trim()) : s)
                .toList(),
            previous: records);
        await machinesRepo.saveAll(
            machines
                .map((m) => m.id == current.machineId &&
                        m.status == MachineStatus.emOperacao
                    ? m.copyWith(status: MachineStatus.disponivel)
                    : m)
                .toList(),
            previous: machines);
      });
}
