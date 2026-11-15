import 'dart:convert';
import 'dart:io';

import 'package:agrogestao/features/analyses/coffee_analysis_repository.dart';
import 'package:agrogestao/features/coffee_finance/coffee_finance_repository.dart';
import 'package:agrogestao/features/local_backup/local_backup_service.dart';
import 'package:agrogestao/features/operators/operator.dart';
import 'package:agrogestao/features/operators/operator_repository.dart';
import 'package:agrogestao/features/products/product_record.dart';
import 'package:agrogestao/features/products/product_repository.dart';
import 'package:agrogestao/features/products/products_screen.dart';
import 'package:agrogestao/features/properties/catalog_store.dart';
import 'package:agrogestao/features/sync/app_database.dart';
import 'package:agrogestao/features/tools/coffee_tools_repository.dart';
import 'package:agrogestao/features/tools/coffee_tools_screen.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;

import 'coffee_notebook_harvest_test.dart' show useCoffeeDatabase;

final _date = DateTime(2026, 6, 10);
const _product = FarmProduct(
    id: 'test-product',
    name: 'Insumo Teste',
    category: 'Insumos',
    unit: 'L',
    quantity: 20,
    lot: '');

CoffeeFinanceEntry _expense(String id, int cents, {String? productId}) =>
    CoffeeFinanceEntry(
      id: id,
      productId: productId,
      propertyId: 'farm',
      seasonYear: 2026,
      date: _date,
      settledAt: _date,
      kind: CoffeeFinanceKind.purchase,
      stage: CoffeeFinanceStage.management,
      category: 'Compras de teste',
      description: id,
      priceCents: cents,
    );

Future<Uint8List> _invoice(String title) {
  final pdf = pw.Document();
  pdf.addPage(pw.Page(build: (_) => pw.Text(title)));
  return pdf.save();
}

final class _InvoiceFile extends PlatformFile {
  _InvoiceFile(this.bytes);
  final Uint8List bytes;

  @override
  String get name => 'nota-ficticia.pdf';
  @override
  Uri get uri => Uri.parse('test:nota-ficticia.pdf');
  @override
  Never get xFile => throw UnsupportedError('PDF lido pelo stream');
  @override
  int lengthSync() => bytes.length;
  @override
  Future<int> length() async => bytes.length;
  @override
  Future<Uint8List> readAsBytes() async => bytes;
  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(bytes);
}

class _InvoicePicker extends FilePickerPlatform {
  _InvoicePicker(this.file);
  final _InvoiceFile file;

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
    expect(allowedExtensions, ['pdf']);
    return file;
  }
}

class _Screen {
  _Screen(this.tester) {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  final WidgetTester tester;

  Future<void> wait(Finder finder) async {
    for (var i = 0; i < 150 && finder.evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finder, findsWidgets);
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> tap(Finder finder) async {
    await wait(finder);
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> enter(String label, String value) async {
    final field = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
        description: 'campo $label');
    await wait(field);
    await tester.ensureVisible(field);
    await tester.enterText(field, value);
    await tester.pump();
  }

  Future<void> close() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  useCoffeeDatabase();

  testWidgets(
      'editar o nome mantém o saldo atualizado enquanto o formulário estava aberto',
      (tester) async {
    final flow = _Screen(tester);
    final repo = ProductRepository();
    await tester.runAsync(() => repo.saveProducts([_product], previous: []));
    try {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                      onPressed: () =>
                          showCoffeeProductEditor(context, product: _product),
                      child: const Text('Editar cadastro teste'),
                    ))),
      ));
      await flow.tap(find.text('Editar cadastro teste'));
      await flow.enter('Produto', 'Novo nome');
      await tester.runAsync(() => repo.saveProducts(
          [_product.copyWith(quantity: 17)],
          previous: [_product]));
      await flow.tap(find.text('Salvar'));
      for (var i = 0;
          i < 150 && find.byType(AlertDialog).evaluate().isNotEmpty;
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.byType(AlertDialog), findsNothing);
      await tester.runAsync(() async {
        final saved = (await repo.getProducts()).single;
        expect(saved.name, 'Novo nome');
        expect(saved.quantity, 17);
      });
    } finally {
      await flow.close();
    }
  });

  test('compras do mesmo produto preservam valor, nota e despesa existente',
      () async {
    final products = ProductRepository();
    final finance = CoffeeFinanceRepository();
    final first = await _invoice('Nota fiscal numero 1');
    final second = await _invoice('Nota fiscal numero 2');
    await products.saveProducts([_product], previous: []);
    await finance.saveEntry(_expense('primeira', 12500, productId: _product.id),
        pickedPdf: first, pickedPdfName: 'primeira.pdf');
    await finance.saveEntry(_expense('segunda', 17250));
    await finance.linkProductPurchase(
        entryId: 'segunda',
        productId: _product.id,
        pickedPdf: second,
        pickedPdfName: 'segunda.pdf');
    await finance.linkProductPurchase(
        entryId: 'segunda', productId: _product.id);
    await appDatabase.close();
    expect((await products.getProducts()).single.id, _product.id);
    final purchases = {
      for (final item in await finance.productPurchases(_product.id))
        item.id: item,
    };
    expect(purchases, hasLength(2));
    expect(purchases['primeira']!.totalCents, 12500);
    expect(purchases['segunda']!.totalCents, 17250);
    expect(await readCoffeeAnalysisPdf(File(purchases['primeira']!.pdfPath!)),
        first);
    expect(await readCoffeeAnalysisPdf(File(purchases['segunda']!.pdfPath!)),
        second);
    final summary = await finance.summary(propertyId: 'farm', seasonYear: 2026);
    expect(summary.entries, hasLength(2));
    expect(summary.cashOutCents, 29750);
  });

  test('backup v7 mantém fotos corretas, ferramenta e vínculo financeiro único',
      () async {
    final root = await getApplicationSupportDirectory();
    final attachments = Directory('${root.path}/attachments');
    await attachments.create();
    Future<File> photo(String name, int marker) async =>
        File('${attachments.path}/$name.img').writeAsBytes([1, 2, marker]);
    final original = await photo('farm-first', 10);
    final replacement = await photo('farm-second', 20);
    final plotPhoto = await photo('plot', 30);
    final personPhoto = await photo('person', 40);
    final productPhoto = await photo('product', 50);
    final toolPhoto = await photo('tool', 60);

    final catalog = await CatalogStore.open();
    await catalog.save('PATCH', '/properties/farm', {
      'id': 'farm-photo-first',
      'name': 'Fazenda teste',
      'photoPath': original.path,
      'expected_version': 1
    });
    await catalog.save('PATCH', '/properties/farm', {
      'id': 'farm-photo-second',
      'name': 'Fazenda teste',
      'photoPath': replacement.path,
      'expected_version': 2
    });
    await catalog.save('PATCH', '/plots/plot-a', {
      'id': 'plot-photo-first',
      'name': 'Talhão A',
      'photoPath': plotPhoto.path,
      'expected_version': 1
    });
    final operators = OperatorRepository();
    final current = await operators.getAll();
    final updated = Operator.fromJson({
      ...current.singleWhere((person) => person.id == 'first').toJson(),
      'photoPath': personPhoto.path,
    });
    await operators.saveAll(
        [for (final person in current) person.id == 'first' ? updated : person],
        previous: current);
    final products = ProductRepository();
    await products.saveProducts([
      FarmProduct.fromJson(
          {..._product.toJson(), 'photoPath': productPhoto.path}),
    ], previous: []);
    final finance = CoffeeFinanceRepository();
    await finance.saveEntry(_expense('ferramenta-despesa', 6500));
    final tools = CoffeeToolsRepository();
    await tools
        .save(const CoffeeTool(id: 'category', name: 'Ferramentas teste'));
    await tools.save(CoffeeTool(
        id: 'tool',
        name: 'Enxada',
        categoryId: 'category',
        paidCents: 6500,
        notes: 'Cabo de madeira',
        expenseId: 'ferramenta-despesa',
        photoPath: toolPhoto.path));
    await expectLater(
        tools.save(const CoffeeTool(
            id: 'duplicate',
            name: 'Outra enxada',
            categoryId: 'category',
            expenseId: 'ferramenta-despesa')),
        throwsFormatException);
    await expectLater(
        finance.linkProductPurchase(
            entryId: 'ferramenta-despesa', productId: _product.id),
        throwsFormatException);
    final backup = LocalBackupService();
    final bytes = await backup.create();
    expect(jsonDecode(utf8.decode(bytes))['schemaVersion'], 7);
    await appDatabase.close();
    await backup.restore(bytes);
    final restored = await CatalogStore.open();
    Future<Map<String, dynamic>> findRecord(String type, String id) async =>
        (await restored.records(type))
            .singleWhere((entry) => entry['id'] == id);
    Future<void> assertPhoto(String? path, int marker) async {
      expect(path, isNotNull);
      expect(path, contains('restore-'));
      expect(await File(path!).readAsBytes(), [1, 2, marker]);
    }

    await assertPhoto(
        (await findRecord('properties', 'farm'))['photoPath'] as String?, 20);
    await assertPhoto(
        (await findRecord('plots', 'plot-a'))['photoPath'] as String?, 30);
    expect((await findRecord('plots', 'plot-b'))['photoPath'], isNull);
    await assertPhoto(
        (await operators.getAll())
            .singleWhere((item) => item.id == 'first')
            .photoPath,
        40);
    expect(
        (await operators.getAll())
            .singleWhere((item) => item.id == 'second')
            .photoPath,
        isNull);
    await assertPhoto((await products.getProducts()).single.photoPath, 50);
    final tool =
        (await tools.getAll()).singleWhere((item) => item.id == 'tool');
    await assertPhoto(tool.photoPath, 60);
    expect(tool.categoryId, 'category');
    expect(tool.paidCents, 6500);
    expect(tool.notes, 'Cabo de madeira');
    expect(tool.expenseId, 'ferramenta-despesa');
    final summary = await finance.summary(propertyId: 'farm', seasonYear: 2026);
    expect(summary.cashOutCents, 6500);
  });

  testWidgets('Ferramentas cadastra categoria e item com preço e observação',
      (tester) async {
    final flow = _Screen(tester);
    try {
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: CoffeeToolsScreen())));
      await flow.tap(find.text('Nova categoria'));
      await flow.enter('Nome', 'Ferramentas do terreiro');
      await flow.tap(find.text('Salvar'));
      await flow
          .tap(find.widgetWithText(ExpansionTile, 'Ferramentas do terreiro'));
      await flow.tap(find.text('Adicionar ferramenta'));
      await flow.enter('Nome', 'Rastelo de madeira');
      await flow.enter('Valor pago (R\$)', '65,50');
      await flow.enter('Observações', 'Usado no terreiro');
      await flow.tap(find.text('Salvar'));
      await flow.wait(find.widgetWithText(ListTile, 'Rastelo de madeira'));
      final items =
          await tester.runAsync(() => CoffeeToolsRepository().getAll());
      final saved =
          items!.singleWhere((item) => item.name == 'Rastelo de madeira');
      expect(saved.paidCents, 6550);
      expect(saved.notes, 'Usado no terreiro');
      expect(
          saved.categoryId,
          items
              .singleWhere((item) => item.name == 'Ferramentas do terreiro')
              .id);
      expect(tester.takeException(), isNull);
    } finally {
      await flow.close();
    }
  });

  testWidgets('cadastro de produto cria compra inicial no Financeiro',
      (tester) async {
    final flow = _Screen(tester);
    final pdf = (await tester.runAsync(() => _invoice('Nota do cadastro')))!;
    final originalPicker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = _InvoicePicker(_InvoiceFile(pdf));
    addTearDown(() => FilePickerPlatform.instance = originalPicker);
    try {
      await tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showCoffeeProductEditor(context, propertyId: 'farm'),
          child: const Text('Cadastrar produto teste'),
        ),
      ))));
      await flow.tap(find.text('Cadastrar produto teste'));
      await flow.enter('Produto', 'Adubo Teste');
      Finder menu(String label) => find.byWidgetPredicate((widget) =>
          widget is InputDecorator && widget.decoration.labelText == label);
      await flow.tap(menu('Categoria'));
      await flow.wait(find.text('Químicos e minerais'));
      await flow.tap(find.text('Químicos e minerais').last);
      await flow.tap(menu('Tipo de produto'));
      await flow.wait(find.text('Fertilizantes e adubos minerais'));
      await flow.tap(find.text('Fertilizantes e adubos minerais').last);
      await flow.enter('Estoque atual', '8');
      await flow.enter('Valor pago (R\$, opcional)', '190,75');
      await flow.tap(find.text('Anexar nota fiscal (PDF)'));
      await flow.wait(find.text('nota-ficticia.pdf'));
      await flow.tap(find.text('Salvar'));
      for (var i = 0;
          i < 150 && find.byType(AlertDialog).evaluate().isNotEmpty;
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.byType(AlertDialog), findsNothing);
      await tester.runAsync(() async {
        final product = (await ProductRepository().getProducts()).single;
        expect(product.name, 'Adubo Teste');
        expect(product.quantity, 8);
        final rows =
            await CoffeeFinanceRepository().productPurchases(product.id);
        expect(rows.single.totalCents, 19075);
        expect(rows.single.propertyId, 'farm');
        expect(await readCoffeeAnalysisPdf(File(rows.single.pdfPath!)), pdf);
      });
      expect(tester.takeException(), isNull);
    } finally {
      await flow.close();
    }
  });
}
