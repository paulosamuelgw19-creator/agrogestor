enum UserRole {
  admin,
  operator,
  mechanic;

  String get label {
    switch (this) {
      case UserRole.admin:
        return 'Gestor / Administrador';
      case UserRole.operator:
        return 'Operador de Campo';
      case UserRole.mechanic:
        return 'Técnico / Mecânico';
    }
  }
}

class AppUser {
  final String id;
  final String name;
  final String email;
  final UserRole role;
  final String? phone;
  final String? farmId;

  const AppUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.phone,
    this.farmId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'role': role.name,
        'phone': phone,
        'farmId': farmId,
      };

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
        id: json['id'] as String,
        name: json['name'] as String,
        email: json['email'] as String,
        role: UserRole.values.firstWhere(
          (r) => r.name == json['role'],
          orElse: () => UserRole.operator,
        ),
        phone: json['phone'] as String?,
        farmId: json['farmId'] as String?,
      );
}
