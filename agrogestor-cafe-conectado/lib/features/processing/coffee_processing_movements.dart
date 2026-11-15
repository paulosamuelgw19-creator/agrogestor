part of 'coffee_processing_screen.dart';

enum _MovementKind { measurement, cleaning, sale }

class _DecimalField extends StatelessWidget {
  const _DecimalField(
      {required this.controller,
      required this.label,
      this.requiredValue = false,
      this.integer = false,
      this.allowZero = false,
      this.enabled = true,
      this.changed,
      this.check});

  final TextEditingController controller;
  final String label;
  final bool requiredValue, integer, allowZero, enabled;
  final VoidCallback? changed;
  final String? Function(double)? check;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        enabled: enabled,
        decoration: InputDecoration(labelText: label),
        keyboardType: TextInputType.numberWithOptions(decimal: !integer),
        onChanged: (_) => changed?.call(),
        validator: (text) {
          final raw = text?.trim() ?? '';
          if (!requiredValue && raw.isEmpty) return null;
          final value = _number(raw);
          if (value == null ||
              (!allowZero && value <= 0) ||
              (integer && !RegExp(r'^\d+$').hasMatch(raw))) {
            return integer
                ? 'Informe uma quantidade inteira de sacos.'
                : 'Informe um número válido.';
          }
          return check?.call(value);
        },
      );
}

class _MovementDialog extends StatefulWidget {
  const _MovementDialog(
      {required this.repository, required this.lot, required this.kind});

  final CoffeeProcessingRepository repository;
  final CoffeeLot lot;
  final _MovementKind kind;

  @override
  State<_MovementDialog> createState() => _MovementDialogState();
}

class _MovementDialogState extends State<_MovementDialog> {
  final _form = GlobalKey<FormState>();
  final _id = const Uuid().v4();
  final _quantity = TextEditingController();
  final _weight = TextEditingController(text: '60');
  final _remainder = TextEditingController();
  final _input = TextEditingController();
  final _location = TextEditingController();
  final _state = TextEditingController();
  final _notes = TextEditingController();
  final _buyer = TextEditingController();
  final _price = TextEditingController();
  late DateTime _dateValue = widget.lot.date.isAfter(DateTime.now())
      ? widget.lot.date
      : DateUtils.dateOnly(DateTime.now());
  CoffeeProcessingStage _stage = CoffeeProcessingStage.reception;
  CoffeeProcessedUnit _unit = CoffeeProcessedUnit.kilograms;
  CoffeeCleaningInputBase? _base;
  bool _busy = false;
  String? _error;

  bool get _measurement => widget.kind == _MovementKind.measurement;
  bool get _cleaning => widget.kind == _MovementKind.cleaning;
  bool get _sale => widget.kind == _MovementKind.sale;
  bool get _bags => _unit == CoffeeProcessedUnit.bags;

  String get _title => switch (widget.kind) {
        _MovementKind.measurement => 'Registrar medição',
        _MovementKind.cleaning => 'Registrar limpa',
        _MovementKind.sale => 'Registrar venda',
      };

  @override
  void dispose() {
    for (final controller in [
      _quantity,
      _weight,
      _remainder,
      _input,
      _location,
      _state,
      _notes,
      _buyer,
      _price
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  double? get _preview {
    final quantity = _number(_quantity.text);
    if (!_bags) return quantity;
    final kgPerBag = _number(_weight.text);
    final remainder =
        _remainder.text.trim().isEmpty ? 0.0 : _number(_remainder.text);
    if (quantity == null ||
        quantity != quantity.truncateToDouble() ||
        kgPerBag == null ||
        kgPerBag <= 0 ||
        remainder == null ||
        remainder >= kgPerBag) {
      return null;
    }
    return quantity * kgPerBag + remainder;
  }

  void _changed() => setState(() => _error = null);

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    final weight = _preview;
    if (!_measurement && (weight == null || weight <= 0)) {
      setState(() => _error = 'Informe um peso maior que zero.');
      return;
    }
    final lot = widget.lot;
    final repository = widget.repository;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      CoffeeLot? updated;
      FormatException? invalid;
      final saved = await runLicensedWrite(context, () async {
        try {
          switch (widget.kind) {
            case _MovementKind.measurement:
              await repository.addMeasurement(
                  propertyId: lot.propertyId,
                  lotId: lot.id,
                  measurement: CoffeeLotMeasurement(
                    id: _id,
                    date: _dateValue,
                    stage: _stage,
                    volumeLiters: _number(_quantity.text),
                    location: _location.text.trim(),
                    state: _state.text.trim(),
                    notes: _notes.text.trim(),
                  ));
            case _MovementKind.cleaning:
              await repository.addCleaning(
                  propertyId: lot.propertyId,
                  lotId: lot.id,
                  cleaning: CoffeeLotCleaning(
                    id: _id,
                    date: _dateValue,
                    unit: _unit,
                    quantity: _number(_quantity.text)!,
                    kgPerBag: _bags ? _number(_weight.text) : null,
                    remainderKg: _bags ? _number(_remainder.text) : null,
                    inputLiters: _number(_input.text),
                    inputBase: _base,
                    notes: _notes.text.trim(),
                  ));
            case _MovementKind.sale:
              await repository.addSale(
                  propertyId: lot.propertyId,
                  lotId: lot.id,
                  sale: CoffeeLotSale(
                    id: _id,
                    date: _dateValue,
                    unit: _unit,
                    quantity: _number(_quantity.text)!,
                    kgPerBag: _bags ? _number(_weight.text) : null,
                    remainderKg: _bags ? _number(_remainder.text) : null,
                    totalPriceCents: _cents(_price.text)!,
                    buyer: _buyer.text.trim(),
                    notes: _notes.text.trim(),
                  ));
          }
          updated = await repository.getLot(
              propertyId: lot.propertyId, lotId: lot.id);
        } on FormatException catch (error) {
          invalid = error;
        }
      });
      if (!mounted) return;
      if (invalid case final FormatException error) {
        setState(() => _error = error.message);
      } else if (saved) {
        Navigator.pop(context, updated);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(_title),
        content: SizedBox(
            width: AppTheme.dialogWidth(context, maxWidth: 480),
            child: Form(
                key: _form,
                child: SingleChildScrollView(
                    child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                        'Lote ${widget.lot.code} · Safra ${widget.lot.seasonYear}'),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () async {
                              final date = await _chooseDate(
                                  context, _dateValue,
                                  from: widget.lot.date);
                              if (mounted && date != null) {
                                setState(() => _dateValue = date);
                              }
                            },
                      icon: const Icon(Icons.calendar_today_outlined),
                      label: Text('Data: ${_date.format(_dateValue)}'),
                    ),
                    const SizedBox(height: 8),
                    if (_measurement) ...[
                      DropdownButtonFormField<CoffeeProcessingStage>(
                        isExpanded: true,
                        initialValue: _stage,
                        decoration: const InputDecoration(labelText: 'Etapa'),
                        items: [
                          for (final entry in _stageNames.entries)
                            DropdownMenuItem(
                                value: entry.key, child: Text(entry.value))
                        ],
                        onChanged:
                            _busy ? null : (value) => _stage = value ?? _stage,
                      ),
                      const SizedBox(height: 8),
                      _DecimalField(
                          controller: _quantity,
                          label: 'Volume medido (L)',
                          enabled: !_busy),
                      const SizedBox(height: 8),
                      TextFormField(
                          controller: _location,
                          enabled: !_busy,
                          maxLength: 160,
                          decoration: const InputDecoration(
                              labelText: 'Local', counterText: '')),
                      const SizedBox(height: 8),
                      TextFormField(
                          controller: _state,
                          enabled: !_busy,
                          maxLength: 160,
                          decoration: const InputDecoration(
                              labelText: 'Estado do café', counterText: '')),
                    ] else ...[
                      DropdownButtonFormField<CoffeeProcessedUnit>(
                        isExpanded: true,
                        initialValue: _unit,
                        decoration:
                            const InputDecoration(labelText: 'Unidade do peso'),
                        items: const [
                          DropdownMenuItem(
                              value: CoffeeProcessedUnit.kilograms,
                              child: Text('Quilos (kg)')),
                          DropdownMenuItem(
                              value: CoffeeProcessedUnit.bags,
                              child: Text('Sacos e sobra em kg')),
                        ],
                        onChanged: _busy
                            ? null
                            : (value) => setState(() {
                                  if (value != _unit) _quantity.clear();
                                  _unit = value ?? _unit;
                                  _error = null;
                                }),
                      ),
                      const SizedBox(height: 8),
                      _DecimalField(
                          controller: _quantity,
                          label: _bags ? 'Sacos inteiros' : 'Peso (kg)',
                          enabled: !_busy,
                          requiredValue: true,
                          integer: _bags,
                          allowZero: _bags,
                          changed: _changed),
                      if (_bags) ...[
                        const SizedBox(height: 8),
                        _DecimalField(
                            controller: _weight,
                            label: 'Quilos por saco',
                            enabled: !_busy,
                            requiredValue: true,
                            changed: _changed),
                        const SizedBox(height: 8),
                        _DecimalField(
                            controller: _remainder,
                            label: 'Sobra (kg)',
                            enabled: !_busy,
                            allowZero: true,
                            changed: _changed,
                            check: (value) {
                              final reference = _number(_weight.text);
                              return reference != null && value >= reference
                                  ? 'A sobra precisa ser menor que um saco.'
                                  : null;
                            }),
                      ],
                      if (_preview case final double weight) ...[
                        const SizedBox(height: 8),
                        Text('Peso total: ${_kg(weight)}')
                      ],
                      if (_cleaning) ...[
                        const SizedBox(height: 8),
                        _DecimalField(
                            controller: _input,
                            label: 'Volume usado nesta limpa (L)',
                            enabled: !_busy,
                            changed: _changed),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<CoffeeCleaningInputBase?>(
                          isExpanded: true,
                          initialValue: _base,
                          decoration: const InputDecoration(
                              labelText: 'Base do volume de entrada'),
                          items: [
                            const DropdownMenuItem(
                                value: null, child: Text('Não informada')),
                            for (final entry in _baseNames.entries)
                              DropdownMenuItem(
                                  value: entry.key, child: Text(entry.value))
                          ],
                          onChanged: _busy
                              ? null
                              : (value) => setState(() => _base = value),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                            'Para calcular o rendimento desta limpa, informe o volume usado e a base de medição.'),
                      ],
                      if (_sale) ...[
                        const SizedBox(height: 8),
                        Text('Saldo atual: ${_kg(widget.lot.stockKg)}'),
                        const SizedBox(height: 8),
                        TextFormField(
                            controller: _buyer,
                            enabled: !_busy,
                            maxLength: 160,
                            decoration: const InputDecoration(
                                labelText: 'Comprador', counterText: '')),
                        const SizedBox(height: 8),
                        TextFormField(
                            controller: _price,
                            enabled: !_busy,
                            decoration: const InputDecoration(
                                labelText: 'Valor total (R\$)'),
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            validator: (text) => _cents(text ?? '') == null
                                ? 'Informe um valor maior que zero com até duas casas decimais.'
                                : null),
                      ],
                    ],
                    const SizedBox(height: 8),
                    TextFormField(
                        controller: _notes,
                        enabled: !_busy,
                        maxLines: 2,
                        maxLength: 1000,
                        decoration: const InputDecoration(
                            labelText: 'Observações', counterText: '')),
                    if (_busy) const LinearProgressIndicator(),
                  ],
                )))),
        actions: [
          if (_error case final String error)
            Text(error,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: _busy ? null : _save, child: const Text('Salvar')),
        ],
      ));
}
