import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show FilteringTextInputFormatter, LengthLimitingTextInputFormatter;
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'package:uuid/uuid.dart';

import '../../app/app_theme.dart';
import '../analyses/coffee_analysis_repository.dart'
    show
        CoffeeAnalysisRepository,
        coffeeAnalysisPdfMaxBytes,
        readCoffeeAnalysisPdf,
        validateCoffeeAnalysisPdf;
import '../auth/farm_access_policy.dart';
import '../harvest/coffee_harvest_screen.dart';
import '../licensing/write_gate.dart';
import '../operations_v2/v2_store.dart' show Json;
import '../properties/catalog_store.dart';
import 'coffee_finance_repository.dart';
import 'coffee_finance_check_repository.dart';

part 'coffee_finance_forms.dart';
part 'coffee_finance_pdf.dart';
part 'coffee_finance_check.dart';

final _date = DateFormat('dd/MM/yyyy');
final _currency = NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$');
const _kinds = {
  CoffeeFinanceKind.purchase: 'Compra',
  CoffeeFinanceKind.contractedService: 'Serviço contratado',
  CoffeeFinanceKind.expense: 'Outra despesa',
  CoffeeFinanceKind.income: 'Outra receita',
};
const _stages = {
  CoffeeFinanceStage.establishment: 'Implantação',
  CoffeeFinanceStage.management: 'Manejo',
  CoffeeFinanceStage.harvest: 'Colheita',
  CoffeeFinanceStage.processing: 'Beneficiamento',
};
const _originNames = {
  CoffeeFinanceOriginKind.fuel: 'Abastecimento',
  CoffeeFinanceOriginKind.maintenance: 'Manutenção',
};

String _money(int cents) => _currency.format(cents / 100);
String _priceText(int? cents) =>
    cents == null ? '' : (cents / 100).toStringAsFixed(2).replaceAll('.', ',');
String _qtyText(double? value) =>
    value?.toString().replaceFirst(RegExp(r'\.0$'), '').replaceAll('.', ',') ??
    '';
String _name(Json item) =>
    '${item['name']}${item['archived'] == 1 ? ' · Arquivado' : ''}';

int? _cents(String? raw) {
  final match =
      RegExp(r'^(\d+)(?:[.,](\d{1,2}))?$').firstMatch(raw?.trim() ?? '');
  if (match == null) return null;
  final whole = int.tryParse(match.group(1)!);
  if (whole == null || whole > 10000000000) return null;
  final amount =
      whole * 100 + int.parse((match.group(2) ?? '').padRight(2, '0'));
  return amount <= 1000000000000 ? amount : null;
}

double? _positive(String? raw) {
  final text = raw?.trim() ?? '';
  if (!RegExp(r'^\d+(?:[.,]\d+)?$').hasMatch(text)) return null;
  final value = double.tryParse(text.replaceAll(',', '.'));
  return value != null && value.isFinite && value > 0 && value <= 1e12
      ? value
      : null;
}

Future<DateTime?> _pickDate(BuildContext context, DateTime date,
    {DateTime? from}) {
  final first = DateUtils.dateOnly(from ?? DateTime(1900));
  final today = DateUtils.dateOnly(DateTime.now());
  final initial = date.isBefore(first) ? first : date;
  final last = initial.isAfter(today) ? initial : today;
  return showDatePicker(
      context: context, firstDate: first, lastDate: last, initialDate: initial);
}

typedef _Catalog = ({List<Json> farms, List<Json> plots});

class CoffeeFinanceScreen extends StatefulWidget {
  const CoffeeFinanceScreen({super.key});

  @override
  State<CoffeeFinanceScreen> createState() => _CoffeeFinanceScreenState();
}

class _CoffeeFinanceScreenState extends State<CoffeeFinanceScreen> {
  final _repository = CoffeeFinanceRepository();
  late Future<_Catalog> _catalog = _loadCatalog();
  late int _year = DateTime.now().year;
  late final _yearField = TextEditingController(text: '$_year');
  String? _farmId, _plotId, _yearError;
  DateTimeRange? _period;
  Future<CoffeeFinanceSummary>? _summary;

  @override
  void dispose() {
    _yearField.dispose();
    super.dispose();
  }

  Future<_Catalog> _loadCatalog() async {
    FarmAccessPolicy.requireCoffeeManager();
    final catalog = await CatalogStore.open();
    final farms = await catalog.records('properties');
    final plots = await catalog.records('plots');
    if (mounted && _farmId == null && farms.length == 1) {
      _farmId = farms.single['id'] as String;
      _loadSummary();
    }
    return (
      farms: farms,
      plots: plots,
    );
  }

  void _loadSummary() {
    final propertyId = _farmId;
    _summary = propertyId == null
        ? null
        : (_repository.summary(
            propertyId: propertyId,
            seasonYear: _year,
            plotId: _plotId,
            start: _period?.start,
            end: _period?.end)
          ..ignore());
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
      _loadSummary();
    });
  }

  Future<void> _choosePeriod() async {
    final period = await showDateRangePicker(
        context: context,
        firstDate: DateTime(1900),
        lastDate: DateTime.now(),
        initialDateRange: _period);
    if (mounted && period != null) {
      setState(() {
        _period = period;
        _loadSummary();
      });
    }
  }

  Future<void> _edit(Json farm, List<Json> plots,
      {CoffeeFinanceEntry? entry}) async {
    final saved = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) => _FinanceEntryEditor(
                  repository: _repository,
                  farm: farm,
                  plots: plots,
                  year: _year,
                  initialPlotId: _plotId,
                  existing: entry,
                )));
    if (mounted && saved == true) setState(_loadSummary);
  }

  Future<void> _openSale(Json farm, CoffeeFinanceSale sale) async {
    await Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (_) =>
                _SaleDetails(repository: _repository, farm: farm, sale: sale)));
    if (mounted) setState(_loadSummary);
  }

  Future<void> _openEntry(
      Json farm, List<Json> plots, CoffeeFinanceEntry entry) async {
    final plot = plots.where((plot) => plot['id'] == entry.plotId).firstOrNull;
    final edit = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) =>
                _FinanceEntryDetails(farm: farm, plot: plot, entry: entry)));
    if (mounted && edit == true) await _edit(farm, plots, entry: entry);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
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
                        'Não foi possível abrir as fazendas. Tentar novamente')));
          }
          final catalog = snapshot.data;
          if (catalog == null) {
            return const Center(child: CircularProgressIndicator());
          }
          final farm =
              catalog.farms.where((item) => item['id'] == _farmId).firstOrNull;
          final plots = catalog.plots
              .where((item) => item['property_id'] == _farmId)
              .toList();
          return _FinancePage(children: [
            if (catalog.farms.isEmpty)
              const Text(
                  'Cadastre uma fazenda em Propriedades para registrar gastos e receitas.')
            else ...[
              DropdownButtonFormField<String>(
                decoration: const InputDecoration(labelText: 'Fazenda'),
                initialValue: _farmId,
                isExpanded: true,
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
                  _loadSummary();
                }),
              ),
              const SizedBox(height: 8),
              if (plots.isNotEmpty) ...[
                DropdownButtonFormField<String>(
                  key: ValueKey(_farmId),
                  decoration: const InputDecoration(labelText: 'Talhão'),
                  initialValue: _plotId ?? '',
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(
                        value: '', child: Text('Todos os talhões')),
                    for (final plot in plots)
                      DropdownMenuItem(
                          value: plot['id'] as String,
                          child: Text(_name(plot),
                              style: AppTheme.nameStyle(context),
                              overflow: TextOverflow.ellipsis))
                  ],
                  onChanged: (value) => setState(() {
                    _plotId = value == '' ? null : value;
                    _loadSummary();
                  }),
                ),
                const SizedBox(height: 8),
              ],
              TextField(
                  controller: _yearField,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                      labelText: 'Ano da safra', errorText: _yearError),
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(4)
                  ],
                  onSubmitted: (_) => _applyYear()),
              Wrap(spacing: 8, runSpacing: 4, children: [
                TextButton(
                    onPressed: _applyYear, child: const Text('Ver safra')),
                if (farm != null)
                  TextButton.icon(
                      onPressed: () => setState(_loadSummary),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Atualizar')),
                OutlinedButton.icon(
                    onPressed: _choosePeriod,
                    icon: const Icon(Icons.date_range_outlined),
                    label: Text(_period == null
                        ? 'Filtrar período'
                        : '${_date.format(_period!.start)} a ${_date.format(_period!.end)}')),
                if (_period != null)
                  TextButton(
                      onPressed: () => setState(() {
                            _period = null;
                            _loadSummary();
                          }),
                      child: const Text('Limpar período')),
                if (farm != null && farm['archived'] != 1)
                  FilledButton.icon(
                      onPressed: () => _edit(farm, plots),
                      icon: const Icon(Icons.add),
                      label: const Text('Novo lançamento')),
              ]),
              const SizedBox(height: 12),
              if (farm == null)
                const Text('Selecione a fazenda para consultar o financeiro.')
              else
                FutureBuilder<CoffeeFinanceSummary>(
                    future: _summary,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const LinearProgressIndicator();
                      }
                      if (snapshot.hasError) {
                        return TextButton(
                            onPressed: () => setState(_loadSummary),
                            child: const Text(
                                'Não foi possível carregar o financeiro. Tentar novamente'));
                      }
                      final summary = snapshot.data;
                      if (summary == null) return const SizedBox.shrink();
                      return _FinanceSummaryView(
                          summary: summary,
                          year: _year,
                          filteredPlot: _plotId != null,
                          filteredPeriod: _period != null,
                          onCheck: () => showDialog<void>(
                                context: context,
                                builder: (_) => _FinanceCheckDialog(
                                  propertyId: farm['id'] as String,
                                  plotId: _plotId,
                                  year: _year,
                                  period: _period,
                                  entries: summary.entries,
                                  canEdit: farm['archived'] != 1,
                                  onEntry: (entry) => Navigator.of(context)
                                      .push<void>(MaterialPageRoute(
                                    builder: (_) => _FinanceEntryDetails(
                                        farm: farm,
                                        plot: plots
                                            .where((plot) =>
                                                plot['id'] == entry.plotId)
                                            .firstOrNull,
                                        entry: entry,
                                        canEdit: false),
                                  )),
                                ),
                              ),
                          onEntry: (entry) => _openEntry(farm, plots, entry),
                          onHarvestPayments: () async {
                            await openCoffeeHarvestPayments(context,
                                payments: summary.harvestPayments,
                                propertyName: '${farm['name']}',
                                seasonYear: _year);
                            if (mounted) setState(_loadSummary);
                          },
                          onSale: (sale) => _openSale(farm, sale));
                    }),
            ],
          ]);
        },
      ));
}

class _FinancePage extends StatelessWidget {
  const _FinancePage({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Center(
      child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: ListView(
              padding: AppTheme.pagePadding(context), children: children)));
}

class _FinanceSummaryView extends StatelessWidget {
  const _FinanceSummaryView(
      {required this.summary,
      required this.year,
      required this.filteredPlot,
      required this.filteredPeriod,
      required this.onEntry,
      required this.onCheck,
      required this.onHarvestPayments,
      required this.onSale});

  final CoffeeFinanceSummary summary;
  final int year;
  final bool filteredPlot, filteredPeriod;
  final ValueChanged<CoffeeFinanceEntry> onEntry;
  final VoidCallback onHarvestPayments, onCheck;
  final ValueChanged<CoffeeFinanceSale> onSale;

  @override
  Widget build(BuildContext context) {
    final titles = Theme.of(context).textTheme.titleMedium;
    final costs = <CoffeeFinanceStage, Map<String, List<CoffeeFinanceEntry>>>{};
    for (final entry in summary.entries.where((entry) => !entry.isIncome)) {
      costs
          .putIfAbsent(entry.stage, () => {})
          .putIfAbsent(entry.category, () => [])
          .add(entry);
    }
    final harvestCost = summary.knownHarvestCostCents;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Financeiro · Safra $year',
          style: Theme.of(context).textTheme.headlineSmall),
      if (filteredPeriod)
        const Text(
            'O período considera a data do lançamento e, no caixa, a data de pagamento ou recebimento.'),
      if (filteredPlot)
        const Text(
            'Vendas de lotes sem um único talhão confirmado aparecem em Todos os talhões.'),
      if (summary.hasUnallocatedHarvestPayments)
        const AppNotice(
            message:
                'Existem pagamentos de colheita lançados para a fazenda. Escolha Todos os talhões para consultá-los.'),
      const SizedBox(height: 8),
      Card(
          child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Resultado dos valores conhecidos', style: titles),
                    Text(
                        'Receitas conhecidas: ${_money(summary.knownRevenueCents)}'),
                    Text(
                        'Despesas conhecidas: ${_money(summary.knownExpenseCents)}'),
                    Text(
                        'Resultado conhecido: ${_money(summary.recognizedBalanceCents)}'),
                    if (summary.knownHarvestCostCents > 0)
                      Text(
                          'Valor conhecido devido pela colheita: ${_money(summary.knownHarvestCostCents)}'),
                    if (summary.unknownExpenseCount > 0 ||
                        summary.unknownRevenueCount > 0)
                      Text(
                          'Sem valor informado: ${summary.unknownExpenseCount} despesa(s) e ${summary.unknownRevenueCount} receita(s).'),
                  ]))),
      Card(
          child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Caixa registrado', style: titles),
                    Text('Entradas: ${_money(summary.cashInCents)}'),
                    Text('Saídas: ${_money(summary.cashOutCents)}'),
                    Text('Saldo de caixa: ${_money(summary.cashBalanceCents)}'),
                    if (summary.harvestCashPaidCents > 0)
                      Text(
                          'Vales e pagamentos da colheita: ${_money(summary.harvestCashPaidCents)}'),
                    if (summary.harvestPayments.isNotEmpty) ...[
                      Text(
                          'Adiantamentos: ${_money(summary.harvestAdvanceCents)} · Pagamentos: ${_money(summary.harvestPaymentCents)}'),
                      TextButton.icon(
                          onPressed: onHarvestPayments,
                          icon: const Icon(Icons.receipt_long_outlined),
                          label:
                              const Text('Consultar pagamentos da colheita')),
                    ],
                    Text(
                        'A receber das vendas: ${_money(summary.outstandingSalesCents)}'),
                  ]))),
      if (costs.isNotEmpty ||
          harvestCost > 0 ||
          summary.harvestPayments.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('Despesas por etapa e categoria', style: titles),
        Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
                onPressed: onCheck,
                icon: const Icon(Icons.fact_check_outlined),
                label: const Text('Conferir subtotal do caderno'))),
        for (final stage in CoffeeFinanceStage.values)
          if (costs.containsKey(stage) ||
              (stage == CoffeeFinanceStage.harvest &&
                  (harvestCost > 0 || summary.harvestPayments.isNotEmpty)))
            Card(
              child: ExpansionTile(
                title: Text(_stages[stage]!),
                children: [
                  for (final category in (costs[stage] ??
                          const <String, List<CoffeeFinanceEntry>>{})
                      .entries)
                    ExpansionTile(
                      title: Text(category.key),
                      subtitle: Text(
                        category.value.any((entry) => entry.totalCents != null)
                            ? 'Valores conhecidos: ${_money(category.value.fold(0, (total, entry) => total + (entry.totalCents ?? 0)))}'
                            : 'Valores não informados',
                      ),
                      children: [
                        for (final entry in category.value)
                          ListTile(
                            title: Text(entry.description),
                            subtitle: Text(entry.totalCents == null
                                ? 'Valor não informado'
                                : _money(entry.totalCents!)),
                            onTap: () => onEntry(entry),
                          ),
                      ],
                    ),
                  if (stage == CoffeeFinanceStage.harvest && harvestCost > 0)
                    ListTile(
                      title: const Text('Mão de obra registrada na Colheita'),
                      subtitle: Text('Valor devido: ${_money(harvestCost)}'),
                    ),
                  if (stage == CoffeeFinanceStage.harvest &&
                      summary.harvestPayments.isNotEmpty)
                    ListTile(
                        title: const Text('Saídas de colheita no caixa'),
                        subtitle: Text(_money(summary.harvestCashPaidCents)),
                        onTap: onHarvestPayments,
                        trailing: const Icon(Icons.chevron_right)),
                ],
              ),
            ),
      ],
      const Divider(height: 30),
      Text('Compras, serviços, despesas e outras receitas', style: titles),
      if (summary.entries.isEmpty)
        const Text('Nenhum lançamento neste filtro.'),
      for (final entry in summary.entries)
        Card(
            child: ListTile(
                title: Text(entry.description),
                subtitle: Text(
                    '${_kinds[entry.kind]} · ${_date.format(entry.date)}\n${entry.totalCents == null ? 'Valor não informado' : _money(entry.totalCents!)}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => onEntry(entry))),
      const Divider(height: 30),
      Text('Vendas de lotes', style: titles),
      if (summary.sales.isEmpty) const Text('Nenhuma venda neste filtro.'),
      for (final sale in summary.sales)
        Card(
            child: ListTile(
                title: Text('Lote ${sale.lot.code}'),
                subtitle: Text(
                    '${_date.format(sale.sale.date)} · ${_money(sale.sale.totalPriceCents)}\nA receber: ${_money(sale.outstandingCents)}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => onSale(sale))),
    ]);
  }
}

class _FinanceEntryDetails extends StatelessWidget {
  const _FinanceEntryDetails(
      {required this.farm,
      required this.plot,
      required this.entry,
      this.canEdit = true});

  final Json farm;
  final Json? plot;
  final CoffeeFinanceEntry entry;
  final bool canEdit;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Lançamento financeiro')),
        body: SafeArea(
            child: _FinancePage(children: [
          Text('${farm['name']} · Safra ${entry.seasonYear}',
              style: Theme.of(context).textTheme.titleMedium),
          if (plot != null) Text('Talhão: ${plot!['name']}'),
          Text(entry.description,
              style: Theme.of(context).textTheme.headlineSmall),
          Text(
              '${_kinds[entry.kind]} · ${_stages[entry.stage]} · ${entry.category}'),
          Text('Data: ${_date.format(entry.date)}'),
          if (entry.supplier.isNotEmpty)
            Text('Fornecedor ou pessoa: ${entry.supplier}'),
          if (entry.quantity case final double quantity)
            Text('Quantidade: ${_qtyText(quantity)} ${entry.unit}'),
          if (entry.priceCents case final int price)
            Text(
                '${entry.priceMode == CoffeeFinancePriceMode.unit ? 'Preço unitário' : 'Preço informado'}: ${_money(price)}'),
          if (entry.freightMode == CoffeeFinanceFreightMode.separate)
            Text(entry.freightCents == null
                ? 'Frete: valor não informado'
                : 'Frete: ${_money(entry.freightCents!)}'),
          Text(entry.totalCents == null
              ? 'Total não informado'
              : 'Total: ${_money(entry.totalCents!)}'),
          if (entry.settledAt case final DateTime date)
            Text('Data de pagamento ou recebimento: ${_date.format(date)}')
          else
            const Text('Sem baixa no caixa.'),
          if (entry.originKind case final CoffeeFinanceOriginKind origin)
            Text('Origem vinculada: ${_originNames[origin]}'),
          if (entry.analysisId != null)
            const Text('Vinculado a um laudo do talhão'),
          if (entry.notes.isNotEmpty) Text(entry.notes),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, children: [
            if (canEdit && farm['archived'] != 1)
              TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Editar lançamento')),
            if (entry.pdfPath case final String path)
              OutlinedButton.icon(
                  onPressed: () => _openFinancePdf(context, path),
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('Abrir comprovante PDF')),
          ]),
        ])),
      );
}

/// Opens the canonical expense from another area without editing it there.
Future<void> openCoffeeFinanceEntry(
  BuildContext context, {
  required Json farm,
  required Json plot,
  required CoffeeFinanceEntry entry,
}) =>
    Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => _FinanceEntryDetails(
          farm: farm, plot: plot, entry: entry, canEdit: false),
    ));

class _SaleDetails extends StatefulWidget {
  const _SaleDetails(
      {required this.repository, required this.farm, required this.sale});

  final CoffeeFinanceRepository repository;
  final Json farm;
  final CoffeeFinanceSale sale;

  @override
  State<_SaleDetails> createState() => _SaleDetailsState();
}

class _SaleDetailsState extends State<_SaleDetails> {
  late CoffeeFinanceSale _sale = widget.sale;

  Future<void> _receive() async {
    final updated = await showDialog<CoffeeFinanceSale>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            _ReceiptDialog(repository: widget.repository, sale: _sale));
    if (!mounted || updated == null) return;
    setState(() => _sale = updated);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Venda do lote')),
        body: SafeArea(
            child: _FinancePage(children: [
          Text('${widget.farm['name']} · Safra ${_sale.lot.seasonYear}',
              style: Theme.of(context).textTheme.titleMedium),
          Text('Lote ${_sale.lot.code}',
              style: Theme.of(context).textTheme.headlineSmall),
          Text('Venda em ${_date.format(_sale.sale.date)}'),
          if (_sale.sale.buyer.isNotEmpty)
            Text('Comprador: ${_sale.sale.buyer}'),
          Text('Valor da venda: ${_money(_sale.sale.totalPriceCents)}'),
          Text('Recebido: ${_money(_sale.receivedCents)}'),
          Text('A receber: ${_money(_sale.outstandingCents)}'),
          if (_sale.outstandingCents > 0 && widget.farm['archived'] != 1)
            Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton(
                    onPressed: _receive,
                    child: const Text('Registrar recebimento'))),
          const Divider(height: 30),
          Text('Recebimentos', style: Theme.of(context).textTheme.titleMedium),
          if (_sale.receipts.isEmpty)
            const Text('Nenhum recebimento registrado.'),
          for (final receipt in _sale.receipts)
            ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                    '${_date.format(receipt.date)} · ${_money(receipt.amountCents)}'),
                subtitle: receipt.notes.isEmpty ? null : Text(receipt.notes)),
        ])),
      );
}
