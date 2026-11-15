import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../app/app_theme.dart';
import '../auth/auth_service.dart';
import '../auth/farm_access_policy.dart';
import '../coffee_finance/coffee_finance_repository.dart';
import '../licensing/write_gate.dart';
import '../operations_v2/v2_store.dart' show Json;
import '../properties/catalog_store.dart';
import '../sync/farm_api_client.dart';
import '../sync/sync_service.dart';
import '../sync/sync_settings_screen.dart';
import '../sync/sync_status_label.dart';
import 'coffee_processing_repository.dart';

part 'coffee_lot_form.dart';
part 'coffee_processing_movements.dart';
part 'coffee_processing_sale_receipt.dart';

const _connectedProcessing = !FarmApiClient.standaloneLocalMode;
const _processingModule = 'coffeeProcessingLots';

mixin _ProcessingSession<T extends StatefulWidget> on State<T> {
  late final _session = _processingSession;

  (String?, String?, String?) get _processingSession => (
        AuthService().currentUser?.id,
        AuthService().currentUser?.farmId,
        AuthService().accessToken,
      );

  bool get _allowed =>
      FarmAccessPolicy.canUseCoffeeHarvest && _session == _processingSession;

  @override
  void initState() {
    super.initState();
    _session;
    if (_connectedProcessing) AuthService().addListener(_sessionChanged);
  }

  @override
  void dispose() {
    if (_connectedProcessing) AuthService().removeListener(_sessionChanged);
    super.dispose();
  }

  void _sessionChanged() => setState(() {});

  Widget _unavailable() => const Center(
        child: Text('A sessão mudou. Volte e reabra o beneficiamento.'),
      );
}

class _ProcessingSyncActions extends StatelessWidget {
  const _ProcessingSyncActions();

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: SyncService(),
        builder: (context, _) {
          final syncing = SyncService().state == SyncState.syncing;
          return Wrap(spacing: 8, runSpacing: 4, children: [
            TextButton.icon(
                onPressed: syncing ? null : SyncService().syncNow,
                icon: const Icon(Icons.sync),
                label: Text(syncing ? 'Sincronizando' : 'Sincronizar agora')),
            TextButton(
                onPressed: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                        builder: (_) => Scaffold(
                            appBar: AppBar(title: const Text('Sincronização')),
                            body:
                                const SafeArea(child: SyncSettingsScreen())))),
                child: const Text('Ver fila e conflitos')),
          ]);
        },
      );
}

final _date = DateFormat('dd/MM/yyyy');
final _decimal = NumberFormat('#,##0.###', 'pt_BR');
final _ratio = NumberFormat('#,##0.######', 'pt_BR');
final _currency = NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$');

const _sourceNames = {
  CoffeeLotSourceKind.picked: 'Panha',
  CoffeeLotSourceKind.raked: 'Rastelação',
};
const _originNames = {
  CoffeeLotOrigin.confirmed: 'Confirmada',
  CoffeeLotOrigin.partial: 'Parcial',
  CoffeeLotOrigin.unknown: 'Desconhecida',
};
const _stageNames = {
  CoffeeProcessingStage.reception: 'Recebimento',
  CoffeeProcessingStage.washed: 'Lavado',
  CoffeeProcessingStage.dried: 'Seco',
  CoffeeProcessingStage.cleaned: 'Beneficiado',
  CoffeeProcessingStage.other: 'Outra etapa',
};
const _baseNames = {
  CoffeeCleaningInputBase.ripe: 'Café maduro',
  CoffeeCleaningInputBase.dry: 'Café seco',
  CoffeeCleaningInputBase.washed: 'Café lavado',
};

String _kg(double weight) => '${_decimal.format(weight)} kg';
String _liters(double volume) => '${_decimal.format(volume)} L';
String _money(int cents) => _currency.format(cents / 100);
String _name(Json item) =>
    '${item['name']}${item['archived'] == 1 ? ' · Arquivado' : ''}';
String _numberText(double? value) =>
    value?.toString().replaceFirst(RegExp(r'\.0$'), '').replaceAll('.', ',') ??
    '';

List<T> _mostRecent<T>(List<T> items, DateTime Function(T) dateOf) =>
    items.reversed.toList()
      ..sort((first, second) => dateOf(second).compareTo(dateOf(first)));

double? _number(String? raw) {
  final value = raw?.trim() ?? '';
  if (!RegExp(r'^\d+(?:[.,]\d+)?$').hasMatch(value)) return null;
  final number = double.tryParse(value.replaceAll(',', '.'));
  return number != null && number.isFinite && number <= 1e12 ? number : null;
}

int? _cents(String raw) {
  final match = RegExp(r'^(\d+)(?:[.,](\d{1,2}))?$').firstMatch(raw.trim());
  if (match == null) return null;
  final whole = int.tryParse(match.group(1)!);
  if (whole == null || whole > 10000000000) return null;
  final amount =
      whole * 100 + int.parse((match.group(2) ?? '').padRight(2, '0'));
  return amount <= 0 || amount > 1000000000000 ? null : amount;
}

Future<DateTime?> _chooseDate(BuildContext context, DateTime date,
    {DateTime? from}) {
  final first = DateUtils.dateOnly(from ?? DateTime(1900));
  final today = DateUtils.dateOnly(DateTime.now());
  final last = date.isAfter(today) ? date : today;
  return showDatePicker(
      context: context,
      firstDate: first,
      lastDate: last,
      initialDate: date.isBefore(first) ? first : date);
}

class CoffeeProcessingScreen extends StatefulWidget {
  const CoffeeProcessingScreen(
      {super.key, this.initialProperty, this.initialPlot, this.initialYear});

  final Json? initialProperty, initialPlot;
  final int? initialYear;

  @override
  State<CoffeeProcessingScreen> createState() => _CoffeeProcessingScreenState();
}

typedef _Catalog = ({List<Json> farms, List<Json> plots});

class _CoffeeProcessingScreenState extends State<CoffeeProcessingScreen>
    with _ProcessingSession<CoffeeProcessingScreen> {
  final _repository = CoffeeProcessingRepository();
  late String? _farmId = widget.initialProperty?['id'] as String?;
  late int _year = widget.initialYear ?? DateTime.now().year;
  late final _yearField = TextEditingController(text: '$_year');
  late Future<_Catalog> _catalog = _loadCatalog();
  Future<List<CoffeeLot>>? _lots;
  String? _yearError;
  bool _wasSyncing = false;

  @override
  void initState() {
    super.initState();
    _loadLots();
    if (_connectedProcessing) {
      _wasSyncing = SyncService().state == SyncState.syncing;
      SyncService().addListener(_onSync);
    }
  }

  void _onSync() {
    final syncing = SyncService().state == SyncState.syncing;
    final completed = _wasSyncing && !syncing;
    _wasSyncing = syncing;
    if (completed && mounted && _allowed) {
      setState(() {
        _catalog = _loadCatalog();
        _loadLots();
      });
    }
  }

  @override
  void dispose() {
    if (_connectedProcessing) SyncService().removeListener(_onSync);
    _yearField.dispose();
    super.dispose();
  }

  Future<_Catalog> _loadCatalog() async {
    FarmAccessPolicy.requireCoffeeHarvest();
    final catalog = await CatalogStore.open();
    return (
      farms: await catalog.records('properties'),
      plots: await catalog.records('plots')
    );
  }

  void _loadLots() {
    final propertyId = _farmId;
    _lots = propertyId == null
        ? null
        : (_repository.list(propertyId: propertyId, seasonYear: _year)
          ..ignore());
  }

  void _changeYear() {
    final year = int.tryParse(_yearField.text.trim());
    if (year == null || year < 1900 || year > 9999) {
      setState(() => _yearError = 'Informe o ano da safra com quatro dígitos.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _year = year;
      _yearError = null;
      _loadLots();
    });
  }

  Future<void> _create(Json farm, List<Json> plots) async {
    if (!_allowed) return;
    final preselected = plots
        .where((item) => item['id'] == widget.initialPlot?['id'])
        .firstOrNull;
    final result = await Navigator.push<CoffeeLot>(
        context,
        MaterialPageRoute(
            builder: (_) => _LotEditor(
                  repository: _repository,
                  farm: farm,
                  plots: plots,
                  year: _year,
                  initialPlot: preselected,
                )));
    if (!mounted || !_allowed || result == null) return;
    setState(_loadLots);
    await _open(result, farm, plots);
  }

  Future<void> _open(CoffeeLot lot, Json farm, List<Json> plots) async {
    if (!_allowed) return;
    await Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (_) => _LotScreen(
                  repository: _repository,
                  initialLot: lot,
                  farm: farm,
                  plots: plots,
                )));
    if (mounted && _allowed) setState(_loadLots);
  }

  void _compareYields(List<CoffeeLot> lots, List<Json> plots) {
    if (!_allowed) return;
    final totals = compareCoffeeYields(lots);
    Navigator.of(context).push<void>(MaterialPageRoute(
        builder: (context) => Scaffold(
              appBar: AppBar(title: const Text('Rendimento por origem')),
              body: ListenableBuilder(
                  listenable: AuthService(),
                  builder: (context, _) => !_allowed
                      ? _unavailable()
                      : SafeArea(
                          child: _ProcessingPage(children: [
                          Text('Safra $_year'),
                          const Text(
                              'O rendimento usa o volume e o peso das limpas com as duas medidas registradas. Café maduro, seco e lavado são apresentados separadamente.'),
                          if (totals.isEmpty)
                            const Text(
                                'Nenhuma limpa tem volume, base e peso suficientes.'),
                          for (final entry in totals.entries)
                            Card(
                                child: ListTile(
                              title: Text(entry.key.$1 == null
                                  ? (entry.key.$2
                                      ? 'Lotes mistos'
                                      : 'Origem não confirmada')
                                  : '${plots.where((plot) => plot['id'] == entry.key.$1).firstOrNull?['name'] ?? 'Talhão indisponível'}'),
                              subtitle: Text(
                                  '${_baseNames[entry.key.$3]} · ${entry.value.count} limpa(s)\n'
                                  '${_ratio.format(entry.value.liters / (entry.value.outputKg / 60))} L por saca de 60 kg\n'
                                  '${_liters(entry.value.liters)} de entrada · ${_kg(entry.value.outputKg)} beneficiados'),
                            )),
                        ]))),
            )));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Beneficiamento')),
        body: !_allowed
            ? _unavailable()
            : SafeArea(
                child: FutureBuilder<_Catalog>(
                future: _catalog,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(
                        child: TextButton(
                      onPressed: () => setState(() {
                        _catalog = _loadCatalog();
                      }),
                      child: const Text(
                          'Não foi possível abrir as fazendas. Tentar novamente'),
                    ));
                  }
                  final catalog = snapshot.data;
                  if (catalog == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final farm = catalog.farms
                      .where((item) => item['id'] == _farmId)
                      .firstOrNull;
                  final plots = catalog.plots
                      .where((item) => item['property_id'] == _farmId)
                      .toList();
                  return _ProcessingPage(children: [
                    if (_connectedProcessing) const _ProcessingSyncActions(),
                    if (catalog.farms.isEmpty)
                      const Text(
                          'Cadastre uma fazenda em Propriedades para registrar lotes.')
                    else ...[
                      DropdownButtonFormField<String>(
                        decoration: const InputDecoration(labelText: 'Fazenda'),
                        initialValue: farm?['id'] as String?,
                        isExpanded: true,
                        items: [
                          for (final item in catalog.farms)
                            DropdownMenuItem(
                                value: item['id'] as String,
                                child: Text(_name(item),
                                    overflow: TextOverflow.ellipsis))
                        ],
                        onChanged: (value) => setState(() {
                          _farmId = value;
                          _loadLots();
                        }),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _yearField,
                        decoration: InputDecoration(
                            labelText: 'Ano da safra', errorText: _yearError),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                          LengthLimitingTextInputFormatter(4)
                        ],
                        onSubmitted: (_) => _changeYear(),
                      ),
                      Wrap(spacing: 8, runSpacing: 4, children: [
                        TextButton(
                            onPressed: _changeYear,
                            child: const Text('Ver safra')),
                        if (farm != null &&
                            farm['archived'] != 1 &&
                            (!_connectedProcessing ||
                                farm['_sync_state'] == 'synced'))
                          FilledButton.icon(
                              onPressed: () => _create(farm, plots),
                              icon: const Icon(Icons.add),
                              label: const Text('Novo lote')),
                      ]),
                      const SizedBox(height: 12),
                      if (farm == null)
                        const Text(
                            'Selecione a fazenda para consultar os lotes.')
                      else
                        FutureBuilder<List<CoffeeLot>>(
                          future: _lots,
                          builder: (context, snapshot) {
                            if (snapshot.connectionState ==
                                ConnectionState.waiting) {
                              return const LinearProgressIndicator();
                            }
                            if (snapshot.hasError) {
                              return TextButton(
                                  onPressed: () => setState(_loadLots),
                                  child: const Text(
                                      'Não foi possível carregar os lotes. Tentar novamente'));
                            }
                            final lots = snapshot.data ?? [];
                            if (lots.isEmpty) {
                              return Text(
                                  'Nenhum lote nesta fazenda e safra $_year.');
                            }
                            return Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Align(
                                    alignment: AlignmentDirectional.centerStart,
                                    child: OutlinedButton.icon(
                                      onPressed: () =>
                                          _compareYields(lots, plots),
                                      icon: const Icon(Icons.bar_chart),
                                      label: const Text(
                                          'Comparar rendimento por origem'),
                                    ),
                                  ),
                                  for (final lot in lots)
                                    Card(
                                        child: ListTile(
                                      title: Text(lot.code),
                                      subtitle: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                                '${_date.format(lot.date)} · Saldo ${_kg(lot.stockKg)}${lot.location.isEmpty ? '' : '\n${lot.location}'}'),
                                            if (_connectedProcessing)
                                              SyncStatusLabel(
                                                  module: _processingModule,
                                                  recordId: lot.id),
                                          ]),
                                      trailing: const Icon(Icons.chevron_right),
                                      onTap: () => _open(lot, farm, plots),
                                    )),
                                ]);
                          },
                        ),
                    ],
                  ]);
                },
              )),
      );
}

class _ProcessingPage extends StatelessWidget {
  const _ProcessingPage({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
          child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: ListView(
            padding: AppTheme.pagePadding(context), children: children),
      ));
}

class _LotScreen extends StatefulWidget {
  const _LotScreen(
      {required this.repository,
      required this.initialLot,
      required this.farm,
      required this.plots});

  final CoffeeProcessingRepository repository;
  final CoffeeLot initialLot;
  final Json farm;
  final List<Json> plots;

  @override
  State<_LotScreen> createState() => _LotScreenState();
}

class _LotScreenState extends State<_LotScreen>
    with _ProcessingSession<_LotScreen> {
  late CoffeeLot _lot = widget.initialLot;
  final _finance = CoffeeFinanceRepository();
  Future<_ConnectedSales>? _sales;
  bool _busy = false;
  bool get _active => widget.farm['archived'] != 1 && _allowed;
  bool _wasSyncing = false;

  @override
  void initState() {
    super.initState();
    if (_connectedProcessing) {
      _refreshSales();
      _wasSyncing = SyncService().state == SyncState.syncing;
      SyncService().addListener(_onSync);
    }
  }

  @override
  void dispose() {
    if (_connectedProcessing) SyncService().removeListener(_onSync);
    super.dispose();
  }

  Future<void> _onSync() async {
    final syncing = SyncService().state == SyncState.syncing;
    final completed = _wasSyncing && !syncing;
    _wasSyncing = syncing;
    if (!completed || !mounted || !_allowed) return;
    try {
      final lot = await widget.repository
          .getLot(propertyId: _lot.propertyId, lotId: _lot.id);
      if (mounted && _allowed) {
        setState(() {
          _lot = lot;
          _refreshSales();
        });
      }
    } on Exception {
      // A consulta volta a ser feita ao abrir o lote pela lista.
    }
  }

  void _refreshSales() {
    if (!_connectedProcessing) return;
    _sales = _loadSales()..ignore();
  }

  Future<_ConnectedSales> _loadSales() async {
    final propertyId = _lot.propertyId;
    final lotId = _lot.id;
    final sales = await _finance.connectedSalesForLot(
        propertyId: propertyId, lotId: lotId);
    final pending = await _finance.pendingConnectedSaleIds(
        propertyId: propertyId, lotId: lotId);
    final rejected = await _finance.rejectedConnectedSalePayments(
        propertyId: propertyId, lotId: lotId);
    return (sales: sales, pending: pending, rejected: rejected);
  }

  Future<void> _discardRejectedPayment(CoffeeSaleReceipt payment) async {
    if (_busy || !_allowed) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Descartar pagamento recusado?'),
        content: Text(
            'O lançamento de ${_money(payment.amountCents)} foi recusado pelo PC gestor. Você poderá registrar outro valor após descartá-lo.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Voltar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Descartar'),
          ),
        ],
      ),
    );
    if (!mounted || !_allowed || confirmed != true || _busy) return;
    setState(() => _busy = true);
    try {
      await SyncService().discardRejectedSalePayment(payment.id);
    } on Exception catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _refreshSales();
        });
      }
    }
  }

  Future<void> _receive(CoffeeFinanceSale sale) async {
    if (_busy || !_active) return;
    setState(() => _busy = true);
    try {
      await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _SaleReceiptDialog(finance: _finance, sale: sale));
      if (mounted) setState(_refreshSales);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _plotName(String? id) => id == null
      ? null
      : widget.plots.where((plot) => plot['id'] == id).firstOrNull?['name']
          as String?;

  Future<void> _edit() async {
    final result = await Navigator.push<CoffeeLot>(
        context,
        MaterialPageRoute(
            builder: (_) => _LotEditor(
                  repository: widget.repository,
                  farm: widget.farm,
                  plots: widget.plots,
                  year: _lot.seasonYear,
                  existing: _lot,
                )));
    if (mounted && result != null) setState(() => _lot = result);
  }

  Future<void> _record(_MovementKind kind) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final updated = await showDialog<CoffeeLot>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _MovementDialog(
            repository: widget.repository, lot: _lot, kind: kind),
      );
      if (mounted && updated != null) {
        setState(() {
          _lot = updated;
          _refreshSales();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _historyCard(String title, List<String> lines) => Card(
          child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          for (final line in lines)
            if (line.isNotEmpty) Text(line),
        ]),
      ));

  @override
  Widget build(BuildContext context) {
    if (!_allowed) {
      return Scaffold(
          appBar: AppBar(title: const Text('Beneficiamento')),
          body: _unavailable());
    }
    final titles = Theme.of(context).textTheme.titleMedium;
    final receipts = _lot.measurements
        .where((item) =>
            item.stage == CoffeeProcessingStage.reception &&
            item.volumeLiters != null)
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    final latestReceipt = receipts.firstOrNull;
    return Scaffold(
      appBar: AppBar(title: Text('Lote ${_lot.code}')),
      body: SafeArea(
          child: _ProcessingPage(children: [
        Text('${widget.farm['name']} · Safra ${_lot.seasonYear}',
            style: Theme.of(context).textTheme.headlineSmall),
        Text('Abertura: ${_date.format(_lot.date)}'),
        if (_connectedProcessing) ...[
          SyncStatusLabel(module: _processingModule, recordId: _lot.id),
          const _ProcessingSyncActions(),
        ],
        if (_lot.location.isNotEmpty) Text('Local: ${_lot.location}'),
        if (_lot.notes.isNotEmpty) Text(_lot.notes),
        const SizedBox(height: 12),
        if (_connectedProcessing)
          Text(
              'Volume vinculado aos recebimentos: ${_liters(_lot.inputs.fold(0.0, (sum, input) => sum + (input.linkedLiters ?? 0)))}')
        else if (latestReceipt != null)
          Text(
              'Último recebimento: ${_liters(latestReceipt.volumeLiters!)} · ${_date.format(latestReceipt.date)}')
        else
          const Text('Recebimento: sem medição em litros'),
        Text('Beneficiado: ${_kg(_lot.producedKg)}'),
        if (_connectedProcessing)
          Text(
              '${_decimal.format(_lot.producedKg / 60)} sacas equivalentes de 60 kg'),
        ...[
          Text('Vendido: ${_kg(_lot.soldKg)}'),
          Text('Saldo: ${_kg(_lot.stockKg)}', style: titles),
        ],
        const SizedBox(height: 8),
        if (_active)
          Wrap(spacing: 8, runSpacing: 4, children: [
            TextButton(
                onPressed: _busy ? null : _edit,
                child: const Text('Editar lote')),
            if (!_connectedProcessing)
              OutlinedButton(
                  onPressed:
                      _busy ? null : () => _record(_MovementKind.measurement),
                  child: const Text('Registrar medição')),
            OutlinedButton(
                onPressed: _busy ? null : () => _record(_MovementKind.cleaning),
                child: const Text('Registrar limpa')),
            if (_connectedProcessing)
              _WhenLotSynced(
                  lot: _lot,
                  builder: (synced) => FilledButton(
                        onPressed: !synced || _busy || _lot.stockKg <= 0
                            ? null
                            : () => _record(_MovementKind.sale),
                        child: const Text('Registrar venda'),
                      ))
            else
              FilledButton(
                  onPressed: _busy || _lot.stockKg <= 0
                      ? null
                      : () => _record(_MovementKind.sale),
                  child: const Text('Registrar venda')),
          ]),
        const Divider(height: 30),
        Text('Entradas do lote', style: titles),
        for (final input in _lot.inputs)
          _historyCard(
              '${_sourceNames[input.kind]} · Origem ${_originNames[input.origin]!.toLowerCase()}',
              [
                input.volumeLiters == null
                    ? 'Volume não informado'
                    : _liters(input.volumeLiters!),
                if (_plotName(input.plotId) case final String plot) plot,
                if (input.harvestDate case final DateTime date)
                  '${input.receiptId == null ? 'Colheita' : 'Recebimento da colheita'} de ${_date.format(date)}',
                if (input.linkedLiters case final double volume)
                  'Volume vinculado: ${_liters(volume)}',
                input.notes,
              ]),
        if (!_connectedProcessing) ...[
          const Divider(height: 30),
          Text('Medições por etapa', style: titles),
          if (_lot.measurements.isEmpty)
            const Text('Nenhuma medição registrada.'),
          for (final item
              in _mostRecent(_lot.measurements, (item) => item.date))
            _historyCard(
                '${_stageNames[item.stage]} · ${_date.format(item.date)}', [
              item.volumeLiters == null
                  ? 'Volume não informado'
                  : _liters(item.volumeLiters!),
              item.location,
              item.state,
              item.notes,
            ]),
        ],
        const Divider(height: 30),
        Text('Limpas', style: titles),
        if (_lot.cleanings.isEmpty) const Text('Nenhuma limpa registrada.'),
        for (final item in _mostRecent(_lot.cleanings, (item) => item.date))
          _historyCard(
              '${_date.format(item.date)} · ${_kg(item.outputKg)} beneficiados',
              [
                if (item.unit == CoffeeProcessedUnit.bags)
                  '${_decimal.format(item.quantity)} sacos de ${_kg(item.kgPerBag!)}${(item.remainderKg ?? 0) > 0 ? ' + ${_kg(item.remainderKg!)} de sobra' : ''}',
                if (item.inputLiters case final double volume)
                  'Entrada usada: ${_liters(volume)}${item.inputBase == null ? '' : ' · ${_baseNames[item.inputBase]}'}',
                if (item.inputLiters == null && item.inputBase != null)
                  'Base da entrada: ${_baseNames[item.inputBase]} · volume não informado',
                if (item.yieldKgPerLiter case final double rate) ...[
                  'Rendimento desta limpa: ${_ratio.format(rate)} kg/L de ${_baseNames[item.inputBase]!.toLowerCase()}',
                  '${_ratio.format(item.litersPerSack60!)} L de ${_baseNames[item.inputBase]!.toLowerCase()} por saca de 60 kg',
                  if (item.kgPerBag case final double reference
                      when reference != 60)
                    '${_ratio.format(item.inputLiters! / (item.outputKg / reference))} L de ${_baseNames[item.inputBase]!.toLowerCase()} por saco de ${_kg(reference)}',
                ],
                item.notes,
              ]),
        if (!_connectedProcessing) ...[
          const Divider(height: 30),
          Text('Vendas', style: titles),
          if (_lot.sales.isEmpty) const Text('Nenhuma venda registrada.'),
          for (final item in _mostRecent(_lot.sales, (item) => item.date))
            _historyCard(
                '${_date.format(item.date)} · ${_kg(item.outputKg)} · ${_money(item.totalPriceCents)}',
                [
                  if (item.unit == CoffeeProcessedUnit.bags)
                    '${_decimal.format(item.quantity)} sacos de ${_kg(item.kgPerBag!)}${(item.remainderKg ?? 0) > 0 ? ' + ${_kg(item.remainderKg!)} de sobra' : ''}',
                  item.buyer,
                  item.notes,
                ]),
        ] else ...[
          const Divider(height: 30),
          Text('Vendas', style: titles),
          TextButton.icon(
              onPressed: _busy ? null : () => setState(_refreshSales),
              icon: const Icon(Icons.refresh),
              label: const Text('Atualizar vendas e pagamentos')),
          _ConnectedSaleHistory(
              lot: _lot,
              future: _sales,
              canWrite: _active && !_busy,
              onReceive: _receive,
              onDiscardRejected: _discardRejectedPayment),
        ],
      ])),
    );
  }
}
