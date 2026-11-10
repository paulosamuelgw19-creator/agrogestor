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
      cancellationReason,
      implementId,
      implementName,
      notes;
  final DateTime startedAt;
  final DateTime? cancelledAt, endedAt;
  bool get isCancelled => cancelledAt != null;
  final double startMeter;
  final double? endMeter;
  final double? fuelLiters, areaHectares;
  bool get isFinished => endMeter != null;
  double? get workedHours => endMeter == null ? null : endMeter! - startMeter;

  FarmService copyWith({
    double? endMeter,
    double? fuelLiters,
    double? areaHectares,
    String? notes,
    DateTime? cancelledAt,
    String? cancellationReason,
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
        startedAt: startedAt,
        startMeter: startMeter,
        endMeter: endMeter ?? this.endMeter,
        fuelLiters: fuelLiters ?? this.fuelLiters,
        areaHectares: areaHectares ?? this.areaHectares,
        notes: notes ?? this.notes,
        cancelledAt: cancelledAt ?? this.cancelledAt,
        cancellationReason: cancellationReason ?? this.cancellationReason,
        endedAt: endedAt,
        implementId: implementId,
        implementName: implementName,
      );

  FarmService finishWith({
    required double endMeter,
    required double? fuelLiters,
    required double? areaHectares,
    required String notes,
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
        startedAt: startedAt,
        startMeter: startMeter,
        endMeter: endMeter,
        fuelLiters: fuelLiters,
        areaHectares: areaHectares,
        notes: notes,
        cancelledAt: cancelledAt,
        cancellationReason: cancellationReason,
        endedAt: DateTime.now(),
        implementId: implementId,
        implementName: implementName,
      );

  FarmService cancel(String reason) =>
      copyWith(cancelledAt: DateTime.now(), cancellationReason: reason);

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
        startedAt: DateTime.parse(json['startedAt'] as String),
        startMeter: (json['startMeter'] as num).toDouble(),
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
      );
}
