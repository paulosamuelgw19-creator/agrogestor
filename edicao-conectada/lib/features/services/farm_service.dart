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
    required this.jobType,
    required this.startedAt,
    required this.startMeter,
    this.endMeter,
    this.fuelLiters = 0,
    this.areaHectares = 0,
    this.notes = '',
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
      jobType,
      notes;
  final DateTime startedAt;
  final double startMeter;
  final double? endMeter;
  final double fuelLiters, areaHectares;
  bool get isFinished => endMeter != null;
  double? get workedHours => endMeter == null ? null : endMeter! - startMeter;

  FarmService copyWith({
    double? endMeter,
    double? fuelLiters,
    double? areaHectares,
    String? notes,
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
        jobType: jobType,
        startedAt: startedAt,
        startMeter: startMeter,
        endMeter: endMeter ?? this.endMeter,
        fuelLiters: fuelLiters ?? this.fuelLiters,
        areaHectares: areaHectares ?? this.areaHectares,
        notes: notes ?? this.notes,
      );

  FarmService finishWith({
    required double endMeter,
    required double fuelLiters,
    required double areaHectares,
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
        jobType: jobType,
        startedAt: startedAt,
        startMeter: startMeter,
        endMeter: endMeter,
        fuelLiters: fuelLiters,
        areaHectares: areaHectares,
        notes: notes,
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
        'jobType': jobType,
        'startedAt': startedAt.toIso8601String(),
        'startMeter': startMeter,
        'endMeter': endMeter,
        'fuelLiters': fuelLiters,
        'areaHectares': areaHectares,
        'notes': notes,
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
        jobType: json['jobType'] as String? ?? 'Outro',
        startedAt: DateTime.parse(json['startedAt'] as String),
        startMeter: (json['startMeter'] as num).toDouble(),
        endMeter: (json['endMeter'] as num?)?.toDouble(),
        fuelLiters: (json['fuelLiters'] as num?)?.toDouble() ?? 0,
        areaHectares: (json['areaHectares'] as num?)?.toDouble() ?? 0,
        notes: json['notes'] as String? ?? '',
      );
}
