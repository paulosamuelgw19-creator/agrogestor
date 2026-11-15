import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:agrogestao/features/operations_v2/v2_store.dart';
import 'package:agrogestao/features/sync/farm_api_client.dart';
import 'package:agrogestao/features/work/work_store.dart';
import 'package:agrogestao/features/work/work_screen.dart';

class CachedWorkStore extends WorkStore {
  CachedWorkStore(super.core, this.snapshot);
  final Json snapshot;
  @override
  Future<Json?> workspace() async => snapshot;
  @override
  Future<List<Json>> pending() async => [];
  @override
  Future<void> sync() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late Directory folder;
  late V2Store core;
  setUpAll(sqfliteFfiInit);
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('agro-profile-ui-');
    db = await databaseFactoryFfi.openDatabase('${folder.path}/test.sqlite');
    await V2Store.initialize(db);
    core = V2Store(
        db: db,
        client: FarmApiClient.forSession(
            baseUrl: 'http://127.0.0.1:1', token: 'synthetic', farmId: 'test'),
        scope: 'pc/test/user',
        tokenExpiry: DateTime.utc(2030));
    await WorkStore.initialize(core);
  });
  tearDown(() async {
    await db.close();
    await folder.delete(recursive: true);
  });

  Future<void> open(WidgetTester tester, String role,
      {String section = 'panel'}) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final snapshot = <String, dynamic>{
      'role': role,
      'user_id': 'user',
      'generated_at': '2026-10-15',
      'tasks': [],
      'orders': [],
      'machines': [],
      'alerts': [],
      'properties': [],
      'cycles': [],
      'inputs': [],
      'checklists': [],
      'users': [
        {'id': 'op', 'name': 'Operador fictício', 'role': 'operator'},
        {'id': 'mech', 'name': 'Mecânico fictício', 'role': 'mechanic'},
      ],
    };
    await tester.pumpWidget(MaterialApp(
        home: WorkScreen(
            section: section, store: CachedWorkStore(core, snapshot))));
    await tester.pumpAndSettle();
  }

  testWidgets('operador vê tarefas sem indicadores e ações da oficina',
      (tester) async {
    await open(tester, 'operator');
    expect(find.text('Minhas tarefas'), findsOneWidget);
    expect(find.text('Minhas tarefas pendentes'), findsOneWidget);
    expect(find.text('Oficina'), findsNothing);
    expect(find.text('Máquinas paradas'), findsNothing);
    expect(find.text('Ordens em andamento'), findsNothing);
    expect(find.text('Aguardando peças'), findsNothing);
    expect(find.text('Funcionários'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('gerente tem indicadores separados e equipe por função',
      (tester) async {
    await open(tester, 'admin');
    expect(find.text('Tarefas dos operadores'), findsOneWidget);
    expect(find.text('Manutenções dos mecânicos'), findsOneWidget);
    await tester.tap(find.text('Funcionários'));
    await tester.pumpAndSettle();
    expect(find.text('Operadores'), findsOneWidget);
    expect(find.text('Mecânicos'), findsOneWidget);
    expect(find.text('Operador fictício'), findsOneWidget);
    expect(find.text('Mecânico fictício'), findsOneWidget);
    expect(find.byTooltip('Adicionar tarefa'), findsNWidgets(2));
    expect(find.textContaining('Sem execução informada'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('mecânico mantém oficina sem receber tarefas agrícolas',
      (tester) async {
    await open(tester, 'mechanic', section: 'orders');
    expect(find.text('Oficina e andamento'), findsOneWidget);
    expect(find.text('Tarefas'), findsNothing);
    expect(find.text('Funcionários'), findsNothing);
    expect(find.text('Reservar peças'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
