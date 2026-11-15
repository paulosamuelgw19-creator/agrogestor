part of 'coffee_processing_screen.dart';

class _LotEditor extends StatefulWidget {
  const _LotEditor(
      {required this.repository,
      required this.farm,
      required this.plots,
      required this.year,
      this.initialPlot,
      this.existing});

  final CoffeeProcessingRepository repository;
  final Json farm;
  final List<Json> plots;
  final int year;
  final Json? initialPlot;
  final CoffeeLot? existing;

  @override
  State<_LotEditor> createState() => _LotEditorState();
}

class _LotEditorState extends State<_LotEditor> {
  final _form = GlobalKey<FormState>();
  late final _id = widget.existing?.id ?? const Uuid().v4();
  late final _code = TextEditingController(text: widget.existing?.code);
  late final _location = TextEditingController(text: widget.existing?.location);
  late final _notes = TextEditingController(text: widget.existing?.notes);
  late DateTime _day =
      widget.existing?.date ?? DateUtils.dateOnly(DateTime.now());
  late final List<CoffeeLotInput> _inputs = [...?widget.existing?.inputs];
  bool _busy = false;
  String? _inputsError;

  String get _propertyId => widget.farm['id'] as String;
  bool get _editableSources => widget.existing?.cleanings.isNotEmpty != true;

  @override
  void dispose() {
    _code.dispose();
    _location.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _editSource([int? index]) async {
    final source = await showDialog<CoffeeLotInput>(
        context: context,
        builder: (_) => _SourceDialog(
              repository: widget.repository,
              propertyId: _propertyId,
              year: widget.year,
              plots: widget.plots,
              initialPlot: widget.initialPlot,
              existing: index == null ? null : _inputs[index],
              lotId: widget.existing?.id,
              otherInputs: [
                for (final (position, input) in _inputs.indexed)
                  if (position != index) input
              ],
            ));
    if (!mounted || source == null) return;
    setState(() {
      if (index == null) {
        _inputs.add(source);
      } else {
        _inputs[index] = source;
      }
      _inputsError = null;
    });
  }

  Future<void> _save() async {
    if (_busy || !_form.currentState!.validate()) return;
    if (_inputs.isEmpty) {
      setState(() => _inputsError = _connectedProcessing
          ? 'Vincule ao menos um recebimento sincronizado.'
          : 'Adicione ao menos uma entrada. A origem pode ficar desconhecida.');
      return;
    }
    final lot = CoffeeLot(
        id: _id,
        propertyId: _propertyId,
        seasonYear: widget.year,
        code: _code.text.trim(),
        date: _day,
        location: _location.text.trim(),
        notes: _notes.text.trim(),
        inputs: List.unmodifiable(_inputs));
    setState(() => _busy = true);
    try {
      CoffeeLot? result;
      final saved = await runLicensedWrite(context, () async {
        await widget.repository.saveLot(lot, expected: widget.existing);
        result =
            await widget.repository.getLot(propertyId: _propertyId, lotId: _id);
      });
      if (mounted && saved) Navigator.pop(context, result);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
            title: Text(widget.existing == null ? 'Novo lote' : 'Editar lote')),
        body: SafeArea(
            child: Form(
                key: _form,
                child: _ProcessingPage(children: [
                  Text('${widget.farm['name']} · Safra ${widget.year}',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  TextFormField(
                      controller: _code,
                      enabled: !_busy,
                      maxLength: 120,
                      decoration: const InputDecoration(
                          labelText: 'Código do lote', counterText: ''),
                      validator: (value) => (value ?? '').trim().isEmpty
                          ? 'Informe o código do lote.'
                          : null),
                  const SizedBox(height: 8),
                  Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: OutlinedButton.icon(
                        onPressed: _busy || !_editableSources
                            ? null
                            : () async {
                                final date = await _chooseDate(context, _day);
                                if (mounted && date != null) {
                                  setState(() => _day = date);
                                }
                              },
                        icon: const Icon(Icons.calendar_today_outlined),
                        label: Text('Data de abertura: ${_date.format(_day)}'),
                      )),
                  const SizedBox(height: 8),
                  TextFormField(
                      controller: _location,
                      enabled: !_busy,
                      maxLength: 160,
                      decoration: const InputDecoration(
                          labelText: 'Local', counterText: '')),
                  const SizedBox(height: 8),
                  TextFormField(
                      controller: _notes,
                      enabled: !_busy,
                      maxLines: 2,
                      maxLength: 1000,
                      decoration: const InputDecoration(
                          labelText: 'Observações', counterText: '')),
                  const Divider(height: 30),
                  Text('Entradas do lote',
                      style: Theme.of(context).textTheme.titleMedium),
                  if (!_editableSources)
                    const Text(
                        'As entradas ficam preservadas após a primeira limpa.'),
                  for (final (index, input) in _inputs.indexed)
                    Card(
                        child: ListTile(
                      title: Text(
                          '${_sourceNames[input.kind]} · ${_originNames[input.origin]}'),
                      subtitle: Text(input.volumeLiters == null
                          ? 'Volume não informado'
                          : _liters(input.volumeLiters!)),
                      onTap: _busy || !_editableSources
                          ? null
                          : () => _editSource(index),
                      trailing: _editableSources
                          ? IconButton(
                              tooltip: 'Remover entrada',
                              onPressed: _busy
                                  ? null
                                  : () =>
                                      setState(() => _inputs.removeAt(index)),
                              icon: const Icon(Icons.delete_outline))
                          : null,
                    )),
                  if (_editableSources)
                    Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: OutlinedButton.icon(
                            onPressed: _busy ? null : () => _editSource(),
                            icon: const Icon(Icons.add),
                            label: const Text('Adicionar entrada'))),
                  if (_inputsError case final String error)
                    Text(error,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 12),
                  if (_busy) const LinearProgressIndicator(),
                  Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: FilledButton(
                          onPressed: _busy ? null : _save,
                          child: const Text('Salvar lote'))),
                ]))),
      );
}

class _SourceDialog extends StatefulWidget {
  const _SourceDialog(
      {required this.repository,
      required this.propertyId,
      required this.year,
      required this.plots,
      this.initialPlot,
      this.existing,
      this.lotId,
      required this.otherInputs});

  final CoffeeProcessingRepository repository;
  final String propertyId;
  final int year;
  final List<Json> plots;
  final Json? initialPlot;
  final CoffeeLotInput? existing;
  final String? lotId;
  final List<CoffeeLotInput> otherInputs;

  @override
  State<_SourceDialog> createState() => _SourceDialogState();
}

class _SourceDialogState extends State<_SourceDialog> {
  final _form = GlobalKey<FormState>();
  late final _id = widget.existing?.id ?? const Uuid().v4();
  late final _volume =
      TextEditingController(text: _numberText(widget.existing?.volumeLiters));
  late final _linked =
      TextEditingController(text: _numberText(widget.existing?.linkedLiters));
  late final _notes = TextEditingController(text: widget.existing?.notes);
  late CoffeeLotSourceKind _kind =
      widget.existing?.kind ?? CoffeeLotSourceKind.picked;
  late CoffeeLotOrigin _origin = _connectedProcessing
      ? CoffeeLotOrigin.confirmed
      : widget.existing?.origin ??
          (widget.initialPlot == null
              ? CoffeeLotOrigin.unknown
              : CoffeeLotOrigin.partial);
  late String? _plotId = widget.existing == null
      ? (widget.initialPlot?['id'] as String?)
      : widget.existing!.plotId;
  late DateTime? _harvestDay = widget.existing?.harvestDate;
  late String? _receiptId = widget.existing?.receiptId;
  Future<List<CoffeeLotHarvestSource>>? _sources;
  List<CoffeeLotHarvestSource> _currentDays = [];
  String? _error;
  bool _submitted = false;

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  void _loadSources() {
    _currentDays = [];
    final plotId = _plotId;
    _sources = plotId == null || _origin == CoffeeLotOrigin.unknown
        ? null
        : widget.repository.harvestSources(
            propertyId: widget.propertyId,
            plotId: plotId,
            seasonYear: widget.year,
            excludingLotId: widget.lotId);
  }

  @override
  void dispose() {
    _volume.dispose();
    _linked.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _save() {
    if (_submitted || !_form.currentState!.validate()) return;
    final volume = _number(_volume.text);
    final day = _harvestDay;
    final linked = day == null
        ? null
        : (_origin == CoffeeLotOrigin.confirmed
            ? volume
            : _number(_linked.text));
    final matching = day == null
        ? null
        : _currentDays
            .where((source) => _connectedProcessing
                ? source.receiptId == _receiptId
                : DateUtils.isSameDay(source.date, day))
            .firstOrNull;
    if (_origin == CoffeeLotOrigin.confirmed &&
        (day == null || volume == null)) {
      setState(() => _error = _connectedProcessing
          ? 'Selecione o recebimento e informe o volume usado no lote.'
          : 'Escolha o dia da colheita e informe o volume desta entrada.');
      return;
    }
    if (_origin == CoffeeLotOrigin.partial &&
        _plotId == null &&
        _notes.text.trim().isEmpty) {
      setState(() =>
          _error = 'Indique o talhão ou descreva o que sabe sobre a origem.');
      return;
    }
    if (day != null &&
        (matching == null ||
            linked == null ||
            linked <= 0 ||
            linked - _available(matching) > 0.000001 ||
            (volume != null && linked > volume))) {
      setState(() => _error = _connectedProcessing
          ? 'O volume usado precisa caber no saldo disponível do recebimento.'
          : 'Confira o volume vinculado. Ele precisa caber no saldo do dia e no total da entrada, quando informado.');
      return;
    }
    _submitted = true;
    Navigator.pop(
        context,
        CoffeeLotInput(
            id: _id,
            kind: _kind,
            origin: _origin,
            volumeLiters: volume,
            plotId: _origin == CoffeeLotOrigin.unknown ? null : _plotId,
            harvestDate: day,
            linkedLiters: linked,
            receiptId: _connectedProcessing ? _receiptId : null,
            notes: _notes.text.trim()));
  }

  double _available(CoffeeLotHarvestSource source) {
    if (!_connectedProcessing) return source.availableLiters;
    final used = widget.otherInputs
        .where((item) => item.receiptId == source.receiptId)
        .fold(0.0, (total, item) => total + (item.linkedLiters ?? 0));
    return (source.availableLiters - used).clamp(0, double.infinity).toDouble();
  }

  Widget _receiptOptions() => FutureBuilder<List<CoffeeLotHarvestSource>>(
        future: _sources,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const LinearProgressIndicator();
          }
          if (snapshot.hasError) {
            return TextButton(
                onPressed: () => setState(_loadSources),
                child: const Text(
                    'Não foi possível carregar os recebimentos. Tentar novamente'));
          }
          final sources = (snapshot.data ?? [])
              .where((source) => source.receiptId != null)
              .toList();
          _currentDays = sources;
          if (sources.isEmpty) {
            return const AppNotice(
                message:
                    'Não há recebimentos sincronizados com volume disponível neste talhão e nesta safra.');
          }
          final selected = sources
              .where((source) => source.receiptId == _receiptId)
              .firstOrNull;
          return DropdownButtonFormField<String>(
            key: ValueKey((_plotId, _sources)),
            initialValue: selected?.receiptId,
            isExpanded: true,
            decoration:
                const InputDecoration(labelText: 'Recebimento sincronizado'),
            validator: (value) =>
                value == null ? 'Selecione um recebimento.' : null,
            items: [
              for (final source in sources)
                DropdownMenuItem(
                    value: source.receiptId,
                    enabled: _available(source) > 0 ||
                        source.receiptId == _receiptId,
                    child: Text(
                        '${_date.format(source.date)} · ${_liters(_available(source))} disponíveis',
                        overflow: TextOverflow.ellipsis))
            ],
            onChanged: (id) => setState(() {
              final source =
                  sources.where((item) => item.receiptId == id).firstOrNull;
              _receiptId = id;
              _harvestDay = source?.date;
              _error = null;
            }),
          );
        },
      );

  Widget _dateOptions() => FutureBuilder<List<CoffeeLotHarvestSource>>(
        future: _sources,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const LinearProgressIndicator();
          }
          if (snapshot.hasError) {
            return TextButton(
                onPressed: () => setState(_loadSources),
                child: const Text(
                    'Não foi possível carregar os dias de colheita. Tentar novamente'));
          }
          final days = snapshot.data ?? [];
          _currentDays = days;
          if (days.isEmpty && _harvestDay == null) {
            return const Text(
                'Ainda não há dias de colheita registrados neste talhão e safra.');
          }
          final selected = _harvestDay;
          final saved = days
              .where((day) => DateUtils.isSameDay(day.date, selected))
              .firstOrNull;
          return DropdownButtonFormField<DateTime?>(
            key: ValueKey((_plotId, _origin, _sources)),
            initialValue: saved?.date ?? selected,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Dia da colheita'),
            items: [
              if (_origin == CoffeeLotOrigin.partial)
                const DropdownMenuItem(
                    value: null, child: Text('Sem dia confirmado')),
              if (selected != null && saved == null)
                DropdownMenuItem(
                    value: selected,
                    child: Text('${_date.format(selected)} · Indisponível')),
              for (final day in days)
                DropdownMenuItem(
                    value: day.date,
                    enabled: day.availableLiters > 0 ||
                        DateUtils.isSameDay(day.date, selected),
                    child: Text(
                        '${_date.format(day.date)} · ${_liters(day.availableLiters)} disponíveis',
                        overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (value) => setState(() {
              _harvestDay = value;
              _linked.clear();
              _error = null;
            }),
          );
        },
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(
            widget.existing == null ? 'Adicionar entrada' : 'Editar entrada'),
        content: SizedBox(
            width: AppTheme.dialogWidth(context, maxWidth: 480),
            child: Form(
                key: _form,
                child: SingleChildScrollView(
                    child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownButtonFormField<CoffeeLotSourceKind>(
                      isExpanded: true,
                      initialValue: _kind,
                      decoration:
                          const InputDecoration(labelText: 'Tipo de entrada'),
                      items: [
                        for (final item in _sourceNames.entries)
                          DropdownMenuItem(
                              value: item.key, child: Text(item.value))
                      ],
                      onChanged: (value) => _kind = value ?? _kind,
                    ),
                    const SizedBox(height: 8),
                    if (!_connectedProcessing)
                      DropdownButtonFormField<CoffeeLotOrigin>(
                        isExpanded: true,
                        initialValue: _origin,
                        decoration: const InputDecoration(labelText: 'Origem'),
                        items: [
                          for (final item in _originNames.entries)
                            DropdownMenuItem(
                                value: item.key, child: Text(item.value))
                        ],
                        onChanged: (value) => setState(() {
                          _origin = value ?? _origin;
                          if (_origin == CoffeeLotOrigin.unknown) {
                            _harvestDay = null;
                            _plotId = null;
                            _linked.clear();
                          }
                          _error = null;
                          _loadSources();
                        }),
                      ),
                    const SizedBox(height: 8),
                    _DecimalField(
                        controller: _volume,
                        label: _connectedProcessing
                            ? 'Volume usado no lote (L)'
                            : 'Volume da entrada (L)',
                        requiredValue: _origin == CoffeeLotOrigin.confirmed),
                    if (_origin != CoffeeLotOrigin.unknown) ...[
                      const SizedBox(height: 8),
                      DropdownButtonFormField<String?>(
                        initialValue: _plotId,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Talhão'),
                        items: [
                          if (_origin == CoffeeLotOrigin.partial)
                            const DropdownMenuItem(
                                value: null,
                                child: Text('Sem talhão confirmado')),
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
                        onChanged: (value) => setState(() {
                          _plotId = value;
                          _harvestDay = null;
                          _receiptId = null;
                          _linked.clear();
                          _error = null;
                          _loadSources();
                        }),
                      ),
                      if (_plotId != null) ...[
                        const SizedBox(height: 8),
                        if (_connectedProcessing)
                          _receiptOptions()
                        else
                          _dateOptions()
                      ],
                      if (_harvestDay != null &&
                          _origin == CoffeeLotOrigin.partial) ...[
                        const SizedBox(height: 8),
                        _DecimalField(
                            controller: _linked,
                            label: 'Volume vinculado ao dia (L)',
                            requiredValue: true),
                      ],
                    ],
                    const SizedBox(height: 8),
                    TextFormField(
                        controller: _notes,
                        maxLines: 2,
                        maxLength: 1000,
                        decoration: const InputDecoration(
                            labelText: 'Observações da entrada',
                            counterText: '')),
                    if (_error case final String error)
                      Text(error,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                  ],
                )))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar')),
          FilledButton(onPressed: _save, child: const Text('Salvar entrada')),
        ],
      );
}
