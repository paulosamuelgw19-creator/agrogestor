import 'dart:typed_data';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'package:uuid/uuid.dart';
import '../../app/app_theme.dart';
import 'product_record.dart';
import 'product_categories.dart';
import 'product_classification_fields.dart';
import 'product_repository.dart';
import '../sync/sync_status_label.dart';
import '../licensing/write_gate.dart';
import '../analyses/coffee_analysis_repository.dart';
import '../coffee_finance/coffee_finance_repository.dart';
import '../local_backup/local_photo.dart';
import '../operations_v2/v2_store.dart' show Json;
import '../properties/catalog_store.dart';
import '../sync/farm_api_client.dart';
import '../sync/local_write_batch.dart';

Future<FarmProduct?> showCoffeeProductEditor(BuildContext context,
    {FarmProduct? product,
    String? propertyId,
    bool purchaseOnly = false}) async {
  final finance = CoffeeFinanceRepository();
  final catalog = await CatalogStore.open();
  final farms = await catalog.records('properties', archived: false);
  final expenses = await finance.unlinkedProductExpenses();
  if (!context.mounted) return null;
  return showDialog<FarmProduct>(
    context: context,
    builder: (_) => _ProductForm(
      product: product,
      coffee: true,
      farms: farms,
      expenses: expenses,
      propertyId: propertyId,
      purchaseOnly: purchaseOnly,
      save: (item, purchase) async {
        await LocalWriteBatch.run(() async {
          final repository = ProductRepository();
          final previous = await repository.getProducts();
          final stored = previous
              .where((candidate) => candidate.id == item.id)
              .firstOrNull;
          if (product != null && stored == null) {
            throw const FormatException(
                'O produto foi removido. Abra o estoque novamente.');
          }
          var saved = item;
          if (product != null && stored != null) {
            final changesStock =
                item.quantity != product.quantity || item.unit != product.unit;
            if (stored.unit != product.unit ||
                (!purchaseOnly &&
                    changesStock &&
                    stored.quantity != product.quantity)) {
              throw const FormatException(
                'O estoque mudou enquanto este cadastro estava aberto. Confira o saldo e abra o formulário novamente.',
              );
            }
            if (purchaseOnly) {
              saved =
                  stored.copyWith(quantity: stored.quantity + item.quantity);
            } else if (!changesStock) {
              saved = item.copyWith(quantity: stored.quantity);
            }
          }
          await repository.saveProducts(
            [...previous.where((candidate) => candidate.id != saved.id), saved],
            previous: previous,
          );
          if (purchase == null) return;
          final (farmId, year, amount, expenseId, pdf, pdfName) = purchase;
          if (expenseId != null) {
            await finance.linkProductPurchase(
              entryId: expenseId,
              productId: saved.id,
              pickedPdf: pdf,
              pickedPdfName: pdfName,
              catalogContext: catalog,
            );
            return;
          }
          final today = DateTime.now();
          await finance.saveEntry(
            CoffeeFinanceEntry(
              id: const Uuid().v4(),
              productId: saved.id,
              propertyId: farmId!,
              seasonYear: year,
              date: today,
              settledAt: amount == null ? null : today,
              kind: CoffeeFinanceKind.purchase,
              stage: CoffeeFinanceStage.management,
              category: 'Insumos',
              description: saved.name,
              quantity: item.quantity > 0 ? item.quantity : null,
              unit: item.quantity > 0 ? saved.unit : '',
              priceCents: amount,
            ),
            pickedPdf: pdf,
            pickedPdfName: pdfName,
            catalogContext: catalog,
          );
        });
      },
    ),
  );
}

typedef _ProductPurchase = (String?, int, int?, String?, Uint8List?, String?);

class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key, this.usageOnly = false});
  final bool usageOnly;
  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen>
    with SingleTickerProviderStateMixin {
  final _repo = ProductRepository();
  late final TabController _tabs;
  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: 0,
    )..addListener(() {
        if (mounted) setState(() {});
      });
    _load();
  }

  List<FarmProduct> _products = [];
  List<ProductUsage> _usage = [];
  bool _loading = true;
  String? _categoryFilter;
  List<FarmProduct> get _visibleProducts => _products
      .where((product) =>
          _categoryFilter == null || product.category == _categoryFilter)
      .toList();

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final result =
        await Future.wait<Object>([_repo.getProducts(), _repo.getUsage()]);
    if (mounted) {
      setState(() {
        _products = result[0] as List<FarmProduct>;
        _usage = result[1] as List<ProductUsage>;
        _loading = false;
      });
    }
  }

  Future<bool> _saveProducts(List<FarmProduct> items) async {
    final saved = await runLicensedWrite(
        context, () => _repo.saveProducts(items, previous: _products));
    if (saved && mounted) {
      setState(() => _products = items);
    }
    return saved;
  }

  Future<void> _edit([FarmProduct? original]) async {
    if (FarmApiClient.standaloneLocalMode) {
      await showCoffeeProductEditor(context, product: original);
      if (mounted) await _load();
      return;
    }
    final item = await showDialog<FarmProduct>(
        context: context, builder: (_) => _ProductForm(product: original));
    if (item == null) return;
    final list = [..._products];
    final index = list.indexWhere((x) => x.id == item.id);
    if (index < 0) {
      list.insert(0, item);
    } else {
      list[index] = item;
    }
    await _saveProducts(list);
  }

  Future<void> _purchases(FarmProduct product) async {
    final rows = await CoffeeFinanceRepository().productPurchases(product.id);
    if (!mounted) return;
    final money = NumberFormat.simpleCurrency(locale: 'pt_BR');
    final dates = DateFormat('dd/MM/yyyy');
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Compras de ${product.name}'),
        content: SizedBox(
          width: AppTheme.dialogWidth(context, maxWidth: 420),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (rows.isEmpty) const Text('Nenhuma compra vinculada.'),
              for (final row in rows)
                ListTile(
                  title: Text(row.totalCents == null
                      ? 'Valor não informado'
                      : money.format(row.totalCents! / 100)),
                  subtitle: Text(
                      '${dates.format(row.date)} · Safra ${row.seasonYear}'
                      '${row.pdfPath == null ? '' : ' · Nota fiscal anexada'}'),
                  trailing: row.pdfPath == null
                      ? null
                      : IconButton(
                          tooltip: 'Abrir nota fiscal',
                          icon: const Icon(Icons.picture_as_pdf_outlined),
                          onPressed: () => Navigator.of(context).push<void>(
                            MaterialPageRoute(
                              builder: (_) => Scaffold(
                                appBar:
                                    AppBar(title: const Text('Nota fiscal')),
                                body: PdfPreview(
                                  build: (_) =>
                                      readCoffeeAnalysisPdf(File(row.pdfPath!)),
                                  canChangePageFormat: false,
                                  canChangeOrientation: false,
                                ),
                              ),
                            ),
                          ),
                        ),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _delete(FarmProduct product) async {
    final yes = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                    title: const Text('Excluir produto?'),
                    content:
                        const Text('O histórico de utilização será mantido.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancelar')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Excluir'))
                    ])) ??
        false;
    if (yes) {
      await _saveProducts(_products.where((x) => x.id != product.id).toList());
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        floatingActionButton: !widget.usageOnly && _tabs.index == 0
            ? FloatingActionButton.extended(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add),
                label: const Text('Novo produto'))
            : null,
        body: SafeArea(
            child: Center(
                child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1000),
                    child: Padding(
                        padding: AppTheme.pagePadding(context),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('Produtos e insumos',
                                  style: TextStyle(
                                      fontSize: 28,
                                      fontWeight: FontWeight.w800,
                                      color: AppTheme.forest)),
                              const SizedBox(height: 5),
                              const Text(
                                  'Cadastros e estoque. Informe o consumo somente ao finalizar uma operação.',
                                  style: TextStyle(color: Colors.black54)),
                              const SizedBox(height: 12),
                              if (_tabs.index == 0)
                                DropdownButtonFormField<String>(
                                    initialValue: _categoryFilter ?? '',
                                    isExpanded: true,
                                    decoration: const InputDecoration(
                                        labelText: 'Filtrar categoria'),
                                    items: [
                                      const DropdownMenuItem(
                                          value: '',
                                          child: Text('Todas as categorias')),
                                      for (final category in {
                                        ...productCategories.keys,
                                        ..._products.map((p) => p.category),
                                        if (_categoryFilter != null)
                                          _categoryFilter!
                                      }.where((v) => v.isNotEmpty))
                                        DropdownMenuItem(
                                            value: category,
                                            child: Text(category,
                                                overflow:
                                                    TextOverflow.ellipsis))
                                    ],
                                    onChanged: (value) => setState(() =>
                                        _categoryFilter =
                                            value == '' ? null : value)),
                              TabBar(controller: _tabs, tabs: const [
                                Tab(text: 'Produtos e insumos'),
                                Tab(text: 'Histórico anterior')
                              ]),
                              Expanded(
                                  child: _loading
                                      ? const Center(
                                          child: CircularProgressIndicator())
                                      : TabBarView(
                                          controller: _tabs,
                                          children: [
                                              _productList(),
                                              _usageList()
                                            ])),
                            ]))))),
      );
  Widget _productList() => _visibleProducts.isEmpty
      ? _empty('Nenhum produto cadastrado', Icons.inventory_2_outlined,
          widget.usageOnly ? null : () => _edit())
      : ListView.separated(
          padding: const EdgeInsets.only(top: 12, bottom: 88),
          itemCount: _visibleProducts.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final product = _visibleProducts[index];
            final low = product.quantity <= 5;
            return Card(
                child: ListTile(
                    leading: product.photoPath != null
                        ? LocalPhotoThumbnail(
                            path: product.photoPath!,
                            fallback: const Icon(Icons.inventory_2_outlined))
                        : CircleAvatar(
                            backgroundColor:
                                (low ? const Color(0xFFC4852C) : AppTheme.leaf)
                                    .withValues(alpha: .12),
                            foregroundColor:
                                low ? const Color(0xFFC4852C) : AppTheme.leaf,
                            child: const Icon(Icons.inventory_2_outlined)),
                    title: Row(children: [
                      Expanded(
                          child: Text(product.name,
                              style: AppTheme.nameStyle(context))),
                      SyncStatusLabel(module: 'products', recordId: product.id),
                    ]),
                    subtitle: Text(
                        '${productClassification(product.category, product.productType)}${product.lot.isEmpty ? '' : ' · Lote ${product.lot}'}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(
                          '${product.quantity.toStringAsFixed(1)} ${product.unit}',
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: low
                                  ? const Color(0xFFC4852C)
                                  : AppTheme.forest)),
                      if (!widget.usageOnly)
                        PopupMenuButton<String>(
                            onSelected: (action) async {
                              switch (action) {
                                case 'edit':
                                  await _edit(product);
                                case 'purchase':
                                  await showCoffeeProductEditor(context,
                                      product: product, purchaseOnly: true);
                                  if (mounted) await _load();
                                case 'history':
                                  await _purchases(product);
                                case 'delete':
                                  await _delete(product);
                              }
                            },
                            itemBuilder: (_) => [
                                  const PopupMenuItem(
                                      value: 'edit', child: Text('Editar')),
                                  if (FarmApiClient.standaloneLocalMode) ...[
                                    const PopupMenuItem(
                                        value: 'purchase',
                                        child: Text('Registrar compra')),
                                    const PopupMenuItem(
                                        value: 'history',
                                        child: Text('Histórico de compras')),
                                  ],
                                  const PopupMenuItem(
                                      value: 'delete', child: Text('Excluir'))
                                ])
                    ])));
          });
  Widget _usageList() => _usage.isEmpty
      ? _empty('Nenhuma utilização anterior registrada', Icons.history, null)
      : ListView.separated(
          padding: const EdgeInsets.only(top: 12, bottom: 88),
          itemCount: _usage.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final item = _usage[index];
            return Card(
                child: ListTile(
                    leading: const CircleAvatar(
                        backgroundColor: Color(0xFFE8F1E9),
                        foregroundColor: AppTheme.leaf,
                        child: Icon(Icons.science_outlined)),
                    title: Row(children: [
                      Expanded(
                          child: Text(item.productName,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700))),
                      SyncStatusLabel(
                          module: 'productUsage', recordId: item.id),
                    ]),
                    subtitle: Text(
                        '${item.machine}${item.field.isEmpty ? '' : ' · ${item.field}'}${item.operatorName.isEmpty ? '' : ' · ${item.operatorName}'}\n${_date(item.date)}'),
                    isThreeLine: true,
                    trailing: Text(
                        '-${item.quantity.toStringAsFixed(1)} ${item.unit}',
                        style: const TextStyle(fontWeight: FontWeight.w700))));
          });
  Widget _empty(String message, IconData icon, VoidCallback? action) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 48, color: AppTheme.leaf),
        const SizedBox(height: 12),
        Text(message, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        if (action != null)
          OutlinedButton.icon(
              onPressed: action,
              icon: const Icon(Icons.add),
              label: const Text('Adicionar'))
      ]));
  String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

class _ProductForm extends StatefulWidget {
  const _ProductForm({
    this.product,
    this.coffee = false,
    this.purchaseOnly = false,
    this.farms = const [],
    this.expenses = const [],
    this.propertyId,
    this.save,
  });
  final FarmProduct? product;
  final bool coffee, purchaseOnly;
  final List<Json> farms;
  final List<CoffeeFinanceEntry> expenses;
  final String? propertyId;
  final Future<void> Function(FarmProduct, _ProductPurchase?)? save;
  @override
  State<_ProductForm> createState() => _ProductFormState();
}

class _ProductFormState extends State<_ProductForm> {
  final _key = GlobalKey<FormState>();
  bool _submitted = false;
  late final _name = TextEditingController(text: widget.product?.name ?? '');
  late String _category = widget.product?.category ?? '';
  late String _productType = widget.product?.productType ?? '';
  late final _unit = TextEditingController(text: widget.product?.unit ?? 'L');
  late final _quantity = TextEditingController(
      text: widget.purchaseOnly
          ? '0'
          : widget.product?.quantity.toString() ?? '0');
  late final _lot = TextEditingController(text: widget.product?.lot ?? '');
  final _amount = TextEditingController();
  final _year = TextEditingController(text: DateTime.now().year.toString());
  late String? _farm =
      widget.farms.any((farm) => farm['id'] == widget.propertyId)
          ? widget.propertyId
          : widget.farms.singleOrNull?['id'] as String?;
  late String? _photo = widget.product?.photoPath;
  String? _expense, _pdfName, _error;
  Uint8List? _pdf;
  bool _picking = false;
  bool get _purchaseFields =>
      widget.coffee && (widget.product == null || widget.purchaseOnly);
  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    _quantity.dispose();
    _lot.dispose();
    _amount.dispose();
    _year.dispose();
    super.dispose();
  }

  double? _num(String s) {
    final n = double.tryParse(s.trim().replaceAll(',', '.'));
    return n != null && n.isFinite ? n : null;
  }

  int? _cents(String text) {
    final input = text.trim().replaceAll(',', '.');
    if (!RegExp(r'^\d+(?:\.\d{1,2})?$').hasMatch(input)) return null;
    final value = _num(input);
    return value == null || value > 1e10 ? null : (value * 100).round();
  }

  Future<void> _pickPdf() async {
    setState(() => _picking = true);
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['pdf'],
      );
      if (file == null) return;
      final length = await file.length();
      if (length != null && length > coffeeAnalysisPdfMaxBytes) {
        throw const FormatException('Escolha um PDF de até 8 MB.');
      }
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in file.readAsByteStream()) {
        if (buffer.length + chunk.length > coffeeAnalysisPdfMaxBytes) {
          throw const FormatException('Escolha um PDF de até 8 MB.');
        }
        buffer.add(chunk);
      }
      final bytes = buffer.takeBytes();
      validateCoffeeAnalysisPdf(bytes);
      if (mounted) {
        setState(() {
          _pdf = bytes;
          _pdfName = file.name;
          _error = null;
        });
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Não foi possível anexar a nota.');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _submit() async {
    if (_submitted || !_key.currentState!.validate()) return;
    final amount = _cents(_amount.text);
    final hasPurchase = _purchaseFields &&
        (widget.purchaseOnly ||
            _expense != null ||
            _pdf != null ||
            amount != null);
    final year = int.tryParse(_year.text.trim());
    if (hasPurchase &&
        _expense == null &&
        (_farm == null || year == null || year < 1900 || year > 9999)) {
      setState(() => _error = 'Escolha a fazenda e informe a safra da compra.');
      return;
    }
    final item = FarmProduct(
        id: widget.product?.id ?? const Uuid().v4(),
        name: _name.text.trim(),
        category: _category,
        productType: _productType,
        unit: _unit.text.trim(),
        quantity: _num(_quantity.text)!,
        lot: _lot.text.trim(),
        photoPath: _photo);
    final save = widget.save;
    if (save == null) {
      Navigator.pop(context, item);
      return;
    }
    setState(() {
      _submitted = true;
      _error = null;
    });
    try {
      if (await runLicensedWrite(
              context,
              () => save(
                  item,
                  hasPurchase
                      ? (
                          _farm,
                          year ?? DateTime.now().year,
                          amount,
                          _expense,
                          _pdf,
                          _pdfName
                        )
                      : null)) &&
          mounted) {
        Navigator.pop(context, item);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Não foi possível salvar o produto ou a nota.');
      }
    } finally {
      if (mounted) setState(() => _submitted = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.purchaseOnly
              ? 'Registrar compra'
              : widget.product == null
                  ? 'Novo produto'
                  : 'Editar produto'),
          content: SizedBox(
              width: AppTheme.dialogWidth(context, maxWidth: 430),
              child: Form(
                  key: _key,
                  child: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    if (!widget.purchaseOnly) ...[
                      TextFormField(
                          controller: _name,
                          decoration:
                              const InputDecoration(labelText: 'Produto'),
                          validator: (v) => v == null || v.trim().isEmpty
                              ? 'Informe o nome'
                              : null),
                      const SizedBox(height: 10),
                      ProductClassificationFields(
                          requireType: widget.product == null,
                          category: _category,
                          type: _productType,
                          onChanged: (category, type) {
                            _category = category;
                            _productType = type;
                          }),
                    ],
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                          child: TextFormField(
                              controller: _quantity,
                              decoration: InputDecoration(
                                  labelText: widget.purchaseOnly
                                      ? 'Quantidade comprada'
                                      : 'Estoque atual'),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              validator: (v) =>
                                  _num(v ?? '') == null || _num(v ?? '')! < 0
                                      ? 'Quantidade inválida'
                                      : null)),
                      const SizedBox(width: 10),
                      Expanded(
                          child: TextFormField(
                              controller: _unit,
                              readOnly: widget.purchaseOnly,
                              decoration:
                                  const InputDecoration(labelText: 'Unidade'),
                              validator: (v) => v == null || v.trim().isEmpty
                                  ? 'Informe a unidade'
                                  : null))
                    ]),
                    const SizedBox(height: 10),
                    if (!widget.purchaseOnly)
                      TextFormField(
                          controller: _lot,
                          decoration: const InputDecoration(
                              labelText: 'Lote (opcional)')),
                    if (widget.coffee && !widget.purchaseOnly)
                      LocalPhotoField(
                          photoPath: _photo,
                          enabled: !_submitted,
                          onChanged: (value) => setState(() => _photo = value)),
                    if (_purchaseFields) ...[
                      const Divider(height: 24),
                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: _expense ?? '',
                        decoration: const InputDecoration(
                            labelText: 'Despesa existente (opcional)'),
                        items: [
                          const DropdownMenuItem(
                              value: '',
                              child: Text('Nenhuma despesa vinculada')),
                          for (final entry in widget.expenses)
                            DropdownMenuItem(
                                value: entry.id,
                                child: Text(
                                    '${entry.description} · ${DateFormat('dd/MM/yyyy').format(entry.date)}',
                                    overflow: TextOverflow.ellipsis)),
                        ],
                        onChanged: _submitted
                            ? null
                            : (value) => setState(
                                () => _expense = value == '' ? null : value),
                      ),
                      if (_expense == null) ...[
                        DropdownButtonFormField<String>(
                          isExpanded: true,
                          initialValue: _farm,
                          decoration: const InputDecoration(
                              labelText: 'Fazenda da compra'),
                          items: [
                            for (final farm in widget.farms)
                              DropdownMenuItem(
                                  value: farm['id'] as String,
                                  child: Text(farm['name'] as String,
                                      overflow: TextOverflow.ellipsis)),
                          ],
                          onChanged: _submitted
                              ? null
                              : (value) => setState(() => _farm = value),
                        ),
                        TextFormField(
                          controller: _year,
                          maxLength: 4,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                              labelText: 'Safra da compra', counterText: ''),
                        ),
                        TextFormField(
                          controller: _amount,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          decoration: const InputDecoration(
                              labelText: r'Valor pago (R$, opcional)'),
                          validator: (text) => (text ?? '').trim().isNotEmpty &&
                                  _cents(text!) == null
                              ? 'Informe um valor válido.'
                              : null,
                        ),
                      ],
                      TextButton.icon(
                        onPressed: _picking || _submitted ? null : _pickPdf,
                        icon: const Icon(Icons.attach_file),
                        label: const Text('Anexar nota fiscal (PDF)'),
                      ),
                      if (_pdfName != null)
                        ListTile(
                            title: Text(_pdfName!),
                            trailing: IconButton(
                              tooltip: 'Remover nota fiscal',
                              onPressed: _submitted
                                  ? null
                                  : () => setState(() {
                                        _pdf = null;
                                        _pdfName = null;
                                      }),
                              icon: const Icon(Icons.close),
                            )),
                    ],
                    if (_error case final String error) Text(error),
                  ])))),
          actions: [
            TextButton(
                onPressed: _submitted ? null : () => Navigator.pop(context),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: _submitted || _picking ? null : _submit,
                child: const Text('Salvar'))
          ]);
}
