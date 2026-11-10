import 'dart:io';
import 'package:flutter/material.dart';
import '../../app/app_theme.dart';
import '../fuel/fuel_record.dart';
import '../fuel/fuel_repository.dart';
import '../maintenance/maintenance_record.dart';
import '../maintenance/maintenance_repository.dart';
import '../services/farm_service.dart';
import '../services/service_repository.dart';
import 'machine.dart';

class MachineTimelineScreen extends StatefulWidget {
  const MachineTimelineScreen({super.key, required this.machine});
  final Machine machine;

  @override
  State<MachineTimelineScreen> createState() => _MachineTimelineScreenState();
}

class _TimelineEntry {
  final DateTime date;
  final String title;
  final String subtitle;
  final double? cost;
  final IconData icon;
  final Color color;
  final String category;

  _TimelineEntry({
    required this.date,
    required this.title,
    required this.subtitle,
    this.cost,
    required this.icon,
    required this.color,
    required this.category,
  });
}

class _MachineTimelineScreenState extends State<MachineTimelineScreen> {
  bool _loading = true;
  List<FarmService> _services = [];
  List<FuelRecord> _fuels = [];
  List<MaintenanceRecord> _maintenances = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final sList = await ServiceRepository().getAll();
    final fList = await FuelRepository().getAll();
    final mList = await MaintenanceRepository().getAll();

    if (mounted) {
      setState(() {
        _services = sList.where((s) => s.machineId == widget.machine.id).toList();
        _fuels = fList.where((f) => f.machineId == widget.machine.id).toList();
        _maintenances = mList.where((m) => m.machineId == widget.machine.id).toList();
        _loading = false;
      });
    }
  }

  double get _totalWorkedHours {
    return _services.fold(0.0, (acc, s) => acc + (s.workedHours ?? 0.0));
  }

  double get _totalFuelCost {
    return _fuels.fold(0.0, (acc, f) => acc + f.totalCost);
  }

  double get _totalMaintenanceCost {
    return _maintenances.fold(0.0, (acc, m) => acc + m.cost);
  }

  double get _totalCost => _totalFuelCost + _totalMaintenanceCost;

  double get _totalFuelLiters {
    return _fuels.fold(0.0, (acc, f) => acc + f.liters);
  }

  double get _averageConsumption {
    if (_totalWorkedHours > 0 && _totalFuelLiters > 0) {
      return _totalFuelLiters / _totalWorkedHours;
    }
    return widget.machine.averageConsumption;
  }

  List<_TimelineEntry> _buildEntries() {
    final entries = <_TimelineEntry>[];

    // Cadastro inicial da máquina
    if (widget.machine.acquisitionDate != null) {
      entries.add(_TimelineEntry(
        date: widget.machine.acquisitionDate!,
        title: 'Aquisição / Cadastro da Máquina',
        subtitle: 'Cadastrada com horímetro inicial em ${widget.machine.hourMeter.toStringAsFixed(1)} h',
        cost: widget.machine.acquisitionValue > 0 ? widget.machine.acquisitionValue : null,
        icon: Icons.agriculture,
        color: AppTheme.primary,
        category: 'Cadastro',
      ));
    }

    // Serviços
    for (final s in _services) {
      entries.add(_TimelineEntry(
        date: s.startedAt,
        title: 'Serviço: ${s.jobType}',
        subtitle: '${s.customer.isNotEmpty ? "Cliente: ${s.customer} | " : ""}'
            '${s.isFinished ? "Trabalhado: ${(s.workedHours ?? 0).toStringAsFixed(1)} h" : "Em andamento"}'
            '${s.areaHectares > 0 ? " | ${s.areaHectares.toStringAsFixed(1)} ha" : ""}',
        icon: Icons.assignment_turned_in,
        color: s.isFinished ? AppTheme.leaf : const Color(0xFFC4852C),
        category: 'Operação',
      ));
    }

    // Abastecimentos
    for (final f in _fuels) {
      entries.add(_TimelineEntry(
        date: f.date,
        title: 'Abastecimento: ${f.liters.toStringAsFixed(1)} L',
        subtitle: 'Horímetro: ${f.hourMeter.toStringAsFixed(1)} h | Preço/L: R\$ ${f.pricePerLiter.toStringAsFixed(2)}',
        cost: f.totalCost,
        icon: Icons.local_gas_station,
        color: const Color(0xFF4779B5),
        category: 'Combustível',
      ));
    }

    // Manutenções
    for (final m in _maintenances) {
      entries.add(_TimelineEntry(
        date: m.date,
        title: 'Manutenção: ${m.type}',
        subtitle: '${m.description.isNotEmpty ? m.description : "Revisão"} | Horímetro: ${m.hourMeter.toStringAsFixed(1)} h\nPeças: ${m.parts.isNotEmpty ? m.parts : "Sem peças"}',
        cost: m.cost,
        icon: Icons.build_circle,
        color: const Color(0xFFCF5B51),
        category: 'Oficina',
      ));
    }

    // Ordena do mais recente para o mais antigo
    entries.sort((a, b) => b.date.compareTo(a.date));
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.machine;
    final entries = _buildEntries();

    return Scaffold(
      appBar: AppBar(
        title: Text('${m.brand} ${m.model} - Histórico'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 900),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Cartão resumo de indicadores da máquina
                      Card(
                        elevation: 2,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  m.photoPath != null && m.photoPath!.isNotEmpty
                                      ? ClipRRect(
                                          borderRadius: BorderRadius.circular(16),
                                          child: SizedBox(
                                            width: 64,
                                            height: 64,
                                            child: Image.file(
                                              File(m.photoPath!),
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, __, ___) => CircleAvatar(
                                                radius: 28,
                                                backgroundColor: AppTheme.primary.withValues(alpha: 0.12),
                                                child: const Icon(Icons.agriculture_rounded, size: 32, color: AppTheme.primary),
                                              ),
                                            ),
                                          ),
                                        )
                                      : CircleAvatar(
                                          radius: 28,
                                          backgroundColor: AppTheme.primary.withValues(alpha: 0.12),
                                          child: const Icon(Icons.agriculture_rounded, size: 32, color: AppTheme.primary),
                                        ),
                                  const SizedBox(width: 16),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(m.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                                        Text('${m.brand} ${m.model} · Ano ${m.year} · ${m.fuelType}',
                                            style: const TextStyle(color: Colors.black54)),
                                      ],
                                    ),
                                  ),
                                  Chip(
                                    label: Text(m.status.label),
                                    backgroundColor: AppTheme.primary.withValues(alpha: 0.1),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 20),
                              const Divider(),
                              const SizedBox(height: 12),
                              Wrap(
                                spacing: 20,
                                runSpacing: 14,
                                children: [
                                  _infoItem('Horímetro Atual', '${m.hourMeter.toStringAsFixed(1)} h', Icons.speed),
                                  _infoItem('Horas Trabalhadas', '${_totalWorkedHours.toStringAsFixed(1)} h', Icons.timelapse),
                                  _infoItem('Gasto Acumulado', 'R\$ ${_totalCost.toStringAsFixed(2)}', Icons.attach_money),
                                  _infoItem('Consumo Médio', '${_averageConsumption.toStringAsFixed(1)} L/h', Icons.local_gas_station),
                                  _infoItem('Serviços Realizados', '${_services.length}', Icons.assignment_turned_in_outlined),
                                  _infoItem('Revisões/Reparos', '${_maintenances.length}', Icons.build_outlined),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      // Título da Linha do Tempo
                      const Row(
                        children: [
                          Icon(Icons.timeline, color: AppTheme.primary),
                          SizedBox(width: 8),
                          Text(
                            'Linha do Tempo de Operações',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),

                      if (entries.isEmpty)
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Text('Nenhum evento registrado para esta máquina.'),
                          ),
                        )
                      else
                        ListView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: entries.length,
                          itemBuilder: (context, index) {
                            final entry = entries[index];
                            final isLast = index == entries.length - 1;

                            return IntrinsicHeight(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // Coluna de data e linha visual
                                  SizedBox(
                                    width: 80,
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: [
                                        Text(
                                          '${entry.date.day.toString().padLeft(2, '0')}/${entry.date.month.toString().padLeft(2, '0')}',
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                        ),
                                        Text(
                                          '${entry.date.year}',
                                          style: const TextStyle(fontSize: 11, color: Colors.grey),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Column(
                                    children: [
                                      CircleAvatar(
                                        radius: 14,
                                        backgroundColor: entry.color.withValues(alpha: 0.18),
                                        child: Icon(entry.icon, size: 16, color: entry.color),
                                      ),
                                      if (!isLast)
                                        Expanded(
                                          child: Container(
                                            width: 2,
                                            color: Colors.grey.shade300,
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.only(bottom: 20),
                                      child: Card(
                                        elevation: 1,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                        child: Padding(
                                          padding: const EdgeInsets.all(14),
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      entry.title,
                                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                                    ),
                                                  ),
                                                  if (entry.cost != null)
                                                    Text(
                                                      'R\$ ${entry.cost!.toStringAsFixed(2)}',
                                                      style: const TextStyle(
                                                        fontWeight: FontWeight.bold,
                                                        color: AppTheme.primary,
                                                        fontSize: 13,
                                                      ),
                                                    ),
                                                ],
                                              ),
                                              const SizedBox(height: 6),
                                              Text(
                                                entry.subtitle,
                                                style: const TextStyle(color: Colors.black87, fontSize: 12),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _infoItem(String label, String value, IconData icon) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: AppTheme.primary),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
            Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
          ],
        ),
      ],
    );
  }
}
