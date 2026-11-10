import '../machines/machine.dart';

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
        'acquisitionValue'
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
  if (module == 'services') {
    if (data['endMeter'] != null &&
        (data['endMeter'] as num) < (data['startMeter'] as num)) {
      throw const FormatException(
          'O horimetro final nao pode ser menor que o inicial.');
    }
    if (data['cancelledAt'] != null &&
        (data['endMeter'] != null ||
            '${data['cancellationReason'] ?? ''}'.trim().isEmpty)) {
      throw const FormatException(
          'Confira o motivo e o estado do cancelamento.');
    }
  }
}
