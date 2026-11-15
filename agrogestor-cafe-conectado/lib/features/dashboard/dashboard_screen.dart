import 'package:flutter/material.dart';
import '../../app/app_theme.dart';
import '../machines/machine.dart';
import '../machines/machine_repository.dart';
import '../services/farm_service.dart';
import '../services/service_repository.dart';
import '../services/services_screen.dart';
import '../properties/catalog_store.dart';
import '../properties/coffee_planting.dart';
import '../fuel/fuel_repository.dart';
import '../fuel/fuel_record.dart';
import '../maintenance/maintenance_repository.dart';
import '../maintenance/maintenance_record.dart';
import '../sync/farm_api_client.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    this.onNavigate,
    this.showFarmCards = false,
  });
  final ValueChanged<int>? onNavigate;
  final bool showFarmCards;
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _FarmCards extends StatelessWidget {
  const _FarmCards({required this.onNavigate});

  final ValueChanged<int> onNavigate;

  static const entries = [
    (
      12,
      'Propriedades',
      'Escolha a fazenda e o talhão para trabalhar',
      Icons.landscape_outlined,
      AppTheme.forest,
    ),
    (
      1,
      'Máquinas',
      'Consulte e cadastre seus equipamentos',
      Icons.agriculture_outlined,
      Color(0xFF385443),
    ),
    (
      7,
      'Produtos e insumos',
      'Consulte seu estoque',
      Icons.inventory_2_outlined,
      Color(0xFF62502B),
    ),
    (
      9,
      'Relatórios',
      'Acompanhe atividades e custos registrados',
      Icons.bar_chart_rounded,
      Color(0xFF315365),
    ),
  ];

  @override
  Widget build(BuildContext context) => Column(
        children: [
          for (final (destination, title, description, icon, color) in entries)
            Card(
              color: color,
              margin: const EdgeInsets.only(bottom: 10),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => onNavigate(destination),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 19,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              description,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Icon(icon, color: Colors.white, size: 31),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
}

class _DashboardScreenState extends State<DashboardScreen> {
  late Future<_DashboardStats> _stats = _loadStats();
  _DashboardPeriod _period = _DashboardPeriod.month;

  Future<_DashboardStats> _loadStats() async {
    final values = await Future.wait<Object>([
      MachineRepository().getAll(),
      ServiceRepository().getAll(),
      FuelRepository().getAll(),
      MaintenanceRepository().getAll(),
    ]);
    return _DashboardStats(
      machines: values[0] as List<Machine>,
      services: values[1] as List<FarmService>,
      fuelRecords: values[2] as List<FuelRecord>,
      maintenance: values[3] as List<MaintenanceRecord>,
    );
  }

  Future<void> _openService(FarmService service) async {
    final catalog = await CatalogStore.open();
    final plot = (await catalog.records('plots'))
        .where((item) =>
            item['id'] == service.fieldId &&
            item['property_id'] == service.propertyId)
        .firstOrNull;
    if (!mounted) return;
    await Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Serviço')),
        body: ServicesScreen(
          propertyId: service.propertyId.isEmpty ? null : service.propertyId,
          fieldId: service.fieldId.isEmpty ? null : service.fieldId,
          plotArea: plotAreaHectares(plot?['area_ha']),
          locationLabel: _serviceLocation(service),
          serviceId: service.id,
          canStart: false,
        ),
      ),
    ));
    if (mounted) setState(() => _stats = _loadStats());
  }

  bool _isInPeriod(DateTime date) {
    final now = DateTime.now();
    return switch (_period) {
      _DashboardPeriod.today =>
        date.year == now.year && date.month == now.month && date.day == now.day,
      _DashboardPeriod.week => !date.isBefore(
            DateTime(now.year, now.month, now.day - now.weekday + 1),
          ) &&
          date.isBefore(DateTime(now.year, now.month, now.day + 1)),
      _DashboardPeriod.month =>
        date.year == now.year && date.month == now.month,
      _DashboardPeriod.year => date.year == now.year,
      _DashboardPeriod.all => true,
    };
  }

  Future<void> _choosePeriod() async {
    final period = await showDialog<_DashboardPeriod>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Período do dashboard'),
        children: [
          for (final period in _DashboardPeriod.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, period),
              child: Row(
                children: [
                  Icon(
                    _period == period
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  const SizedBox(width: 12),
                  Text(period.label),
                ],
              ),
            ),
        ],
      ),
    );
    if (period != null && mounted) setState(() => _period = period);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<_DashboardStats>(
        future: _stats,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final stats = snapshot.data ?? _DashboardStats.empty;
          final openServices = stats.services
              .where((service) => !service.isFinished && !service.isCancelled)
              .toList()
            ..sort(
                (a, b) => _lastServiceDate(b).compareTo(_lastServiceDate(a)));
          final periodStats = _DashboardStats(
            machines: stats.machines,
            services:
                stats.services.where((x) => _isInPeriod(x.startedAt)).toList(),
            fuelRecords:
                stats.fuelRecords.where((x) => _isInPeriod(x.date)).toList(),
            maintenance:
                stats.maintenance.where((x) => _isInPeriod(x.date)).toList(),
          );
          return SingleChildScrollView(
            padding: AppTheme.pagePadding(context),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1200),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (widget.showFarmCards && widget.onNavigate != null) ...[
                      _FarmCards(onNavigate: widget.onNavigate!),
                      const SizedBox(height: 20),
                    ],
                    if (widget.showFarmCards && openServices.isNotEmpty)
                      _Panel(
                        title: 'Serviços abertos',
                        child: Column(
                          children: [
                            for (final service in openServices)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(service.jobType),
                                subtitle: Text([
                                  _serviceLocation(service),
                                  service.isPaused ? 'Pausado' : 'Em andamento',
                                  'Último registro: ${MaterialLocalizations.of(context).formatCompactDate(_lastServiceDate(service))}',
                                ].where((part) => part.isNotEmpty).join(' · ')),
                                trailing: IconButton(
                                  icon: const Icon(Icons.chevron_right),
                                  tooltip: service.isPaused
                                      ? 'Continuar serviço'
                                      : 'Abrir serviço',
                                  onPressed: () => _openService(service),
                                ),
                                onTap: () => _openService(service),
                                isThreeLine: true,
                              ),
                          ],
                        ),
                      ),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        const heading = Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Visão geral',
                              style: TextStyle(
                                fontSize: 28,
                                height: 1.2,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.forest,
                              ),
                            ),
                            SizedBox(height: 4),
                            Text(
                              'Resumo da sua operação rural',
                              softWrap: true,
                              style: TextStyle(color: Colors.black54),
                            ),
                          ],
                        );
                        final periodButton = OutlinedButton.icon(
                          onPressed: _choosePeriod,
                          icon: const Icon(Icons.calendar_today_outlined),
                          label: Text(
                            _period.label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                        if (constraints.maxWidth < 520) {
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              heading,
                              const SizedBox(height: 12),
                              periodButton,
                            ],
                          );
                        }
                        return Row(
                          children: [
                            const Expanded(child: heading),
                            const SizedBox(width: 12),
                            periodButton,
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 14,
                      runSpacing: 14,
                      children: [
                        _Metric(
                          label: 'Máquinas ativas',
                          value: '${stats.activeMachines}',
                          detail: '${stats.operatingMachines} em operação',
                          icon: Icons.agriculture_rounded,
                          tone: const Color(0xFF37845A),
                        ),
                        _Metric(
                          label: 'Horas trabalhadas',
                          value: '${periodStats.hours.toStringAsFixed(1)} h',
                          detail: 'Em serviços concluídos',
                          icon: Icons.schedule_rounded,
                          tone: const Color(0xFF4779B5),
                        ),
                        _Metric(
                          label: 'Operações realizadas',
                          value: '${periodStats.completedServices}',
                          detail: '${periodStats.pendingServices} em aberto',
                          icon: Icons.assignment_turned_in_outlined,
                          tone: const Color(0xFFC4852C),
                        ),
                        _Metric(
                          label: 'Custo conhecido',
                          value:
                              'R\$ ${periodStats.totalCost.toStringAsFixed(2)}',
                          detail: 'Combustível e manutenção',
                          icon: Icons.payments_outlined,
                          tone: const Color(0xFF7655A4),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    LayoutBuilder(
                      builder: (context, box) {
                        final split = box.maxWidth > 760;
                        final chart = _Panel(
                          title: 'Atividade da frota',
                          trailing: 'Últimos 7 dias',
                          child: _ActivityChart(services: stats.services),
                        );
                        final alerts = _Panel(
                          title: 'Atenção necessária',
                          trailing: 'Ver tudo',
                          onTrailingTap: _openAttentionOptions,
                          child: _Alerts(
                            maintenance: stats.maintenance,
                            machines: stats.machines,
                            services: stats.services,
                            onNavigate: widget.onNavigate,
                          ),
                        );
                        return split
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(flex: 3, child: chart),
                                  const SizedBox(width: 16),
                                  Expanded(flex: 2, child: alerts),
                                ],
                              )
                            : Column(
                                children: [
                                  chart,
                                  const SizedBox(height: 16),
                                  alerts,
                                ],
                              );
                      },
                    ),
                    const SizedBox(height: 22),
                    _Panel(
                      title: 'Operações recentes',
                      trailing: 'Ver serviços',
                      child: _RecentServices(services: stats.services),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      );

  Future<void> _openAttentionOptions() async {
    final destination = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Atenções necessárias'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 3),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.build_circle_outlined),
              title: Text('Manutenções'),
              subtitle: Text('Consultar histórico e próximas revisões'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 2),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.assignment_outlined),
              title: Text('Operações em andamento'),
              subtitle: Text('Acompanhar e concluir serviços'),
            ),
          ),
        ],
      ),
    );
    if (destination != null && mounted) widget.onNavigate?.call(destination);
  }
}

class _DashboardStats {
  const _DashboardStats({
    required this.machines,
    required this.services,
    required this.fuelRecords,
    required this.maintenance,
  });
  static const empty = _DashboardStats(
    machines: [],
    services: [],
    fuelRecords: [],
    maintenance: [],
  );
  final List<Machine> machines;
  final List<FarmService> services;
  final List<FuelRecord> fuelRecords;
  final List<MaintenanceRecord> maintenance;
  double get fuelCost =>
      fuelRecords.fold<double>(0, (sum, item) => sum + (item.totalCost ?? 0));
  double get maintenanceCost =>
      maintenance.fold<double>(0, (sum, item) => sum + (item.cost ?? 0));
  int get activeMachines =>
      machines.where((x) => x.status != MachineStatus.inativa).length;
  int get operatingMachines =>
      machines.where((x) => x.status == MachineStatus.emOperacao).length;
  int get completedServices => services.where((x) => x.isFinished).length;
  int get pendingServices =>
      services.where((x) => !x.isFinished && !x.isCancelled).length;
  double get hours =>
      services.fold<double>(0, (sum, x) => sum + (x.workedHours ?? 0));
  double get totalCost => fuelCost + maintenanceCost;
}

enum _DashboardPeriod { today, week, month, year, all }

extension on _DashboardPeriod {
  String get label => switch (this) {
        _DashboardPeriod.today => 'Hoje',
        _DashboardPeriod.week => 'Esta semana',
        _DashboardPeriod.month => 'Este mês',
        _DashboardPeriod.year => 'Este ano',
        _DashboardPeriod.all => 'Todo o período',
      };
}

class _Metric extends StatelessWidget {
  const _Metric({
    required this.label,
    required this.value,
    required this.detail,
    required this.icon,
    required this.tone,
  });
  final String label, value, detail;
  final IconData icon;
  final Color tone;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 270,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(icon, color: tone),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(label,
                          textAlign: TextAlign.end,
                          style: const TextStyle(
                              color: Colors.black54, fontSize: 12)),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.forest,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ),
        ),
      );
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    this.trailing = '',
    required this.child,
    this.onTrailingTap,
  });
  final String title, trailing;
  final Widget child;
  final VoidCallback? onTrailingTap;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  if (onTrailingTap == null)
                    Text(
                      trailing,
                      style:
                          const TextStyle(color: AppTheme.leaf, fontSize: 12),
                    )
                  else
                    TextButton(
                      onPressed: onTrailingTap,
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(48, 40),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(trailing),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              child,
            ],
          ),
        ),
      );
}

class _ActivityChart extends StatelessWidget {
  const _ActivityChart({required this.services});
  final List<FarmService> services;
  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final days = List.generate(
      7,
      (i) => DateTime(today.year, today.month, today.day - 6 + i),
    );
    final dailyHours = days
        .map(
          (day) => services
              .where(
                (service) =>
                    service.isFinished &&
                    service.startedAt.year == day.year &&
                    service.startedAt.month == day.month &&
                    service.startedAt.day == day.day,
              )
              .fold<double>(
                0,
                (sum, service) => sum + (service.workedHours ?? 0),
              ),
        )
        .toList();
    final maxHours = dailyHours.fold<double>(
      0,
      (max, value) => value > max ? value : max,
    );
    const weekdayLabels = ['Seg', 'Ter', 'Qua', 'Qui', 'Sex', 'Sáb', 'Dom'];
    return SizedBox(
      height: 178,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: List.generate(
          dailyHours.length,
          (i) => Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: maxHours == 0
                            ? .025
                            : (dailyHours[i] / maxHours).clamp(.025, 1.0),
                        widthFactor: .7,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: dailyHours[i] == maxHours && maxHours > 0
                                ? AppTheme.forest
                                : const Color(0xFF9FC8A8),
                            borderRadius: BorderRadius.circular(7),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    weekdayLabels[days[i].weekday - 1],
                    style: const TextStyle(fontSize: 11, color: Colors.black54),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Alerts extends StatelessWidget {
  const _Alerts({
    required this.maintenance,
    required this.machines,
    required this.services,
    required this.onNavigate,
  });
  final List<MaintenanceRecord> maintenance;
  final List<Machine> machines;
  final List<FarmService> services;
  final ValueChanged<int>? onNavigate;
  @override
  Widget build(BuildContext context) {
    final alerts = <_AlertData>[];
    final now = DateTime.now();
    final today = DateTime.utc(now.year, now.month, now.day);
    for (final machine in machines) {
      final history = maintenance
          .where((x) => x.machineId == machine.id)
          .toList()
        ..sort((a, b) => b.date.compareTo(a.date));
      final types = <String>{};
      for (final last in history) {
        if (!types.add(last.type.trim().toLowerCase())) continue;
        final currentMeter = services
            .where((x) => x.machineId == machine.id && x.endMeter != null)
            .fold<double>(
              machine.hourMeter,
              (current, service) =>
                  service.endMeter! > current ? service.endMeter! : current,
            );
        final meter = last.nextDueMeter;
        final remaining = meter == null ? null : meter - currentMeter;
        final due = FarmApiClient.standaloneLocalMode ? last.nextDueDate : null;
        final days = due == null
            ? null
            : DateTime.utc(due.year, due.month, due.day)
                .difference(today)
                .inDays;
        if ((remaining != null && remaining <= 25) ||
            (days != null && days <= 7)) {
          final overdue = (remaining != null && remaining <= 0) ||
              (days != null && days < 0);
          final reasons = [
            if (remaining != null && remaining <= 25)
              if (remaining <= 0)
                '${remaining.abs().toStringAsFixed(0)} h atrasada'
              else
                'em ${remaining.toStringAsFixed(0)} h',
            if (days != null && days <= 7)
              if (days < 0)
                'data vencida em ${MaterialLocalizations.of(context).formatCompactDate(due!)}'
              else if (days == 0)
                'prazo hoje'
              else
                'prazo em ${MaterialLocalizations.of(context).formatCompactDate(due!)}',
          ];
          alerts.add(
            _AlertData(
              icon:
                  overdue ? Icons.warning_amber_rounded : Icons.build_outlined,
              title: overdue ? 'Manutenção em atraso' : 'Manutenção próxima',
              subtitle:
                  '${last.machineName} · ${last.type} · ${reasons.join(' · ')}',
              color:
                  overdue ? const Color(0xFFCF5B51) : const Color(0xFFE4A341),
              destination: 3,
            ),
          );
        }
      }
      if (history.isEmpty) {
        // Alerta inteligente de óleo a cada 250h se nunca registrou revisão
        final hoursTo250 = 250 - (machine.hourMeter % 250);
        if (hoursTo250 <= 25) {
          alerts.add(
            _AlertData(
              icon: Icons.oil_barrel_outlined,
              title: 'Troca de Óleo Recomendada (250h)',
              subtitle:
                  '${machine.name} · Faltam ${hoursTo250.toStringAsFixed(0)} h para atingir o ciclo',
              color: const Color(0xFFE4A341),
              destination: 3,
            ),
          );
        }
      }

      // Máquinas paradas ou em manutenção
      if (machine.status == MachineStatus.parada) {
        alerts.add(
          _AlertData(
            icon: Icons.pause_circle_outline,
            title: 'Máquina Parada',
            subtitle: '${machine.name} está parada. Verifique disponibilidade',
            color: const Color(0xFFCF5B51),
            destination: 1,
          ),
        );
      }
    }

    for (final service in services.where(
      (x) => !x.isFinished && !x.isCancelled,
    )) {
      final hours = service.workedHours;
      alerts.add(
        _AlertData(
          icon: Icons.assignment_late_outlined,
          title: service.isPaused ? 'Serviço pausado' : 'Serviço em andamento',
          subtitle: [
            service.jobType,
            service.machineName,
            if (hours != null) '${hours.toStringAsFixed(1)} h registradas',
          ].join(' · '),
          color: const Color(0xFF4779B5),
          destination: 2,
        ),
      );
    }
    final visible = alerts.take(5).toList();
    if (visible.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Icon(Icons.check_circle_outline, color: AppTheme.leaf),
            SizedBox(width: 10),
            Expanded(child: Text('Tudo em dia. Nenhum alerta registrado.')),
          ],
        ),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < visible.length; i++) ...[
          if (i > 0) const Divider(height: 20),
          _Alert(
            icon: visible[i].icon,
            title: visible[i].title,
            subtitle: visible[i].subtitle,
            color: visible[i].color,
            onTap: onNavigate == null
                ? null
                : () => onNavigate!(visible[i].destination),
          ),
        ],
      ],
    );
  }
}

class _AlertData {
  const _AlertData({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.destination,
  });
  final IconData icon;
  final String title, subtitle;
  final Color color;
  final int destination;
}

class _Alert extends StatelessWidget {
  const _Alert({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    this.onTap,
  });
  final IconData icon;
  final String title, subtitle;
  final Color color;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: color.withValues(alpha: .12),
                  child: Icon(icon, color: color, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        subtitle,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, color: Colors.black38),
              ],
            ),
          ),
        ),
      );
}

String _serviceLocation(FarmService service) => [
      service.property,
      service.fieldName
    ].where((item) => item.isNotEmpty).join(' · ');

DateTime _lastServiceDate(FarmService service) => service.days.fold(
    service.activeSince,
    (latest, day) => day.date.isAfter(latest) ? day.date : latest);

class _RecentServices extends StatelessWidget {
  const _RecentServices({required this.services});
  final List<FarmService> services;
  @override
  Widget build(BuildContext context) {
    final recent = [...services]
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    if (recent.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Text(
          'Os serviços registrados aparecerão aqui.',
          style: TextStyle(color: Colors.black54),
        ),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < recent.take(3).length; i++) ...[
          if (i > 0) const Divider(height: 18),
          _ServiceRow(
            machine: recent[i].machineName,
            job:
                '${recent[i].jobType}${recent[i].customer.isEmpty ? '' : ' · ${recent[i].customer}'}${recent[i].fieldName.isEmpty ? '' : ' · ${recent[i].fieldName}'}',
            operator:
                recent[i].operatorName.isEmpty ? '—' : recent[i].operatorName,
            hours: recent[i].workedHours == null
                ? 'Horas não informadas'
                : '${recent[i].workedHours!.toStringAsFixed(1)} h',
            status: recent[i].isFinished
                ? 'Concluído'
                : recent[i].isCancelled
                    ? 'Cancelada'
                    : recent[i].isPaused
                        ? 'Pausado'
                        : 'Em andamento',
            color:
                recent[i].isFinished ? AppTheme.leaf : const Color(0xFFC4852C),
          ),
        ],
      ],
    );
  }
}

class _ServiceRow extends StatelessWidget {
  const _ServiceRow({
    required this.machine,
    required this.job,
    required this.operator,
    required this.hours,
    required this.status,
    required this.color,
  });
  final String machine, job, operator, hours, status;
  final Color color;
  @override
  Widget build(BuildContext context) => Row(
        children: [
          const Icon(Icons.agriculture_rounded, color: AppTheme.leaf),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(machine,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(
                  job,
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(operator,
                    textAlign: TextAlign.end,
                    style: const TextStyle(fontSize: 12)),
                Text(hours,
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600)),
                Text(status,
                    textAlign: TextAlign.end,
                    style: TextStyle(color: color, fontSize: 12)),
              ],
            ),
          ),
        ],
      );
}
