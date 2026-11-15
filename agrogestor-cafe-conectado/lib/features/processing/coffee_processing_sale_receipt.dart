part of 'coffee_processing_screen.dart';

typedef _ConnectedSales = ({
  List<CoffeeFinanceSale> sales,
  Set<String> pending,
  Map<String, CoffeeSaleReceipt> rejected,
});

class _WhenLotSynced extends StatelessWidget {
  const _WhenLotSynced({required this.lot, required this.builder});

  final CoffeeLot lot;
  final Widget Function(bool synced) builder;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: SyncService(),
        builder: (context, _) => FutureBuilder<String?>(
          future: SyncService().recordState(_processingModule, lot.id),
          builder: (context, snapshot) => builder(snapshot.data == 'synced'),
        ),
      );
}

class _ConnectedSaleHistory extends StatelessWidget {
  const _ConnectedSaleHistory(
      {required this.lot,
      required this.future,
      required this.canWrite,
      required this.onReceive,
      required this.onDiscardRejected});

  final CoffeeLot lot;
  final Future<_ConnectedSales>? future;
  final bool canWrite;
  final ValueChanged<CoffeeFinanceSale> onReceive;
  final ValueChanged<CoffeeSaleReceipt> onDiscardRejected;

  @override
  Widget build(BuildContext context) => FutureBuilder<_ConnectedSales>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const LinearProgressIndicator();
          }
          if (snapshot.hasError) {
            return const AppNotice(
                message:
                    'Não foi possível carregar os pagamentos. Atualize para tentar novamente.',
                tone: AppNoticeTone.error);
          }
          final data = snapshot.data;
          if (data == null) return const SizedBox.shrink();
          if (lot.sales.isEmpty) return const Text('Nenhuma venda registrada.');
          final confirmed = {for (final sale in data.sales) sale.sale.id: sale};
          return _WhenLotSynced(
              lot: lot,
              builder: (synced) => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final sale
                            in _mostRecent(lot.sales, (item) => item.date))
                          Card(
                              child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                            '${_date.format(sale.date)} · ${_kg(sale.outputKg)}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleMedium),
                                        if (sale.buyer.isNotEmpty)
                                          Text(sale.buyer,
                                              style:
                                                  AppTheme.nameStyle(context)),
                                        Text(
                                            'Vendido: ${_money(sale.totalPriceCents)}'),
                                        if (confirmed[sale.id]
                                            case final CoffeeFinanceSale
                                                item) ...[
                                          Text(
                                              'Recebido: ${_money(item.receivedCents)}'),
                                          Text(
                                              'A receber: ${_money(item.outstandingCents)}'),
                                          for (final receipt
                                              in item.receipts) ...[
                                            const SizedBox(height: 6),
                                            Text(
                                                'Pagamento em ${_date.format(receipt.date)} · ${_money(receipt.amountCents)}'),
                                            if (receipt.notes.isNotEmpty)
                                              Text(receipt.notes),
                                          ],
                                          if (data.rejected[sale.id]
                                              case final CoffeeSaleReceipt
                                                  rejected) ...[
                                            const AppNotice(
                                                message: SyncService
                                                    .rejectedSaleBalanceMessage,
                                                tone: AppNoticeTone.error),
                                            if (canWrite)
                                              TextButton(
                                                onPressed: () =>
                                                    onDiscardRejected(rejected),
                                                child: const Text(
                                                    'Descartar pagamento recusado'),
                                              ),
                                          ] else if (data.pending
                                              .contains(sale.id))
                                            const AppNotice(
                                                message:
                                                    'Existe um pagamento aguardando confirmação do PC gestor. Acompanhe em Ver fila e conflitos.',
                                                tone: AppNoticeTone.info),
                                          if (canWrite &&
                                              synced &&
                                              item.outstandingCents > 0 &&
                                              !data.pending.contains(sale.id))
                                            TextButton.icon(
                                                onPressed: () =>
                                                    onReceive(item),
                                                icon: const Icon(
                                                    Icons.payments_outlined),
                                                label: const Text(
                                                    'Registrar pagamento da venda')),
                                        ] else
                                          const Text(
                                              'Venda aguardando confirmação do PC gestor.'),
                                        if (sale.notes.isNotEmpty)
                                          Text(sale.notes),
                                      ]))),
                      ]));
        },
      );
}

class _SaleReceiptDialog extends StatefulWidget {
  const _SaleReceiptDialog({required this.finance, required this.sale});

  final CoffeeFinanceRepository finance;
  final CoffeeFinanceSale sale;

  @override
  State<_SaleReceiptDialog> createState() => _SaleReceiptDialogState();
}

class _SaleReceiptDialogState extends State<_SaleReceiptDialog>
    with _ProcessingSession<_SaleReceiptDialog> {
  final _form = GlobalKey<FormState>();
  final _id = const Uuid().v4();
  late final _amount = TextEditingController(
      text: (widget.sale.outstandingCents / 100)
          .toStringAsFixed(2)
          .replaceAll('.', ','));
  final _notes = TextEditingController();
  late DateTime _day = widget.sale.sale.date.isAfter(DateTime.now())
      ? DateUtils.dateOnly(widget.sale.sale.date)
      : DateUtils.dateOnly(DateTime.now());
  bool _busy = false;

  @override
  void dispose() {
    _amount.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pickDay() async {
    final date = await _chooseDate(context, _day, from: widget.sale.sale.date);
    if (mounted && date != null) setState(() => _day = date);
  }

  Future<void> _save() async {
    if (!_allowed || _busy || !_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final sale = widget.sale;
      final saved = await runLicensedWrite(
          context,
          () => widget.finance.saveReceipt(CoffeeSaleReceipt(
                id: _id,
                propertyId: sale.lot.propertyId,
                lotId: sale.lot.id,
                saleId: sale.sale.id,
                date: _day,
                amountCents: _cents(_amount.text)!,
                notes: _notes.text.trim(),
              )));
      if (mounted && saved) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => !_allowed
      ? const AlertDialog(content: Text('A sessão mudou. Reabra a venda.'))
      : PopScope(
          canPop: !_busy,
          child: AlertDialog(
            title: const Text('Registrar pagamento da venda'),
            content: SizedBox(
                width: AppTheme.dialogWidth(context, maxWidth: 440),
                child: Form(
                    key: _form,
                    child: SingleChildScrollView(
                        child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                            'Lote ${widget.sale.lot.code} · A receber: ${_money(widget.sale.outstandingCents)}'),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                            onPressed: _busy ? null : _pickDay,
                            icon: const Icon(Icons.calendar_today_outlined),
                            label: Text(
                                'Data do pagamento: ${_date.format(_day)}')),
                        const SizedBox(height: 8),
                        TextFormField(
                            controller: _amount,
                            enabled: !_busy,
                            decoration: const InputDecoration(
                                labelText: 'Valor recebido (R\$)'),
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            validator: (text) {
                              final cents = _cents(text ?? '');
                              if (cents == null) {
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
                                labelText: 'Observações (opcional)')),
                        if (_busy) const LinearProgressIndicator(),
                      ],
                    )))),
            actions: [
              TextButton(
                  onPressed: _busy ? null : () => Navigator.pop(context),
                  child: const Text('Cancelar')),
              FilledButton(
                  onPressed: _busy ? null : _save,
                  child: const Text('Salvar pagamento')),
            ],
          ));
}
