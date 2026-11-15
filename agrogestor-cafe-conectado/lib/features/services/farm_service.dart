import 'coffee_input_plan.dart';

class ServiceWorkerRate {
  const ServiceWorkerRate({
    required this.workerId,
    required this.workerName,
    this.dailyRateCents,
  });

  final String workerId, workerName;
  final int? dailyRateCents;

  Map<String, Object?> toJson() => {
        'workerId': workerId,
        'workerName': workerName.trim(),
        if (dailyRateCents != null) 'dailyRateCents': dailyRateCents,
      };

  factory ServiceWorkerRate.fromJson(Map<String, dynamic> json) =>
      ServiceWorkerRate(
        workerId: json['workerId'] as String,
        workerName: json['workerName'] as String,
        dailyRateCents: json['dailyRateCents'] as int?,
      );
}

void validateManualWorkerRates(List<ServiceWorkerRate> workers) {
  final ids = <String>{};
  for (final worker in workers) {
    final cents = worker.dailyRateCents;
    if (worker.workerId.trim().isEmpty ||
        worker.workerId.length > 160 ||
        worker.workerName.trim().isEmpty ||
        worker.workerName.length > 300 ||
        (cents != null && (cents < 0 || cents > 1000000000000)) ||
        !ids.add(worker.workerId)) {
      throw const FormatException(
          'Confira as pessoas e os valores das diárias.');
    }
  }
}

void validateServiceManualWorkers(FarmService service) {
  final active = service.manualWorkers;
  if (!service.isManual) {
    if (active.isNotEmpty ||
        service.days.any((day) => day.manualWorkers.isNotEmpty)) {
      throw const FormatException(
          'A diária por pessoa é exclusiva do serviço manual.');
    }
    return;
  }
  validateManualWorkerRates(active);
  if (active.isNotEmpty && service.people != active.length) {
    throw const FormatException(
        'Confira a quantidade de pessoas selecionadas.');
  }
  final ratesByDay = <(DateTime, String), int?>{};
  for (final day in service.days) {
    validateManualWorkerRates(day.manualWorkers);
    final date = DateTime(day.date.year, day.date.month, day.date.day);
    for (final worker in day.manualWorkers) {
      final key = (date, worker.workerId);
      if (ratesByDay.containsKey(key) &&
          ratesByDay[key] != worker.dailyRateCents) {
        throw const FormatException(
            'A diária já foi registrada com outro valor neste dia.');
      }
      ratesByDay[key] = worker.dailyRateCents;
    }
  }
}

List<ServiceWorkerRate> _readManualWorkers(Object? json) => List.unmodifiable(
      (json as List? ?? const []).map((item) =>
          ServiceWorkerRate.fromJson(Map<String, dynamic>.from(item as Map))),
    );

class ServiceDay {
  const ServiceDay({
    required this.date,
    this.startMeter,
    this.endMeter,
    this.areaHectares,
    this.fuelLiters,
    this.manualWorkers = const [],
  });

  final DateTime date;
  final double? startMeter, endMeter, areaHectares, fuelLiters;
  final List<ServiceWorkerRate> manualWorkers;

  double? get hours =>
      startMeter == null || endMeter == null ? null : endMeter! - startMeter!;

  Map<String, Object?> toJson() => {
        'date': date.toIso8601String(),
        'startMeter': startMeter,
        'endMeter': endMeter,
        'areaHectares': areaHectares,
        'fuelLiters': fuelLiters,
        if (manualWorkers.isNotEmpty)
          'manualWorkers': [
            for (final worker in manualWorkers) worker.toJson()
          ],
      };

  factory ServiceDay.fromJson(Map<String, dynamic> json) => ServiceDay(
        date: DateTime.parse(json['date'] as String),
        startMeter: (json['startMeter'] as num?)?.toDouble(),
        endMeter: (json['endMeter'] as num?)?.toDouble(),
        areaHectares: (json['areaHectares'] as num?)?.toDouble(),
        fuelLiters: (json['fuelLiters'] as num?)?.toDouble(),
        manualWorkers: _readManualWorkers(json['manualWorkers']),
      );

  ServiceDay withManualWorkers(List<ServiceWorkerRate> workers) => ServiceDay(
        date: date,
        startMeter: startMeter,
        endMeter: endMeter,
        areaHectares: areaHectares,
        fuelLiters: fuelLiters,
        manualWorkers: workers,
      );
}

class FarmService {
  const FarmService({
    required this.id,
    required this.machineId,
    required this.machineName,
    required this.operatorName,
    required this.customer,
    required this.property,
    this.clientId = '',
    this.propertyId = '',
    this.fieldName = '',
    this.fieldId = '',
    required this.jobType,
    this.applicationNumber,
    this.workSection = '',
    this.workObjective = '',
    required this.startedAt,
    required this.startMeter,
    this.endMeter,
    this.fuelLiters,
    this.areaHectares,
    this.notes = '',
    this.cancelledAt,
    this.cancellationReason = '',
    this.endedAt,
    this.implementId = '',
    this.implementName = '',
    this.isManual = false,
    this.withoutMeter = false,
    this.people,
    this.manualWorkers = const [],
    this.days = const [],
    this.plannedInputs = const [],
    this.appliedSprayInputs = const [],
    this.isPaused = false,
    this.plotCompleted = false,
    this.resumedAt,
    this.resumedMeter,
  });
  final String id,
      machineId,
      machineName,
      operatorName,
      customer,
      property,
      clientId,
      propertyId,
      fieldName,
      fieldId,
      jobType,
      workSection,
      workObjective,
      cancellationReason,
      implementId,
      implementName,
      notes;
  final DateTime startedAt;
  final DateTime? cancelledAt, endedAt;
  bool get isCancelled => cancelledAt != null;
  final double? startMeter;
  final double? endMeter;
  final double? fuelLiters, areaHectares;
  final bool isManual, withoutMeter, isPaused, plotCompleted;
  bool get tracksMeter => !isManual && !withoutMeter;
  final int? people, applicationNumber;
  final List<ServiceDay> days;
  final List<ServiceWorkerRate> manualWorkers;
  final List<CoffeeInputPlan> plannedInputs;
  final List<CoffeeInputPlan> appliedSprayInputs;
  final DateTime? resumedAt;
  final double? resumedMeter;
  DateTime get activeSince => resumedAt ?? startedAt;
  double? get activeStartMeter => resumedMeter ?? startMeter;
  bool get isFinished => endMeter != null || endedAt != null;
  double? get workedHours => days.isNotEmpty
      ? _sumDays(days.map((day) => day.hours))
      : endMeter == null || startMeter == null
          ? null
          : endMeter! - startMeter!;

  static double? _sumDays(Iterable<double?> values) =>
      values.any((value) => value == null)
          ? null
          : values.fold<double>(0, (sum, value) => sum + value!);

  FarmService copyWith({
    double? endMeter,
    double? fuelLiters,
    double? areaHectares,
    String? notes,
    DateTime? cancelledAt,
    String? cancellationReason,
    DateTime? endedAt,
    List<ServiceDay>? days,
    List<ServiceWorkerRate>? manualWorkers,
    List<CoffeeInputPlan>? appliedSprayInputs,
    bool? isPaused,
    bool? plotCompleted,
    DateTime? resumedAt,
    double? resumedMeter,
  }) =>
      FarmService(
        id: id,
        machineId: machineId,
        machineName: machineName,
        operatorName: operatorName,
        customer: customer,
        property: property,
        clientId: clientId,
        propertyId: propertyId,
        fieldName: fieldName,
        fieldId: fieldId,
        jobType: jobType,
        applicationNumber: applicationNumber,
        workSection: workSection,
        workObjective: workObjective,
        startedAt: startedAt,
        startMeter: startMeter,
        endMeter: endMeter ?? this.endMeter,
        fuelLiters: fuelLiters ?? this.fuelLiters,
        areaHectares: areaHectares ?? this.areaHectares,
        notes: notes ?? this.notes,
        cancelledAt: cancelledAt ?? this.cancelledAt,
        cancellationReason: cancellationReason ?? this.cancellationReason,
        endedAt: endedAt ?? this.endedAt,
        implementId: implementId,
        implementName: implementName,
        isManual: isManual,
        withoutMeter: withoutMeter,
        people: manualWorkers == null || manualWorkers.isEmpty
            ? people
            : manualWorkers.length,
        manualWorkers: manualWorkers ?? this.manualWorkers,
        days: days ?? this.days,
        plannedInputs: plannedInputs,
        appliedSprayInputs: appliedSprayInputs ?? this.appliedSprayInputs,
        isPaused: isPaused ?? this.isPaused,
        plotCompleted: plotCompleted ?? this.plotCompleted,
        resumedAt: resumedAt ?? this.resumedAt,
        resumedMeter: resumedMeter ?? this.resumedMeter,
      );

  FarmService finishWith({
    required double? endMeter,
    required double? fuelLiters,
    required double? areaHectares,
    required String notes,
    ServiceDay? day,
  }) {
    final recordedDays = [...days, if (day != null) day];
    return copyWith(
      endMeter: endMeter,
      fuelLiters: day == null
          ? fuelLiters
          : _sumDays(recordedDays.map((d) => d.fuelLiters)),
      areaHectares: day == null
          ? areaHectares
          : _sumDays(recordedDays.map((d) => d.areaHectares)),
      notes: notes,
      endedAt: day?.date ?? DateTime.now(),
      days: recordedDays,
      isPaused: false,
    );
  }

  FarmService cancel(String reason) => copyWith(
        cancelledAt: DateTime.now(),
        cancellationReason: reason,
        isPaused: false,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'machineId': machineId,
        'machineName': machineName,
        'operatorName': operatorName,
        'customer': customer,
        'property': property,
        'clientId': clientId,
        'propertyId': propertyId,
        'fieldName': fieldName,
        'fieldId': fieldId,
        'jobType': jobType,
        if (applicationNumber != null) 'applicationNumber': applicationNumber,
        if (workSection.isNotEmpty) 'workSection': workSection,
        if (workObjective.isNotEmpty) 'workObjective': workObjective,
        'startedAt': startedAt.toIso8601String(),
        'startMeter': startMeter,
        'endMeter': endMeter,
        'fuelLiters': fuelLiters,
        'areaHectares': areaHectares,
        'notes': notes,
        'cancelledAt': cancelledAt?.toIso8601String(),
        'cancellationReason': cancellationReason,
        'endedAt': endedAt?.toIso8601String(),
        'implementId': implementId,
        'implementName': implementName,
        if (isManual) 'isManual': true,
        if (withoutMeter) 'withoutMeter': true,
        if (people != null) 'people': people,
        if (manualWorkers.isNotEmpty)
          'manualWorkers': [
            for (final worker in manualWorkers) worker.toJson()
          ],
        if (days.isNotEmpty) 'days': days.map((day) => day.toJson()).toList(),
        if (plannedInputs.isNotEmpty)
          'plannedInputs':
              plannedInputs.map((input) => input.toJson()).toList(),
        if (appliedSprayInputs.isNotEmpty)
          'appliedSprayInputs':
              appliedSprayInputs.map((input) => input.toJson()).toList(),
        if (isPaused) 'isPaused': true,
        if (plotCompleted) 'plotCompleted': true,
        if (resumedAt != null) 'resumedAt': resumedAt!.toIso8601String(),
        if (resumedMeter != null) 'resumedMeter': resumedMeter,
      };
  factory FarmService.fromJson(Map<String, dynamic> json) => FarmService(
        id: json['id'] as String,
        machineId: json['machineId'] as String? ?? '',
        machineName: json['machineName'] as String? ?? '',
        operatorName: json['operatorName'] as String? ?? '',
        customer: json['customer'] as String? ?? '',
        property: json['property'] as String? ?? '',
        clientId: json['clientId'] as String? ?? '',
        propertyId: json['propertyId'] as String? ?? '',
        fieldName: json['fieldName'] as String? ?? '',
        fieldId: json['fieldId'] as String? ?? '',
        jobType: json['jobType'] as String? ?? 'Outro',
        applicationNumber: json['applicationNumber'] as int?,
        workSection: json['workSection'] as String? ?? '',
        workObjective: json['workObjective'] as String? ?? '',
        startedAt: DateTime.parse(json['startedAt'] as String),
        startMeter: (json['startMeter'] as num?)?.toDouble(),
        endMeter: (json['endMeter'] as num?)?.toDouble(),
        fuelLiters: (json['fuelLiters'] as num?)?.toDouble(),
        areaHectares: (json['areaHectares'] as num?)?.toDouble(),
        notes: json['notes'] as String? ?? '',
        cancelledAt: json['cancelledAt'] == null
            ? null
            : DateTime.parse(json['cancelledAt'] as String),
        cancellationReason: json['cancellationReason'] as String? ?? '',
        endedAt: json['endedAt'] == null
            ? null
            : DateTime.parse(json['endedAt'] as String),
        implementId: json['implementId'] as String? ?? '',
        implementName: json['implementName'] as String? ?? '',
        isManual: json['isManual'] == true,
        withoutMeter: json['withoutMeter'] == true,
        people: json['people'] as int?,
        manualWorkers: _readManualWorkers(json['manualWorkers']),
        days: (json['days'] as List? ?? const [])
            .map(
              (day) =>
                  ServiceDay.fromJson(Map<String, dynamic>.from(day as Map)),
            )
            .toList(),
        plannedInputs: List.unmodifiable(
          (json['plannedInputs'] as List? ?? const [])
              .map((input) => CoffeeInputPlan.fromJson(
                    Map<String, dynamic>.from(input as Map),
                  )),
        ),
        appliedSprayInputs: List.unmodifiable(
          (json['appliedSprayInputs'] as List? ?? const [])
              .map((input) => CoffeeInputPlan.fromJson(
                    Map<String, dynamic>.from(input as Map),
                  )),
        ),
        isPaused: json['isPaused'] == true,
        plotCompleted: json['plotCompleted'] == true,
        resumedAt: json['resumedAt'] == null
            ? null
            : DateTime.parse(json['resumedAt'] as String),
        resumedMeter: (json['resumedMeter'] as num?)?.toDouble(),
      );
}
