part of 'coffee_finance_screen.dart';

class _FinanceEntryEditor extends StatefulWidget {
  const _FinanceEntryEditor(
      {required this.repository,
      required this.farm,
      required this.plots,
      required this.year,
      this.initialPlotId,
      this.existing});

  final CoffeeFinanceRepository repository;
  final Json farm;
  final List<Json> plots;
  final int year;
  final String? initialPlotId;
  final CoffeeFinanceEntry? existing;

  @override
  State<_FinanceEntryEditor> createState() => _FinanceEntryEditorState();
}

class _FinanceEntryEditorState extends State<_FinanceEntryEditor> {
  final _form = GlobalKey<FormState>();
  late final _id = widget.existing?.id ?? const Uuid().v4();
  late final _category = TextEditingController(text: widget.existing?.category);
  late final _description =
      TextEditingController(text: widget.existing?.description);
  late final _supplier = TextEditingController(text: widget.existing?.supplier);
  late final _quantity =
      TextEditingController(text: _qtyText(widget.existing?.quantity));
  late final _unit = TextEditingController(text: widget.existing?.unit);
  late final _price =
      TextEditingController(text: _priceText(widget.existing?.priceCents));
  late final _freight =
      TextEditingController(text: _priceText(widget.existing?.freightCents));
  late final _notes = TextEditingController(text: widget.existing?.notes);
  late CoffeeFinanceKind _kind =
      widget.existing?.kind ?? CoffeeFinanceKind.purchase;
  late CoffeeFinanceStage _stage =
      widget.existing?.stage ?? CoffeeFinanceStage.management;
  late CoffeeFinancePriceMode _priceMode =
      widget.existing?.priceMode ?? CoffeeFinancePriceMode.total;
  late CoffeeFinanceFreightMode _freightMode =
      widget.existing?.freightMode ?? CoffeeFinanceFreightMode.included;
  late DateTime _dateValue =
      widget.existing?.date ?? DateUtils.dateOnly(DateTime.now());
  late DateTime? _settledAt = widget.existing?.settledAt;
  late String? _plotId =
      widget.existing == null ? widget.initialPlotId : widget.existing!.plotId;
  late String? _analysisId = widget.existing?.analysisId;
  late String? _pdfPath = widget.existing?.pdfPath;
  late CoffeeFinanceOriginKind? _originKind = widget.existing?.originKind;
  Future<List<CoffeeFinanceLegacySource>>? _legacyOptions;
  CoffeeFinanceLegacySource? _legacy;
  ({Uint8List bytes, String name})? _picked;
  bool _busy = false;
  String? _error;

  bool get _existingLink => widget.existing?.originId != null;
  bool get _linked => _existingLink || _legacy != null;
  bool get _unitPrice => _priceMode == CoffeeFinancePriceMode.unit;
  bool get _separateFreight =>
      _freightMode == CoffeeFinanceFreightMode.separate;
  bool get _income => _kind == CoffeeFinanceKind.income;

  @override
  void dispose() {
    for (final controller in [
      _category,
      _description,
      _supplier,
      _quantity,
      _unit,
      _price,
      _freight,
      _notes
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  CoffeeFinanceEntry _draft() => CoffeeFinanceEntry(
        id: _id,
        propertyId: widget.farm['id'] as String,
        seasonYear: widget.year,
        date: _dateValue,
        kind: _kind,
        stage: _stage,
        category: _category.text.trim(),
        description: _description.text.trim(),
        plotId: _plotId,
        analysisId: _income ? null : _analysisId,
        settledAt: _settledAt,
        supplier: _supplier.text.trim(),
        quantity: _positive(_quantity.text),
        unit: _unit.text.trim(),
        priceMode: _priceMode,
        priceCents: _cents(_price.text),
        freightMode: _freightMode,
        freightCents: _separateFreight ? _cents(_freight.text) : null,
        pdfPath: _pdfPath,
        notes: _notes.text.trim(),
        originKind: _legacy?.kind ?? widget.existing?.originKind,
        originId: _legacy?.id ?? widget.existing?.originId,
      );

  Future<void> _chooseAnalysis() async {
    final plotId = _plotId;
    if (plotId == null) return;
    try {
      final analyses = await CoffeeAnalysisRepository().list(
        propertyId: widget.farm['id'] as String,
        plotId: plotId,
      );
      if (!mounted || _plotId != plotId) return;
      final result = await showDialog<String>(
          context: context,
          builder: (_) =>
              SimpleDialog(title: const Text('Vincular laudo'), children: [
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, ''),
                  child: const Text('Sem vínculo'),
                ),
                if (analyses.isEmpty)
                  const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('Este talhão ainda não tem laudos.')),
                for (final analysis in analyses)
                  SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, analysis.id),
                      child: Text(
                          '${_date.format(analysis.collectedAt)} · ${analysis.sampleId} · ${analysis.laboratory}')),
              ]));
      if (mounted && result != null && _plotId == plotId) {
        setState(() => _analysisId = result.isEmpty ? null : result);
      }
    } catch (_) {
      if (mounted) {
        setState(
            () => _error = 'Não foi possível consultar os laudos do talhão.');
      }
    }
  }

  void _changeOrigin(CoffeeFinanceOriginKind? origin) {
    if (_legacy != null) {
      _price.clear();
      _description.clear();
    }
    _legacy = null;
    _originKind = origin;
    _legacyOptions =
        origin == null ? null : widget.repository.legacySources(kind: origin);
  }

  void _chooseLegacy(CoffeeFinanceLegacySource source) => setState(() {
        _legacy = source;
        _dateValue = source.date;
        _price.text = _priceText(source.amountCents);
        _description.text = source.description;
        if (_category.text.trim().isEmpty) {
          _category.text = _originNames[source.kind]!;
        }
        _priceMode = CoffeeFinancePriceMode.total;
        _freightMode = CoffeeFinanceFreightMode.included;
        _freight.clear();
        _quantity.clear();
        _unit.clear();
        _error = null;
      });

  Future<void> _attach() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await _selectFinancePdf();
      if (mounted && file != null) setState(() => _picked = file);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Não foi possível importar o comprovante.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    if (_originKind != null && !_linked) {
      setState(
          () => _error = 'Escolha o lançamento existente que deseja vincular.');
      return;
    }
    final entry = _draft();
    if (_settledAt != null && entry.totalCents == null) {
      setState(() =>
          _error = 'Informe o valor total para registrar a baixa no caixa.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await runLicensedWrite(
          context,
          () => widget.repository.saveEntry(entry,
              pickedPdf: _picked?.bytes, pickedPdfName: _picked?.name));
      if (mounted && saved) Navigator.pop(context, true);
    } on FileSystemException {
      if (mounted) {
        setState(() =>
            _error = 'Não foi possível guardar o comprovante no aparelho.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _required(String? value) =>
      (value ?? '').trim().isEmpty ? 'Preencha este campo.' : null;
  String? _validCents(String? value) =>
      (value ?? '').trim().isEmpty || _cents(value) != null
          ? null
          : 'Informe o valor com até duas casas decimais.';

  Widget _moneyField(TextEditingController controller, String label) =>
      TextFormField(
        controller: controller,
        decoration: InputDecoration(labelText: label),
        enabled: !_busy && !_linked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        onChanged: (_) => setState(() {}),
        validator: _validCents,
      );

  Widget _originSelector() {
    if (_existingLink) {
      return Text('Origem vinculada: ${_originNames[_originKind]}');
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DropdownButtonFormField<CoffeeFinanceOriginKind?>(
        isExpanded: true,
        initialValue: _originKind,
        decoration:
            const InputDecoration(labelText: 'Vincular despesa existente'),
        items: [
          const DropdownMenuItem(value: null, child: Text('Sem vínculo')),
          for (final item in _originNames.entries)
            DropdownMenuItem(value: item.key, child: Text(item.value))
        ],
        onChanged:
            _busy ? null : (value) => setState(() => _changeOrigin(value)),
      ),
      if (_originKind != null) ...[
        const SizedBox(height: 8),
        FutureBuilder<List<CoffeeFinanceLegacySource>>(
          future: _legacyOptions,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const LinearProgressIndicator();
            }
            if (snapshot.hasError) {
              return const Text(
                  'Não foi possível consultar os lançamentos existentes.');
            }
            final options = snapshot.data ?? [];
            if (options.isEmpty) {
              return const Text(
                  'Nenhum lançamento com valor informado disponível para vínculo.');
            }
            return DropdownButtonFormField<CoffeeFinanceLegacySource>(
              key: ValueKey(_originKind),
              initialValue: _legacy,
              decoration:
                  const InputDecoration(labelText: 'Lançamento existente'),
              isExpanded: true,
              items: [
                for (final source in options)
                  DropdownMenuItem(
                      value: source,
                      child: Text(
                          '${_date.format(source.date)} · ${source.description} · ${_money(source.amountCents)}',
                          overflow: TextOverflow.ellipsis))
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      if (value != null) _chooseLegacy(value);
                    },
            );
          },
        ),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final total = _draft().totalCents;
    final title =
        widget.existing == null ? 'Novo lançamento' : 'Editar lançamento';
    return PopScope(
        canPop: !_busy,
        child: Scaffold(
          appBar: AppBar(title: Text(title)),
          body: SafeArea(
              child: Form(
                  key: _form,
                  child: _FinancePage(children: [
                    Text('${widget.farm['name']} · Safra ${widget.year}',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<CoffeeFinanceKind>(
                      isExpanded: true,
                      initialValue: _kind,
                      decoration: const InputDecoration(
                          labelText: 'Tipo de lançamento'),
                      items: [
                        for (final item in _kinds.entries)
                          DropdownMenuItem(
                              value: item.key, child: Text(item.value))
                      ],
                      onChanged: _busy || _existingLink
                          ? null
                          : (value) => setState(() {
                                _kind = value ?? _kind;
                                if (_kind != CoffeeFinanceKind.expense) {
                                  _changeOrigin(null);
                                }
                              }),
                    ),
                    const SizedBox(height: 8),
                    if (_kind == CoffeeFinanceKind.expense) ...[
                      _originSelector(),
                      const SizedBox(height: 8)
                    ],
                    DropdownButtonFormField<CoffeeFinanceStage>(
                      isExpanded: true,
                      initialValue: _stage,
                      decoration:
                          const InputDecoration(labelText: 'Etapa da safra'),
                      items: [
                        for (final item in _stages.entries)
                          DropdownMenuItem(
                              value: item.key, child: Text(item.value))
                      ],
                      onChanged:
                          _busy ? null : (value) => _stage = value ?? _stage,
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                        controller: _category,
                        enabled: !_busy,
                        maxLength: 160,
                        decoration: const InputDecoration(
                            labelText: 'Categoria', counterText: ''),
                        validator: _required),
                    const SizedBox(height: 8),
                    TextFormField(
                        controller: _description,
                        enabled: !_busy,
                        maxLength: 300,
                        decoration: const InputDecoration(
                            labelText: 'Descrição', counterText: ''),
                        validator: _required),
                    const SizedBox(height: 8),
                    TextFormField(
                        controller: _supplier,
                        enabled: !_busy,
                        maxLength: 300,
                        decoration: const InputDecoration(
                            labelText: 'Fornecedor ou pessoa (opcional)',
                            counterText: '')),
                    if (widget.plots.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String>(
                        initialValue: _plotId ?? '',
                        isExpanded: true,
                        decoration: const InputDecoration(
                            labelText: 'Talhão (opcional)'),
                        items: [
                          const DropdownMenuItem(
                              value: '', child: Text('Geral da fazenda')),
                          if (_plotId != null &&
                              !widget.plots
                                  .any((plot) => plot['id'] == _plotId))
                            DropdownMenuItem(
                                value: _plotId,
                                child: const Text('Talhão indisponível')),
                          for (final plot in widget.plots)
                            DropdownMenuItem(
                                value: plot['id'] as String,
                                child: Text(_name(plot),
                                    overflow: TextOverflow.ellipsis)),
                        ],
                        onChanged: _busy
                            ? null
                            : (value) => setState(() {
                                  _plotId =
                                      value?.isNotEmpty == true ? value : null;
                                  _analysisId = null;
                                }),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: OutlinedButton.icon(
                            onPressed: _busy || _linked
                                ? null
                                : () async {
                                    final picked =
                                        await _pickDate(context, _dateValue);
                                    if (mounted && picked != null) {
                                      setState(() => _dateValue = picked);
                                    }
                                  },
                            icon: const Icon(Icons.calendar_today_outlined),
                            label: Text(
                                'Data do lançamento: ${_date.format(_dateValue)}'))),
                    const Divider(height: 28),
                    if (!_income && _plotId != null)
                      Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: TextButton.icon(
                              onPressed: _busy ? null : _chooseAnalysis,
                              icon: const Icon(Icons.link),
                              label: Text(_analysisId == null
                                  ? 'Vincular laudo do talhão'
                                  : 'Alterar laudo vinculado'))),
                    Text('Valor e frete',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<CoffeeFinancePriceMode>(
                      isExpanded: true,
                      key: ValueKey(('price', _legacy?.id)),
                      initialValue: _priceMode,
                      decoration: const InputDecoration(
                          labelText: 'Forma de informar o preço'),
                      items: const [
                        DropdownMenuItem(
                            value: CoffeeFinancePriceMode.total,
                            child: Text('Preço total')),
                        DropdownMenuItem(
                            value: CoffeeFinancePriceMode.unit,
                            child: Text('Preço unitário'))
                      ],
                      onChanged: _busy || _linked
                          ? null
                          : (value) => setState(() {
                                if (value != _priceMode) _price.clear();
                                _priceMode = value ?? _priceMode;
                              }),
                    ),
                    if (!_linked) ...[
                      const SizedBox(height: 8),
                      TextFormField(
                          controller: _quantity,
                          enabled: !_busy,
                          decoration:
                              const InputDecoration(labelText: 'Quantidade'),
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          onChanged: (_) => setState(() {}),
                          validator: (value) => (_unitPrice ||
                                      (value ?? '').trim().isNotEmpty ||
                                      _unit.text.trim().isNotEmpty) &&
                                  _positive(value) == null
                              ? 'Informe uma quantidade maior que zero.'
                              : null),
                      const SizedBox(height: 8),
                      TextFormField(
                          controller: _unit,
                          enabled: !_busy,
                          maxLength: 80,
                          decoration: const InputDecoration(
                              labelText: 'Unidade', counterText: ''),
                          validator: (value) => _quantity.text.trim().isNotEmpty
                              ? _required(value)
                              : null),
                    ],
                    const SizedBox(height: 8),
                    _moneyField(
                        _price,
                        _unitPrice
                            ? 'Preço unitário (R\$)'
                            : 'Preço total (R\$)'),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<CoffeeFinanceFreightMode>(
                      isExpanded: true,
                      key: ValueKey(('freight', _legacy?.id)),
                      initialValue: _freightMode,
                      decoration: const InputDecoration(labelText: 'Frete'),
                      items: const [
                        DropdownMenuItem(
                            value: CoffeeFinanceFreightMode.included,
                            child: Text('Incluído ou sem frete')),
                        DropdownMenuItem(
                            value: CoffeeFinanceFreightMode.separate,
                            child: Text('Frete separado'))
                      ],
                      onChanged: _busy || _linked
                          ? null
                          : (value) => setState(
                              () => _freightMode = value ?? _freightMode),
                    ),
                    if (_separateFreight) ...[
                      const SizedBox(height: 8),
                      _moneyField(_freight, 'Frete (R\$)')
                    ],
                    const SizedBox(height: 8),
                    Text(total == null
                        ? 'Total: valor não informado'
                        : 'Total: ${_money(total)}'),
                    Wrap(spacing: 8, runSpacing: 4, children: [
                      OutlinedButton.icon(
                          onPressed: _busy ||
                                  (total == null && _settledAt == null)
                              ? null
                              : () async {
                                  final date = await _pickDate(
                                      context,
                                      _settledAt ??
                                          DateUtils.dateOnly(DateTime.now()));
                                  if (mounted && date != null) {
                                    setState(() => _settledAt = date);
                                  }
                                },
                          icon: const Icon(Icons.event_available_outlined),
                          label: Text(_settledAt == null
                              ? (_income
                                  ? 'Data de recebimento'
                                  : 'Data de pagamento')
                              : '${_income ? 'Recebido' : 'Pago'} em ${_date.format(_settledAt!)}')),
                      if (_settledAt != null)
                        TextButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() => _settledAt = null),
                            child: const Text('Limpar data de baixa')),
                    ]),
                    const Divider(height: 28),
                    Text('Nota fiscal ou comprovante',
                        style: Theme.of(context).textTheme.titleMedium),
                    if (_picked case final file?)
                      Text(file.name)
                    else if (_pdfPath != null)
                      const Text('PDF anexado'),
                    Wrap(spacing: 8, runSpacing: 4, children: [
                      OutlinedButton.icon(
                          onPressed: _busy ? null : _attach,
                          icon: const Icon(Icons.attach_file),
                          label: const Text('Anexar PDF')),
                      if (_picked != null || _pdfPath != null)
                        TextButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() {
                                      _picked = null;
                                      _pdfPath = null;
                                    }),
                            child: const Text('Remover PDF')),
                    ]),
                    const SizedBox(height: 8),
                    TextFormField(
                        controller: _notes,
                        enabled: !_busy,
                        maxLines: 2,
                        maxLength: 4000,
                        decoration: const InputDecoration(
                            labelText: 'Observações', counterText: '')),
                    const SizedBox(height: 12),
                    if (_error case final String error)
                      Text(error,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    if (_busy) const LinearProgressIndicator(),
                    Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: FilledButton(
                            onPressed: _busy ? null : _save,
                            child: const Text('Salvar lançamento'))),
                  ]))),
        ));
  }
}

class _ReceiptDialog extends StatefulWidget {
  const _ReceiptDialog({required this.repository, required this.sale});

  final CoffeeFinanceRepository repository;
  final CoffeeFinanceSale sale;

  @override
  State<_ReceiptDialog> createState() => _ReceiptDialogState();
}

class _ReceiptDialogState extends State<_ReceiptDialog> {
  final _form = GlobalKey<FormState>();
  final _id = const Uuid().v4();
  late final _amount =
      TextEditingController(text: _priceText(widget.sale.outstandingCents));
  final _notes = TextEditingController();
  late DateTime _day = widget.sale.sale.date.isAfter(DateTime.now())
      ? widget.sale.sale.date
      : DateUtils.dateOnly(DateTime.now());
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    final sale = widget.sale;
    final receipt = CoffeeSaleReceipt(
        id: _id,
        propertyId: sale.lot.propertyId,
        lotId: sale.lot.id,
        saleId: sale.sale.id,
        date: _day,
        amountCents: _cents(_amount.text)!,
        notes: _notes.text.trim());
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      CoffeeFinanceSale? result;
      final saved = await runLicensedWrite(context, () async {
        try {
          await widget.repository.saveReceipt(receipt);
          final list = await widget.repository.sales(
              propertyId: sale.lot.propertyId, seasonYear: sale.lot.seasonYear);
          result = list
              .where((item) =>
                  item.lot.id == sale.lot.id && item.sale.id == sale.sale.id)
              .firstOrNull;
        } on FormatException catch (error) {
          if (mounted) setState(() => _error = error.message);
        }
      });
      if (mounted && saved && result != null) Navigator.pop(context, result);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('Registrar recebimento'),
        content: SizedBox(
            width: AppTheme.dialogWidth(context, maxWidth: 440),
            child: Form(
                key: _form,
                child: SingleChildScrollView(
                    child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('A receber: ${_money(widget.sale.outstandingCents)}'),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () async {
                                final date = await _pickDate(context, _day,
                                    from: widget.sale.sale.date);
                                if (mounted && date != null) {
                                  setState(() => _day = date);
                                }
                              },
                        icon: const Icon(Icons.calendar_today_outlined),
                        label:
                            Text('Data do recebimento: ${_date.format(_day)}')),
                    const SizedBox(height: 8),
                    TextFormField(
                        controller: _amount,
                        enabled: !_busy,
                        decoration: const InputDecoration(
                            labelText: 'Valor recebido (R\$)'),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        validator: (value) {
                          final cents = _cents(value);
                          if (cents == null || cents <= 0) {
                            return 'Informe um valor maior que zero.';
                          }
                          return cents > widget.sale.outstandingCents
                              ? 'O valor excede o saldo a receber.'
                              : null;
                        }),
                    const SizedBox(height: 8),
                    TextFormField(
                        controller: _notes,
                        enabled: !_busy,
                        maxLines: 2,
                        maxLength: 4000,
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
              onPressed: _busy ? null : _save,
              child: const Text('Salvar recebimento')),
        ],
      ));
}
