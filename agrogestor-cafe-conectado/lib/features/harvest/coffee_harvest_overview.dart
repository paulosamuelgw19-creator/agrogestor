part of 'coffee_harvest_screen.dart';

typedef _HarvestOverviewData = ({
  List<({Json plot, CoffeePlotProductionSummary production})> plots,
  List<CoffeeLot> lots,
});

class _HarvestOverview extends StatefulWidget {
  const _HarvestOverview({required this.farms, required this.plots});

  final List<Json> farms, plots;

  @override
  State<_HarvestOverview> createState() => _HarvestOverviewState();
}

class _HarvestOverviewState extends State<_HarvestOverview>
    with _HarvestSyncRefresh {
  String? _farmId;
  late int _year = DateTime.now().year;
  late final _yearField = TextEditingController(text: '$_year');
  String? _yearError;
  late Future<_HarvestOverviewData> _data = _load();

  Future<_HarvestOverviewData> _load() async {
    final farms = widget.farms
        .where((farm) => _farmId == null || farm['id'] == _farmId)
        .toList();
    final ids = farms.map((farm) => farm['id']).toSet();
    final year = _year;
    final harvest = CoffeeHarvestRepository();
    final processing = CoffeeProcessingRepository();
    return (
      plots: [
        for (final plot
            in widget.plots.where((plot) => ids.contains(plot['property_id'])))
          (
            plot: plot,
            production: await harvest.production(
              propertyId: plot['property_id'] as String,
              plotId: plot['id'] as String,
              seasonYear: year,
            ),
          ),
      ],
      lots: [
        if (!_connectedHarvest)
          for (final farm in farms)
            ...await processing.list(
                propertyId: farm['id'] as String, seasonYear: year),
      ],
    );
  }

  void _applyYear() {
    final year = int.tryParse(_yearField.text);
    if (year == null || year < 1900 || year > 9999) {
      setState(() => _yearError = 'Informe um ano de quatro dígitos.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _year = year;
      _yearError = null;
      _data = _load();
    });
  }

  @override
  void refreshHarvest() => setState(() {
        _data = _load();
      });

  @override
  void dispose() {
    _yearField.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Resumo da safra')),
        body: SafeArea(
            child: FutureBuilder<_HarvestOverviewData>(
          future: _data,
          builder: (context, snapshot) {
            if (!_allowed) return _requireHarvestSession;
            final data = snapshot.connectionState == ConnectionState.done
                ? snapshot.data
                : null;
            final plots = data?.plots;
            final lots = data?.lots;
            final days = <DateTime, double>{};
            for (final row in plots ??
                <({Json plot, CoffeePlotProductionSummary production})>[]) {
              for (final day in row.production.days) {
                days.update(day.date, (value) => value + day.totalLiters,
                    ifAbsent: () => day.totalLiters);
              }
            }
            final dates = days.keys.toList()..sort((a, b) => b.compareTo(a));
            String sacks(double kg) =>
                '${_decimal.format(kg / 60)} sacas de 60 kg';
            final produced =
                lots?.expand((lot) => lot.cleanings).isNotEmpty == true;
            final sold = lots?.expand((lot) => lot.sales).isNotEmpty == true;
            return ListView(padding: AppTheme.pagePadding(context), children: [
              DropdownButtonFormField<String>(
                initialValue: _farmId ?? '',
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Fazenda'),
                items: [
                  const DropdownMenuItem(
                      value: '', child: Text('Todas as fazendas')),
                  for (final farm in widget.farms)
                    DropdownMenuItem(
                        value: farm['id'] as String,
                        child: Text('${farm['name']}',
                            overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (id) => setState(() {
                  _farmId = id == '' ? null : id;
                  _data = _load();
                }),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _yearField,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(4)
                ],
                onSubmitted: (_) => _applyYear(),
                decoration: InputDecoration(
                    labelText: 'Ano da safra', errorText: _yearError),
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                    onPressed: _applyYear, child: const Text('Ver safra')),
              ),
              if (snapshot.hasError)
                TextButton(
                    onPressed: _applyYear,
                    child: const Text(
                        'Não foi possível carregar. Tentar novamente'))
              else if (plots == null || lots == null)
                const LinearProgressIndicator()
              else ...[
                Text('Safra $_year',
                    style: Theme.of(context).textTheme.titleLarge),
                Text(
                    'Litros colhidos: ${days.isEmpty ? 'Sem lançamentos' : _liters(days.values.fold(0.0, (a, b) => a + b))}'),
                if (!_connectedHarvest) ...[
                  Text(
                      'Beneficiado: ${produced ? sacks(lots.fold(0.0, (a, lot) => a + lot.producedKg)) : 'Sem lançamentos'}'),
                  Text(
                      'Vendido: ${sold ? sacks(lots.fold(0.0, (a, lot) => a + lot.soldKg)) : 'Sem lançamentos'}'),
                  Text(
                      'Saldo disponível: ${produced ? sacks(lots.fold(0.0, (a, lot) => a + lot.stockKg)) : 'Sem lançamentos'}'),
                ],
                const Divider(height: 28),
                Text('Produção por talhão',
                    style: Theme.of(context).textTheme.titleMedium),
                for (final row in plots)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${row.plot['name']}'),
                    subtitle: Text([
                      '${widget.farms.firstWhere((farm) => farm['id'] == row.plot['property_id'])['name']}',
                      row.production.days.isEmpty
                          ? 'Sem lançamentos'
                          : _liters(row.production.totalLiters),
                      if (row.production.days.any((day) => day.needsReview))
                        'Produção a conferir',
                    ].join(' · ')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      final farm = widget.farms.firstWhere(
                          (farm) => farm['id'] == row.plot['property_id']);
                      await Navigator.of(context).push<void>(MaterialPageRoute(
                        builder: (_) => CoffeeHarvestScreen(
                            property: farm, plot: row.plot, initialYear: _year),
                      ));
                      if (mounted) refreshHarvest();
                    },
                  ),
                const Divider(height: 28),
                Text('Produção por dia',
                    style: Theme.of(context).textTheme.titleMedium),
                if (dates.isEmpty) const Text('Sem lançamentos'),
                for (final date in dates)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_date.format(date)),
                    subtitle: Text(_liters(days[date]!)),
                  ),
              ],
            ]);
          },
        )),
      );
}
