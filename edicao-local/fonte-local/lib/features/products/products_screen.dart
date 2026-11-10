import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../app/app_theme.dart';
import 'product_record.dart';
import 'product_categories.dart';
import 'product_classification_fields.dart';
import 'product_repository.dart';
import '../sync/sync_status_label.dart';
import '../licensing/write_gate.dart';

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
                    leading: CircleAvatar(
                        backgroundColor:
                            (low ? const Color(0xFFC4852C) : AppTheme.leaf)
                                .withValues(alpha: .12),
                        foregroundColor:
                            low ? const Color(0xFFC4852C) : AppTheme.leaf,
                        child: const Icon(Icons.inventory_2_outlined)),
                    title: Row(children: [
                      Expanded(
                          child: Text(product.name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700))),
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
                            onSelected: (action) => action == 'edit'
                                ? _edit(product)
                                : _delete(product),
                            itemBuilder: (_) => const [
                                  PopupMenuItem(
                                      value: 'edit', child: Text('Editar')),
                                  PopupMenuItem(
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
  const _ProductForm({this.product});
  final FarmProduct? product;
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
  late final _quantity =
      TextEditingController(text: widget.product?.quantity.toString() ?? '0');
  late final _lot = TextEditingController(text: widget.product?.lot ?? '');
  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    _quantity.dispose();
    _lot.dispose();
    super.dispose();
  }

  double? _num(String s) {
    final n = double.tryParse(s.trim().replaceAll(',', '.'));
    return n != null && n.isFinite ? n : null;
  }

  void _submit() {
    if (_submitted || !_key.currentState!.validate()) return;
    _submitted = true;
    Navigator.pop(
        context,
        FarmProduct(
            id: widget.product?.id ?? const Uuid().v4(),
            name: _name.text.trim(),
            category: _category,
            productType: _productType,
            unit: _unit.text.trim(),
            quantity: _num(_quantity.text)!,
            lot: _lot.text.trim()));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title:
              Text(widget.product == null ? 'Novo produto' : 'Editar produto'),
          content: SizedBox(
              width: AppTheme.dialogWidth(context, maxWidth: 430),
              child: Form(
                  key: _key,
                  child: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextFormField(
                        controller: _name,
                        decoration: const InputDecoration(labelText: 'Produto'),
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
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                          child: TextFormField(
                              controller: _quantity,
                              decoration: const InputDecoration(
                                  labelText: 'Estoque atual'),
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
                              decoration:
                                  const InputDecoration(labelText: 'Unidade'),
                              validator: (v) => v == null || v.trim().isEmpty
                                  ? 'Informe a unidade'
                                  : null))
                    ]),
                    const SizedBox(height: 10),
                    TextFormField(
                        controller: _lot,
                        decoration: const InputDecoration(
                            labelText: 'Lote (opcional)')),
                  ])))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar')),
            FilledButton(onPressed: _submit, child: const Text('Salvar'))
          ]);
}
