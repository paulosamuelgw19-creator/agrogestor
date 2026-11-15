import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:uuid/uuid.dart';

import '../../app/app_theme.dart';
import '../auth/auth_service.dart';
import '../auth/farm_access_policy.dart';
import '../licensing/write_gate.dart';
import '../operations_v2/v2_store.dart' show Json;
import '../operators/operator.dart';
import '../operators/operator_repository.dart';
import '../processing/coffee_processing_screen.dart';
import '../processing/coffee_processing_repository.dart';
import '../properties/catalog_store.dart';
import '../properties/coffee_planting.dart';
import '../sync/farm_api_client.dart';
import '../sync/sync_notice.dart';
import '../sync/sync_service.dart';
import '../sync/sync_settings_screen.dart';
import '../sync/sync_status_label.dart';
import 'coffee_harvest_repository.dart';
import 'coffee_receipt_repository.dart';
import 'coffee_season_check_card.dart';

part 'coffee_production_form.dart';
part 'coffee_harvest_overview.dart';
part 'coffee_receipt_form.dart';

typedef _HarvestData = ({
  CoffeeHarvestSummary summary,
  CoffeePlotProductionSummary production,
  bool catalogWritable,
  List<CoffeeHarvestReceipt> receipts,
  bool receiptReadError,
});

const _unitLabels = {
  CoffeeHarvestUnit.measures: 'Medidas',
  CoffeeHarvestUnit.liters: 'Litros',
  CoffeeHarvestUnit.carts: 'Carretas',
};

final _decimal = NumberFormat('#,##0.###', 'pt_BR');
final _currency = NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$');
final _date = DateFormat('dd/MM/yyyy');
const _connectedHarvest = !FarmApiClient.standaloneLocalMode;

class _HarvestSyncActions extends StatelessWidget {
  const _HarvestSyncActions();

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: SyncService(),
        builder: (context, _) {
          final sync = SyncService();
          final running = sync.state == SyncState.syncing;
          return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SyncNotice(state: sync.state, message: sync.message),
                Wrap(spacing: 8, runSpacing: 4, children: [
                  OutlinedButton.icon(
                      onPressed: running ? null : sync.syncNow,
                      icon: const Icon(Icons.sync),
                      label: Text(
                          running ? 'Sincronizando' : 'Sincronizar agora')),
                  TextButton(
                      onPressed: () => Navigator.push<void>(
                          context,
                          MaterialPageRoute(
                              builder: (_) => Scaffold(
                                  appBar: AppBar(
                                      title: const Text('Sincronização')),
                                  body: const SafeArea(
                                      child: SyncSettingsScreen())))),
                      child: const Text('Ver fila e conflitos')),
                ]),
                if (running) const LinearProgressIndicator(),
              ]);
        },
      );
}

mixin _HarvestSyncRefresh<T extends StatefulWidget> on State<T> {
  late final (String?, String?) _session;
  bool _wasSyncing = false;

  (String?, String?) get _currentSession =>
      (AuthService().currentUser?.id, AuthService().currentUser?.farmId);
  bool get _allowed =>
      FarmAccessPolicy.canUseCoffeeHarvest && _session == _currentSession;

  void refreshHarvest();

  @override
  void initState() {
    super.initState();
    _session = _currentSession;
    if (_connectedHarvest) {
      AuthService().addListener(_sessionChanged);
      _wasSyncing = SyncService().state == SyncState.syncing;
      SyncService().addListener(_syncChanged);
    }
  }

  @override
  void dispose() {
    if (_connectedHarvest) {
      AuthService().removeListener(_sessionChanged);
      SyncService().removeListener(_syncChanged);
    }
    super.dispose();
  }

  void _sessionChanged() => setState(() {});

  void _syncChanged() {
    final running = SyncService().state == SyncState.syncing;
    final completed = _wasSyncing && !running;
    _wasSyncing = running;
    if (!mounted || !completed) return;
    if (_allowed) {
      refreshHarvest();
    } else {
      _sessionChanged();
    }
  }
}

const _requireHarvestSession = Padding(
  padding: EdgeInsets.all(16),
  child: AppNotice(
      message:
          'Entre com uma sessão válida de gestor para consultar a colheita.'),
);

String _money(int? cents) =>
    cents == null ? 'Pendente' : _currency.format(cents / 100);
String _liters(double liters) => '${_decimal.format(liters)} L';
String _quantity(CoffeeHarvestEntry entry) =>
    '${_decimal.format(entry.quantity)} ${_unitLabels[entry.unit]!.toLowerCase()}';
String _paymentKind(CoffeeHarvestPaymentKind kind) =>
    kind == CoffeeHarvestPaymentKind.advance ? 'Vale' : 'Pagamento';

double? _number(String? value) {
  final text = value?.trim() ?? '';
  if (!RegExp(r'^\d+(?:[.,]\d+)?$').hasMatch(text)) return null;
  final number = double.tryParse(text.replaceAll(',', '.'));
  return number != null && number.isFinite ? number : null;
}

int? _cents(String? value) {
  final match =
      RegExp(r'^(\d+)(?:[.,](\d{1,2}))?$').firstMatch(value?.trim() ?? '');
  if (match == null) return null;
  final whole = int.tryParse(match.group(1)!);
  if (whole == null || whole > 10000000000) return null;
  return whole * 100 + int.parse((match.group(2) ?? '').padRight(2, '0'));
}

class CoffeeHarvestCatalogScreen extends StatefulWidget {
  const CoffeeHarvestCatalogScreen({super.key});

  @override
  State<CoffeeHarvestCatalogScreen> createState() =>
      _CoffeeHarvestCatalogScreenState();
}

class _CoffeeHarvestCatalogScreenState extends State<CoffeeHarvestCatalogScreen>
    with _HarvestSyncRefresh {
  late Future<({List<Json> farms, List<Json> plots})> _catalog = _loadCatalog();
  String? _farmId, _plotId;

  Future<({List<Json> farms, List<Json> plots})> _loadCatalog() async {
    FarmAccessPolicy.requireCoffeeHarvest();
    final catalog = await CatalogStore.open();
    return (
      farms: await catalog.records('properties'),
      plots: await catalog.records('plots')
    );
  }

  String _name(Json record) =>
      '${record['name']}${record['archived'] == 1 ? ' · Arquivado' : ''}';

  @override
  void refreshHarvest() => setState(() {
        _catalog = _loadCatalog();
      });

  @override
  Widget build(BuildContext context) => !_allowed
      ? _requireHarvestSession
      : FutureBuilder(
          future: _catalog,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                  child: TextButton(
                onPressed: () => setState(() {
                  _catalog = _loadCatalog();
                }),
                child: const Text(
                    'Não foi possível abrir a colheita. Tentar novamente'),
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
            final plot =
                plots.where((item) => item['id'] == _plotId).firstOrNull;
            return Center(
                child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 700),
              child: ListView(
                padding: AppTheme.pagePadding(context),
                children: [
                  if (_connectedHarvest) const _HarvestSyncActions(),
                  Text('Selecione a fazenda e o talhão',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  if (catalog.farms.isNotEmpty)
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: FilledButton.icon(
                        onPressed: () => Navigator.of(context).push<void>(
                          MaterialPageRoute(
                              builder: (_) => _HarvestOverview(
                                  farms: catalog.farms, plots: catalog.plots)),
                        ),
                        icon: const Icon(Icons.summarize_outlined),
                        label: const Text('Resumo da safra'),
                      ),
                    ),
                  if (catalog.farms.isEmpty)
                    const Text(
                        'Cadastre uma fazenda e um talhão em Propriedades para registrar a colheita.')
                  else ...[
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Fazenda'),
                      initialValue: farm?['id'] as String?,
                      items: [
                        for (final item in catalog.farms)
                          DropdownMenuItem(
                              value: item['id'] as String,
                              child: Text(_name(item),
                                  style: AppTheme.nameStyle(context),
                                  overflow: TextOverflow.ellipsis))
                      ],
                      onChanged: (value) => setState(() {
                        _farmId = value;
                        _plotId = null;
                      }),
                    ),
                    const SizedBox(height: 12),
                    if (farm != null && plots.isEmpty)
                      const Text('Esta fazenda ainda não tem talhões.')
                    else if (farm != null)
                      DropdownButtonFormField<String>(
                        key: ValueKey(_farmId),
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Talhão'),
                        initialValue: plot?['id'] as String?,
                        items: [
                          for (final item in plots)
                            DropdownMenuItem(
                                value: item['id'] as String,
                                child: Text(_name(item),
                                    style: AppTheme.nameStyle(context),
                                    overflow: TextOverflow.ellipsis))
                        ],
                        onChanged: (value) => setState(() => _plotId = value),
                      ),
                    const SizedBox(height: 12),
                    Wrap(spacing: 8, runSpacing: 4, children: [
                      FilledButton(
                        onPressed: farm == null || plot == null
                            ? null
                            : () => Navigator.push<void>(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => CoffeeHarvestScreen(
                                        property: farm, plot: plot))),
                        child: const Text('Abrir colheita'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                                builder: (_) => CoffeeProcessingScreen(
                                    initialProperty: farm, initialPlot: plot))),
                        icon: const Icon(Icons.inventory_2_outlined),
                        label: const Text('Beneficiamento'),
                      ),
                    ]),
                  ],
                ],
              ),
            ));
          },
        );
}

class CoffeeHarvestScreen extends StatefulWidget {
  const CoffeeHarvestScreen(
      {super.key,
      required this.property,
      required this.plot,
      this.initialYear});

  final Map<String, dynamic> property, plot;
  final int? initialYear;

  @override
  State<CoffeeHarvestScreen> createState() => _CoffeeHarvestScreenState();
}

class _CoffeeHarvestScreenState extends State<CoffeeHarvestScreen>
    with _HarvestSyncRefresh {
  final _repository = CoffeeHarvestRepository();
  final _receipts = CoffeeReceiptRepository();
  late int _year = widget.initialYear ?? DateTime.now().year;
  late final _yearField = TextEditingController(text: '$_year');
  late Future<_HarvestData> _summary = _load();
  bool _busy = false;
  String? _yearError;

  String get _propertyId => widget.property['id'] as String;
  String get _propertyName => '${widget.property['name']}';
  String get _plotId => widget.plot['id'] as String;
  String get _plotName => '${widget.plot['name']}';
  bool get _activePlot =>
      widget.property['archived'] != 1 && widget.plot['archived'] != 1;

  Future<_HarvestData> _load() async {
    final year = _year;
    final summary = _connectedHarvest
        ? CoffeeHarvestSummary(
            await _repository.entries(
                propertyId: _propertyId, seasonYear: year, plotId: _plotId),
            [],
          )
        : await _repository.summary(propertyId: _propertyId, seasonYear: year);
    final production = await _repository.production(
        propertyId: _propertyId, plotId: _plotId, seasonYear: year);
    var catalogWritable = _activePlot;
    var receipts = <CoffeeHarvestReceipt>[];
    var receiptReadError = false;
    if (_connectedHarvest) {
      final catalog = await CatalogStore.open();
      final properties = await catalog.records('properties', archived: false);
      final plots = await catalog.records('plots', archived: false);
      catalogWritable = properties.any((item) =>
              item['id'] == _propertyId && item['_sync_state'] == 'synced') &&
          plots.any((item) =>
              item['id'] == _plotId &&
              item['property_id'] == _propertyId &&
              item['_sync_state'] == 'synced');
      try {
        receipts = await _receipts.list(
            propertyId: _propertyId, plotId: _plotId, seasonYear: year);
      } on Exception {
        receiptReadError = true;
      }
    }
    return (
      summary: summary,
      production: production,
      catalogWritable: catalogWritable,
      receipts: receipts,
      receiptReadError: receiptReadError,
    );
  }

  Future<void> _registerReceipt(DateTime day, double? currentLiters,
      {CoffeeHarvestReceipt? existing}) async {
    if (_busy || !_allowed) return;
    final year = _year;
    setState(() => _busy = true);
    try {
      final saved = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _CoffeeReceiptForm(
                repository: _receipts,
                propertyId: _propertyId,
                plotId: _plotId,
                location: '$_propertyName · $_plotName',
                seasonYear: year,
                day: day,
                currentLiters: currentLiters,
                existing: existing,
              ));
      if (mounted && _allowed && saved == true) _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _declareProduction(CoffeePlotProductionSummary summary,
      {CoffeePlotProduction? existing}) async {
    if (_busy) return;
    final result = await showDialog<CoffeePlotProduction>(
      context: context,
      builder: (_) => _ProductionDialog(
        propertyId: _propertyId,
        plotId: _plotId,
        location: '$_propertyName · $_plotName',
        seasonYear: _year,
        declarations: [
          for (final day in summary.days)
            if (day.declared case final CoffeePlotProduction item) item
        ],
        existing: existing,
      ),
    );
    if (!mounted || !_allowed || result == null || _busy) return;
    setState(() => _busy = true);
    try {
      final saved = await runLicensedWrite(
          context, () => _repository.saveProduction(result));
      if (saved && mounted) {
        setState(() {
          _summary = _load();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reviewProduction(CoffeePlotProductionDay day) async {
    final declared = day.declared!;
    final workerLiters = day.workerLiters!;
    final choice = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Conferir produção'),
        content: Text(
          'Total informado: ${_liters(declared.volumeLiters)}\n'
          'Soma por pessoa: ${_liters(workerLiters)}\n\n'
          'Qual valor deve entrar no total do dia?',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Usar soma por pessoa')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Manter total informado')),
        ],
      ),
    );
    if (!mounted || !_allowed || choice == null || _busy) return;
    setState(() => _busy = true);
    try {
      final saved = await runLicensedWrite(context,
          () => _repository.reviewProduction(day, keepDeclared: choice));
      if (saved && mounted) _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _yearField.dispose();
    super.dispose();
  }

  void _applyYear() {
    final year = int.tryParse(_yearField.text.trim());
    if (year == null || year < 1900 || year > 9999) {
      setState(() => _yearError = 'Informe o ano da safra com quatro dígitos.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _year = year;
      _yearError = null;
      _summary = _load();
    });
  }

  Future<void> _register(
      {CoffeeHarvestSummary? summary,
      String? workerId,
      bool payment = false}) async {
    if (_busy) return;
    final year = _year;
    setState(() => _busy = true);
    try {
      final operators = await OperatorRepository().getAll();
      if (!mounted || !_allowed) return;
      final workers = operators
          .where((worker) => worker.active || worker.id == workerId)
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      if (workers.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Cadastre uma pessoa ativa em Funcionários para registrar a colheita.')));
        return;
      }
      final last = summary?.entries.firstOrNull;
      final result = await showDialog<Object>(
        context: context,
        builder: (_) => _HarvestEntryDialog(
          propertyId: _propertyId,
          plotId: _plotId,
          location: payment ? _propertyName : '$_propertyName · $_plotName',
          seasonYear: year,
          workers: workers,
          workerId: workerId,
          payment: payment,
          litersPerMeasure: last?.litersPerMeasure ?? 60,
        ),
      );
      if (!mounted || !_allowed || result == null) return;
      final saved = await runLicensedWrite(
          context,
          () => switch (result) {
                final CoffeeHarvestEntry entry => _repository.saveEntry(entry),
                final CoffeeHarvestPayment payment =>
                  _repository.savePayment(payment),
                _ => throw StateError('Lançamento inválido'),
              });
      if (saved && mounted) _refresh();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Não foi possível registrar a colheita. Tente novamente.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showWorker(String workerId, String name) async {
    await Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (_) => _WorkerHarvestScreen(
                  repository: _repository,
                  propertyId: _propertyId,
                  propertyName: _propertyName,
                  workerId: workerId,
                  workerName: name,
                  seasonYear: _year,
                )));
  }

  void _refresh() => setState(() {
        _summary = _load();
      });

  @override
  void refreshHarvest() => _refresh();

  Future<void> _editRate(CoffeeHarvestEntry entry) async {
    final key = GlobalKey<FormState>();
    final rate = entry.ratePerMeasureCents;
    var value = rate == null
        ? ''
        : (rate / 100).toStringAsFixed(2).replaceAll('.', ',');
    final result = await showDialog<({int? cents})>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Editar valor por medida'),
        content: Form(
          key: key,
          child: TextFormField(
            initialValue: value,
            decoration: const InputDecoration(
                labelText: 'Valor por medida (R\$, opcional)'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (text) => value = text,
            validator: (text) =>
                (text ?? '').trim().isEmpty || _cents(text) != null
                    ? null
                    : 'Informe um valor válido.',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar')),
          FilledButton(
            onPressed: () {
              if (key.currentState!.validate()) {
                Navigator.pop(context, (cents: _cents(value)));
              }
            },
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    if (!mounted || result == null || _busy) return;
    setState(() => _busy = true);
    try {
      final saved = await runLicensedWrite(
          context,
          () => _repository.setEntryRate(
                propertyId: _propertyId,
                plotId: _plotId,
                id: entry.id,
                ratePerMeasureCents: result.cents,
              ));
      if (saved && mounted) _refresh();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Colheita')),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: FutureBuilder<_HarvestData>(
                future: _summary,
                builder: (context, snapshot) {
                  if (!_allowed) return _requireHarvestSession;
                  final data =
                      snapshot.connectionState == ConnectionState.done &&
                              !snapshot.hasError
                          ? snapshot.data
                          : null;
                  final summary = data?.summary;
                  final production = data?.production;
                  final canRegister = data?.catalogWritable ?? false;
                  final receipts = <DateTime, List<CoffeeHarvestReceipt>>{};
                  for (final receipt
                      in data?.receipts ?? const <CoffeeHarvestReceipt>[]) {
                    (receipts[DateUtils.dateOnly(receipt.harvestDate)] ??= [])
                        .add(receipt);
                  }
                  final area = plotAreaHectares(widget.plot['area_ha']);
                  final plot = summary == null
                      ? null
                      : CoffeeHarvestSummary(
                          summary.entries
                              .where((entry) => entry.plotId == _plotId)
                              .toList(),
                          []);
                  final names = <String, String>{};
                  if (summary != null) {
                    for (final entry in summary.entries) {
                      names.putIfAbsent(entry.workerId, () => entry.workerName);
                    }
                    for (final payment in summary.payments) {
                      names.putIfAbsent(
                          payment.workerId, () => payment.workerName);
                    }
                  }
                  final people = names.entries.toList()
                    ..sort((a, b) => a.value.compareTo(b.value));
                  final titles = Theme.of(context).textTheme.titleMedium;
                  return ListView(
                    padding: AppTheme.pagePadding(context),
                    children: [
                      Text('$_propertyName · $_plotName',
                          style: AppTheme.nameStyle(context)
                              .copyWith(fontSize: 24)),
                      if (_connectedHarvest) const _HarvestSyncActions(),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.push<void>(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => CoffeeProcessingScreen(
                                      initialProperty: widget.property,
                                      initialPlot: widget.plot,
                                      initialYear: _year))),
                          icon: const Icon(Icons.inventory_2_outlined),
                          label: const Text('Beneficiamento'),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _yearField,
                        enabled: !_busy,
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
                              onPressed: _busy ? null : _applyYear,
                              child: const Text('Ver safra'))),
                      if (snapshot.hasError) ...[
                        Text(snapshot.error is FarmAccessDenied
                            ? '${snapshot.error}'
                            : 'Não foi possível carregar a colheita.'),
                        TextButton(
                            onPressed: _applyYear,
                            child: const Text('Tentar novamente')),
                      ] else if (plot == null ||
                          summary == null ||
                          production == null)
                        const LinearProgressIndicator()
                      else ...[
                        if (_connectedHarvest && !canRegister && _activePlot)
                          const AppNotice(
                              message:
                                  'Sincronize os cadastros da fazenda e do talhão para liberar os lançamentos.'),
                        if (canRegister)
                          Wrap(spacing: 8, runSpacing: 4, children: [
                            FilledButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _declareProduction(production),
                              icon: const Icon(Icons.scale_outlined),
                              label: const Text('Registrar produção do dia'),
                            ),
                            FilledButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _register(summary: summary),
                              icon: const Icon(Icons.add),
                              label: const Text('Registrar colheita'),
                            ),
                            if (!_connectedHarvest)
                              OutlinedButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => _register(payment: true),
                                icon: const Icon(Icons.payments_outlined),
                                label:
                                    const Text('Registrar vale ou pagamento'),
                              ),
                          ]),
                        const SizedBox(height: 16),
                        Text('Produção do talhão · Safra $_year',
                            style: titles),
                        if (production.days.isEmpty)
                          const Text(
                              'Nenhuma produção registrada neste talhão.')
                        else ...[
                          Text(
                              'Produção acumulada: ${_liters(production.totalLiters)}'),
                          if (area != null && area > 0)
                            Text(
                                'Produção por hectare: ${_liters(production.totalLiters / area)}/ha'),
                        ],
                        if (!_connectedHarvest)
                          CoffeeSeasonCheckCard(
                            propertyId: _propertyId,
                            plotId: _plotId,
                            seasonYear: _year,
                            registeredLiters: production.days.isEmpty
                                ? null
                                : production.totalLiters,
                            canEdit: canRegister,
                          ),
                        if (data?.receiptReadError == true)
                          const AppNotice(
                              message:
                                  'Não foi possível carregar os recebimentos. As informações de colheita continuam disponíveis.',
                              tone: AppNoticeTone.error),
                        if (production.days.isNotEmpty) ...[
                          const Text(
                              'O consolidado usa o total informado no dia. Quando ele falta, usa a soma por pessoa.'),
                          for (final day in production.days) ...[
                            _ProductionDayCard(
                              day: day,
                              onReview:
                                  !canRegister || _busy || !day.needsReview
                                      ? null
                                      : () => _reviewProduction(day),
                              onEdit:
                                  !canRegister || _busy || day.declared == null
                                      ? null
                                      : () => _declareProduction(production,
                                          existing: day.declared),
                            ),
                            if (_connectedHarvest &&
                                data?.receiptReadError == false)
                              _CoffeeReceiptDay(
                                receipts:
                                    receipts[DateUtils.dateOnly(day.date)] ??
                                        const [],
                                currentLiters: day.totalLiters,
                                onNew: canRegister && !_busy
                                    ? () => _registerReceipt(
                                        day.date, day.totalLiters)
                                    : null,
                                onRetry: canRegister && !_busy
                                    ? (receipt) => _registerReceipt(
                                        day.date, day.totalLiters,
                                        existing: receipt)
                                    : null,
                              ),
                          ],
                        ],
                        if (_connectedHarvest)
                          for (final day in receipts.entries.where((group) =>
                              !production.days.any((day) =>
                                  DateUtils.isSameDay(day.date, group.key))))
                            _CoffeeReceiptDay(
                                receipts: day.value, currentLiters: null),
                        const Divider(height: 32),
                        Text('Colheita por pessoa · Safra $_year',
                            style: titles),
                        if (plot.entries.isEmpty)
                          const Text(
                              'Nenhuma colheita registrada neste talhão.'),
                        if (plot.entries.isNotEmpty) ...[
                          Text(
                              'Acumulado do talhão: ${_liters(plot.totalLiters)}'),
                          for (final day in plot.litersByDay.entries) ...[
                            const SizedBox(height: 8),
                            Text(
                                '${_date.format(day.key)} · Total do dia: ${_liters(day.value)}',
                                style: titles),
                            for (final entry in plot.entries.where((entry) =>
                                DateUtils.isSameDay(entry.date, day.key)))
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 6),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(entry.workerName,
                                        style: AppTheme.nameStyle(context)),
                                    Text(
                                        '${_quantity(entry)} · ${_liters(entry.volumeLiters)}'),
                                    if (entry.unit !=
                                        CoffeeHarvestUnit.measures)
                                      Text(
                                          '${_decimal.format(entry.measureEquivalent)} medidas equivalentes'),
                                    if (!_connectedHarvest)
                                      Text(
                                          'Medida de ${_liters(entry.litersPerMeasure)} · ${_money(entry.earnedCents)}'),
                                    if (_connectedHarvest)
                                      SyncStatusLabel(
                                          module: 'coffeeHarvestEntries',
                                          recordId: entry.id),
                                    if (!_connectedHarvest && canRegister)
                                      TextButton(
                                        onPressed: _busy
                                            ? null
                                            : () => _editRate(entry),
                                        child: const Text(
                                            'Editar valor por medida'),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ],
                        if (!_connectedHarvest) ...[
                          const Divider(height: 32),
                          Text('Pessoas e pagamentos da fazenda · Safra $_year',
                              style: titles),
                          if (people.isEmpty)
                            const Text(
                                'Nenhum lançamento nesta fazenda e safra.')
                          else
                            for (final person in people)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(person.value,
                                    style: AppTheme.nameStyle(context)),
                                subtitle: Text(summary.litersByWorker
                                        .containsKey(person.key)
                                    ? 'Acumulado na fazenda: ${_liters(summary.litersByWorker[person.key]!)}'
                                    : 'Sem colheita registrada'),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () =>
                                    _showWorker(person.key, person.value),
                              ),
                        ],
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
}

class _HarvestEntryDialog extends StatefulWidget {
  const _HarvestEntryDialog(
      {required this.propertyId,
      required this.plotId,
      required this.location,
      required this.seasonYear,
      required this.workers,
      required this.workerId,
      required this.payment,
      required this.litersPerMeasure});

  final String propertyId, plotId, location;
  final int seasonYear;
  final List<Operator> workers;
  final String? workerId;
  final bool payment;
  final double litersPerMeasure;

  @override
  State<_HarvestEntryDialog> createState() => _HarvestEntryDialogState();
}

class _HarvestEntryDialogState extends State<_HarvestEntryDialog> {
  final _form = GlobalKey<FormState>();
  final _id = const Uuid().v4();
  late String? _worker =
      widget.workers.any((worker) => worker.id == widget.workerId)
          ? widget.workerId
          : null;
  final _quantityField = TextEditingController();
  final _cartField = TextEditingController();
  final _remainderField = TextEditingController();
  final _moneyField = TextEditingController();
  final _notes = TextEditingController();
  late final _measureField = TextEditingController(
      text: widget.litersPerMeasure.toString().replaceAll('.', ','));
  DateTime _day = DateUtils.dateOnly(DateTime.now());
  CoffeeHarvestUnit _unit = CoffeeHarvestUnit.measures;
  CoffeeHarvestPaymentKind _payment = CoffeeHarvestPaymentKind.advance;
  bool _submitted = false;

  @override
  void dispose() {
    _quantityField.dispose();
    _cartField.dispose();
    _remainderField.dispose();
    _moneyField.dispose();
    _notes.dispose();
    _measureField.dispose();
    super.dispose();
  }

  Future<void> _chooseDate() async {
    final date = await showDatePicker(
        context: context,
        firstDate: DateTime(1900),
        lastDate: DateTime.now(),
        initialDate: _day);
    if (mounted && date != null) setState(() => _day = date);
  }

  void _save() {
    if (_submitted || !_form.currentState!.validate()) return;
    _submitted = true;
    if (widget.payment) {
      Navigator.pop(
          context,
          CoffeeHarvestPayment(
            id: _id,
            propertyId: widget.propertyId,
            workerId: _worker!,
            date: _day,
            seasonYear: widget.seasonYear,
            kind: _payment,
            amountCents: _cents(_moneyField.text)!,
            notes: _notes.text.trim(),
          ));
    } else {
      final measure = _number(_measureField.text)!;
      final quantity = _number(_quantityField.text) ?? 0;
      final leftover = _number(_remainderField.text) ?? 0;
      Navigator.pop(
          context,
          CoffeeHarvestEntry(
            id: _id,
            propertyId: widget.propertyId,
            plotId: widget.plotId,
            workerId: _worker!,
            date: _day,
            seasonYear: widget.seasonYear,
            unit: _unit,
            quantity: _unit == CoffeeHarvestUnit.measures
                ? quantity + leftover / measure
                : quantity,
            litersPerMeasure: measure,
            cartCapacityLiters: _unit == CoffeeHarvestUnit.carts
                ? _number(_cartField.text)
                : null,
            ratePerMeasureCents: _cents(_moneyField.text),
          ));
    }
  }

  Widget _positive(TextEditingController controller, String label) =>
      TextFormField(
        controller: controller,
        decoration: InputDecoration(labelText: label),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        validator: (text) => (_number(text) ?? 0) > 0
            ? null
            : 'Informe um número maior que zero.',
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.payment
            ? 'Registrar vale ou pagamento'
            : 'Registrar colheita'),
        content: SizedBox(
          width: AppTheme.dialogWidth(context, maxWidth: 460),
          child: Form(
              key: _form,
              child: SingleChildScrollView(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('${widget.location} · Safra ${widget.seasonYear}'),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: _worker,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Pessoa'),
                    items: [
                      for (final worker in widget.workers)
                        DropdownMenuItem(
                            value: worker.id, child: Text(worker.name))
                    ],
                    onChanged: (value) => _worker = value,
                    validator: (value) =>
                        value == null ? 'Selecione uma pessoa.' : null,
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                      onPressed: _chooseDate,
                      icon: const Icon(Icons.calendar_today_outlined),
                      label: Text('Data: ${_date.format(_day)}')),
                  const SizedBox(height: 10),
                  if (widget.payment)
                    DropdownButtonFormField<CoffeeHarvestPaymentKind>(
                      initialValue: _payment,
                      isExpanded: true,
                      decoration: const InputDecoration(
                          labelText: 'Tipo de lançamento'),
                      items: [
                        for (final kind in CoffeeHarvestPaymentKind.values)
                          DropdownMenuItem(
                              value: kind, child: Text(_paymentKind(kind)))
                      ],
                      onChanged: (value) => _payment = value ?? _payment,
                    )
                  else ...[
                    DropdownButtonFormField<CoffeeHarvestUnit>(
                      initialValue: _unit,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Unidade'),
                      items: [
                        for (final unit in CoffeeHarvestUnit.values)
                          DropdownMenuItem(
                              value: unit, child: Text(_unitLabels[unit]!))
                      ],
                      onChanged: (value) => setState(() {
                        if (value != _unit) _quantityField.clear();
                        _unit = value ?? _unit;
                      }),
                    ),
                    const SizedBox(height: 10),
                    if (_unit == CoffeeHarvestUnit.measures)
                      TextFormField(
                        controller: _quantityField,
                        decoration: const InputDecoration(
                            labelText: 'Quantidade',
                            helperText: 'Medidas inteiras'),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly
                        ],
                        validator: (text) {
                          if ((_number(text) ?? 0) > 0 ||
                              (_number(_remainderField.text) ?? 0) > 0) {
                            return null;
                          }
                          return 'Informe as medidas ou os litros de sobra.';
                        },
                      )
                    else
                      _positive(_quantityField, 'Quantidade'),
                    const SizedBox(height: 10),
                    _positive(_measureField, 'Litros por medida'),
                    if (_unit == CoffeeHarvestUnit.measures) ...[
                      const SizedBox(height: 10),
                      TextFormField(
                        controller: _remainderField,
                        decoration:
                            const InputDecoration(labelText: 'Litros de sobra'),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        validator: (text) {
                          if ((text ?? '').trim().isEmpty) return null;
                          final liters = _number(text);
                          final measure = _number(_measureField.text);
                          return liters == null ||
                                  (measure != null && liters >= measure)
                              ? 'A sobra precisa ser menor que uma medida.'
                              : null;
                        },
                      ),
                    ],
                    if (_unit == CoffeeHarvestUnit.carts) ...[
                      const SizedBox(height: 10),
                      _positive(_cartField, 'Litros por carreta'),
                    ],
                  ],
                  if (!_connectedHarvest) ...[
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _moneyField,
                      decoration: InputDecoration(
                          labelText: widget.payment
                              ? 'Valor (R\$)'
                              : 'Valor por medida (R\$, opcional)'),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      validator: (text) {
                        if (!widget.payment && (text ?? '').trim().isEmpty) {
                          return null;
                        }
                        final cents = _cents(text);
                        return cents == null || (widget.payment && cents == 0)
                            ? 'Informe um valor válido.'
                            : null;
                      },
                    ),
                    if (widget.payment) ...[
                      const SizedBox(height: 10),
                      TextFormField(
                          controller: _notes,
                          decoration:
                              const InputDecoration(labelText: 'Observações'),
                          maxLines: 2),
                    ],
                  ],
                ],
              ))),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar')),
          FilledButton(onPressed: _save, child: const Text('Salvar')),
        ],
      );
}

Future<void> openCoffeeHarvestPayments(
  BuildContext context, {
  required List<CoffeeHarvestPayment> payments,
  required String propertyName,
  required int seasonYear,
}) =>
    Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (_) => Scaffold(
                  appBar: AppBar(title: const Text('Pagamentos da colheita')),
                  body: SafeArea(
                      child: ListView(
                          padding: AppTheme.pagePadding(context),
                          children: [
                        Text('$propertyName · Safra $seasonYear',
                            style: AppTheme.nameStyle(context)),
                        if (payments.isEmpty)
                          const Text(
                              'Nenhuma saída da colheita neste período.'),
                        for (final payment in payments)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(payment.workerName,
                                style: AppTheme.nameStyle(context)),
                            subtitle: Text(
                                '${_harvestOutflowName(payment.kind)} · ${_date.format(payment.date)} · ${_money(payment.amountCents)}'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => Navigator.push<void>(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => _HarvestPaymentDetails(
                                        payment: payment,
                                        propertyName: propertyName))),
                          ),
                      ])),
                )));

String _harvestOutflowName(CoffeeHarvestPaymentKind kind) =>
    kind == CoffeeHarvestPaymentKind.advance ? 'Adiantamento' : 'Pagamento';

class _HarvestPaymentDetails extends StatelessWidget {
  const _HarvestPaymentDetails(
      {required this.payment, required this.propertyName});

  final CoffeeHarvestPayment payment;
  final String propertyName;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Lançamento de colheita')),
        body: SafeArea(
            child: ListView(padding: AppTheme.pagePadding(context), children: [
          Text(payment.workerName, style: AppTheme.nameStyle(context)),
          Text('$propertyName · Safra ${payment.seasonYear}'),
          Text(_harvestOutflowName(payment.kind)),
          Text('Pago em ${_date.format(payment.date)}'),
          Text('Valor: ${_money(payment.amountCents)}'),
          if (payment.notes.isNotEmpty) Text(payment.notes),
          const SizedBox(height: 8),
          Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                        builder: (_) => _WorkerHarvestScreen(
                              repository: CoffeeHarvestRepository(),
                              propertyId: payment.propertyId,
                              propertyName: propertyName,
                              workerId: payment.workerId,
                              workerName: payment.workerName,
                              seasonYear: payment.seasonYear,
                            ))),
                icon: const Icon(Icons.badge_outlined),
                label: const Text('Abrir ficha do funcionário'),
              )),
        ])),
      );
}

class _WorkerHarvestScreen extends StatefulWidget {
  const _WorkerHarvestScreen(
      {required this.repository,
      required this.propertyId,
      required this.propertyName,
      required this.workerId,
      required this.workerName,
      required this.seasonYear});

  final CoffeeHarvestRepository repository;
  final String propertyId, propertyName, workerId, workerName;
  final int seasonYear;

  @override
  State<_WorkerHarvestScreen> createState() => _WorkerHarvestScreenState();
}

class _WorkerHarvestScreenState extends State<_WorkerHarvestScreen> {
  late final _summary = widget.repository.summary(
      propertyId: widget.propertyId,
      seasonYear: widget.seasonYear,
      workerId: widget.workerId);
  bool _sharing = false;

  List<String> _totals(CoffeeHarvestSummary summary) => [
        'Colheita acumulada: ${_liters(summary.totalLiters)}',
        if (summary.entries.isNotEmpty)
          'Medidas equivalentes dos lançamentos: ${_decimal.format(summary.entries.fold<double>(0, (total, entry) => total + entry.measureEquivalent))}',
        'Valor devido pela colheita: ${_money(summary.earnedCents)}',
        if (summary.earnedCents == null)
          'Valores já informados: ${_money(summary.knownEarnedCents)}. Há lançamentos sem valor por medida.',
        'Vales: ${_money(summary.advancesCents)}',
        'Pagamentos: ${_money(summary.paymentsCents)}',
        'Saldo a pagar: ${_money(summary.balanceCents)}',
      ];

  Future<void> _share(CoffeeHarvestSummary summary) async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      FarmAccessPolicy.requireCoffeeManager();
      final regular = pw.Font.ttf(
          await rootBundle.load('assets/fonts/NotoSans-Regular.ttf'));
      final bold =
          pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSans-Bold.ttf'));
      final doc = pw.Document();
      doc.addPage(pw.MultiPage(
        theme: pw.ThemeData.withFont(base: regular, bold: bold),
        build: (_) => [
          pw.Header(level: 0, child: pw.Text('Resumo individual da colheita')),
          pw.Text(widget.workerName),
          pw.Text('${widget.propertyName} · Safra ${widget.seasonYear}'),
          pw.Text('Gerado em ${_date.format(DateTime.now())}'),
          pw.SizedBox(height: 10),
          for (final text in _totals(summary)) pw.Text(text),
          pw.Header(level: 1, child: pw.Text('Colheita por dia')),
          if (summary.entries.isEmpty) pw.Text('Nenhuma colheita registrada.'),
          for (final day in summary.litersByDay.entries)
            pw.Text('${_date.format(day.key)} · ${_liters(day.value)}'),
          pw.Header(level: 1, child: pw.Text('Vales e pagamentos')),
          if (summary.payments.isEmpty)
            pw.Text('Nenhum vale ou pagamento registrado.'),
          for (final payment in summary.payments)
            pw.Text(
                '${_date.format(payment.date)} · ${_paymentKind(payment.kind)} · ${_money(payment.amountCents)}'),
        ],
      ));
      final bytes = await doc.save();
      if (!mounted) return;
      FarmAccessPolicy.requireCoffeeManager();
      await Printing.sharePdf(
          bytes: bytes, filename: 'colheita-${widget.seasonYear}.pdf');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Não foi possível abrir o compartilhamento do PDF.')));
      }
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Resumo individual')),
        body: SafeArea(
          child: FutureBuilder<CoffeeHarvestSummary>(
            future: _summary,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Center(
                    child: Text('Não foi possível carregar o resumo.'));
              }
              final summary = snapshot.data;
              if (summary == null) {
                return const Center(child: CircularProgressIndicator());
              }
              final titles = Theme.of(context).textTheme.titleMedium;
              return Center(
                  child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1000),
                child:
                    ListView(padding: AppTheme.pagePadding(context), children: [
                  Text(widget.workerName, style: AppTheme.nameStyle(context)),
                  Text('${widget.propertyName} · Safra ${widget.seasonYear}'),
                  const SizedBox(height: 12),
                  for (final text in _totals(summary)) Text(text),
                  const SizedBox(height: 12),
                  Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: OutlinedButton.icon(
                        onPressed: _sharing ? null : () => _share(summary),
                        icon: const Icon(Icons.share_outlined),
                        label: const Text('Compartilhar resumo em PDF'),
                      )),
                  const Divider(height: 32),
                  Text('Colheita por dia', style: titles),
                  if (summary.entries.isEmpty)
                    const Text('Nenhuma colheita registrada.'),
                  for (final day in summary.litersByDay.entries)
                    ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(_date.format(day.key)),
                        subtitle: Text(_liters(day.value))),
                  const Divider(height: 32),
                  Text('Vales e pagamentos', style: titles),
                  if (summary.payments.isEmpty)
                    const Text('Nenhum vale ou pagamento registrado.'),
                  for (final payment in summary.payments)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                          '${_paymentKind(payment.kind)} · ${_money(payment.amountCents)}'),
                      subtitle: Text([
                        _date.format(payment.date),
                        if (payment.notes.isNotEmpty) payment.notes
                      ].join('\n')),
                    ),
                ]),
              ));
            },
          ),
        ),
      );
}
