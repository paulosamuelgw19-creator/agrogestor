import 'user_model.dart';

/// Client-side mirror of the module policy enforced by the farm API.
/// The server remains the authority; this prevents hidden modules from being
/// read or queued by a different role on the same installation.
class FarmAccessPolicy {
  const FarmAccessPolicy._();

  static const _adminModules = {
    'machines',
    'services',
    'maintenance',
    'fuel',
    'operators',
    'implements',
    'clients',
    'products',
    'productUsage',
  };
  static const _operatorModules = {
    'machines',
    'services',
    'implements',
    'fuel',
    'products',
    'productUsage',
  };
  static const _mechanicModules = {'machines', 'maintenance'};

  static bool canRead(UserRole role, String module) =>
      _modulesFor(role).contains(module);

  static bool canWrite(UserRole role, String module) => canRead(role, module);

  static Set<String> readableModules(UserRole role) => _modulesFor(role);

  static Set<String> _modulesFor(UserRole role) => switch (role) {
        UserRole.admin => _adminModules,
        UserRole.operator => _operatorModules,
        UserRole.mechanic => _mechanicModules,
      };
}

class FarmAccessDenied implements Exception {
  const FarmAccessDenied(this.message);
  final String message;

  @override
  String toString() => message;
}
