import 'dart:io';

import 'package:agrogestao/features/analyses/coffee_analysis_repository.dart';
import 'package:agrogestao/features/harvest/coffee_harvest_repository.dart';
import 'package:agrogestao/features/properties/plot_notebook_screen.dart';
import 'package:agrogestao/features/shell/app_shell.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'coffee_notebook_harvest_test.dart' show useCoffeeDatabase;
import 'coffee_production_analysis_test.dart' show buildAnalysisPdf;

final class _Pdf extends PlatformFile {
  _Pdf(this.bytes);
  final Uint8List bytes;

  @override
  String get name => 'amostra-ficticia.pdf';
  @override
  Uri get uri => Uri.parse('test:amostra-ficticia.pdf');
  @override
  Never get xFile => throw UnsupportedError('A seleção é lida pelo stream');
  @override
  int lengthSync() => bytes.length;
  @override
  Future<int> length() async => bytes.length;
  @override
  Future<Uint8List> readAsBytes() async => bytes;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(bytes);
}

class _Picker extends FilePickerPlatform {
  _Picker(this.pdf);
  final _Pdf pdf;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus status)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    expect(type, FileType.custom);
    expect(allowedExtensions, ['pdf']);
    return pdf;
  }
}

class _Flow {
  _Flow(this.tester) {
    tester.view.physicalSize = const Size(320, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  final WidgetTester tester;

  Future<void> wait(Finder finder) async {
    for (var i = 0; i < 180 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsWidgets);
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> show(Finder finder, {bool scroll = false}) async {
    if (scroll && finder.evaluate().isEmpty) {
      final page = find.byType(ListView).last;
      final scrollable =
          find.descendant(of: page, matching: find.byType(Scrollable)).first;
      await tester.scrollUntilVisible(finder, 250, scrollable: scrollable);
    }
    await wait(finder);
    await tester.ensureVisible(finder);
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> tap(Finder finder, {bool scroll = false}) async {
    await show(finder, scroll: scroll);
    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> enter(String label, String value) async {
    final field = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
      description: 'campo $label',
    );
    await show(field);
    await tester.enterText(field, value);
    await tester.pump();
  }

  Finder menu(String label) => find.byWidgetPredicate(
        (widget) =>
            widget is InputDecorator && widget.decoration.labelText == label,
        description: 'seletor $label',
      );

  Future<void> close() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  }
}

const _notebook = PlotNotebookScreen(
  property: {'id': 'farm', 'name': 'Fazenda teste'},
  plot: {'id': 'plot-a', 'name': 'Talhão A', 'area_ha': 2},
);

void main() {
  useCoffeeDatabase();

  testWidgets('atalho Colheita registra produção e Caderno reabre o histórico',
      (tester) async {
    final flow = _Flow(tester);
    try {
      await tester.pumpWidget(const MaterialApp(home: AppShell()));
      await flow.tap(find.descendant(
        of: find.byType(NavigationBar),
        matching: find.text('Colheita'),
      ));
      await flow.tap(flow.menu('Fazenda'));
      await flow.wait(find.text('Fazenda teste'));
      await flow.tap(find.text('Fazenda teste').last);
      await flow.tap(flow.menu('Talhão'));
      await flow.wait(find.text('Talhão A'));
      expect(find.text('Talhão externo'), findsNothing);
      await flow.tap(find.text('Talhão A').last);
      await flow.tap(find.text('Abrir colheita'));
      await flow.wait(find.text('Conferência com o caderno'));
      await flow.tap(find.text('Registrar produção do dia'));
      await flow.enter('Medidas inteiras', '7');
      await flow.enter('Litros de sobra', '40');
      await flow.tap(find.text('Salvar'));
      await flow.wait(find.text('Produção acumulada: 460 L'));
      await flow.wait(find.text('Conferência com o caderno'));
      await flow.tap(find.text('Editar produção do dia'), scroll: true);
      await flow.enter('Litros de sobra', '50');
      await flow.tap(find.text('Salvar'));
      await flow.wait(find.text('Produção acumulada: 470 L'));
      await flow.wait(find.text('Conferência com o caderno'));
      await tester.runAsync(() async {
        final summary = await CoffeeHarvestRepository().production(
            propertyId: 'farm',
            plotId: 'plot-a',
            seasonYear: DateTime.now().year);
        expect(summary.days, hasLength(1));
        expect(summary.days.single.workerLiters, isNull);
        expect(summary.days.single.declared!.remainderLiters, 50);
      });
      await flow.tap(find.byTooltip('Back'));
      await flow.tap(find.text('Resumo da safra'));
      await flow.wait(find.text('Litros colhidos: 470 L'));
      expect(find.text('Beneficiado: Sem lançamentos'), findsOneWidget);
      await flow.tap(find.text('Talhão A'));
      await flow.wait(find.text('Produção acumulada: 470 L'));
      await tester.pumpWidget(const MaterialApp(
        key: ValueKey('notebook'),
        home: _notebook,
      ));
      await flow.tap(find.text('Colheita'));
      await flow.wait(find.text('Produção acumulada: 470 L'));
      await flow.wait(find.text('Conferência com o caderno'));
      expect(tester.takeException(), isNull);
    } finally {
      await flow.close();
    }
  });

  testWidgets('Caderno cadastra laudo PDF e resultado em tela de 320 px',
      (tester) async {
    final flow = _Flow(tester);
    final bytes = (await tester.runAsync(buildAnalysisPdf))!;
    final previousPicker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _Picker(_Pdf(bytes));
    addTearDown(() => FilePickerPlatform.instance = previousPicker);
    try {
      await tester.runAsync(() => CoffeeAnalysisRepository().save(
            CoffeeAnalysis(
              id: 'soil-previous',
              propertyId: 'farm',
              plotId: 'plot-a',
              type: CoffeeAnalysisType.soil,
              collectedAt: DateTime(2024, 1, 1),
              laboratory: 'Laboratório Teste',
              sampleId: 'SOLO-BASE',
              context: 'Profundidade: 0 a 20 cm\nLocal: Centro do talhão',
              results: const [
                CoffeeAnalysisResult(
                  indicator: 'Fósforo',
                  unit: 'mg/dm3',
                  value: 12.4,
                  method: 'Mehlich 1',
                ),
              ],
            ),
          ));
      await tester.pumpWidget(const MaterialApp(home: _notebook));
      await flow.tap(find.text('Análises'));
      await flow.tap(find.text('Adicionar análise'));
      await flow.enter('Laboratório', 'Laboratório Teste');
      await flow.enter('Código da amostra', 'SOLO-A');
      await flow.enter('Profundidade', '0 a 20 cm');
      await flow.enter('Local da coleta', 'Centro do talhão');
      await flow.tap(find.text('Importar PDF'), scroll: true);
      await flow.wait(find.text('amostra-ficticia.pdf'));
      await flow.tap(find.text('Adicionar resultado'), scroll: true);
      await flow.enter('Indicador', 'Fósforo');
      await flow.enter('Unidade', 'mg/dm3');
      await flow.enter('Valor', '12,5');
      await flow.enter('Método', 'Mehlich 1');
      await flow.tap(find.text('Salvar resultado'));
      await flow.tap(find.text('Salvar análise'), scroll: true);
      await flow.wait(find.textContaining('· SOLO-A'));
      await tester.runAsync(() async {
        final analysis = (await CoffeeAnalysisRepository()
                .list(propertyId: 'farm', plotId: 'plot-a'))
            .singleWhere((entry) => entry.sampleId == 'SOLO-A');
        expect(analysis.type, CoffeeAnalysisType.soil);
        expect(analysis.results.single.value, 12.5);
        expect(analysis.results.single.unit, 'mg/dm3');
        expect(analysis.context,
            'Profundidade: 0 a 20 cm\nLocal: Centro do talhão');
        expect(await readCoffeeAnalysisPdf(File(analysis.pdfPath!)), bytes);
      });
      await flow.tap(find.text('Comparar coletas'));
      await flow.tap(find.text('Comparar'));
      await flow.show(find.text('Diferença: +0,1 mg/dm3'), scroll: true);
      expect(tester.takeException(), isNull);
    } finally {
      await flow.close();
    }
  });
}
