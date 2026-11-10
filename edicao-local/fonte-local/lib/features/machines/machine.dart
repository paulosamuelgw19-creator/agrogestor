enum MachineStatus { disponivel, emOperacao, emManutencao, parada, inativa }

extension MachineStatusLabel on MachineStatus {
  String get label => switch (this) {
        MachineStatus.disponivel => 'Disponível',
        MachineStatus.emOperacao => 'Em operação',
        MachineStatus.emManutencao => 'Em manutenção',
        MachineStatus.parada => 'Parada',
        MachineStatus.inativa => 'Inativa',
      };
}

class Machine {
  const Machine({
    required this.id,
    required this.name,
    required this.brand,
    required this.model,
    required this.year,
    required this.hourMeter,
    required this.fuelType,
    required this.status,
    this.identificationNumber = '',
    this.plate = '',
    this.serialNumber = '',
    this.tankCapacity = 0,
    this.averageConsumption = 0,
    this.acquisitionValue = 0,
    this.acquisitionDate,
    this.photoPath,
    this.photoAttachmentId,
  });

  final String id;
  final String name;
  final String brand;
  final String model;
  final int year;
  final double hourMeter;
  final String fuelType;
  final MachineStatus status;
  final String identificationNumber, plate, serialNumber;
  final double tankCapacity, averageConsumption, acquisitionValue;
  final DateTime? acquisitionDate;
  final String? photoPath;
  final String? photoAttachmentId;

  Machine copyWith({double? hourMeter, MachineStatus? status, String? photoPath, String? photoAttachmentId}) => Machine(
        id: id,
        name: name,
        brand: brand,
        model: model,
        year: year,
        hourMeter: hourMeter ?? this.hourMeter,
        fuelType: fuelType,
        status: status ?? this.status,
        identificationNumber: identificationNumber,
        plate: plate,
        serialNumber: serialNumber,
        tankCapacity: tankCapacity,
        averageConsumption: averageConsumption,
        acquisitionValue: acquisitionValue,
        acquisitionDate: acquisitionDate,
        photoPath: photoPath ?? this.photoPath,
        photoAttachmentId: photoAttachmentId ?? this.photoAttachmentId,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'brand': brand,
        'model': model,
        'year': year,
        'hourMeter': hourMeter,
        'fuelType': fuelType,
        'status': status.name,
        'identificationNumber': identificationNumber,
        'plate': plate,
        'serialNumber': serialNumber,
        'tankCapacity': tankCapacity,
        'averageConsumption': averageConsumption,
        'acquisitionValue': acquisitionValue,
        'acquisitionDate': acquisitionDate?.toIso8601String(),
        'photoPath': photoPath,
        'photoAttachmentId': photoAttachmentId,
      };

  factory Machine.fromJson(Map<String, dynamic> json) => Machine(
        id: json['id'] as String,
        name: json['name'] as String,
        brand: json['brand'] as String,
        model: json['model'] as String,
        year: json['year'] as int,
        hourMeter: (json['hourMeter'] as num).toDouble(),
        fuelType: json['fuelType'] as String,
        status: MachineStatus.values.firstWhere(
          (status) => status.name == json['status'],
          orElse: () => MachineStatus.disponivel,
        ),
        identificationNumber: json['identificationNumber'] as String? ?? '',
        plate: json['plate'] as String? ?? '',
        serialNumber: json['serialNumber'] as String? ?? '',
        tankCapacity: (json['tankCapacity'] as num?)?.toDouble() ?? 0,
        averageConsumption:
            (json['averageConsumption'] as num?)?.toDouble() ?? 0,
        acquisitionValue: (json['acquisitionValue'] as num?)?.toDouble() ?? 0,
        acquisitionDate: json['acquisitionDate'] == null
            ? null
            : DateTime.tryParse(json['acquisitionDate'] as String),
        photoPath: json['photoPath'] as String?,
        photoAttachmentId: json['photoAttachmentId'] as String?,
      );
}
