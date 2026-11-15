import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../products/product_record.dart';
import '../properties/coffee_planting.dart';
import 'coffee_input_plan.dart';

const _labels = {
  CoffeeInputKind.direct: 'Quantidade direta',
  CoffeeInputKind.fertilizer: 'Adubação por pé',
  CoffeeInputKind.bags: 'Adubação por sacos',
  CoffeeInputKind.spray: 'Pulverização por carga',
};

enum _PlantSource { wholePlot, counted, partialArea, savedEstimate }

String _display(double value) =>
    value.toString().replaceFirst(RegExp(r'\.0$'), '').replaceAll('.', ',');

String _amount(double? value, String unit) => value == null
    ? 'Pendente'
    : '${_display(double.parse(value.toStringAsPrecision(10)))} $unit';

String coffeeInputSummary(CoffeeInputPlan plan, {bool applied = false}) => [
      '${plan.productName} · ${_labels[plan.kind]}',
      if (plan.doseQuantity case final double dose)
        'Dose: ${_amount(dose, plan.inputUnit)} por ${plan.doseReference}',
      'Quantidade informada: ${_amount(plan.quantity > 0 ? plan.quantity : null, plan.inputUnit)}',
      if (plan.kind == CoffeeInputKind.fertilizer)
        plan.treatedPlants == null
            ? 'Pés tratados: pendente'
            : '${plan.treatedPlants} pés tratados${plan.estimatedPlants ? ' (estimativa)' : ''}',
      if (plan.kind == CoffeeInputKind.bags && plan.bagWeightKg != null)
        'Peso por saco: ${_amount(plan.bagWeightKg, 'kg')}',
      if (plan.kind == CoffeeInputKind.spray) ...[
        if (plan.capacityLiters != null)
          'Capacidade da carga: ${_amount(plan.capacityLiters, 'L')}',
        if (plan.coveredHectares != null)
          'Área coberta: ${_amount(plan.coveredHectares, 'ha')}',
        if (plan.appliedLiters != null)
          plan.loadCount == null
              ? 'Calda da carga: ${_amount(plan.appliedLiters, 'L')}'
              : 'Calda total: ${_amount(plan.appliedLiters, 'L')} · ${plan.loadCount} cargas de ${_amount(plan.litersPerLoad, 'L')}',
        'Produto por hectare: ${_amount(plan.productPerHectare, '${plan.inputUnit}/ha')}',
        'Calda por hectare: ${_amount(plan.sprayLitersPerHectare, 'L/ha')}',
      ],
      '${applied ? 'Quantidade aplicada' : 'Total previsto no estoque'}: ${_amount(plan.quantityInStockUnit, plan.stockUnit)}',
    ].join('\n');

class CoffeeInputPlanning extends StatelessWidget {
  const CoffeeInputPlanning({
    super.key,
    required this.products,
    required this.plot,
    required this.plans,
    required this.onChanged,
    this.applied = false,
    this.plannedSprays = const [],
    this.application = false,
    this.createProduct,
  });

  final List<FarmProduct> products;
  final Map<String, dynamic> plot;
  final List<CoffeeInputPlan> plans;
  final ValueChanged<List<CoffeeInputPlan>> onChanged;
  final bool applied;
  final List<CoffeeInputPlan> plannedSprays;
  final bool application;
  final Future<FarmProduct?> Function(BuildContext)? createProduct;

  Future<void> _edit(BuildContext context,
      {int? index, CoffeeInputPlan? copy}) async {
    final plan = await showDialog<CoffeeInputPlan>(
      context: context,
      builder: (_) => _CoffeeInputDialog(
        products: products,
        plot: plot,
        initial: index == null ? copy : plans[index],
        applied: applied,
        editing: index != null,
        application: application,
        createProduct: createProduct,
      ),
    );
    if (plan == null || !context.mounted) return;
    final updated = [...plans];
    if (index == null) {
      updated.add(plan);
    } else {
      updated[index] = plan;
    }
    onChanged(updated);
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (applied)
            const Text(
                'Inclua a quantidade destas cargas no consumo confirmado. Você pode informar um consumo maior quando houver outras cargas.')
          else ...[
            Text(application ? 'Receita da aplicação' : 'Insumos planejados',
                style: Theme.of(context).textTheme.titleMedium),
            const Text(
                'Confira e ajuste as quantidades reais ao finalizar o serviço.'),
          ],
          if (products.isEmpty && createProduct == null)
            const Text('Cadastre os produtos em Produtos e insumos.'),
          if (applied)
            for (final (index, plan) in plannedSprays.indexed)
              TextButton(
                onPressed: () => _edit(context, copy: plan),
                child: Text(
                    'Copiar carga planejada ${index + 1} · ${plan.productName}'),
              ),
          for (final (index, plan) in plans.indexed)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(coffeeInputSummary(plan, applied: applied)),
                    Wrap(children: [
                      TextButton(
                        onPressed: () => _edit(context, index: index),
                        child: const Text('Editar'),
                      ),
                      TextButton(
                        onPressed: () => onChanged([...plans]..removeAt(index)),
                        child: const Text('Remover'),
                      ),
                    ]),
                  ],
                ),
              ),
            ),
          if (products.isNotEmpty || createProduct != null)
            OutlinedButton.icon(
              onPressed: () => _edit(context),
              icon: const Icon(Icons.add),
              label: Text(
                  applied ? 'Adicionar carga aplicada' : 'Planejar insumo'),
            ),
        ],
      );
}

class _CoffeeInputDialog extends StatefulWidget {
  const _CoffeeInputDialog(
      {required this.products,
      required this.plot,
      this.initial,
      required this.applied,
      required this.editing,
      required this.application,
      this.createProduct});

  final List<FarmProduct> products;
  final Map<String, dynamic> plot;
  final CoffeeInputPlan? initial;
  final bool applied, editing;
  final bool application;
  final Future<FarmProduct?> Function(BuildContext)? createProduct;

  @override
  State<_CoffeeInputDialog> createState() => _CoffeeInputDialogState();
}

class _CoffeeInputDialogState extends State<_CoffeeInputDialog> {
  final _form = GlobalKey<FormState>();
  String _search = '';
  String? _error;
  bool _creating = false;
  late final List<FarmProduct> _products = [...widget.products];
  late FarmProduct? _product = widget.products
      .where((product) => product.id == widget.initial?.productId)
      .firstOrNull;
  late String? _lastProductId = widget.initial?.productId;
  late CoffeeInputKind _kind = widget.applied
      ? CoffeeInputKind.spray
      : widget.initial?.kind ??
          (widget.application ? CoffeeInputKind.spray : CoffeeInputKind.direct);
  late String? _unit = widget.initial?.inputUnit;
  late _PlantSource _source = widget.initial?.estimatedPlants == true
      ? _PlantSource.savedEstimate
      : widget.initial == null
          ? _PlantSource.wholePlot
          : _PlantSource.counted;
  late final _quantity = _controller(
    (widget.initial?.quantity ?? 0) > 0 ? widget.initial!.quantity : null,
  );
  late final _plants = TextEditingController(
      text: widget.initial?.treatedPlants?.toString() ?? '');
  final _partialArea = TextEditingController();
  late final _bagWeight = _controller(widget.initial?.bagWeightKg);
  late final _capacity = _controller(widget.initial?.capacityLiters);
  late final _calda = _controller(
      widget.initial?.litersPerLoad ?? widget.initial?.appliedLiters);
  late final _loadCount =
      TextEditingController(text: widget.initial?.loadCount?.toString() ?? '');
  late final _covered = _controller(widget.initial?.coveredHectares);
  late final _dose = _controller(widget.initial?.doseQuantity);
  late final _reference =
      TextEditingController(text: widget.initial?.doseReference);

  TextEditingController _controller(double? value) =>
      TextEditingController(text: value == null ? '' : _display(value));

  @override
  void dispose() {
    for (final controller in [
      _quantity,
      _plants,
      _partialArea,
      _bagWeight,
      _capacity,
      _calda,
      _loadCount,
      _covered,
      _dose,
      _reference,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  double? _parse(String input) =>
      double.tryParse(input.trim().replaceAll(',', '.'));

  int? get _treatedPlants {
    if (_source == _PlantSource.wholePlot) return plotCoffeePlants(widget.plot);
    if (_source == _PlantSource.counted) {
      return int.tryParse(_plants.text.trim());
    }
    if (_source == _PlantSource.savedEstimate) {
      return widget.initial?.treatedPlants;
    }
    final partial = _parse(_partialArea.text);
    final area = plotAreaHectares(widget.plot['area_ha']);
    final total = plotCoffeePlants(widget.plot);
    final density = (widget.plot[coffeePlantDensity] as num?)?.toDouble() ??
        (total != null && area != null ? total / area : null);
    if (partial == null ||
        !partial.isFinite ||
        partial <= 0 ||
        (area != null && partial > area) ||
        density == null) {
      return null;
    }
    final estimate = partial * density;
    return estimate.isFinite && estimate >= 0.5 && estimate <= 1000000000
        ? estimate.round()
        : null;
  }

  bool get _estimatedPlants =>
      _source == _PlantSource.partialArea ||
      (_source == _PlantSource.wholePlot &&
          widget.plot[coffeePlantCount] == null) ||
      _source == _PlantSource.savedEstimate;

  List<String> _units(FarmProduct product) =>
      switch (product.unit.trim().toLowerCase()) {
        'kg' => [product.unit, 'g'],
        'g' => [product.unit, 'kg'],
        'l' => [product.unit, 'mL'],
        'ml' => [product.unit, 'L'],
        _ => [product.unit],
      };

  CoffeeInputPlan? get _draft {
    final product = _product;
    final quantity = _parse(_quantity.text);
    if (product == null ||
        quantity == null ||
        !quantity.isFinite ||
        quantity <= 0) {
      return null;
    }
    final loads = _kind == CoffeeInputKind.spray
        ? int.tryParse(_loadCount.text.trim())
        : null;
    final calda = _kind == CoffeeInputKind.spray ? _parse(_calda.text) : null;
    return CoffeeInputPlan(
      productId: product.id,
      productName: product.name,
      stockUnit: product.unit,
      kind: _kind,
      quantity: quantity,
      inputUnit: switch (_kind) {
        CoffeeInputKind.fertilizer => 'g/pé',
        CoffeeInputKind.bags => 'sacos',
        _ => _unit ?? product.unit,
      },
      treatedPlants:
          _kind == CoffeeInputKind.fertilizer ? _treatedPlants : null,
      estimatedPlants: _kind == CoffeeInputKind.fertilizer &&
          _treatedPlants != null &&
          _estimatedPlants,
      bagWeightKg:
          _kind == CoffeeInputKind.bags ? _parse(_bagWeight.text) : null,
      capacityLiters:
          _kind == CoffeeInputKind.spray ? _parse(_capacity.text) : null,
      appliedLiters: calda == null ? null : calda * (loads ?? 1),
      loadCount: loads,
      litersPerLoad: loads == null ? null : calda,
      coveredHectares:
          _kind == CoffeeInputKind.spray ? _parse(_covered.text) : null,
      doseQuantity: _parse(_dose.text),
      doseReference: _reference.text.trim(),
    );
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final plan = _draft;
    if (plan == null) return;
    final error = plan.validationError;
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, plan);
  }

  void _refresh() => setState(() => _error = null);

  void _select(FarmProduct product) => setState(() {
        if (_lastProductId != product.id) {
          _quantity.clear();
          _dose.clear();
          _reference.clear();
          _unit = product.unit;
        }
        _product = product;
        _lastProductId = product.id;
        _error = null;
      });

  Future<void> _create() async {
    if (_creating) return;
    final create = widget.createProduct;
    if (create == null) return;
    setState(() => _creating = true);
    try {
      final product = await create(context);
      if (mounted && product != null) {
        _products.removeWhere((item) => item.id == product.id);
        _products.add(product);
        _select(product);
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Widget _number(
    String label,
    TextEditingController controller, {
    bool required = false,
    String? Function(double value)? check,
  }) =>
      Padding(
        padding: const EdgeInsets.only(top: 10),
        child: TextFormField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: label),
          onChanged: (_) => _refresh(),
          validator: (text) {
            if ((text ?? '').trim().isEmpty && !required) return null;
            final value = _parse(text ?? '');
            return value == null || !value.isFinite || value <= 0
                ? 'Informe um número maior que zero.'
                : check?.call(value);
          },
        ),
      );

  List<Widget> _plantFields() => [
        const SizedBox(height: 10),
        DropdownButtonFormField<_PlantSource>(
          initialValue: _source,
          isExpanded: true,
          decoration:
              const InputDecoration(labelText: 'Como informar os pés tratados'),
          items: [
            const DropdownMenuItem(
                value: _PlantSource.wholePlot, child: Text('Talhão inteiro')),
            const DropdownMenuItem(
                value: _PlantSource.counted, child: Text('Contagem informada')),
            const DropdownMenuItem(
                value: _PlantSource.partialArea,
                child: Text('Estimar pela área parcial')),
            if (widget.initial?.estimatedPlants == true)
              const DropdownMenuItem(
                  value: _PlantSource.savedEstimate,
                  child: Text('Estimativa registrada')),
          ],
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              _source = value;
              _error = null;
            });
          },
        ),
        if (_source == _PlantSource.counted)
          TextFormField(
            controller: _plants,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Pés tratados'),
            onChanged: (_) => _refresh(),
            validator: (text) {
              if ((text ?? '').trim().isEmpty) return null;
              final value = int.tryParse(text!.trim());
              return value == null || value <= 0 || value > 1000000000
                  ? 'Informe um total inteiro e válido de pés.'
                  : null;
            },
          ),
        if (_source == _PlantSource.partialArea)
          _number('Área parcial tratada (ha)', _partialArea, check: (value) {
            final plotArea = plotAreaHectares(widget.plot['area_ha']);
            return plotArea != null && value > plotArea
                ? 'A área parcial supera a área cadastrada do talhão.'
                : null;
          }),
        if (_treatedPlants == null)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
                'Total pendente. Informe os pés tratados ou confira a densidade e a área do talhão.'),
          ),
      ];

  List<Widget> _fields(FarmProduct product) {
    final units = _units(product);
    final hasInputUnit =
        _kind == CoffeeInputKind.direct || _kind == CoffeeInputKind.spray;
    final unit = units.contains(_unit) ? _unit! : units.first;
    final label = switch (_kind) {
      CoffeeInputKind.direct => 'Quantidade planejada ($unit)',
      CoffeeInputKind.fertilizer => 'Dose (g por pé)',
      CoffeeInputKind.bags => 'Quantidade de sacos',
      CoffeeInputKind.spray => 'Produto na carga ($unit)',
    };
    return [
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(product.name, style: AppTheme.nameStyle(context)),
        subtitle:
            Text('Estoque: ${_display(product.quantity)} ${product.unit}'),
        trailing: IconButton(
          onPressed: () => setState(() {
            _product = null;
            _search = '';
            _error = null;
          }),
          icon: const Icon(Icons.search),
          tooltip: 'Trocar produto',
        ),
      ),
      if (!widget.applied)
        DropdownButtonFormField<CoffeeInputKind>(
          initialValue: _kind,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Tipo de cálculo'),
          items: _labels.entries
              .map((entry) =>
                  DropdownMenuItem(value: entry.key, child: Text(entry.value)))
              .toList(),
          onChanged: (value) {
            if (value == null) return;
            setState(() {
              if (value != _kind) {
                _quantity.clear();
                _dose.clear();
                _reference.clear();
              }
              _kind = value;
              _error = null;
            });
          },
        ),
      if (hasInputUnit && units.length > 1)
        DropdownButtonFormField<String>(
          key: ValueKey(product.id),
          initialValue: unit,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Unidade informada'),
          items: units
              .map(
                  (value) => DropdownMenuItem(value: value, child: Text(value)))
              .toList(),
          onChanged: (value) {
            setState(() {
              if (value != _unit) {
                _quantity.clear();
                _dose.clear();
              }
              _unit = value;
              _error = null;
            });
          },
        ),
      if (widget.application && !widget.applied && hasInputUnit) ...[
        _number('Quantidade por dose ($unit)', _dose,
            required: _reference.text.trim().isNotEmpty),
        const SizedBox(height: 8),
        TextFormField(
            controller: _reference,
            maxLength: 120,
            decoration: const InputDecoration(
                labelText: 'Referência da dose',
                hintText: 'Tanque, bomba ou hectare',
                counterText: ''),
            onChanged: (_) => _refresh(),
            validator: (text) =>
                _dose.text.trim().isNotEmpty && (text ?? '').trim().isEmpty
                    ? 'Informe a referência da dose.'
                    : null),
      ],
      _number(
          widget.application && !widget.applied && hasInputUnit
              ? 'Quantidade total planejada ($unit)'
              : label,
          _quantity,
          required: true),
      if (_kind == CoffeeInputKind.fertilizer) ..._plantFields(),
      if (_kind == CoffeeInputKind.bags)
        _number('Peso por saco (kg)', _bagWeight),
      if (_kind == CoffeeInputKind.spray) ...[
        _number('Capacidade da carga (L)', _capacity),
        const SizedBox(height: 10),
        TextFormField(
          controller: _loadCount,
          keyboardType: TextInputType.number,
          decoration:
              const InputDecoration(labelText: 'Número de cargas (opcional)'),
          onChanged: (_) => _refresh(),
          validator: (text) {
            if ((text ?? '').trim().isEmpty) return null;
            final count = int.tryParse(text!.trim());
            return count == null || count < 1 || count > 99999
                ? 'Informe um número inteiro de cargas.'
                : null;
          },
        ),
        _number(
          _loadCount.text.trim().isEmpty
              ? 'Calda da carga (L)'
              : 'Calda por carga (L)',
          _calda,
          required: _loadCount.text.trim().isNotEmpty,
          check: (value) {
            final capacity = _parse(_capacity.text);
            return capacity != null && value > capacity
                ? 'A calda supera a capacidade da carga.'
                : null;
          },
        ),
        _number('Área coberta (ha)', _covered),
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
              'Informe a quantidade total do produto e a área coberta. Use o número de cargas quando elas tiverem o mesmo volume.'),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final product = _product;
    final draft = _draft;
    final matches = _products.where(
      (product) => product.name.trimLeft().toLowerCase().startsWith(_search),
    );
    return AlertDialog(
      title: Text(widget.applied
          ? (widget.editing
              ? 'Editar carga aplicada'
              : 'Registrar carga aplicada')
          : (widget.editing ? 'Editar insumo' : 'Planejar insumo')),
      content: SizedBox(
        width: AppTheme.dialogWidth(context, maxWidth: 430),
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (product == null) ...[
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Buscar produto pelo começo do nome',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (value) =>
                        setState(() => _search = value.trim().toLowerCase()),
                  ),
                  for (final match in matches.take(8))
                    ListTile(
                      title:
                          Text(match.name, style: AppTheme.nameStyle(context)),
                      subtitle: Text(
                          'Estoque: ${_display(match.quantity)} ${match.unit}'),
                      onTap: () => _select(match),
                    ),
                  if (matches.isEmpty) const Text('Nenhum produto encontrado.'),
                  if (matches.length > 8)
                    const Text('Digite mais letras para filtrar os produtos.'),
                  if (widget.createProduct != null)
                    OutlinedButton.icon(
                        onPressed: _creating ? null : _create,
                        icon: const Icon(Icons.add),
                        label: const Text('Cadastrar produto')),
                ] else
                  ..._fields(product),
                if (draft != null && draft.validationError == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                        coffeeInputSummary(draft, applied: widget.applied)),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
            onPressed: product == null ? null : _save,
            child: Text(
                widget.applied ? 'Salvar carga aplicada' : 'Salvar insumo')),
      ],
    );
  }
}
