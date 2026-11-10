import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:agrogestao/app/app_theme.dart';
import 'package:agrogestao/features/properties/geography_screen.dart';
import 'package:agrogestao/features/properties/geography_store.dart';
import 'package:agrogestao/features/operations_v2/v2_store.dart';
import 'package:agrogestao/features/operations_v2/operations_screen.dart';
import 'package:agrogestao/features/operations_v2/management_reports_screen.dart';
import 'package:agrogestao/features/sync/farm_api_client.dart';

class _MapFixture extends GeographyStore {
  _MapFixture(super.core);
  @override
  Future<Json> refresh(String propertyId) async => {
        'property': {
          'id': 'farm',
          'name': 'Fazenda de teste — dados sintéticos'
        },
        'plots': [
          {'id': 'plot', 'name': 'Talhão de teste com nome longo'}
        ],
        'boundaries': [],
        'can_edit': true,
        'administrator': true,
      };
  @override
  Future<List<Json>> pending([String? propertyId]) async => [];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  for (final size in [
    const Size(320, 640),
    const Size(360, 800),
    const Size(900, 600)
  ]) {
    testWidgets(
        'mapa offline, seleção e controles cabem em $size com fonte 1.5',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory folder;
      late Database db;
      late V2Store core;
      await tester.runAsync(() async {
        folder = await Directory.systemTemp.createTemp('agro-map-ui-');
        db =
            await databaseFactoryFfi.openDatabase('${folder.path}/test.sqlite');
        core = V2Store(
            db: db,
            client: FarmApiClient.forSession(
                baseUrl: 'http://127.0.0.1:1',
                token: 'synthetic',
                farmId: 'synthetic'),
            scope: 'synthetic-map-ui',
            tokenExpiry: DateTime.utc(2030));
        await GeographyStore.initialize(core);
      });
      await tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.5)),
              child: child!),
          home: GeographyScreen(
              propertyId: 'farm',
              store: _MapFixture(core),
              initialBackground: 'none')));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      for (var attempt = 0;
          attempt < 8 &&
              find
                  .text('Fazenda de teste — dados sintéticos')
                  .evaluate()
                  .isEmpty;
          attempt++) {
        await tester.pump();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
      }
      await tester.pumpAndSettle();
      expect(find.text('Fazenda de teste — dados sintéticos'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Demarcar / editar'), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('Demarcar / editar'), findsOneWidget);
      await tester.ensureVisible(find.text('Demarcar / editar'));
      await tester.tap(find.text('Demarcar / editar'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Salvar desenho'));
      expect(find.text('Verde'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final rows = await tester.runAsync(() => db.query('geography_editor'));
      expect(rows, hasLength(1));
      expect(
          jsonDecode(rows!.single['payload'] as String)['expected_version'], 0);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await db.close();
        await folder.delete(recursive: true);
      });
    });
    testWidgets('gráfico distingue valores ausentes e cabe em $size',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: SingleChildScrollView(
                  child: KnownCostChart(categories: {
        'Máquinas': {
          'known_subtotal': '12000',
          'value': '12000',
          'unit': 'BRL_cent',
          'missing': 0
        },
        'Insumos': {
          'known_subtotal': null,
          'value': null,
          'unit': 'BRL_cent',
          'missing': 1
        },
      })))));
      await tester.pumpAndSettle();
      expect(find.textContaining('informações incompletas'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('colheita preserva zero medido e unidade no formulário',
      (tester) async {
    Json? saved;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () async {
                      saved = await showDialog<Json>(
                          context: context,
                          builder: (_) =>
                              const OperationDialog(cycleId: 'cycle', data: {
                                'cycles': [
                                  {
                                    'id': 'cycle',
                                    'name': 'Café sintético',
                                    'plot_id': 'plot'
                                  }
                                ],
                                'plots': [
                                  {'id': 'plot', 'name': 'Talhão sintético'}
                                ],
                                'machines': [],
                                'inputs': [],
                              }));
                    },
                    child: const Text('Abrir'))))));
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
    final kind =
        find.widgetWithText(DropdownButtonFormField<String>, 'Operação');
    await tester.ensureVisible(kind);
    await tester.tap(kind);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Colheita').last);
    await tester.pumpAndSettle();
    final quantity = find.widgetWithText(
        TextFormField, 'Quantidade efetivamente colhida (opcional)');
    await tester.ensureVisible(quantity);
    await tester.enterText(quantity, '0');
    await tester.ensureVisible(find.text('Finalizar e salvar'));
    await tester.tap(find.text('Finalizar e salvar'));
    await tester.pumpAndSettle();
    expect(saved?['harvest_output'],
        {'quantity': '0', 'unit': 'kg', 'kg_per_unit': null});
    expect(tester.takeException(), isNull);
  });
}
