import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:agrogestao/features/properties/catalog_store.dart';
import 'package:agrogestao/features/properties/properties_screen.dart';
import 'package:agrogestao/features/operations_v2/operations_screen.dart';
import 'package:agrogestao/features/operations_v2/v2_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);
  test('farm bundle is durable and rolls back all children on excess area',
      () async {
    final folder = await Directory.systemTemp.createTemp('agro-farm-bundle-');
    final path = '${folder.path}/test.sqlite';
    var db = await databaseFactoryFfi.openDatabase(path);
    await CatalogStore.initialize(db);
    CatalogStore store() => CatalogStore(
        db: db,
        scope: 'pc/org/admin',
        manager: true,
        tokenExpiry: DateTime.utc(2030));
    await store().save('POST', '/properties', {
      'id': 'farm',
      'name': 'Fazenda completa',
      'area_ha': '100',
      'plots': [
        for (var i = 0; i < 4; i++)
          {
            'id': 'plot-$i',
            'name': 'Talhão $i',
            'area_ha': ['20', '30', '25', '25'][i],
            'notes': 'Cadastro'
          }
      ]
    });
    await db.close();
    db = await databaseFactoryFfi.openDatabase(path);
    expect(await store().records('plots'), hasLength(4));
    expect(await store().pending(), hasLength(1));
    final payload =
        jsonDecode((await store().pending()).single['payload'] as String)
            as Map;
    expect(payload['plots'], hasLength(4));
    await expectLater(
        store().save('POST', '/properties', {
          'id': 'invalid',
          'name': 'Excedente',
          'area_ha': '10',
          'plots': [
            {'id': 'excess', 'name': 'Excedente', 'area_ha': '10.000001'}
          ]
        }),
        throwsStateError);
    expect(await store().records('properties'), hasLength(1));
    expect(await store().records('plots'), hasLength(4));
    expect(await store().pending(), hasLength(1));
    await db.close();
    await folder.delete(recursive: true);
  });

  testWidgets('farm form adds multiple plots and shows area difference',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Map<String, dynamic>? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                onPressed: () async {
                  result = await showDialog<Map<String, dynamic>>(
                      context: context,
                      builder: (_) => const CatalogEntityDialog());
                },
                child: const Text('Abrir')))));
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Nome ou identificação'),
        'Fazenda nova');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Área (ha)'), '100');
    for (var i = 0; i < 2; i++) {
      await tester.ensureVisible(find.text('Adicionar talhão'));
      await tester.tap(find.text('Adicionar talhão'));
      await tester.pumpAndSettle();
      final name =
          find.widgetWithText(TextFormField, 'Nome do talhão ${i + 1}');
      await tester.ensureVisible(name);
      await tester.enterText(name, 'Talhão ${i + 1}');
      final area = find
          .widgetWithText(TextFormField, 'Área do talhão (ha, opcional)')
          .at(i);
      await tester.ensureVisible(area);
      await tester.enterText(area, i == 0 ? '20' : '30');
      await tester.pump();
    }
    expect(find.textContaining('50.0000 ha.'), findsOneWidget);
    await tester.ensureVisible(find.text('Salvar'));
    await tester.tap(find.text('Salvar'));
    await tester.pumpAndSettle();
    expect(result?['plots'], hasLength(2));
    expect(result?['area_ha'], '100');
    expect(tester.takeException(), isNull);
  });

  test('administrative exports include filters sources and unknown values',
      () async {
    final report = <String, dynamic>{
      'report_type': 'costs',
      'generated_at': '2026-10-15T12:00:00Z',
      'scope': 'Custos conhecidos',
      'filters': {'property_id': 'farm-1', 'plot_id': 'plot-1'},
      'ledger': [
        {
          'id': 'inventory:source-1',
          'category': 'Combustível',
          'amount_cents': 6000
        },
        {
          'id': 'labor:operation-1',
          'category': 'Mão de obra',
          'amount_cents': null
        }
      ]
    };
    final rows = reportRows(report);
    final text = rows.expand((r) => r).join('\n');
    expect(text, contains('farm-1'));
    expect(text, contains('inventory:source-1'));
    expect(text, contains('Não informado'));
    expect(ascii.decode((await reportPdf(report)).take(4).toList()), '%PDF');
    expect(reportXlsx(report), isNotEmpty);
  });

  testWidgets(
      'completion records measured fuel separately from refueling and cumulative coverage',
      (tester) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Map<String, dynamic>? saved;
    final data = <String, dynamic>{
      'cycles': [
        {'id': 'cycle', 'name': 'Café 2026', 'plot_id': 'plot'}
      ],
      'plots': [
        {'id': 'plot', 'name': 'Talhão 1'}
      ],
      'activity_plans': [
        {
          'plan_id': 'plan',
          'cycle_id': 'cycle',
          'activity': 'management',
          'title': 'Manejo',
          'completed_ha': '2',
          'planned_ha': '10',
          'version': 3
        }
      ],
      'machines': [],
      'inputs': []
    };
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                onPressed: () async {
                  saved = await showDialog<Map<String, dynamic>>(
                      context: context,
                      builder: (_) =>
                          OperationDialog(data: data, cycleId: 'cycle'));
                },
                child: const Text('Abrir')))));
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
    final plan = find.widgetWithText(
        DropdownButtonFormField<String>, 'Programação da safra (opcional)');
    await tester.ensureVisible(plan);
    await tester.tap(plan);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Manejo · 2/10 ha').last);
    await tester.pumpAndSettle();
    final area = find.widgetWithText(
        TextFormField, 'Área única acumulada concluída (ha)');
    await tester.ensureVisible(area);
    await tester.enterText(area, '7,5');
    final fuel = find.widgetWithText(
        TextFormField, 'Combustível efetivamente consumido (L, se medido)');
    await tester.ensureVisible(fuel);
    await tester.enterText(fuel, '0');
    await tester.ensureVisible(find.text('Finalizar e salvar'));
    await tester.tap(find.text('Finalizar e salvar'));
    await tester.pumpAndSettle();
    expect(saved?['coverage_total_ha'], '7.5');
    expect(saved?['plan_expected_version'], 3);
    expect(saved?['consumed_fuel_liters'], '0');
    expect(saved?.containsKey('refuelings'), false);
    expect(tester.takeException(), isNull);
  });
}
