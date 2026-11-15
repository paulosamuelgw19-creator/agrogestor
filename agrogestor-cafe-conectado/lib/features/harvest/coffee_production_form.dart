part of 'coffee_harvest_screen.dart';

class _ProductionDayCard extends StatelessWidget {
  const _ProductionDayCard({required this.day, this.onEdit, this.onReview});

  final CoffeePlotProductionDay day;
  final VoidCallback? onEdit, onReview;

  String _entered(CoffeePlotProduction production) => switch (production.unit) {
        CoffeeHarvestUnit.measures =>
          '${_decimal.format(production.quantity)} medidas de ${_liters(production.litersPerMeasure)} + ${_liters(production.remainderLiters ?? 0)} de sobra',
        CoffeeHarvestUnit.liters => _liters(production.quantity),
        CoffeeHarvestUnit.carts =>
          '${_decimal.format(production.quantity)} carretas de ${_liters(production.cartCapacityLiters!)}',
      };

  @override
  Widget build(BuildContext context) {
    final declared = day.declared;
    final workers = day.workerLiters;
    final difference = day.differenceLiters;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                '${_date.format(day.date)} · Total do dia: ${_liters(day.totalLiters)}',
                style: Theme.of(context).textTheme.titleMedium),
            Text(declared == null
                ? 'Total informado: sem lançamento'
                : 'Total informado: ${_liters(declared.volumeLiters)}'),
            if (declared != null && declared.unit != CoffeeHarvestUnit.liters)
              Text(_entered(declared)),
            if (_connectedHarvest && declared != null)
              SyncStatusLabel(
                  module: 'coffeePlotProduction', recordId: declared.id),
            Text(workers == null
                ? 'Soma por pessoa: sem lançamentos'
                : 'Soma por pessoa: ${_liters(workers)}'),
            if (difference != null)
              Text(
                  'Diferença (informado − por pessoa): ${_liters(difference)}'),
            if (day.needsReview)
              const AppNotice(message: 'Produção a conferir'),
            if (onReview != null)
              FilledButton.tonal(
                  onPressed: onReview, child: const Text('Conferir produção')),
            if (onEdit != null)
              TextButton(
                  onPressed: onEdit,
                  child: const Text('Editar produção do dia')),
          ],
        ),
      ),
    );
  }
}

class _ProductionDialog extends StatefulWidget {
  const _ProductionDialog(
      {required this.propertyId,
      required this.plotId,
      required this.location,
      required this.seasonYear,
      required this.declarations,
      this.existing});

  final String propertyId, plotId, location;
  final int seasonYear;
  final List<CoffeePlotProduction> declarations;
  final CoffeePlotProduction? existing;

  @override
  State<_ProductionDialog> createState() => _ProductionDialogState();
}

class _ProductionDialogState extends State<_ProductionDialog> {
  final _form = GlobalKey<FormState>();
  final _id = const Uuid().v4();
  final _quantity = TextEditingController();
  final _measure = TextEditingController();
  final _remainder = TextEditingController();
  final _capacity = TextEditingController();
  late DateTime _day =
      widget.existing?.date ?? DateUtils.dateOnly(DateTime.now());
  CoffeeHarvestUnit _unit = CoffeeHarvestUnit.measures;
  CoffeePlotProduction? _existing;
  bool _submitted = false;

  String _text(double? value) =>
      value
          ?.toString()
          .replaceFirst(RegExp(r'\.0$'), '')
          .replaceAll('.', ',') ??
      '';

  @override
  void initState() {
    super.initState();
    _fill(_day);
  }

  void _fill(DateTime date) {
    _day = date;
    _existing = widget.declarations
        .where((item) => DateUtils.isSameDay(item.date, date))
        .firstOrNull;
    final current = _existing;
    _unit = current?.unit ?? CoffeeHarvestUnit.measures;
    _quantity.text = _text(current?.quantity);
    _measure.text = _text(current?.litersPerMeasure ??
        widget.declarations
            .where((item) => item.unit == CoffeeHarvestUnit.measures)
            .firstOrNull
            ?.litersPerMeasure ??
        60);
    _remainder.text = _text(current?.remainderLiters);
    _capacity.text = _text(current?.cartCapacityLiters);
  }

  @override
  void dispose() {
    _quantity.dispose();
    _measure.dispose();
    _remainder.dispose();
    _capacity.dispose();
    super.dispose();
  }

  Future<void> _chooseDate() async {
    final date = await showDatePicker(
        context: context,
        firstDate: DateTime(1900),
        lastDate: DateTime.now(),
        initialDate: _day);
    if (mounted && date != null && !DateUtils.isSameDay(date, _day)) {
      setState(() => _fill(date));
    }
  }

  double? get _wholeMeasures => RegExp(r'^\d+$').hasMatch(_quantity.text.trim())
      ? _number(_quantity.text)
      : null;
  double? get _leftover =>
      _remainder.text.trim().isEmpty ? 0 : _number(_remainder.text);

  CoffeePlotProduction? get _draft {
    final isMeasure = _unit == CoffeeHarvestUnit.measures;
    final quantity = isMeasure ? _wholeMeasures : _number(_quantity.text);
    final measure = isMeasure
        ? _number(_measure.text)
        : _existing?.litersPerMeasure ?? 60.0;
    final leftover = isMeasure ? _leftover : null;
    final capacity =
        _unit == CoffeeHarvestUnit.carts ? _number(_capacity.text) : null;
    if (quantity == null ||
        measure == null ||
        measure <= 0 ||
        (isMeasure && (leftover == null || leftover >= measure)) ||
        (_unit == CoffeeHarvestUnit.carts &&
            (capacity == null || capacity <= 0))) {
      return null;
    }
    final result = CoffeePlotProduction(
        id: _existing?.id ?? _id,
        propertyId: widget.propertyId,
        plotId: widget.plotId,
        date: _day,
        seasonYear: widget.seasonYear,
        unit: _unit,
        quantity: quantity,
        litersPerMeasure: measure,
        remainderLiters: leftover,
        cartCapacityLiters: capacity);
    return result.volumeLiters.isFinite ? result : null;
  }

  Widget _field(TextEditingController controller, String label,
          String? Function(String?) validate,
          {bool integer = false}) =>
      TextFormField(
        controller: controller,
        decoration: InputDecoration(labelText: label),
        keyboardType: TextInputType.numberWithOptions(decimal: !integer),
        inputFormatters:
            integer ? [FilteringTextInputFormatter.digitsOnly] : null,
        onChanged: (_) => setState(() {}),
        validator: validate,
      );

  void _save() {
    if (_submitted || !_form.currentState!.validate()) return;
    final result = _draft;
    if (result == null) return;
    _submitted = true;
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final preview = _draft;
    return AlertDialog(
      title: Text(_existing == null
          ? 'Registrar produção do dia'
          : 'Editar produção do dia'),
      content: SizedBox(
        width: AppTheme.dialogWidth(context, maxWidth: 460),
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('${widget.location} · Safra ${widget.seasonYear}'),
                  const SizedBox(height: 8),
                  if (widget.existing == null)
                    OutlinedButton.icon(
                        onPressed: _chooseDate,
                        icon: const Icon(Icons.calendar_today_outlined),
                        label: Text('Data: ${_date.format(_day)}'))
                  else
                    Text('Data: ${_date.format(_day)}'),
                  if (_existing != null && widget.existing == null)
                    const Text(
                        'Já existe um total nesta data. Salvar vai atualizar esse lançamento.'),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<CoffeeHarvestUnit>(
                    key: ValueKey(_day),
                    initialValue: _unit,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Unidade'),
                    items: [
                      for (final unit in CoffeeHarvestUnit.values)
                        DropdownMenuItem(
                            value: unit, child: Text(_unitLabels[unit]!))
                    ],
                    onChanged: (value) => setState(() {
                      if (value != _unit) _quantity.clear();
                      _unit = value ?? _unit;
                    }),
                  ),
                  const SizedBox(height: 8),
                  _field(
                      _quantity,
                      _unit == CoffeeHarvestUnit.measures
                          ? 'Medidas inteiras'
                          : 'Quantidade',
                      (text) => (_unit == CoffeeHarvestUnit.measures
                                  ? _wholeMeasures
                                  : _number(text)) ==
                              null
                          ? 'Informe a quantidade, inclusive zero.'
                          : null,
                      integer: _unit == CoffeeHarvestUnit.measures),
                  if (_unit == CoffeeHarvestUnit.measures) ...[
                    const SizedBox(height: 8),
                    _field(
                        _measure,
                        'Litros por medida',
                        (text) => (_number(text) ?? 0) > 0
                            ? null
                            : 'Informe o tamanho da medida.'),
                    const SizedBox(height: 8),
                    _field(_remainder, 'Litros de sobra', (_) {
                      final size = _number(_measure.text);
                      final remainder = _leftover;
                      return remainder == null ||
                              (size != null && size > 0 && remainder >= size)
                          ? 'A sobra precisa ser menor que uma medida.'
                          : null;
                    }),
                  ],
                  if (_unit == CoffeeHarvestUnit.carts) ...[
                    const SizedBox(height: 8),
                    _field(
                        _capacity,
                        'Litros por carreta',
                        (text) => (_number(text) ?? 0) > 0
                            ? null
                            : 'Informe a capacidade da carreta.'),
                  ],
                  const SizedBox(height: 8),
                  Text(preview == null
                      ? 'Total em litros: aguarda os dados'
                      : 'Total em litros: ${_liters(preview.volumeLiters)}'),
                ]),
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar')),
        FilledButton(onPressed: _save, child: const Text('Salvar')),
      ],
    );
  }
}
