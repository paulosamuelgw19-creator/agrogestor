import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:agrogestao/features/auth/auth_service.dart';
import 'package:agrogestao/features/auth/user_model.dart';
import 'package:agrogestao/features/auth/farm_access_policy.dart';
import 'package:agrogestao/features/licensing/licensing_service.dart';
import 'package:agrogestao/features/machines/machine.dart';
import 'package:agrogestao/features/machines/machine_repository.dart';
import 'package:agrogestao/features/sync/app_database.dart';
import 'package:agrogestao/features/sync/sync_errors.dart';
import 'package:agrogestao/features/sync/sync_service.dart';
import 'package:agrogestao/features/sync/local_write_batch.dart';

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  const farm = 'test-farm-local';
  const machine = Machine(
    id: 'machine-a',
    name: 'Trator A',
    brand: 'Marca',
    model: 'Modelo',
    year: 2020,
    hourMeter: 100,
    fuelType: 'Diesel',
    status: MachineStatus.disponivel,
  );

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('agrogestor-store-');
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    PathProviderPlatform.instance = _TestPaths(directory.path);
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await AuthService().selectDemoUser(const AppUser(
      id: 'test-admin',
      name: 'Admin',
      email: 'admin@example.invalid',
      role: UserRole.admin,
      farmId: farm,
    ));
    final now = DateTime.now().toUtc();
    await LicensingService().cache(farm, {
      'status': 'licensed',
      'writeAllowed': true,
      'checkedAt': now.toIso8601String(),
      'offlineUntil': now.add(const Duration(days: 7)).toIso8601String(),
    });
    final db = await appDatabase.database;
    await db.delete('sync_outbox');
    await db.delete('local_records');
  });

  tearDownAll(() async {
    await SyncService().syncNow();
    final db = await appDatabase.database;
    await db.close();
    debugDefaultTargetPlatformOverride = null;
    await directory.delete(recursive: true);
  });

  Future<void> receive(Machine item, {int version = 1}) async {
    final db = await appDatabase.database;
    await db.rawInsert('''INSERT OR REPLACE INTO local_records
      (farm_id,module,record_id,payload,server_version,sync_state,is_deleted,changed_at)
      VALUES(?,?,?,?,?,'synced',0,?)''', [
      farm,
      'machines',
      item.id,
      jsonEncode(item.toJson()),
      version,
      DateTime.now().toUtc().toIso8601String(),
    ]);
  }

  test(
      'salvar uma edição mantém máquina recebida enquanto a tela estava aberta',
      () async {
    final repo = MachineRepository();
    await receive(machine);
    final seen = await repo.getAll();
    await receive(const Machine(
      id: 'machine-b',
      name: 'Remoto',
      brand: 'Marca',
      model: 'Modelo',
      year: 2021,
      hourMeter: 1,
      fuelType: 'Diesel',
      status: MachineStatus.disponivel,
    ));
    await repo.saveAll([machine.copyWith(hourMeter: 110)], previous: seen);
    expect((await repo.getAll()).map((item) => item.id).toSet(),
        {'machine-a', 'machine-b'});
    final queue = await (await appDatabase.database).query('sync_outbox');
    expect(queue, hasLength(1));
    expect(queue.single['operation'], 'upsert');
    expect(queue.single['record_id'], 'machine-a');
  });

  test('edição desatualizada não altera banco nem fila', () async {
    final repo = MachineRepository();
    await receive(machine);
    final seen = await repo.getAll();
    await receive(machine.copyWith(hourMeter: 200), version: 2);
    await expectLater(
        repo.saveAll([machine.copyWith(hourMeter: 110)], previous: seen),
        throwsA(isA<SyncConflictWriteBlocked>()));
    expect((await repo.getAll()).single.hourMeter, 200);
    expect(await (await appDatabase.database).query('sync_outbox'), isEmpty);
  });

  test('exclusão usa somente os registros presentes na lista original',
      () async {
    final repo = MachineRepository();
    await receive(machine);
    final seen = await repo.getAll();
    await repo.saveAll([], previous: seen);
    expect(await repo.getAll(), isEmpty);
    final event =
        (await (await appDatabase.database).query('sync_outbox')).single;
    expect(event['operation'], 'delete');
    expect(event['base_version'], 1);
  });

  test('perfil sem permissão não altera máquinas', () async {
    await AuthService().logout();
    await expectLater(
        MachineRepository().saveAll([machine], previous: []), throwsException);
    expect(await (await appDatabase.database).query('sync_outbox'), isEmpty);
  });
  test('falha em operação composta desfaz dados e fila juntos', () async {
    final repo = MachineRepository();
    await receive(machine);
    final seen = await repo.getAll();
    await expectLater(LocalWriteBatch.run(() async {
      await repo.saveAll([machine.copyWith(hourMeter: 110)], previous: seen);
      throw StateError('Falha simulada na segunda gravação');
    }), throwsStateError);
    expect((await repo.getAll()).single.hourMeter, 100);
    expect(await (await appDatabase.database).query('sync_outbox'), isEmpty);
  });

  test('sucesso em operação composta confirma dados e fila juntos', () async {
    final repo = MachineRepository();
    await receive(machine);
    final seen = await repo.getAll();
    await LocalWriteBatch.run(() async {
      await repo.saveAll([machine.copyWith(hourMeter: 120)], previous: seen);
    });
    expect((await repo.getAll()).single.hourMeter, 120);
    expect(
        await (await appDatabase.database).query('sync_outbox'), hasLength(1));
  });
  test('conta por propriedade não lê nem altera cache legado do administrador', () async {
    await receive(machine);
    await AuthService().selectDemoUser(const AppUser(id: 'restricted', name: 'Cliente',
      email: 'cliente@example.invalid', role: UserRole.operator, farmId: farm));
    final repo = MachineRepository();
    expect(await repo.getAll(), isEmpty);
    await expectLater(repo.saveAll([machine], previous: []), throwsA(isA<FarmAccessDenied>()));
    final db = await appDatabase.database;
    expect(await db.query('local_records'), hasLength(1));
    expect(await db.query('sync_outbox'), isEmpty);
  });

  test('editar máquina preserva ID da foto e trocar foto gera outro ID', () async {
    final repo = MachineRepository();
    final original = machine.copyWith(photoPath: '${directory.path}/original.jpg');
    await receive(original);
    final seen = await repo.getAll();
    final edited = original.copyWith(hourMeter: 110);
    await repo.saveAll([edited], previous: seen);
    final firstId = (await repo.getAll()).single.photoAttachmentId;
    expect(firstId, isNotNull);
    final editedAgain = edited.copyWith(hourMeter: 120);
    await repo.saveAll([editedAgain], previous: [edited]);
    expect((await repo.getAll()).single.photoAttachmentId, firstId);
    await repo.saveAll([editedAgain.copyWith(photoPath: '${directory.path}/new.jpg')], previous: [editedAgain]);
    expect((await repo.getAll()).single.photoAttachmentId, isNot(firstId));
  });

}
