part of 'coffee_harvest_screen.dart';

String _receiptDifference(double received, double field) {
  final difference = received - field;
  return '${difference > 0 ? '+' : ''}${_liters(difference)}';
}

class _CoffeeReceiptDay extends StatelessWidget {
  const _CoffeeReceiptDay(
      {required this.receipts,
      required this.currentLiters,
      this.onNew,
      this.onRetry});

  final List<CoffeeHarvestReceipt> receipts;
  final double? currentLiters;
  final VoidCallback? onNew;
  final ValueChanged<CoffeeHarvestReceipt>? onRetry;

  @override
  Widget build(BuildContext context) {
    if (receipts.isEmpty && onNew == null) return const SizedBox.shrink();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Recebimento físico',
              style: Theme.of(context).textTheme.titleMedium),
          if (receipts.isEmpty)
            TextButton.icon(
                onPressed: onNew,
                icon: const Icon(Icons.move_to_inbox_outlined),
                label: const Text('Registrar recebimento')),
          for (final receipt in receipts) ...[
            Text(
                'Colheita de ${_date.format(receipt.harvestDate)} · Recebido em ${_date.format(receipt.receivedDate)}'),
            Text(
                'Campo confirmado no recebimento: ${_liters(receipt.fieldLiters)}'),
            Text('Recebido: ${_liters(receipt.receivedLiters)}'),
            Text(
                'Diferença (recebido − campo): ${_receiptDifference(receipt.receivedLiters, receipt.fieldLiters)}'),
            if (currentLiters == null)
              const AppNotice(
                  message:
                      'A colheita atual desse dia está indisponível. O volume confirmado no recebimento continua registrado.')
            else if ((currentLiters! - receipt.fieldLiters).abs() > 0.000001)
              AppNotice(
                  message:
                      'Colheita atual: ${_liters(currentLiters!)}. Diferença frente ao recebido: ${_receiptDifference(receipt.receivedLiters, currentLiters!)}.'),
            if (receipt.notes case final String notes when notes.isNotEmpty)
              Text(notes),
            SyncStatusLabel(
                module: CoffeeReceiptRepository.module, recordId: receipt.id),
            if (onRetry case final ValueChanged<CoffeeHarvestReceipt> retry)
              AnimatedBuilder(
                  animation: SyncService(),
                  builder: (context, _) => FutureBuilder<String?>(
                        future: SyncService().recordState(
                            CoffeeReceiptRepository.module, receipt.id),
                        builder: (context, snapshot) => snapshot.data == 'error'
                            ? TextButton(
                                onPressed: () => retry(receipt),
                                child: const Text('Conferir fonte e reenviar'))
                            : const SizedBox.shrink(),
                      )),
          ],
        ]),
      ),
    );
  }
}

class _CoffeeReceiptForm extends StatefulWidget {
  const _CoffeeReceiptForm(
      {required this.repository,
      required this.propertyId,
      required this.plotId,
      required this.location,
      required this.seasonYear,
      required this.day,
      required this.currentLiters,
      this.existing});

  final CoffeeReceiptRepository repository;
  final String propertyId, plotId, location;
  final int seasonYear;
  final DateTime day;
  final double? currentLiters;
  final CoffeeHarvestReceipt? existing;

  @override
  State<_CoffeeReceiptForm> createState() => _CoffeeReceiptFormState();
}

class _CoffeeReceiptFormState extends State<_CoffeeReceiptForm> {
  final _form = GlobalKey<FormState>();
  late final _volume = TextEditingController(
      text: widget.existing?.receivedLiters.toString().replaceAll('.', ','));
  late final _notes = TextEditingController(text: widget.existing?.notes);
  late DateTime _receivedDate =
      widget.existing?.receivedDate ?? DateUtils.dateOnly(DateTime.now());
  late Future<CoffeeReceiptSource> _source = _loadSource();
  bool _saving = false;

  Future<CoffeeReceiptSource> _loadSource() => widget.repository.source(
        propertyId: widget.propertyId,
        plotId: widget.plotId,
        seasonYear: widget.seasonYear,
        harvestDate: widget.day,
      );

  @override
  void dispose() {
    _volume.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save(CoffeeReceiptSource source) async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final saved = await runLicensedWrite(
          context,
          () => widget.repository.save(
                source: source,
                receivedDate: _receivedDate,
                receivedLiters: _number(_volume.text)!,
                notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
              ));
      if (mounted && saved) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickDate() async {
    final first = DateUtils.dateOnly(widget.day);
    final today = DateUtils.dateOnly(DateTime.now());
    final date = await showDatePicker(
      context: context,
      firstDate: first,
      lastDate: _receivedDate.isAfter(today)
          ? _receivedDate
          : today.isBefore(first)
              ? first
              : today,
      initialDate: _receivedDate.isBefore(first) ? first : _receivedDate,
    );
    if (mounted && date != null) setState(() => _receivedDate = date);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<CoffeeReceiptSource>(
        future: _source,
        builder: (context, snapshot) {
          final ready = snapshot.connectionState == ConnectionState.done &&
                  !snapshot.hasError
              ? snapshot.data
              : null;
          final amount = _number(_volume.text);
          return PopScope(
              canPop: !_saving,
              child: AlertDialog(
                title: Text(widget.existing == null
                    ? 'Registrar recebimento'
                    : 'Conferir fonte do recebimento'),
                content: SizedBox(
                    width: AppTheme.dialogWidth(context, maxWidth: 460),
                    child: Form(
                        key: _form,
                        child: SingleChildScrollView(
                            child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(widget.location,
                                style: AppTheme.nameStyle(context)),
                            Text(
                                'Colheita de ${_date.format(widget.day)} · Safra ${widget.seasonYear}'),
                            const SizedBox(height: 8),
                            if (snapshot.connectionState !=
                                ConnectionState.done) ...[
                              const Text(
                                  'Consultando a colheita no PC gestor…'),
                              const LinearProgressIndicator(),
                            ] else if (snapshot.hasError) ...[
                              AppNotice(
                                  message: snapshot.error is FormatException
                                      ? (snapshot.error! as FormatException)
                                          .message
                                      : 'Conecte-se ao PC gestor e sincronize a colheita antes de registrar o recebimento.',
                                  tone: AppNoticeTone.error),
                              TextButton(
                                  onPressed: () => setState(() {
                                        _source = _loadSource();
                                      }),
                                  child: const Text('Tentar de novo')),
                            ] else if (ready != null) ...[
                              Text(
                                  'Campo confirmado no PC: ${_liters(ready.fieldLiters)}'),
                              if (widget.currentLiters case final double current
                                  when (current - ready.fieldLiters).abs() >
                                      0.000001)
                                AppNotice(
                                    message:
                                        'Colheita neste aparelho: ${_liters(current)}. Sincronize a colheita antes de continuar se esse for o total correto.'),
                              const SizedBox(height: 8),
                              OutlinedButton.icon(
                                  onPressed: _saving ? null : _pickDate,
                                  icon:
                                      const Icon(Icons.calendar_today_outlined),
                                  label: Text(
                                      'Data de recebimento: ${_date.format(_receivedDate)}')),
                              const SizedBox(height: 8),
                              TextFormField(
                                  controller: _volume,
                                  enabled: !_saving,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                          decimal: true),
                                  decoration: const InputDecoration(
                                      labelText: 'Volume recebido (L)'),
                                  onChanged: (_) => setState(() {}),
                                  validator: (text) => (_number(text) ??
                                              double.infinity) >
                                          1e12
                                      ? 'Informe os litros recebidos, inclusive zero.'
                                      : null),
                              if (amount != null)
                                Text(
                                    'Diferença (recebido − campo): ${_receiptDifference(amount, ready.fieldLiters)}'),
                              const SizedBox(height: 8),
                              TextFormField(
                                  controller: _notes,
                                  enabled: !_saving,
                                  maxLength: 1000,
                                  maxLines: 2,
                                  decoration: const InputDecoration(
                                      labelText: 'Observações (opcional)')),
                              if (_saving) const LinearProgressIndicator(),
                            ],
                          ],
                        )))),
                actions: [
                  TextButton(
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      child: const Text('Cancelar')),
                  FilledButton(
                      onPressed:
                          _saving || ready == null ? null : () => _save(ready),
                      child: const Text('Salvar recebimento')),
                ],
              ));
        },
      );
}
