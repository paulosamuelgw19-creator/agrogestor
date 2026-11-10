import 'package:flutter_test/flutter_test.dart';
import 'package:agrogestao/features/auth/farm_access_policy.dart';
import 'package:agrogestao/features/auth/user_model.dart';
import 'package:agrogestao/features/licensing/licensing_service.dart';

void main() {
  group('permissões locais por perfil', () {
    test('administrador tem acesso a todos os módulos de fazenda', () {
      for (final module in [
        'machines',
        'services',
        'maintenance',
        'fuel',
        'operators',
        'implements',
        'clients',
        'products',
        'productUsage',
      ]) {
        expect(FarmAccessPolicy.canRead(UserRole.admin, module), isTrue,
            reason: module);
        expect(FarmAccessPolicy.canWrite(UserRole.admin, module), isTrue,
            reason: module);
      }
    });

    test('operador também acessa catálogo e lançamentos de consumo', () {
      for (final module in ['machines', 'services', 'implements', 'fuel']) {
        expect(FarmAccessPolicy.canRead(UserRole.operator, module), isTrue,
            reason: module);
        expect(FarmAccessPolicy.canWrite(UserRole.operator, module), isTrue,
            reason: module);
      }
      for (final module in ['products', 'productUsage']) {
        expect(FarmAccessPolicy.canRead(UserRole.operator, module), isTrue,
            reason: module);
        expect(FarmAccessPolicy.canWrite(UserRole.operator, module), isTrue,
            reason: module);
      }
      for (final module in ['maintenance', 'operators', 'clients']) {
        expect(FarmAccessPolicy.canRead(UserRole.operator, module), isFalse,
            reason: module);
        expect(FarmAccessPolicy.canWrite(UserRole.operator, module), isFalse,
            reason: module);
      }
    });

    test('mecânico só acessa máquinas e manutenção', () {
      for (final module in ['machines', 'maintenance']) {
        expect(FarmAccessPolicy.canRead(UserRole.mechanic, module), isTrue,
            reason: module);
        expect(FarmAccessPolicy.canWrite(UserRole.mechanic, module), isTrue,
            reason: module);
      }
      for (final module in [
        'services',
        'fuel',
        'operators',
        'implements',
        'clients',
        'products',
        'productUsage'
      ]) {
        expect(FarmAccessPolicy.canRead(UserRole.mechanic, module), isFalse,
            reason: module);
        expect(FarmAccessPolicy.canWrite(UserRole.mechanic, module), isFalse,
            reason: module);
      }
    });

    test('módulos desconhecidos são negados por padrão', () {
      for (final role in UserRole.values) {
        expect(FarmAccessPolicy.canRead(role, 'unknown'), isFalse);
        expect(FarmAccessPolicy.canWrite(role, 'unknown'), isFalse);
      }
    });
  });

  group('estado de licença offline', () {
    test('mostra teste expirado pelo prazo local salvo', () {
      final now = DateTime.now();
      final entitlement = FarmEntitlement(
        status: 'trial',
        writeAllowed: true,
        checkedAt: now.subtract(const Duration(days: 2)),
        offlineUntil: now.add(const Duration(days: 5)),
        trialEndsAt: now.subtract(const Duration(minutes: 1)),
        activeDevices: 1,
        deviceLimit: 2,
        daysRemaining: 3,
      );

      expect(entitlement.effectiveStatus, 'expired');
      expect(entitlement.canWriteAt(now), isFalse);
      expect(entitlement.notice, contains('encerrado'));
    });

    test('licença paga vencida bloqueia escrita mesmo com cache válido', () {
      final now = DateTime.now();
      final entitlement = FarmEntitlement(
        status: 'licensed',
        writeAllowed: true,
        checkedAt: now.subtract(const Duration(days: 1)),
        offlineUntil: now.add(const Duration(days: 6)),
        licenseExpiresAt: now.subtract(const Duration(seconds: 1)),
        activeDevices: 1,
        deviceLimit: -1,
      );
      expect(entitlement.effectiveStatus, 'expired');
      expect(entitlement.canWriteAt(now), isFalse);
      expect(entitlement.canWriteAt(entitlement.licenseExpiresAt!), isFalse);
    });

    test('licença vitalícia respeita validação e detecta relógio atrasado', () {
      final now = DateTime.now();
      final entitlement = FarmEntitlement(
        status: 'licensed',
        writeAllowed: true,
        checkedAt: now,
        offlineUntil: now.add(const Duration(days: 7)),
        activeDevices: 1,
        deviceLimit: -1,
      );
      expect(entitlement.canWriteAt(now), isTrue);
      expect(entitlement.canWriteAt(now.subtract(const Duration(days: 1))),
          isFalse);
      expect(entitlement.canWriteAt(now.add(const Duration(days: 7))), isFalse);
    });

    test('exige nova validação depois de sete dias sem conexão', () {
      final now = DateTime.now();
      final entitlement = FarmEntitlement(
        status: 'licensed',
        writeAllowed: true,
        checkedAt: now.subtract(const Duration(days: 8)),
        offlineUntil: now.subtract(const Duration(days: 1)),
        activeDevices: 1,
        deviceLimit: 2,
      );

      expect(entitlement.effectiveStatus, 'validation_required');
      expect(entitlement.canWriteAt(now), isFalse);
      expect(entitlement.notice, contains('sete dias'));
    });
  });
}
