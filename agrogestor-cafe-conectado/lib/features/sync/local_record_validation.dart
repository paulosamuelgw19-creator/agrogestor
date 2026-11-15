import '../analyses/coffee_analysis_repository.dart';
import '../coffee_finance/coffee_finance_repository.dart';
import '../coffee_finance/coffee_finance_check_repository.dart';
import '../harvest/coffee_harvest_repository.dart';
import '../harvest/coffee_season_check_repository.dart';
import '../machines/machine.dart';
import '../maintenance/maintenance_record.dart';
import '../processing/coffee_processing_repository.dart';
import '../properties/plot_notebook_repository.dart';
import '../services/coffee_input_plan.dart';
import '../services/coffee_manual_labor_repository.dart';
import '../services/farm_service.dart';
import '../tools/coffee_tools_repository.dart';

void validateLocalRecord(String module, Map<String, dynamic> data) {
  void finite(Object? value) {
    if (value is num && !value.isFinite) {
      throw const FormatException('Informe numeros finitos e validos.');
    }
    if (value is Map) {
      for (final item in value.values) {
        finite(item);
      }
    }
    if (value is List) {
      for (final item in value) {
        finite(item);
      }
    }
  }

  finite(data);
  if (data['id'] is! String ||
      (data['id'] as String).isEmpty ||
      (data['id'] as String).length > 160) {
    throw const FormatException('Identificador de cadastro invalido.');
  }
  for (final key in switch (module) {
    'machines' => [
        'hourMeter',
        'tankCapacity',
        'averageConsumption',
        'acquisitionValue',
      ],
    'services' => ['startMeter', 'endMeter', 'fuelLiters', 'areaHectares'],
    'products' => ['quantity'],
    'productUsage' => ['quantity'],
    'fuel' => ['hourMeter', 'liters', 'pricePerLiter'],
    'maintenance' => ['hourMeter', 'cost', 'intervalHours'],
    'implements' => ['hours'],
    _ => <String>[],
  }) {
    final value = data[key];
    if (value != null && (value is! num || value < 0)) {
      throw FormatException('Valor invalido no campo $key.');
    }
  }
  if (module == 'machines' &&
      data['status'] != null &&
      !MachineStatus.values.any((s) => s.name == data['status'])) {
    throw const FormatException('Status da maquina invalido.');
  }
  if ((module == 'fuel' && (data['liters'] as num) <= 0) ||
      (module == 'productUsage' && (data['quantity'] as num) <= 0)) {
    throw const FormatException('A quantidade precisa ser maior que zero.');
  }
  switch (module) {
    case 'plotNotebook':
      PlotNote.fromJson(data).validate();
    case 'coffeeHarvestEntries':
      CoffeeHarvestEntry.fromJson(data).validate();
    case 'coffeeHarvestPayments':
      CoffeeHarvestPayment.fromJson(data).validate();
    case 'coffeePlotProduction':
      CoffeePlotProduction.fromJson(data).validate();
    case 'coffeeAnalyses':
      CoffeeAnalysis.fromJson(data).validate();
    case 'coffeeProcessingLots':
      CoffeeLot.fromJson(data).validate();
    case CoffeeSeasonCheck.module:
      CoffeeSeasonCheck.fromJson(data).validate();
    case CoffeeFinanceCheck.module:
      CoffeeFinanceCheck.fromJson(data);
    case CoffeeFinanceRepository.entriesModule:
      CoffeeFinanceEntry.fromJson(data).validate();
    case CoffeeFinanceRepository.receiptsModule:
      CoffeeSaleReceipt.fromJson(data).validate();
    case CoffeeToolsRepository.module:
      CoffeeTool.fromJson(data).validate();
    case CoffeeManualLaborRepository.module:
      CoffeeManualLaborPayment.fromJson(data).validate();
    case 'operators':
      final dailyRate = data['dailyRateCents'];
      if (dailyRate != null &&
          (dailyRate is! int || dailyRate < 0 || dailyRate > 1000000000000)) {
        throw const FormatException('Informe uma diária válida em centavos.');
      }
      _validatePhotoPath(data);
    case 'products':
      _validatePhotoPath(data);
    case 'maintenance':
      final maintenance = MaintenanceRecord.fromJson(data);
      final dueDate = maintenance.nextDueDate;
      if (dueDate == null && maintenance.intervalHours == null) {
        throw const FormatException(
            'Informe a próxima revisão por data ou horímetro.');
      }
      final performed = maintenance.date;
      if (dueDate != null &&
          DateTime(dueDate.year, dueDate.month, dueDate.day).isBefore(
            DateTime(performed.year, performed.month, performed.day),
          )) {
        throw const FormatException(
            'A próxima revisão deve ser na data do serviço ou depois.');
      }
  }
  if (module == 'services') {
    final service = FarmService.fromJson(data);
    validateServiceManualWorkers(service);
    final application = service.applicationNumber;
    if ((application != null && (application < 1 || application > 9999)) ||
        service.workSection.length > 120 ||
        service.workObjective.length > 240) {
      throw const FormatException(
          'Confira a parcela, o trecho e o objetivo do serviço.');
    }
    if (service.appliedSprayInputs.isNotEmpty &&
        (!service.isFinished ||
            service.appliedSprayInputs
                .any((input) => input.kind != CoffeeInputKind.spray))) {
      throw const FormatException(
        'Cargas aplicadas devem pertencer a uma operação concluída de pulverização.',
      );
    }
    for (final input in [
      ...service.plannedInputs,
      ...service.appliedSprayInputs
    ]) {
      final error = input.validationError;
      if (error != null) throw FormatException(error);
    }
    final start = service.startMeter;
    final end = service.endMeter;
    final unexpectedMeter =
        start != null || end != null || service.resumedMeter != null;
    if (service.isManual
        ? unexpectedMeter ||
            service.withoutMeter ||
            service.machineId.isNotEmpty ||
            service.implementId.isNotEmpty ||
            service.fuelLiters != null ||
            (service.people ?? 0) < 1
        : service.withoutMeter
            ? unexpectedMeter
            : start == null ||
                (end != null && end < start) ||
                (service.isFinished && end == null)) {
      throw const FormatException(
        'Confira a modalidade, as pessoas e os horímetros da operação.',
      );
    }
    if (service.isCancelled &&
        (service.isFinished || service.cancellationReason.trim().isEmpty)) {
      throw const FormatException(
        'Confira o motivo e o estado do cancelamento.',
      );
    }
    if (service.isPaused &&
        (service.days.isEmpty || service.isFinished || service.isCancelled)) {
      throw const FormatException('O estado da pausa é inválido.');
    }
    if (service.plotCompleted && !service.isFinished) {
      throw const FormatException('Conclua a operação para encerrar o talhão.');
    }
    var previousDate = service.startedAt;
    var previousMeter = start;
    for (final day in service.days) {
      final date = day.date;
      if (DateTime(date.year, date.month, date.day).isBefore(
            DateTime(previousDate.year, previousDate.month, previousDate.day),
          ) ||
          [
            day.areaHectares,
            day.fuelLiters,
          ].any((value) => value != null && value < 0) ||
          (service.isManual && day.fuelLiters != null) ||
          (!service.tracksMeter
              ? day.startMeter != null || day.endMeter != null
              : day.startMeter == null ||
                  day.endMeter == null ||
                  day.startMeter! < previousMeter! ||
                  day.endMeter! < day.startMeter!)) {
        throw const FormatException('Confira os dados das etapas da operação.');
      }
      previousDate = date;
      previousMeter = day.endMeter;
    }
    if (service.tracksMeter &&
        service.days.isNotEmpty &&
        ((service.isFinished && end != previousMeter) ||
            (!service.isFinished &&
                !service.isPaused &&
                !service.isCancelled &&
                (service.resumedMeter == null ||
                    service.resumedMeter! < previousMeter!)))) {
      throw const FormatException('A última leitura da operação é inválida.');
    }
  }
}

void _validatePhotoPath(Map<String, dynamic> data) {
  final photo = data['photoPath'];
  if (photo != null && photo is! String) {
    throw const FormatException('A referência da foto é inválida.');
  }
}
