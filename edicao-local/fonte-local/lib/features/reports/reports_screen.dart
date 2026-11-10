import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../app/app_theme.dart';
import '../fuel/fuel_record.dart';
import '../fuel/fuel_repository.dart';
import '../machines/machine.dart';
import '../machines/machine_repository.dart';
import '../maintenance/maintenance_record.dart';
import '../maintenance/maintenance_repository.dart';
import '../services/farm_service.dart';
import '../services/service_repository.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
  }

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
      doc.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        build: (context) => [
          pw.Text('AgroGestor - Relatorio da operacao',
              style:
                  pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 6),
          pw.Text(
              'Periodo: $_periodLabel  |  Gerado em ${_date(DateTime.now())}'),
          pw.Divider(),
          pw.Header(level: 1, text: 'Resumo'),
          pw.Bullet(text: 'Maquinas cadastradas: ${_machines.length}'),
          pw.Bullet(
              text:
                  'Servicos registrados: ${services.length} (${services.where((x) => x.isFinished).length} concluidos)'),
          pw.Bullet(text: 'Horas trabalhadas: ${_hours.toStringAsFixed(1)} h'),
          pw.Bullet(
              text:
                  'Abastecido (nao e consumo medido): ${_fuelLiters.toStringAsFixed(1)} L  |  Custo: R\$ ${_fuelCost.toStringAsFixed(2)}'),
          pw.Bullet(
              text: 'Manutencao: R\$ ${_maintenanceCost.toStringAsFixed(2)}'),
          pw.Bullet(
              text:
                  'Despesas registradas: R\$ ${(_fuelCost + _maintenanceCost).toStringAsFixed(2)}'),
          pw.Text(
              'Valores conhecidos: nao incluem precos ausentes, custos de insumos, mao de obra ou tarifas de maquinas sem valor registrado.'),
          pw.Text(
              'Abastecimentos sem preco: ${fuel.where((f) => f.pricePerLiter == null).length}'),
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
                                'Custos conhecidos. ${_fuelInPeriod.where((f) => f.pricePerLiter == null).length} abastecimento(s) sem preço; ${_maintenanceInPeriod.where((m) => m.cost == null).length} manutenção(ões) sem custo informado. Valores ausentes, insumos sem preço e mão de obra não estão incluídos.'),
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
                                onSelectionChanged: (value) =>
                                    setState(() => _period = value.first),
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
                                        'Subtotal dos custos conhecidos no período',
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
