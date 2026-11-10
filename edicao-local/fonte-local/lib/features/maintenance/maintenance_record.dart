class MaintenanceRecord {
  const MaintenanceRecord(
      {required this.id,
      required this.machineId,
      required this.machineName,
      required this.date,
      required this.hourMeter,
      required this.type,
      required this.description,
      required this.parts,
      required this.cost,
      required this.intervalHours});
  final String id, machineId, machineName, type, description, parts;
  final DateTime date;
  final double hourMeter, intervalHours;
  final double? cost;
  double get nextDueMeter => hourMeter + intervalHours;
  Map<String, Object?> toJson() => {
        'id': id,
        'machineId': machineId,
        'machineName': machineName,
        'date': date.toIso8601String(),
        'hourMeter': hourMeter,
        'type': type,
        'description': description,
        'parts': parts,
        'cost': cost,
        'intervalHours': intervalHours
      };
  factory MaintenanceRecord.fromJson(Map<String, dynamic> j) =>
      MaintenanceRecord(
          id: j['id'] as String,
          machineId: j['machineId'] as String,
          machineName: j['machineName'] as String,
          date: DateTime.parse(j['date'] as String),
          hourMeter: (j['hourMeter'] as num).toDouble(),
          type: j['type'] as String,
          description: j['description'] as String? ?? '',
          parts: j['parts'] as String? ?? '',
          cost: (j['cost'] as num?)?.toDouble(),
          intervalHours: (j['intervalHours'] as num).toDouble());
}
