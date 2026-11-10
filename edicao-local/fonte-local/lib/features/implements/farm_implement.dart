class FarmImplement {
  const FarmImplement(
      {required this.id,
      required this.name,
      required this.type,
      required this.brand,
      required this.model,
      required this.hours,
      required this.compatibleMachine,
      required this.active,
      this.photoPath});
  final String id, name, type, brand, model, compatibleMachine;
  final double? hours;
  final String? photoPath;
  final bool active;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        'brand': brand,
        'model': model,
        'hours': hours,
        'compatibleMachine': compatibleMachine,
        'photoPath': photoPath,
        'active': active
      };

  factory FarmImplement.fromJson(Map<String, dynamic> json) => FarmImplement(
        id: json['id'] as String,
        name: json['name'] as String,
        type: json['type'] as String? ?? 'Outro',
        brand: json['brand'] as String? ?? '',
        model: json['model'] as String? ?? '',
        hours: (json['hours'] as num?)?.toDouble(),
        compatibleMachine: json['compatibleMachine'] as String? ?? '',
        active: json['active'] as bool? ?? true,
        photoPath: json['photoPath'] as String?,
      );
}
