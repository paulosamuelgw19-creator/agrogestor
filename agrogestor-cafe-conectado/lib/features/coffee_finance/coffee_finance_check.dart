part of 'coffee_finance_screen.dart';

class _FinanceCheckDialog extends StatefulWidget {
  const _FinanceCheckDialog(
      {required this.propertyId,
      required this.plotId,
      required this.year,
      required this.period,
      required this.entries,
      required this.canEdit,
      required this.onEntry});

  final String propertyId;
  final String? plotId;
  final int year;
  final DateTimeRange? period;
  final List<CoffeeFinanceEntry> entries;
  final bool canEdit;
  final ValueChanged<CoffeeFinanceEntry> onEntry;

  @override
  State<_FinanceCheckDialog> createState() => _FinanceCheckDialogState();
}

class _FinanceCheckDialogState extends State<_FinanceCheckDialog> {
  final _repository = CoffeeFinanceCheckRepository();
  final _amount = TextEditingController();
  late final _groups = {
    for (final entry in widget.entries)
      if (!entry.isIncome) (entry.stage, entry.category),
  }.toList();
  (CoffeeFinanceStage, String)? _group;
  int? _saved;
  bool _busy = false;
  String? _error;

  CoffeeFinanceCheck _check((CoffeeFinanceStage, String) group, int cents) =>
      CoffeeFinanceCheck(
          propertyId: widget.propertyId,
          plotId: widget.plotId,
          seasonYear: widget.year,
          stage: group.$1,
          category: group.$2,
          cents: cents,
          start: widget.period?.start.toIso8601String(),
          end: widget.period?.end.toIso8601String());

  Future<void> _choose((CoffeeFinanceStage, String)? group) async {
    if (group == null) return;
    setState(() {
      _group = group;
      _saved = null;
      _error = null;
      _amount.clear();
      _busy = true;
    });
    try {
      final stored = await _repository.get(_check(group, 0));
      if (mounted) {
        setState(() {
          _saved = stored?.cents;
          _amount.text = _priceText(_saved);
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Não foi possível carregar a conferência.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final cents = _cents(_amount.text);
    if (cents == null) {
      setState(() => _error = 'Informe um valor válido, por exemplo 739,88.');
      return;
    }
    final check = _check(_group!, cents);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved =
          await runLicensedWrite(context, () => _repository.save(check));
      if (saved && mounted) setState(() => _saved = cents);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final group = _group;
    final entries = group == null
        ? <CoffeeFinanceEntry>[]
        : widget.entries.where(_check(group, 0).matches).toList();
    final known = entries.where((entry) => entry.totalCents != null);
    final total = known.fold(0, (sum, entry) => sum + entry.totalCents!);
    final unknown = entries.length - known.length;
    final saved = _saved;
    return AlertDialog(
      scrollable: true,
      title: const Text('Conferência com o caderno'),
      content: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_groups.isEmpty)
          const Text('Nenhuma despesa registrada nos filtros atuais.')
        else
          DropdownButtonFormField<(CoffeeFinanceStage, String)>(
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Etapa e categoria'),
            items: [
              for (final item in _groups)
                DropdownMenuItem(
                    value: item,
                    child: Text('${_stages[item.$1]} · ${item.$2}',
                        overflow: TextOverflow.ellipsis)),
            ],
            onChanged: _busy ? null : _choose,
          ),
        if (group != null) ...[
          const SizedBox(height: 8),
          if (widget.canEdit)
            TextField(
                controller: _amount,
                enabled: !_busy,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                    labelText: 'Subtotal anotado (R\$)', errorText: _error)),
          Text(
              'Subtotal anotado: ${saved == null ? 'Não informado' : _money(saved)}'),
          Text(
              'Lançamentos com valor: ${known.isEmpty ? 'Não informado' : _money(total)}'),
          if (saved != null && known.isNotEmpty)
            Text('Diferença a conferir: ${_money(saved - total)}'),
          if (unknown != 0) Text('$unknown lançamento(s) sem valor informado'),
          const Divider(),
          for (final entry in entries)
            ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(entry.description),
                subtitle: Text(
                    '${_date.format(entry.date)} · ${entry.totalCents == null ? 'Não informado' : _money(entry.totalCents!)}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => widget.onEntry(entry)),
        ],
      ]),
      actions: [
        TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Fechar')),
        if (widget.canEdit && group != null)
          FilledButton(
              onPressed: _busy ? null : _save,
              child: const Text('Salvar subtotal')),
      ],
    );
  }
}
