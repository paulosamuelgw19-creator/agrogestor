import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../app/app_theme.dart';
import '../coffee_finance/coffee_finance_repository.dart';
import '../fuel/fuel_record.dart';
import '../fuel/fuel_repository.dart';
import '../harvest/coffee_harvest_repository.dart';
import '../harvest/coffee_harvest_screen.dart';
import '../machines/machine.dart';
import '../machines/machine_repository.dart';
import '../maintenance/maintenance_record.dart';
import '../maintenance/maintenance_repository.dart';
import '../operations_v2/v2_store.dart' show Json;
import '../properties/catalog_store.dart';
import '../services/farm_service.dart';
import '../services/service_repository.dart';
import '../sync/farm_api_client.dart';

enum _Period { month, year, all }

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  bool _loading = true;
  bool _exporting = false;
  _Period _period = _Period.month;
  List<Machine> _machines = [];
  List<FarmService> _services = [];
  List<MaintenanceRecord> _maintenance = [];
  List<FuelRecord> _fuel = [];
  final _finance = CoffeeFinanceRepository();
  final _currency = NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$');
  late final _yearField = TextEditingController(text: '$_harvestYear');
  int _harvestYear = DateTime.now().year;
  late Future<List<Json>> _farms = _loadFarms();
  Future<CoffeeFinanceSummary>? _harvest;
  String? _farmId, _yearError;
  DateTimeRange? _harvestPeriod;

  bool get _hasCoffee => FarmApiClient.standaloneLocalMode && !kIsWeb;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _yearField.dispose();
    super.dispose();
  }

  Future<List<Json>> _loadFarms() async {
    final catalog = await CatalogStore.open();
    final farms = await catalog.records('properties');
    if (mounted && _farmId == null && farms.length == 1) {
      _farmId = farms.single['id'] as String;
      _refreshHarvest();
    }
    return farms;
  }

  void _refreshHarvest() {
    final farm = _farmId;
    if (farm == null) {
      _harvest = null;
      return;
    }
    final now = DateTime.now();
    final (start, end) = switch (_period) {
      _Period.month => (
          DateTime(now.year, now.month),
          DateTime(now.year, now.month + 1, 0)
        ),
      _Period.year => (DateTime(now.year), DateTime(now.year, 12, 31)),
      _Period.all => (null, null),
    };
    _harvest = _finance.summary(
        propertyId: farm,
        seasonYear: _harvestYear,
        start: _harvestPeriod?.start ?? start,
        end: _harvestPeriod?.end ?? end)
      ..ignore();
  }

  void _applyHarvestYear() {
    final year = int.tryParse(_yearField.text.trim());
    if (year == null || year < 1900 || year > 9999) {
      setState(() => _yearError = 'Informe o ano da safra com quatro dígitos.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _harvestYear = year;
      _yearError = null;
      _refreshHarvest();
    });
  }

  Future<void> _chooseHarvestPeriod() async {
    final dates = await showDateRangePicker(
        context: context,
        firstDate: DateTime(1900),
        lastDate: DateTime.now(),
        initialDateRange: _harvestPeriod);
    if (mounted && dates != null) {
      setState(() {
        _harvestPeriod = dates;
        _refreshHarvest();
      });
    }
  }

  String _money(int cents) => _currency.format(cents / 100);

  Future<void> _load() async {
    final values = await Future.wait<Object>([
      MachineRepository().getAll(),
      ServiceRepository().getAll(),
      MaintenanceRepository().getAll(),
      FuelRepository().getAll(),
    ]);
    if (mounted) {
      setState(() {
        _machines = values[0] as List<Machine>;
        _services = values[1] as List<FarmService>;
        _maintenance = values[2] as List<MaintenanceRecord>;
        _fuel = values[3] as List<FuelRecord>;
        _loading = false;
      });
    }
  }

  bool _inPeriod(DateTime date) {
    final now = DateTime.now();
    return switch (_period) {
      _Period.month => date.year == now.year && date.month == now.month,
      _Period.year => date.year == now.year,
      _Period.all => true,
    };
  }

  List<FarmService> get _servicesInPeriod =>
      _services.where((x) => _inPeriod(x.startedAt)).toList();
  List<MaintenanceRecord> get _maintenanceInPeriod =>
      _maintenance.where((x) => _inPeriod(x.date)).toList();
  List<FuelRecord> get _fuelInPeriod =>
      _fuel.where((x) => _inPeriod(x.date)).toList();

  double get _hours =>
      _servicesInPeriod.fold<double>(0, (sum, x) => sum + (x.workedHours ?? 0));
  double get _fuelCost =>
      _fuelInPeriod.fold<double>(0, (sum, x) => sum + (x.totalCost ?? 0));
  double get _maintenanceCost =>
      _maintenanceInPeriod.fold<double>(0, (sum, x) => sum + (x.cost ?? 0));
  double get _fuelLiters =>
      _fuelInPeriod.fold<double>(0, (sum, x) => sum + x.liters);

  Future<void> _export() async {
    setState(() => _exporting = true);
    try {
      final doc = pw.Document();
      final services = _servicesInPeriod;
      final maint = _maintenanceInPeriod;
      final fuel = _fuelInPeriod;
      final hours = _hours;
      final fuelCost = _fuelCost;
      final maintenanceCost = _maintenanceCost;
      final fuelLiters = _fuelLiters;
      final harvestYear = _harvestYear;
      final harvestPeriod = _harvestPeriod;
      final periodLabel = _periodLabel;
      final farmId = _farmId;
      final harvestFuture = _harvest;
      final harvest = _hasCoffee ? await harvestFuture : null;
      final harvestFarm = harvest == null
          ? null
          : (await _farms).where((farm) => farm['id'] == farmId).firstOrNull;
      final regular = pw.Font.ttf(
          await rootBundle.load('assets/fonts/NotoSans-Regular.ttf'));
      final bold =
          pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSans-Bold.ttf'));
      doc.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        theme: pw.ThemeData.withFont(base: regular, bold: bold),
        build: (context) => [
          pw.Text('AgroGestor - Relatorio da operacao',
              style:
                  pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 6),
          pw.Text(
              'Período: $periodLabel  |  Gerado em ${_date(DateTime.now())}'),
          pw.Divider(),
          pw.Header(level: 1, text: 'Resumo'),
          pw.Bullet(text: 'Maquinas cadastradas: ${_machines.length}'),
          pw.Bullet(
              text:
                  'Servicos registrados: ${services.length} (${services.where((x) => x.isFinished).length} concluidos)'),
          pw.Bullet(text: 'Horas trabalhadas: ${hours.toStringAsFixed(1)} h'),
          pw.Bullet(
              text:
                  'Abastecido (nao e consumo medido): ${fuelLiters.toStringAsFixed(1)} L  |  Custo: R\$ ${fuelCost.toStringAsFixed(2)}'),
          pw.Bullet(
              text: 'Manutencao: R\$ ${maintenanceCost.toStringAsFixed(2)}'),
          pw.Bullet(
              text:
                  'Subtotal da frota: R\$ ${(fuelCost + maintenanceCost).toStringAsFixed(2)}'),
          pw.Text(
              'Subtotal da frota inclui valores conhecidos de abastecimento e manutenção.'),
          pw.Text(
              'Abastecimentos sem preco: ${fuel.where((f) => f.pricePerLiter == null).length}'),
          if (harvest != null && harvestFarm != null) ...[
            pw.Header(level: 1, text: 'Despesas de colheita'),
            pw.Text('${harvestFarm['name']} · Safra $harvestYear'),
            pw.Text(harvestPeriod == null
                ? periodLabel
                : '${_date(harvestPeriod.start)} a ${_date(harvestPeriod.end)}'),
            pw.Bullet(
                text:
                    'Pago no período: ${_money(harvest.harvestCashPaidCents)}'),
            pw.Bullet(
                text:
                    'Valor conhecido devido pela produção no período: ${_money(harvest.knownHarvestCostCents)}'),
            if (harvest.harvestPayments.isNotEmpty)
              pw.TableHelper.fromTextArray(headers: [
                'Data do pagamento',
                'Funcionário',
                'Tipo',
                'Valor'
              ], data: [
                for (final payment in harvest.harvestPayments)
                  [
                    _date(payment.date),
                    payment.workerName,
                    payment.kind == CoffeeHarvestPaymentKind.advance
                        ? 'Adiantamento'
                        : 'Pagamento',
                    _money(payment.amountCents)
                  ],
              ]),
          ],
          pw.Header(level: 1, text: 'Servicos'),
          if (services.isEmpty)
            pw.Text('Nenhum servico no periodo selecionado.')
          else
            pw.TableHelper.fromTextArray(
              headers: ['Data', 'Servico', 'Maquina', 'Status', 'Horas'],
              data: services
                  .map((x) => [
                        _date(x.startedAt),
                        x.jobType,
                        x.machineName,
                        x.isFinished
                            ? 'Concluido'
                            : x.isCancelled
                                ? 'Cancelada'
                                : 'Em andamento',
                        x.workedHours?.toStringAsFixed(1) ?? '-'
                      ])
                  .toList(),
            ),
          pw.Header(level: 1, text: 'Abastecimentos'),
          if (fuel.isEmpty)
            pw.Text('Nenhum abastecimento no periodo selecionado.')
          else
            pw.TableHelper.fromTextArray(
              headers: ['Data', 'Maquina', 'Litros', 'Total'],
              data: fuel
                  .map((x) => [
                        _date(x.date),
                        x.machineName,
                        x.liters.toStringAsFixed(1),
                        'R\$ ${x.totalCost?.toStringAsFixed(2) ?? 'Nao informado'}'
                      ])
                  .toList(),
            ),
          pw.Header(level: 1, text: 'Manutencoes'),
          if (maint.isEmpty)
            pw.Text('Nenhuma manutencao no periodo selecionado.')
          else
            pw.TableHelper.fromTextArray(
              headers: ['Data', 'Tipo', 'Maquina', 'Horimetro', 'Custo'],
              data: maint
                  .map((x) => [
                        _date(x.date),
                        x.type,
                        x.machineName,
                        '${x.hourMeter.toStringAsFixed(1)} h',
                        'R\$ ${x.cost?.toStringAsFixed(2) ?? 'Nao informado'}'
                      ])
                  .toList(),
            ),
        ],
      ));
      await Printing.sharePdf(
          bytes: await doc.save(), filename: 'agrogestor-relatorio.pdf');
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Não foi possível gerar o PDF: $error')));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  String get _periodLabel => switch (_period) {
        _Period.month => 'Este mês',
        _Period.year => 'Este ano',
        _Period.all => 'Todo o período'
      };
  String _date(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

  Widget _harvestExpenses() => FutureBuilder<List<Json>>(
        future: _farms,
        builder: (context, catalog) {
          if (catalog.hasError) {
            return TextButton(
                onPressed: () => setState(() {
                      _farms = _loadFarms();
                    }),
                child: const Text(
                    'Não foi possível abrir as fazendas. Tentar novamente'));
          }
          final farms = catalog.data;
          if (farms == null) return const LinearProgressIndicator();
          final farm = farms.where((item) => item['id'] == _farmId).firstOrNull;
          return Card(
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Despesas de colheita',
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 8),
                      if (farms.isEmpty)
                        const Text(
                            'Cadastre uma fazenda para consultar os pagamentos da colheita.')
                      else ...[
                        DropdownButtonFormField<String>(
                          initialValue: _farmId,
                          isExpanded: true,
                          decoration:
                              const InputDecoration(labelText: 'Fazenda'),
                          items: [
                            for (final item in farms)
                              DropdownMenuItem(
                                  value: item['id'] as String,
                                  child: Text('${item['name']}',
                                      overflow: TextOverflow.ellipsis,
                                      style: AppTheme.nameStyle(context)))
                          ],
                          onChanged: (id) => setState(() {
                            _farmId = id;
                            _refreshHarvest();
                          }),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                            controller: _yearField,
                            keyboardType: TextInputType.number,
                            inputFormatters: [
                              FilteringTextInputFormatter.digitsOnly,
                              LengthLimitingTextInputFormatter(4)
                            ],
                            decoration: InputDecoration(
                                labelText: 'Ano da safra',
                                errorText: _yearError),
                            onSubmitted: (_) => _applyHarvestYear()),
                        Wrap(spacing: 4, runSpacing: 4, children: [
                          TextButton(
                              onPressed: _applyHarvestYear,
                              child: const Text('Ver safra')),
                          TextButton.icon(
                              onPressed: _chooseHarvestPeriod,
                              icon: const Icon(Icons.date_range_outlined),
                              label: Text(_harvestPeriod == null
                                  ? 'Filtrar período da colheita'
                                  : '${_date(_harvestPeriod!.start)} a ${_date(_harvestPeriod!.end)}')),
                          if (_harvestPeriod != null)
                            TextButton(
                                onPressed: () => setState(() {
                                      _harvestPeriod = null;
                                      _refreshHarvest();
                                    }),
                                child: const Text('Usar período do relatório')),
                          if (farm != null)
                            TextButton.icon(
                                onPressed: () => setState(_refreshHarvest),
                                icon: const Icon(Icons.refresh),
                                label: const Text('Atualizar')),
                        ]),
                        if (farm == null)
                          const Text(
                              'Selecione a fazenda para consultar as saídas da colheita.')
                        else
                          FutureBuilder<CoffeeFinanceSummary>(
                              future: _harvest,
                              builder: (context, snapshot) {
                                if (snapshot.connectionState ==
                                    ConnectionState.waiting) {
                                  return const LinearProgressIndicator();
                                }
                                if (snapshot.hasError) {
                                  return const AppNotice(
                                      message:
                                          'Não foi possível carregar as despesas de colheita.',
                                      tone: AppNoticeTone.error);
                                }
                                final data = snapshot.data;
                                if (data == null) {
                                  return const SizedBox.shrink();
                                }
                                return Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                          'Pago no período: ${_money(data.harvestCashPaidCents)}',
                                          style: AppTheme.nameStyle(context)),
                                      Text(
                                          'Adiantamentos: ${_money(data.harvestAdvanceCents)} · Pagamentos: ${_money(data.harvestPaymentCents)}'),
                                      Text(
                                          'Valor conhecido devido pela produção no período: ${_money(data.knownHarvestCostCents)}'),
                                      if (data.harvestPayments.isEmpty)
                                        const Text(
                                            'Nenhuma saída da colheita neste período.')
                                      else
                                        TextButton.icon(
                                            onPressed: () =>
                                                openCoffeeHarvestPayments(
                                                    context,
                                                    payments:
                                                        data.harvestPayments,
                                                    propertyName:
                                                        '${farm['name']}',
                                                    seasonYear: _harvestYear),
                                            icon: const Icon(
                                                Icons.receipt_long_outlined),
                                            label: const Text(
                                                'Consultar pagamentos da colheita')),
                                    ]);
                              }),
                      ],
                    ],
                  )));
        },
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : SingleChildScrollView(
                      padding: AppTheme.pagePadding(context),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Relatórios',
                                style: TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w800,
                                    color: AppTheme.forest)),
                            const SizedBox(height: 5),
                            const Text(
                                'Acompanhe os resultados da operação e exporte os dados.',
                                style: TextStyle(color: Colors.black54)),
                            Text(
                                'Custos da frota com valores conhecidos. ${_fuelInPeriod.where((f) => f.pricePerLiter == null).length} abastecimento(s) sem preço e ${_maintenanceInPeriod.where((m) => m.cost == null).length} manutenção(ões) sem custo informado.'),
                            const SizedBox(height: 18),
                            Wrap(spacing: 12, runSpacing: 8, children: [
                              SegmentedButton<_Period>(
                                segments: const [
                                  ButtonSegment(
                                      value: _Period.month, label: Text('Mês')),
                                  ButtonSegment(
                                      value: _Period.year, label: Text('Ano')),
                                  ButtonSegment(
                                      value: _Period.all, label: Text('Tudo')),
                                ],
                                selected: {_period},
                                onSelectionChanged: (value) => setState(() {
                                  _period = value.first;
                                  if (_hasCoffee) _refreshHarvest();
                                }),
                              ),
                              FilledButton.icon(
                                  onPressed: _exporting ? null : _export,
                                  icon: _exporting
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2))
                                      : const Icon(
                                          Icons.picture_as_pdf_outlined),
                                  label: Text(_exporting
                                      ? 'Gerando...'
                                      : 'Exportar PDF')),
                            ]),
                            if (_hasCoffee) ...[
                              const SizedBox(height: 12),
                              _harvestExpenses(),
                            ],
                            const SizedBox(height: 20),
                            Wrap(spacing: 12, runSpacing: 12, children: [
                              _ReportCard(
                                  label: 'Máquinas',
                                  value: '${_machines.length}',
                                  icon: Icons.agriculture_outlined),
                              _ReportCard(
                                  label: 'Serviços',
                                  value: '${_servicesInPeriod.length}',
                                  icon: Icons.assignment_outlined),
                              _ReportCard(
                                  label: 'Horas trabalhadas',
                                  value: '${_hours.toStringAsFixed(1)} h',
                                  icon: Icons.schedule_outlined),
                              _ReportCard(
                                  label: 'Litros abastecidos',
                                  value: '${_fuelLiters.toStringAsFixed(1)} L',
                                  icon: Icons.local_gas_station_outlined),
                              _ReportCard(
                                  label: 'Combustível: valor conhecido',
                                  value: _fuelInPeriod.isNotEmpty &&
                                          !_fuelInPeriod
                                              .any((f) => f.totalCost != null)
                                      ? 'Não informado'
                                      : 'R\$ ${_fuelCost.toStringAsFixed(2)}',
                                  icon: Icons.payments_outlined),
                              _ReportCard(
                                  label: 'Manutenção: valor conhecido',
                                  value: _maintenanceInPeriod.isNotEmpty &&
                                          !_maintenanceInPeriod
                                              .any((m) => m.cost != null)
                                      ? 'Não informado'
                                      : 'R\$ ${_maintenanceCost.toStringAsFixed(2)}',
                                  icon: Icons.build_outlined),
                            ]),
                            const SizedBox(height: 18),
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(20),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Subtotal da frota no período',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w600),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        'R\$ ${(_fuelCost + _maintenanceCost).toStringAsFixed(2)}',
                                        style: const TextStyle(
                                          fontSize: 20,
                                          fontWeight: FontWeight.w800,
                                          color: AppTheme.forest,
                                        ),
                                      ),
                                    ]),
                              ),
                            ),
                          ]),
                    ),
            ),
          ),
        ),
      );
}

class _ReportCard extends StatelessWidget {
  const _ReportCard(
      {required this.label, required this.value, required this.icon});
  final String label, value;
  final IconData icon;
  @override
  Widget build(BuildContext context) => SizedBox(
      width: 265,
      child: Card(
          child: Padding(
              padding: const EdgeInsets.all(18),
              child: Row(children: [
                Icon(icon, color: AppTheme.leaf),
                const SizedBox(width: 12),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(label,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.black54)),
                      const SizedBox(height: 4),
                      Text(value,
                          style: const TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.forest))
                    ]))
              ]))));
}
