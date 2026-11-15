import 'package:flutter/material.dart' show DateUtils;

import '../machines/machine.dart';
import '../implements/implement_repository.dart';
import '../implements/farm_implement.dart';
import '../machines/machine_repository.dart';
import '../operators/operator_repository.dart';
import '../products/product_record.dart';
import '../products/product_repository.dart';
import '../sync/local_write_batch.dart';
import 'coffee_input_plan.dart';
import 'farm_service.dart';
import 'service_repository.dart';

/// Local completion is one transaction: stock, consumption, service and meter.
class LocalOperationActions {
  /// A null balance means the requested consumption cannot be recorded.
  static double? remainingStock(double available, double used) {
    if (!available.isFinite || !used.isFinite || available < 0 || used < 0) {
      return null;
    }
    if (used == 0) return available;

    final balance = available - used;
    // Allow only the rounding error from double arithmetic near equal values.
    final rounding = available * 8.881784197001252e-16;
    if (balance.abs() <= rounding) return 0;
    return balance < 0 ? null : balance;
  }

  static double sumStockQuantities(Iterable<double> quantities) {
    var sum = 0.0;
    var compensation = 0.0;
    for (final quantity in quantities) {
      final adjusted = quantity - compensation;
      final next = sum + adjusted;
      compensation = (next - sum) - adjusted;
      sum = next;
    }
    return sum;
  }

  /// Call within the transaction that saves the new operation.
  static Future<void> validatePlannedInputs(FarmService service) async {
    if (service.plannedInputs.isEmpty) return;
    final products = {
      for (final product in await ProductRepository().getProducts())
        product.id: product,
    };
    for (final input in service.plannedInputs) {
      final error = input.validationError;
      if (error != null) throw FormatException(error);
      final product = products[input.productId];
      if (product == null || product.unit != input.stockUnit) {
        throw const FormatException(
          'Um insumo do planejamento mudou no estoque. Selecione-o novamente.',
        );
      }
    }
  }

  /// Call within the transaction that starts a manual operation.
  static Future<void> validateManualWorkers(FarmService service) async {
    validateServiceManualWorkers(service);
    if (service.manualWorkers.isEmpty) return;
    final operators = await OperatorRepository().getAll();
    for (final worker in service.manualWorkers) {
      if (!operators.any((item) =>
          item.id == worker.workerId &&
          item.active &&
          item.name.trim() == worker.workerName.trim())) {
        throw const FormatException(
            'Selecione as pessoas cadastradas novamente.');
      }
    }
  }

  static Future<void> finish(FarmService result, List<ProductUsage> usages,
          {ServiceDay? day}) =>
      LocalWriteBatch.run(() async {
        final serviceRepo = ServiceRepository();
        final services = await serviceRepo.getAll();
        final original = services.where((s) => s.id == result.id).firstOrNull;
        if (original == null ||
            original.isFinished ||
            original.isCancelled ||
            original.isPaused ||
            result.days.length != original.days.length ||
            result.activeSince != original.activeSince) {
          throw const FormatException(
              'A operacao nao esta mais em andamento. O consumo nao foi repetido.');
        }
        final requestedDay = day ??
            ServiceDay(
                date: result.endedAt ?? DateTime.now(),
                startMeter: original.activeStartMeter,
                endMeter: result.endMeter,
                areaHectares: result.areaHectares,
                fuelLiters: result.fuelLiters);
        _checkDay(original, requestedDay);
        final lastDay = await _withDayWorkers(original, requestedDay);
        if (day == null && original.days.isNotEmpty) {
          throw const FormatException('Informe os dados da última etapa.');
        }
        final productRepo = ProductRepository();
        final products = await productRepo.getProducts();
        final productsById = {
          for (final product in products) product.id: product
        };
        final quantities = <String, List<double>>{};
        for (final usage in usages) {
          final product = productsById[usage.productId];
          if (usage.serviceId != original.id ||
              product == null ||
              product.unit != usage.unit ||
              !usage.quantity.isFinite ||
              usage.quantity <= 0) {
            throw const FormatException(
                'Confira os insumos, unidades e quantidades.');
          }
          quantities.putIfAbsent(product.id, () => []).add(usage.quantity);
        }
        final confirmed = quantities.map(
          (id, amounts) => MapEntry(id, sumStockQuantities(amounts)),
        );
        _checkAppliedSprayInputs(
            result.appliedSprayInputs, productsById, confirmed);
        final balances = <String, double>{};
        for (final product in products) {
          final used = confirmed[product.id];
          if (used == null) continue;
          final balance = remainingStock(product.quantity, used);
          if (balance == null) {
            throw const FormatException(
                'Estoque insuficiente. Nenhum lancamento foi salvo.');
          }
          balances[product.id] = balance;
        }
        if (usages.isNotEmpty) {
          await productRepo.saveProducts(
              products
                  .map((p) => balances.containsKey(p.id)
                      ? p.copyWith(quantity: balances[p.id])
                      : p)
                  .toList(),
              previous: products);
          final previous = await productRepo.getUsage();
          await productRepo
              .saveUsage([...usages, ...previous], previous: previous);
        }
        await _recordEquipment(original, lastDay, finished: true);
        final finished = original
            .copyWith(
              plotCompleted: result.plotCompleted,
              appliedSprayInputs: result.appliedSprayInputs,
            )
            .finishWith(
                endMeter: lastDay.endMeter,
                fuelLiters: lastDay.fuelLiters,
                areaHectares: lastDay.areaHectares,
                notes: result.notes,
                day: day != null || lastDay.manualWorkers.isNotEmpty
                    ? lastDay
                    : null);
        await serviceRepo.saveAll(
            services.map((s) => s.id == original.id ? finished : s).toList(),
            previous: services);
      });

  static void _checkAppliedSprayInputs(
    List<CoffeeInputPlan> inputs,
    Map<String, FarmProduct> products,
    Map<String, double> confirmed,
  ) {
    final quantities = <String, List<double>>{};
    for (final input in inputs) {
      if (input.kind != CoffeeInputKind.spray) {
        throw const FormatException(
            'Informe apenas cargas de pulverização aplicadas.');
      }
      final error = input.validationError;
      if (error != null) throw FormatException(error);
      if (products[input.productId]?.unit != input.stockUnit) {
        throw const FormatException(
          'Um produto da pulverização mudou no estoque. Selecione-o novamente.',
        );
      }
      quantities
          .putIfAbsent(input.productId, () => [])
          .add(input.quantityInStockUnit!);
    }
    for (final entry in quantities.entries) {
      final applied = sumStockQuantities(entry.value);
      if (remainingStock(confirmed[entry.key] ?? 0, applied) == null) {
        throw FormatException(
          'Inclua as cargas de ${products[entry.key]!.name} no consumo confirmado.',
        );
      }
    }
  }

  static Future<void> pause(FarmService expected, ServiceDay day) =>
      _changeStage(expected, (current) async {
        _checkDay(current, day);
        final recorded = await _withDayWorkers(current, day);
        await _recordEquipment(current, recorded, finished: false);
        return current
            .copyWith(isPaused: true, days: [...current.days, recorded]);
      }, paused: false);

  static Future<void> resume(
    FarmService expected,
    DateTime date, {
    List<ServiceWorkerRate>? manualWorkers,
  }) =>
      _changeStage(expected, (current) async {
        if (DateUtils.dateOnly(date)
                .isBefore(DateUtils.dateOnly(current.days.last.date)) ||
            DateUtils.dateOnly(date)
                .isAfter(DateUtils.dateOnly(DateTime.now()))) {
          throw const FormatException('Confira a data de retomada.');
        }
        if (current.isManual) {
          final refreshed =
              manualWorkers ?? await _workersOnResume(current, date);
          final workers = await _resolveDayWorkers(
            current,
            date,
            refreshed,
            explicit: manualWorkers != null,
          );
          return current.copyWith(
            isPaused: false,
            resumedAt: date,
            manualWorkers: workers,
          );
        }
        if (manualWorkers?.isNotEmpty == true) {
          throw const FormatException(
              'A diária por pessoa é exclusiva do serviço manual.');
        }
        final machine = (await MachineRepository().getAll())
            .where((m) => m.id == current.machineId)
            .firstOrNull;
        if (machine == null ||
            (current.tracksMeter &&
                machine.hourMeter < current.days.last.endMeter!) ||
            ![MachineStatus.disponivel, MachineStatus.emOperacao]
                .contains(machine.status)) {
          throw const FormatException(
              'Confira a disponibilidade e o horímetro da máquina.');
        }
        return current.copyWith(
            isPaused: false,
            resumedAt: date,
            resumedMeter: current.tracksMeter ? machine.hourMeter : null);
      }, paused: true);

  static Future<ServiceDay> _withDayWorkers(
      FarmService service, ServiceDay day) async {
    if (!service.isManual) {
      if (day.manualWorkers.isNotEmpty) {
        throw const FormatException(
            'A diária por pessoa é exclusiva do serviço manual.');
      }
      return day;
    }
    final explicit = day.manualWorkers.isNotEmpty;
    final selected = explicit ? day.manualWorkers : service.manualWorkers;
    if (selected.isEmpty) return day;
    return day.withManualWorkers(await _resolveDayWorkers(
      service,
      day.date,
      selected,
      explicit: explicit,
    ));
  }

  static Future<List<ServiceWorkerRate>> _workersOnResume(
    FarmService service,
    DateTime date,
  ) async {
    if (service.manualWorkers.isEmpty ||
        DateUtils.isSameDay(date, service.days.last.date)) {
      return service.manualWorkers;
    }
    final current = {
      for (final operator in await OperatorRepository().getAll())
        operator.id: operator,
    };
    return [
      for (final worker in service.manualWorkers)
        if (current[worker.workerId] case final operator?)
          ServiceWorkerRate(
            workerId: worker.workerId,
            workerName: operator.name,
            dailyRateCents: operator.dailyRateCents,
          )
        else
          worker,
    ];
  }

  static Future<List<ServiceWorkerRate>> _resolveDayWorkers(
    FarmService service,
    DateTime date,
    List<ServiceWorkerRate> selected, {
    required bool explicit,
  }) async {
    validateManualWorkerRates(selected);
    if (selected.isEmpty && service.manualWorkers.isNotEmpty) {
      throw const FormatException(
          'Selecione ao menos uma pessoa para esta jornada.');
    }
    final historical = <String, ServiceWorkerRate>{
      for (final day in service.days)
        if (DateUtils.isSameDay(day.date, date))
          for (final worker in day.manualWorkers) worker.workerId: worker,
    };
    final active = {
      for (final worker in service.manualWorkers) worker.workerId: worker,
    };
    final needsLookup = selected.any(
      (worker) =>
          !historical.containsKey(worker.workerId) &&
          !active.containsKey(worker.workerId),
    );
    final names = {
      if (needsLookup)
        for (final operator in await OperatorRepository().getAll())
          if (operator.active) operator.id: operator.name,
    };
    final result = <ServiceWorkerRate>[];
    for (final worker in selected) {
      final recorded = historical[worker.workerId];
      if (recorded != null) {
        if (explicit && recorded.dailyRateCents != worker.dailyRateCents) {
          throw const FormatException(
              'Uma diária já foi registrada com outro valor neste dia.');
        }
        result.add(recorded);
        continue;
      }
      final name =
          active[worker.workerId]?.workerName ?? names[worker.workerId];
      if (name == null) {
        throw const FormatException('Selecione uma pessoa cadastrada.');
      }
      result.add(ServiceWorkerRate(
        workerId: worker.workerId,
        workerName: name,
        dailyRateCents: worker.dailyRateCents,
      ));
    }
    return result;
  }

  static Future<void> _changeStage(FarmService expected,
          Future<FarmService> Function(FarmService) change,
          {required bool paused}) =>
      LocalWriteBatch.run(() async {
        final repo = ServiceRepository();
        final all = await repo.getAll();
        final current = all.where((s) => s.id == expected.id).firstOrNull;
        if (current == null ||
            current.isFinished ||
            current.isCancelled ||
            current.isPaused != paused ||
            current.days.length != expected.days.length ||
            current.activeSince != expected.activeSince) {
          throw const FormatException('A operação mudou. Abra novamente.');
        }
        final updated = await change(current);
        await repo.saveAll(
            all.map((s) => s.id == current.id ? updated : s).toList(),
            previous: all);
      });

  static void _checkDay(FarmService current, ServiceDay day) {
    if (DateUtils.dateOnly(day.date)
            .isBefore(DateUtils.dateOnly(current.activeSince)) ||
        DateUtils.dateOnly(day.date)
            .isAfter(DateUtils.dateOnly(DateTime.now())) ||
        day.startMeter != current.activeStartMeter ||
        (current.tracksMeter &&
            (day.endMeter == null ||
                !day.endMeter!.isFinite ||
                day.endMeter! < current.activeStartMeter!)) ||
        (!current.tracksMeter && day.endMeter != null) ||
        (current.isManual && day.fuelLiters != null) ||
        [day.areaHectares, day.fuelLiters]
            .any((v) => v != null && (!v.isFinite || v < 0))) {
      throw const FormatException(
          'Confira a data, a área, o combustível e o horímetro informados.');
    }
  }

  static Future<void> _recordEquipment(FarmService original, ServiceDay day,
      {required bool finished}) async {
    if (original.isManual) return;
    final end = day.endMeter;
    final machineRepo = MachineRepository();
    final machines = await machineRepo.getAll();
    final machine =
        machines.where((m) => m.id == original.machineId).firstOrNull;
    if (machine == null || (end != null && end < machine.hourMeter)) {
      throw const FormatException(
          'Confira o cadastro e o horímetro atual da máquina.');
    }
    if (original.implementId.isNotEmpty) {
      final repo = ImplementRepository();
      final all = await repo.getAll();
      final item = all.where((i) => i.id == original.implementId).firstOrNull;
      if (item == null) {
        throw const FormatException(
            'O implemento vinculado não foi encontrado. Nada foi salvo.');
      }
      if (item.hours != null && day.hours != null) {
        await repo.saveAll(
            all
                .map((i) => i.id == item.id
                    ? FarmImplement.fromJson(
                        {...i.toJson(), 'hours': i.hours! + day.hours!})
                    : i)
                .toList(),
            previous: all);
      }
    }
    await machineRepo.saveAll(
        machines
            .map((m) => m.id == original.machineId
                ? m.copyWith(
                    hourMeter: end,
                    status: finished && m.status == MachineStatus.emOperacao
                        ? MachineStatus.disponivel
                        : m.status)
                : m)
            .toList(),
        previous: machines);
  }

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
        if (!current.isManual &&
            !machines.any((m) => m.id == current.machineId)) {
          throw const FormatException(
              'A maquina da operacao nao foi encontrada.');
        }
        await repo.saveAll(
            records
                .map((s) => s.id == id ? s.cancel(reason.trim()) : s)
                .toList(),
            previous: records);
        if (!current.isManual) {
          await machinesRepo.saveAll(
              machines
                  .map((m) => m.id == current.machineId &&
                          m.status == MachineStatus.emOperacao
                      ? m.copyWith(status: MachineStatus.disponivel)
                      : m)
                  .toList(),
              previous: machines);
        }
      });
}
