class FuelRecord {
  const FuelRecord(
      {required this.id,
      required this.machineId,
      required this.machineName,
      required this.operatorName,
      required this.date,
      required this.hourMeter,
      required this.liters,
      required this.pricePerLiter,
      required this.location});
  final String id, machineId, machineName, operatorName, location;
  final DateTime date;
  final double hourMeter, liters, pricePerLiter;
  double get totalCost => liters * pricePerLiter;
  Map<String, Object> toJson() => {
        'id': id,
        'machineId': machineId,
        'machineName': machineName,
        'operatorName': operatorName,
        'date': date.toIso8601String(),
        'hourMeter': hourMeter,
        'liters': liters,
        'pricePerLiter': pricePerLiter,
        'location': location
      };
  factory FuelRecord.fromJson(Map<String, dynamic> j) => FuelRecord(
      id: j['id'] as String,
      machineId: j['machineId'] as String,
      machineName: j['machineName'] as String,
      operatorName: j['operatorName'] as String? ?? '',
      date: DateTime.parse(j['date'] as String),
      hourMeter: (j['hourMeter'] as num).toDouble(),
      liters: (j['liters'] as num).toDouble(),
      pricePerLiter: (j['pricePerLiter'] as num).toDouble(),
      location: j['location'] as String? ?? '');
}
