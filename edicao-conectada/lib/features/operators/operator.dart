class Operator {
  const Operator(
      {required this.id,
      required this.name,
      required this.phone,
      required this.role,
      required this.active});

  final String id;
  final String name;
  final String phone;
  final String role;
  final bool active;

  Map<String, Object> toJson() =>
      {'id': id, 'name': name, 'phone': phone, 'role': role, 'active': active};

  factory Operator.fromJson(Map<String, dynamic> json) => Operator(
        id: json['id'] as String,
        name: json['name'] as String,
        phone: json['phone'] as String? ?? '',
        role: json['role'] as String? ?? 'Operador',
        active: json['active'] as bool? ?? true,
      );
}
