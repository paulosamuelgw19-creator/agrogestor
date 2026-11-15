import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../app/app_theme.dart';
import '../machines/machine.dart';
import '../machines/machine_repository.dart';
import '../operators/operator.dart';
import '../operators/operator_repository.dart';
import '../clients/client_record.dart';
import '../clients/client_repository.dart';
import 'farm_service.dart';
import 'local_operation_actions.dart';
import '../properties/catalog_store.dart';
import '../implements/implement_repository.dart';
import '../implements/farm_implement.dart';
import '../operations_v2/v2_store.dart';
import '../sync/farm_api_client.dart';
import 'service_repository.dart';
import '../sync/sync_status_label.dart';
import '../sync/local_write_batch.dart';
import '../licensing/write_gate.dart';
import '../products/product_record.dart';
import '../products/product_repository.dart';
import '../products/products_screen.dart' show showCoffeeProductEditor;
import '../auth/auth_service.dart';
import 'coffee_input_fields.dart';
import 'coffee_input_plan.dart';

class ServicesScreen extends StatefulWidget {
  const ServicesScreen({
    super.key,
    this.propertyId,
    this.fieldId,
    this.plotArea,
    this.locationLabel,
    this.canStart = true,
    this.serviceId,
  });
  final String? propertyId, fieldId;
  final String? locationLabel;
  final double? plotArea;
  final bool canStart;
  final String? serviceId;
  @override
  State<ServicesScreen> createState() => _ServicesScreenState();
}

class _ServicesScreenState extends State<ServicesScreen> {
  final _repo = ServiceRepository();
  List<FarmService> _items = [];
  Map<String, List<ProductUsage>> _usageByService = {};
  bool _loading = true;
  bool? _finishedFilter;
  bool get _byPlot =>
      FarmApiClient.standaloneLocalMode && widget.fieldId != null;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await _repo.getAll();
    final usage = <String, List<ProductUsage>>{};
    if (FarmApiClient.standaloneLocalMode) {
      for (final record in await ProductRepository().getUsage()) {
        if (record.serviceId.isNotEmpty) {
          (usage[record.serviceId] ??= []).add(record);
        }
      }
    }
    if (mounted) {
      setState(() {
        _items = items;
        _usageByService = usage;
        _loading = false;
      });
    }
  }

  Future<void> _copy() async {
    final prior = _items
        .where((item) =>
            item.propertyId == widget.propertyId &&
            item.fieldId.isNotEmpty &&
            item.jobType.trim().isNotEmpty &&
            item.isFinished &&
            !item.isCancelled)
        .toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final template = await showDialog<FarmService>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Copiar serviço anterior'),
        children: [
          if (prior.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('Ainda não há serviços concluídos nesta fazenda.'),
            ),
          for (final service in prior)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, service),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(service.jobType),
                subtitle: Text(
                  '${service.fieldName} · ${MaterialLocalizations.of(context).formatCompactDate(service.startedAt)}',
                ),
              ),
            ),
        ],
      ),
    );
    if (mounted && template != null) await _start(template: template);
  }

  Future<void> _start({FarmService? template}) async {
    final allMachines = await MachineRepository().getAll();
    final operators = await OperatorRepository().getAll();
    final implements =
        (await ImplementRepository().getAll()).where((i) => i.active).toList();
    final clients = await ClientRepository().getAll();
    final catalog =
        FarmApiClient.standaloneLocalMode ? await CatalogStore.open() : null;
    final properties = catalog == null
        ? <Json>[]
        : await catalog.records('properties', archived: false);
    final plots = catalog == null
        ? <Json>[]
        : await catalog.records('plots', archived: false);
    if (!mounted) return;
    final machines = allMachines.where((machine) {
      final canOperate = machine.status == MachineStatus.disponivel ||
          machine.status == MachineStatus.emOperacao;
      final alreadyInService = _items.any(
        (service) =>
            service.machineId == machine.id &&
            !service.isFinished &&
            !service.isCancelled,
      );
      return canOperate && !alreadyInService;
    }).toList();
    final chosenFarm =
        properties.where((p) => p['id'] == widget.propertyId).firstOrNull;
    final chosenPlot = plots
        .where(
          (p) =>
              p['id'] == widget.fieldId &&
              p['property_id'] == widget.propertyId,
        )
        .firstOrNull;
    if (_byPlot && (chosenFarm == null || chosenPlot == null)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Selecione um talhão ativo antes de iniciar.'),
        ),
      );
      return;
    }
    if (!_byPlot && machines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Não há máquinas disponíveis. Verifique o status e os serviços em andamento.',
          ),
        ),
      );
      return;
    }
    final products = _byPlot
        ? await ProductRepository().getProducts()
        : const <FarmProduct>[];
    if (!mounted) return;
    final result = await showDialog<FarmService>(
      context: context,
      builder: (_) => _StartServiceForm(
        machines: machines,
        operators: operators,
        clients: clients,
        localProperties: properties,
        localPlots: plots,
        implements: implements,
        chosenFarm: chosenFarm,
        chosenPlot: chosenPlot,
        savedJobs: _items.map((item) => item.jobType).toSet(),
        products: products,
        template: template,
      ),
    );
    if (result != null && mounted) {
      final repository = MachineRepository();
      final current = await repository.getAll();
      if (!mounted) return;
      final saved = await runLicensedWrite(
        context,
        () => LocalWriteBatch.run(() async {
          final previous = await _repo.getAll();
          await LocalOperationActions.validatePlannedInputs(result);
          if (FarmApiClient.standaloneLocalMode) {
            await LocalOperationActions.validateManualWorkers(result);
          }
          await _repo.saveAll([result, ...previous], previous: previous);
          if (!result.isManual) {
            await repository.saveAll(
              current
                  .map(
                    (machine) => machine.id == result.machineId
                        ? machine.copyWith(
                            status: MachineStatus.emOperacao,
                            hourMeter: FarmApiClient.standaloneLocalMode
                                ? result.startMeter
                                : null,
                          )
                        : machine,
                  )
                  .toList(),
              previous: current,
            );
          }
        }),
      );
      if (saved && mounted) await _load();
    }
  }

  Future<void> _finish(FarmService service, {bool pause = false}) async {
    final productRepository = ProductRepository();
    final stockedProducts = (await productRepository.getProducts())
        .where((product) => product.quantity > 0)
        .toList();
    if (!mounted) return;
    final result = await showDialog<_FinishServiceResult>(
      context: context,
      builder: (_) => _FinishServiceForm(
        service: service,
        products: stockedProducts,
        pause: pause,
        recordDay: _byPlot || !service.tracksMeter || service.days.isNotEmpty,
        plotArea: widget.plotArea,
      ),
    );
    if (result == null) return;
    if (FarmApiClient.standaloneLocalMode) {
      if (!mounted) return;
      final saved = await runLicensedWrite(
        context,
        () => pause
            ? LocalOperationActions.pause(service, result.day!)
            : LocalOperationActions.finish(
                result.service,
                result.usages,
                day: result.day,
              ),
      );
      if (saved && mounted) await _load();
      return;
    }
    final currentProducts = await productRepository.getProducts();
    final quantities = <String, double>{};
    for (final usage in result.usages) {
      quantities.update(
        usage.productId,
        (value) => value + usage.quantity,
        ifAbsent: () => usage.quantity,
      );
    }
    for (final entry in quantities.entries) {
      final product =
          currentProducts.where((item) => item.id == entry.key).firstOrNull;
      if (product == null || product.quantity < entry.value) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Estoque alterado ou insuficiente. Sincronize e tente finalizar novamente.',
              ),
            ),
          );
        }
        return;
      }
    }
    final existingUsage = await productRepository.getUsage();
    final repository = MachineRepository();
    final currentMachines = await repository.getAll();
    final finishedService = result.service;
    final endMeter = finishedService.endMeter;
    if (!mounted) return;
    final saved = await runLicensedWrite(
      context,
      () => LocalWriteBatch.run(() async {
        if (result.usages.isNotEmpty) {
          await productRepository.saveProducts(
            currentProducts
                .map(
                  (product) => quantities.containsKey(product.id)
                      ? product.copyWith(
                          quantity: product.quantity - quantities[product.id]!,
                        )
                      : product,
                )
                .toList(),
            previous: currentProducts,
          );
          await productRepository.saveUsage([
            ...result.usages,
            ...existingUsage,
          ], previous: existingUsage);
        }
        await _repo.saveAll(
          _items
              .map(
                (item) =>
                    item.id == finishedService.id ? finishedService : item,
              )
              .toList(),
          previous: _items,
        );
        if (endMeter != null) {
          await repository.saveAll(
            currentMachines
                .map(
                  (machine) => machine.id == finishedService.machineId
                      ? machine.copyWith(
                          hourMeter: endMeter > machine.hourMeter
                              ? endMeter
                              : machine.hourMeter,
                          status: machine.status == MachineStatus.emOperacao
                              ? MachineStatus.disponivel
                              : machine.status,
                        )
                      : machine,
                )
                .toList(),
            previous: currentMachines,
          );
        }
      }),
    );
    if (saved && mounted) await _load();
  }

  Future<void> _resume(FarmService service) async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: service.days.last.date,
      lastDate: DateTime.now(),
      helpText: 'Data de retomada',
    );
    if (date == null || !mounted) return;
    List<ServiceWorkerRate>? workers;
    if (service.isManual &&
        !DateUtils.isSameDay(date, service.days.last.date) &&
        service.manualWorkers.isNotEmpty) {
      final operators = await OperatorRepository().getAll();
      if (!mounted) return;
      workers = await showDialog<List<ServiceWorkerRate>>(
          context: context,
          builder: (_) => _ManualWorkersDialog(
                operators: operators,
                selected: service.manualWorkers,
                renewRates: true,
                canClear: false,
              ));
      if (!mounted || workers == null) return;
    }
    final saved = await runLicensedWrite(
      context,
      () => LocalOperationActions.resume(service, date, manualWorkers: workers),
    );
    if (saved && mounted) await _load();
  }

  Future<void> _delete(FarmService service) async {
    if (service.isFinished || service.isCancelled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('O historico desta operacao sera preservado.'),
        ),
      );
      return;
    }
    final text = await showDialog<String>(
      context: context,
      builder: (_) => const OperationCancellationDialog(),
    );
    if (text == null || !mounted) return;
    if (FarmApiClient.standaloneLocalMode) {
      final saved = await runLicensedWrite(
        context,
        () => LocalOperationActions.cancel(service.id, text),
      );
      if (saved && mounted) await _load();
      return;
    }
    final saved = await runLicensedWrite(
      context,
      () => LocalWriteBatch.run(() async {
        final services = await _repo.getAll();
        final current = services.where((x) => x.id == service.id).first;
        if (current.isFinished || current.isCancelled) {
          throw const FormatException(
            'A operacao ja foi encerrada. Atualize a tela.',
          );
        }
        await _repo.saveAll(
          services.map((x) => x.id == current.id ? x.cancel(text) : x).toList(),
          previous: services,
        );
        final repo = MachineRepository();
        final machines = await repo.getAll();
        await repo.saveAll(
          machines
              .map(
                (m) => m.id == current.machineId &&
                        m.status == MachineStatus.emOperacao
                    ? m.copyWith(status: MachineStatus.disponivel)
                    : m,
              )
              .toList(),
          previous: machines,
        );
      }),
    );
    if (saved && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _items
        .where(
          (item) =>
              (widget.propertyId == null ||
                  item.propertyId == widget.propertyId) &&
              (widget.fieldId == null || item.fieldId == widget.fieldId) &&
              (widget.serviceId == null || item.id == widget.serviceId),
        )
        .where(
          (item) =>
              _finishedFilter == null ||
              item.isFinished == _finishedFilter && !item.isCancelled,
        )
        .toList();
    return Scaffold(
      floatingActionButton: !widget.canStart
          ? null
          : FloatingActionButton.extended(
              onPressed: _start,
              icon: const Icon(Icons.play_arrow_rounded),
              label: const Text(
                FarmApiClient.standaloneLocalMode
                    ? 'Iniciar operação'
                    : 'Iniciar serviço',
              ),
            ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: Padding(
              padding: AppTheme.pagePadding(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    FarmApiClient.standaloneLocalMode
                        ? 'Operações'
                        : 'Serviços',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.forest,
                    ),
                  ),
                  const SizedBox(height: 5),
                  const Text(
                    'Registre operações e acompanhe horas trabalhadas.',
                    style: TextStyle(color: Colors.black54),
                  ),
                  if (widget.locationLabel != null)
                    Text(
                      widget.locationLabel!,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  if (_byPlot && widget.canStart && !_loading)
                    TextButton.icon(
                      onPressed: _copy,
                      icon: const Icon(Icons.copy_outlined),
                      label: const Text('Copiar serviço anterior'),
                    ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('Todos'),
                        selected: _finishedFilter == null,
                        onSelected: (_) =>
                            setState(() => _finishedFilter = null),
                      ),
                      ChoiceChip(
                        label: const Text('Em andamento'),
                        selected: _finishedFilter == false,
                        onSelected: (_) =>
                            setState(() => _finishedFilter = false),
                      ),
                      ChoiceChip(
                        label: const Text('Concluídos'),
                        selected: _finishedFilter == true,
                        onSelected: (_) =>
                            setState(() => _finishedFilter = true),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator())
                        : visible.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.assignment_outlined,
                                      size: 48,
                                      color: AppTheme.leaf,
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      _items.isEmpty
                                          ? 'Nenhum serviço registrado'
                                          : 'Nenhum serviço neste filtro',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    if (widget.canStart)
                                      OutlinedButton.icon(
                                        onPressed: _start,
                                        icon: const Icon(Icons.play_arrow),
                                        label: const Text(
                                          FarmApiClient.standaloneLocalMode
                                              ? 'Iniciar operação'
                                              : 'Iniciar serviço',
                                        ),
                                      ),
                                  ],
                                ),
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.only(bottom: 88),
                                itemCount: visible.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (context, index) {
                                  final item = visible[index];
                                  final tone = item.isFinished
                                      ? AppTheme.leaf
                                      : const Color(0xFFC4852C);
                                  return Card(
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        18,
                                        10,
                                        8,
                                        10,
                                      ),
                                      child: Row(
                                        children: [
                                          CircleAvatar(
                                            backgroundColor: tone.withValues(
                                              alpha: .12,
                                            ),
                                            foregroundColor: tone,
                                            child: Icon(
                                              item.isFinished
                                                  ? Icons.check
                                                  : Icons.play_arrow,
                                            ),
                                          ),
                                          const SizedBox(width: 14),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        item.jobType,
                                                        style: const TextStyle(
                                                          fontWeight:
                                                              FontWeight.w700,
                                                          fontSize: 16,
                                                        ),
                                                      ),
                                                    ),
                                                    SyncStatusLabel(
                                                      module: 'services',
                                                      recordId: item.id,
                                                    ),
                                                  ],
                                                ),
                                                Text(
                                                  item.isManual
                                                      ? 'Serviço manual · ${item.people} ${item.people == 1 ? 'pessoa' : 'pessoas'}'
                                                      : '${item.machineName}${item.operatorName.isEmpty ? '' : ' · ${item.operatorName}'}',
                                                  style: const TextStyle(
                                                    color: Colors.black54,
                                                  ),
                                                ),
                                                Text(
                                                  '${item.customer.isEmpty ? 'Sem cliente' : item.customer}${item.property.isEmpty ? '' : ' · ${item.property}'}${item.fieldName.isEmpty ? '' : ' · ${item.fieldName}'}',
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    color: Colors.black54,
                                                  ),
                                                ),
                                                const SizedBox(height: 5),
                                                if (_byPlot && item.isPaused)
                                                  const AppNotice(
                                                      message:
                                                          'Serviço pausado')
                                                else
                                                  Text(
                                                    _status(item),
                                                    style: const TextStyle(
                                                      fontSize: 12,
                                                    ),
                                                  ),
                                                for (final day in item.days)
                                                  Text(_daySummary(day)),
                                                if (item.applicationNumber
                                                    case final int number)
                                                  Text(
                                                      'Parcela ou aplicação $number'),
                                                if (item.workSection.isNotEmpty)
                                                  Text(
                                                      'Trecho: ${item.workSection}'),
                                                if (item
                                                    .workObjective.isNotEmpty)
                                                  Text(
                                                      'Objetivo: ${item.workObjective}'),
                                                if (item.plannedInputs
                                                        .isNotEmpty ||
                                                    item.appliedSprayInputs
                                                        .isNotEmpty ||
                                                    (_usageByService[item.id]
                                                            ?.isNotEmpty ??
                                                        false))
                                                  TextButton(
                                                    onPressed: () =>
                                                        _showPlannedInputs(
                                                            item),
                                                    child: Text(
                                                      (_usageByService[item.id]
                                                                  ?.isNotEmpty ??
                                                              false)
                                                          ? 'Ver insumos usados'
                                                          : item.appliedSprayInputs
                                                                  .isEmpty
                                                              ? 'Ver insumos planejados'
                                                              : 'Ver insumos e cargas',
                                                    ),
                                                  ),
                                                if (item.plotCompleted)
                                                  const Text(
                                                      'Talhão concluído'),
                                              ],
                                            ),
                                          ),
                                          if (!item.isFinished &&
                                              !item.isCancelled)
                                            if (item.isPaused)
                                              TextButton(
                                                onPressed: () => _resume(item),
                                                child: const Text('Continuar'),
                                              )
                                            else
                                              Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  TextButton(
                                                    onPressed: () =>
                                                        _finish(item),
                                                    child:
                                                        const Text('Finalizar'),
                                                  ),
                                                  if (_byPlot)
                                                    TextButton(
                                                      onPressed: () => _finish(
                                                        item,
                                                        pause: true,
                                                      ),
                                                      child:
                                                          const Text('Pausar'),
                                                    ),
                                                ],
                                              ),
                                          PopupMenuButton<String>(
                                            onSelected: (_) => _delete(item),
                                            itemBuilder: (_) => const [
                                              PopupMenuItem(
                                                value: 'delete',
                                                child: Text(
                                                  'Cancelar / preservar histórico',
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _status(FarmService item) {
    if (item.isCancelled) return 'Cancelada: ${item.cancellationReason}';
    if (item.isFinished) {
      if (item.isManual) {
        return 'Concluída em ${MaterialLocalizations.of(context).formatCompactDate(item.endedAt!)}';
      }
      return '${item.workedHours?.toStringAsFixed(1) ?? 'Não informado'} h trabalhadas · Área: ${item.areaHectares?.toStringAsFixed(2) ?? 'Não informada'} · Consumo: ${item.fuelLiters?.toStringAsFixed(1) ?? 'Não informado'} L';
    }
    if (item.isPaused) return 'Pausada';
    if (!item.tracksMeter) {
      return 'Em andamento · ${MaterialLocalizations.of(context).formatCompactDate(item.startedAt)}';
    }
    return 'Início ${item.activeStartMeter!.toStringAsFixed(1)} h · ${_date(item.activeSince)}';
  }

  String _daySummary(ServiceDay day) => [
        MaterialLocalizations.of(context).formatCompactDate(day.date),
        if (day.hours != null)
          'Horímetro ${day.startMeter!.toStringAsFixed(1)} a ${day.endMeter!.toStringAsFixed(1)} · ${day.hours!.toStringAsFixed(1)} h',
        if (day.areaHectares != null)
          '${day.areaHectares!.toStringAsFixed(2)} ha',
        if (day.fuelLiters != null)
          '${day.fuelLiters!.toStringAsFixed(1)} L de combustível',
        for (final person in day.manualWorkers)
          '${person.workerName} (${_dailyRateLabel(person.dailyRateCents)})',
      ].join(' · ');

  Future<void> _showPlannedInputs(FarmService service) => showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(service.appliedSprayInputs.isEmpty
              ? 'Insumos planejados'
              : 'Insumos e cargas'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${service.property} · ${service.fieldName}'),
                if (service.plannedInputs.isNotEmpty)
                  const Text('Quantidades registradas no planejamento.'),
                for (final plan in service.plannedInputs) ...[
                  const Divider(),
                  Text(coffeeInputSummary(plan)),
                ],
                if (_usageByService[service.id]
                    case final List<ProductUsage> usages) ...[
                  const Divider(),
                  Text('Insumos efetivamente usados',
                      style: Theme.of(dialogContext).textTheme.titleMedium),
                  for (final use in usages)
                    ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(use.productName,
                            style: AppTheme.nameStyle(dialogContext)),
                        subtitle: Text(
                            '${use.quantity.toString().replaceAll('.', ',')} ${use.unit}')),
                ],
                if (service.appliedSprayInputs.isNotEmpty) ...[
                  const Divider(),
                  Text('Cargas aplicadas',
                      style: Theme.of(dialogContext).textTheme.titleMedium),
                  for (final load in service.appliedSprayInputs) ...[
                    const SizedBox(height: 8),
                    Text(coffeeInputSummary(load, applied: true)),
                  ],
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Fechar'),
            ),
          ],
        ),
      );

  String _date(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
}

class _StartServiceForm extends StatefulWidget {
  const _StartServiceForm({
    required this.machines,
    required this.operators,
    required this.clients,
    this.localProperties = const [],
    this.localPlots = const [],
    this.implements = const [],
    this.chosenFarm,
    this.chosenPlot,
    this.savedJobs = const {},
    this.products = const [],
    this.template,
  });
  final List<Machine> machines;
  final List<Operator> operators;
  final List<RuralClient> clients;
  final List<Json> localProperties, localPlots;
  final List<FarmImplement> implements;
  final Json? chosenFarm, chosenPlot;
  final Set<String> savedJobs;
  final List<FarmProduct> products;
  final FarmService? template;
  @override
  State<_StartServiceForm> createState() => _StartServiceFormState();
}

class _StartServiceFormState extends State<_StartServiceForm> {
  final _key = GlobalKey<FormState>();
  bool _submitted = false;
  late final _meter = TextEditingController(
    text: widget.machines.firstOrNull?.hourMeter.toStringAsFixed(1) ?? '',
  );
  late final _job =
      TextEditingController(text: widget.template?.jobType ?? 'Plantio');
  final _people = TextEditingController(text: '1');
  final _applicationNumber = TextEditingController();
  final _workSection = TextEditingController();
  final _workObjective = TextEditingController();
  late Machine? _machine = widget.machines.firstOrNull;
  late bool _manual = _machine == null;
  bool _newJob = false;
  bool _withoutMeter = false;
  List<ServiceWorkerRate> _manualWorkers = [];
  late List<FarmProduct> _products = [...widget.products];
  late List<CoffeeInputPlan> _plannedInputs = [
    for (final plan
        in widget.template?.plannedInputs ?? const <CoffeeInputPlan>[])
      CoffeeInputPlan(
        productId: plan.productId,
        productName: plan.productName,
        stockUnit: plan.stockUnit,
        kind: plan.kind,
        quantity: 0,
        inputUnit: plan.inputUnit,
      ),
  ];
  bool _copyConfirmed = false;
  String? _copyError;
  DateTime _startedAt = DateTime.now();
  Operator? _operator;
  FarmImplement? _implement;
  RuralClient? _client;
  RuralProperty? _property;
  RuralField? _field;
  late Json? _localProperty = widget.chosenFarm;
  late Json? _localPlot = widget.chosenPlot;
  bool get _scoped => widget.chosenPlot != null;
  bool get _application =>
      RegExp(r'aplica|pulveriza|foliar|herbicida|desseca|aduba|calagem',
              caseSensitive: false)
          .hasMatch(_job.text);
  @override
  void dispose() {
    _meter.dispose();
    _job.dispose();
    _people.dispose();
    _applicationNumber.dispose();
    _workSection.dispose();
    _workObjective.dispose();
    super.dispose();
  }

  void _submit() {
    if (_submitted || !_key.currentState!.validate()) return;
    if (widget.template != null &&
        (!_copyConfirmed ||
            _plannedInputs.any((plan) => plan.validationError != null))) {
      setState(() => _copyError =
          'Revise ou remova cada insumo copiado e confirme o novo planejamento.');
      return;
    }
    _submitted = true;
    Navigator.pop(
      context,
      FarmService(
        id: const Uuid().v4(),
        machineId: _manual ? '' : _machine!.id,
        machineName: _manual
            ? ''
            : '${_machine!.name} · ${_machine!.brand} ${_machine!.model}',
        operatorName: _manual ? '' : _operator?.name ?? '',
        customer: _client?.name ?? '',
        clientId: _client?.id ?? '',
        property: _localProperty?['name'] as String? ?? _property?.name ?? '',
        propertyId: _localProperty?['id'] as String? ?? _property?.id ?? '',
        fieldName: _localPlot?['name'] as String? ?? _field?.name ?? '',
        fieldId: _localPlot?['id'] as String? ?? _field?.id ?? '',
        jobType: _job.text.trim(),
        applicationNumber: int.tryParse(_applicationNumber.text.trim()),
        workSection: _workSection.text.trim(),
        workObjective: _workObjective.text.trim(),
        implementId: _manual ? '' : _implement?.id ?? '',
        implementName: _manual ? '' : _implement?.name ?? '',
        startedAt: _startedAt,
        startMeter: _manual || _withoutMeter
            ? null
            : double.parse(_meter.text.replaceAll(',', '.')),
        isManual: _manual,
        withoutMeter: !_manual && _withoutMeter,
        people: _manual
            ? (_manualWorkers.isEmpty
                ? int.parse(_people.text.trim())
                : _manualWorkers.length)
            : null,
        manualWorkers: _manual ? _manualWorkers : const [],
        plannedInputs: _plannedInputs,
      ),
    );
  }

  Future<void> _pickWorkers() async {
    final chosen = await showDialog<List<ServiceWorkerRate>>(
        context: context,
        builder: (_) => _ManualWorkersDialog(
            operators: widget.operators, selected: _manualWorkers));
    if (mounted && chosen != null) setState(() => _manualWorkers = chosen);
  }

  Future<FarmProduct?> _createProduct(BuildContext pickerContext) async {
    final product = await showCoffeeProductEditor(pickerContext,
        propertyId: _localProperty?['id'] as String?);
    if (mounted && product != null) {
      setState(() => _products = [
            ..._products.where((item) => item.id != product.id),
            product
          ]);
    }
    return product;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text(
          FarmApiClient.standaloneLocalMode
              ? 'Iniciar operação'
              : 'Iniciar serviço',
        ),
        content: SizedBox(
          width: AppTheme.dialogWidth(context, maxWidth: 450),
          child: Form(
            key: _key,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_scoped) ...[
                    Text(
                      '${widget.chosenFarm!['name']} · ${widget.chosenPlot!['name']}',
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<bool>(
                      isExpanded: true,
                      initialValue: _manual,
                      decoration:
                          const InputDecoration(labelText: 'Modalidade'),
                      items: [
                        if (widget.machines.isNotEmpty)
                          const DropdownMenuItem(
                            value: false,
                            child: Text('Serviço tratorizado'),
                          ),
                        const DropdownMenuItem(
                          value: true,
                          child: Text('Serviço manual'),
                        ),
                      ],
                      onChanged: (value) =>
                          setState(() => _manual = value ?? _manual),
                    ),
                    const SizedBox(height: 10),
                    _ServiceDateField(
                      label: 'Data de início',
                      date: _startedAt,
                      firstDate: DateTime(1900),
                      onChanged: (date) => setState(() => _startedAt = date),
                    ),
                    if (_manual &&
                        widget.operators.any((worker) => worker.active)) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                          onPressed: _pickWorkers,
                          icon: const Icon(Icons.groups_outlined),
                          label: const Text('Selecionar pessoas')),
                      for (final worker in _manualWorkers)
                        ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(worker.workerName,
                                style: AppTheme.nameStyle(context)),
                            subtitle:
                                Text(_dailyRateLabel(worker.dailyRateCents))),
                    ],
                    if (_manual && _manualWorkers.isEmpty)
                      TextFormField(
                        controller: _people,
                        decoration: const InputDecoration(labelText: 'Pessoas'),
                        keyboardType: TextInputType.number,
                        validator: (v) =>
                            (int.tryParse(v?.trim() ?? '') ?? 0) < 1
                                ? 'Informe a quantidade de pessoas.'
                                : null,
                      ),
                  ],
                  if (!_manual)
                    DropdownButtonFormField<Machine>(
                      isExpanded: true,
                      initialValue: _machine,
                      decoration: InputDecoration(
                          labelText: _scoped ? 'Trator' : 'Máquina'),
                      items: widget.machines
                          .map(
                            (item) => DropdownMenuItem(
                              value: item,
                              child: Text(
                                '${item.name} · ${item.brand} ${item.model}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) => setState(() {
                        _machine = value ?? _machine;
                        _meter.text = _machine!.hourMeter.toStringAsFixed(1);
                      }),
                    ),
                  if (!_manual && widget.implements.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<FarmImplement>(
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Implemento (opcional)',
                      ),
                      items: widget.implements
                          .map(
                            (i) => DropdownMenuItem(
                              value: i,
                              child: Text(
                                i.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (i) => _implement = i,
                    ),
                  ],
                  if (!_manual && widget.operators.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<Operator>(
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Operador (opcional)',
                      ),
                      items: widget.operators
                          .where((item) => item.active)
                          .map(
                            (item) => DropdownMenuItem(
                              value: item,
                              child: Text(item.name),
                            ),
                          )
                          .toList(),
                      onChanged: (value) => _operator = value,
                    ),
                  ],
                  const SizedBox(height: 10),
                  if (_scoped && !_newJob)
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: _job.text,
                      decoration: const InputDecoration(
                        labelText: 'Tipo de serviço',
                      ),
                      items: {
                        'Plantio',
                        'Adubação',
                        'Aplicação foliar',
                        'Aplicação de herbicida',
                        'Correção de solo',
                        'Calagem',
                        'Roçada',
                        'Capina',
                        'Dessecação',
                        ...widget.savedJobs,
                        _job.text,
                      }
                          .map(
                            (name) => DropdownMenuItem(
                              value: name,
                              child: Text(
                                name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value != null) setState(() => _job.text = value);
                      },
                    ),
                  if (!_scoped || _newJob)
                    TextFormField(
                      controller: _job,
                      decoration: const InputDecoration(
                        labelText: 'Tipo de serviço',
                      ),
                      validator: _required,
                      onChanged: (_) => setState(() {}),
                    ),
                  if (_scoped)
                    TextButton.icon(
                      onPressed: () => setState(() {
                        _newJob = !_newJob;
                        _job.text = _newJob ? '' : 'Plantio';
                      }),
                      icon: Icon(_newJob ? Icons.list : Icons.add),
                      label: Text(
                        _newJob
                            ? 'Escolher tipo existente'
                            : 'Adicionar tipo de serviço',
                      ),
                    ),
                  const SizedBox(height: 10),
                  if (_scoped && !_manual)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Máquina sem horímetro'),
                      value: _withoutMeter,
                      onChanged: (value) =>
                          setState(() => _withoutMeter = value ?? false),
                    ),
                  if (!_manual && !_withoutMeter)
                    TextFormField(
                      controller: _meter,
                      decoration: const InputDecoration(
                        labelText: 'Horímetro inicial',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      validator: _number,
                    ),
                  const SizedBox(height: 10),
                  if (FarmApiClient.standaloneLocalMode && !_scoped) ...[
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Fazenda'),
                      items: widget.localProperties
                          .map(
                            (p) => DropdownMenuItem(
                              value: p['id'] as String,
                              child: Text(
                                p['name'] as String,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      validator: (v) => v == null
                          ? 'Cadastre e selecione uma fazenda.'
                          : null,
                      onChanged: (v) => setState(() {
                        _localProperty = widget.localProperties.firstWhere(
                          (p) => p['id'] == v,
                        );
                        _localPlot = null;
                      }),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      key: ValueKey(_localProperty?['id']),
                      decoration: const InputDecoration(labelText: 'Talhão'),
                      items: widget.localPlots
                          .where(
                              (p) => p['property_id'] == _localProperty?['id'])
                          .map(
                            (p) => DropdownMenuItem(
                              value: p['id'] as String,
                              child: Text(
                                p['name'] as String,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      validator: (v) =>
                          v == null ? 'Cadastre e selecione um talhão.' : null,
                      onChanged: (v) =>
                          _localPlot = widget.localPlots.firstWhere(
                        (p) => p['id'] == v,
                      ),
                    ),
                  ],
                  if (!FarmApiClient.standaloneLocalMode &&
                      widget.clients.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<RuralClient?>(
                      initialValue: _client,
                      decoration: const InputDecoration(
                        labelText: 'Cliente (opcional)',
                      ),
                      items: [
                        const DropdownMenuItem<RuralClient?>(
                          value: null,
                          child: Text('Sem cliente'),
                        ),
                        ...widget.clients.map(
                          (client) => DropdownMenuItem<RuralClient?>(
                            value: client,
                            child: Text(client.name),
                          ),
                        ),
                      ],
                      onChanged: (value) => setState(() {
                        _client = value;
                        _property = null;
                        _field = null;
                      }),
                    ),
                  ],
                  if (_client != null && _client!.properties.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<RuralProperty?>(
                      initialValue: _property,
                      decoration: const InputDecoration(
                        labelText: 'Propriedade (opcional)',
                      ),
                      items: [
                        const DropdownMenuItem<RuralProperty?>(
                          value: null,
                          child: Text('Sem propriedade'),
                        ),
                        ..._client!.properties.map(
                          (property) => DropdownMenuItem<RuralProperty?>(
                            value: property,
                            child: Text(property.name),
                          ),
                        ),
                      ],
                      onChanged: (value) => setState(() {
                        _property = value;
                        _field = null;
                      }),
                    ),
                  ],
                  if (_property != null && _property!.fields.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<RuralField?>(
                      initialValue: _field,
                      decoration: const InputDecoration(
                        labelText: 'Talhão (opcional)',
                      ),
                      items: [
                        const DropdownMenuItem<RuralField?>(
                          value: null,
                          child: Text('Sem talhão'),
                        ),
                        ..._property!.fields.map(
                          (field) => DropdownMenuItem<RuralField?>(
                            value: field,
                            child: Text(field.name),
                          ),
                        ),
                      ],
                      onChanged: (value) => setState(() => _field = value),
                    ),
                  ],
                  if (_scoped) ...[
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _applicationNumber,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Nº da parcela ou aplicação (opcional)',
                      ),
                      validator: (text) {
                        final value = (text ?? '').trim();
                        if (value.isEmpty) return null;
                        final number = int.tryParse(value);
                        return number == null || number < 1 || number > 9999
                            ? 'Informe um número de 1 a 9999.'
                            : null;
                      },
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _workSection,
                      maxLength: 120,
                      decoration: const InputDecoration(
                        labelText: 'Trecho atendido (opcional)',
                        hintText: 'Ex.: rua ou linha',
                      ),
                    ),
                    TextFormField(
                      controller: _workObjective,
                      maxLength: 240,
                      decoration: const InputDecoration(
                        labelText: 'Objetivo do serviço (opcional)',
                      ),
                    ),
                    const SizedBox(height: 10),
                    CoffeeInputPlanning(
                      products: _products,
                      plot: widget.chosenPlot!,
                      plans: _plannedInputs,
                      application: _application,
                      createProduct: _createProduct,
                      onChanged: (plans) => setState(() {
                        _plannedInputs = plans;
                        _copyConfirmed = false;
                        _copyError = null;
                      }),
                    ),
                    if (widget.template != null)
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                            'Conferi o planejamento para este talhão'),
                        value: _copyConfirmed,
                        onChanged: (value) => setState(() {
                          _copyConfirmed = value ?? false;
                          _copyError = null;
                        }),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          if (_copyError case final String message)
            Text(message,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            onPressed: _submit,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Iniciar'),
          ),
        ],
      );
  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Preencha este campo' : null;
  String? _number(String? value) {
    final n = double.tryParse((value ?? '').replaceAll(',', '.'));
    return n == null || !n.isFinite || n < _machine!.hourMeter
        ? 'O horímetro deve ser pelo menos ${_machine!.hourMeter.toStringAsFixed(1)} h'
        : null;
  }
}

String _dailyRateLabel(int? cents) => cents == null
    ? 'Diária não informada'
    : 'R\$ ${(cents / 100).toStringAsFixed(2).replaceAll('.', ',')}';

int? _parseDailyRate(String input) {
  final parts = RegExp(r'^(\d+)(?:[,.](\d{1,2}))?$').firstMatch(input.trim());
  if (parts == null) return null;
  final whole = int.tryParse(parts.group(1)!);
  if (whole == null || whole > 10000000000) return null;
  final cents =
      whole * 100 + int.parse((parts.group(2) ?? '').padRight(2, '0'));
  return cents <= 1000000000000 ? cents : null;
}

class _ManualWorkersDialog extends StatefulWidget {
  const _ManualWorkersDialog(
      {required this.operators,
      required this.selected,
      this.renewRates = false,
      this.canClear = true});

  final List<Operator> operators;
  final List<ServiceWorkerRate> selected;
  final bool renewRates, canClear;

  @override
  State<_ManualWorkersDialog> createState() => _ManualWorkersDialogState();
}

class _ManualWorkersDialogState extends State<_ManualWorkersDialog> {
  final _form = GlobalKey<FormState>();
  late final Map<String, ServiceWorkerRate> _workers = {
    for (final worker in widget.selected) worker.workerId: worker,
    for (final operator in widget.operators)
      if (operator.active ||
          widget.selected.any((worker) => worker.workerId == operator.id))
        operator.id: ServiceWorkerRate(
            workerId: operator.id,
            workerName: operator.name,
            dailyRateCents: operator.dailyRateCents),
  };
  late final _selected =
      widget.selected.map((worker) => worker.workerId).toSet();
  final _rates = <String, TextEditingController>{};

  TextEditingController _rate(ServiceWorkerRate worker) =>
      _rates.putIfAbsent(worker.workerId, () {
        final existing = widget.selected
            .where((item) => item.workerId == worker.workerId)
            .firstOrNull;
        final cents = existing == null || widget.renewRates
            ? worker.dailyRateCents
            : existing.dailyRateCents;
        return TextEditingController(
            text: cents == null
                ? ''
                : (cents / 100).toStringAsFixed(2).replaceAll('.', ','));
      });

  @override
  void dispose() {
    for (final controller in _rates.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _confirm() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(context, [
      for (final worker in _workers.values
          .where((person) => _selected.contains(person.workerId)))
        ServiceWorkerRate(
            workerId: worker.workerId,
            workerName: worker.workerName,
            dailyRateCents: _parseDailyRate(_rate(worker).text)),
    ]);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Selecionar pessoas'),
        content: SizedBox(
            width: AppTheme.dialogWidth(context, maxWidth: 460),
            child: Form(
                key: _form,
                child: SingleChildScrollView(
                    child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final worker in _workers.values) ...[
                      CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(worker.workerName,
                              style: AppTheme.nameStyle(context)),
                          value: _selected.contains(worker.workerId),
                          onChanged: (value) => setState(() {
                                if (value == true) {
                                  _selected.add(worker.workerId);
                                } else {
                                  _selected.remove(worker.workerId);
                                }
                              })),
                      if (_selected.contains(worker.workerId))
                        TextFormField(
                            key: ValueKey(worker.workerId),
                            controller: _rate(worker),
                            decoration: const InputDecoration(
                                labelText: 'Diária (R\$)'),
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            validator: (text) => (text ?? '').trim().isEmpty ||
                                    _parseDailyRate(text!) != null
                                ? null
                                : 'Informe um valor com até duas casas decimais.'),
                    ],
                  ],
                )))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed:
                  _selected.isEmpty && !widget.canClear ? null : _confirm,
              child: const Text('Confirmar pessoas')),
        ],
      );
}

class _FinishServiceResult {
  const _FinishServiceResult(this.service, this.usages, this.day);
  final FarmService service;
  final List<ProductUsage> usages;
  final ServiceDay? day;
}

class _ServiceDateField extends StatelessWidget {
  const _ServiceDateField({
    required this.label,
    required this.date,
    required this.firstDate,
    required this.onChanged,
  });
  final String label;
  final DateTime date, firstDate;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle:
            Text(MaterialLocalizations.of(context).formatCompactDate(date)),
        trailing: const Icon(Icons.calendar_today_outlined),
        onTap: () async {
          final selected = await showDatePicker(
            context: context,
            initialDate: date,
            firstDate: firstDate,
            lastDate: DateTime.now(),
            helpText: label,
          );
          if (selected != null && context.mounted) onChanged(selected);
        },
      );
}

class _ProductConsumptionEntry {
  _ProductConsumptionEntry(this.product, {double? plannedQuantity})
      : quantity = TextEditingController(text: plannedQuantity?.toString());
  FarmProduct product;
  final TextEditingController quantity;
  bool manuallyEdited = false;
}

class _FinishServiceForm extends StatefulWidget {
  const _FinishServiceForm({
    required this.service,
    required this.products,
    required this.pause,
    required this.recordDay,
    this.plotArea,
  });
  final FarmService service;
  final List<FarmProduct> products;
  final bool pause, recordDay;
  final double? plotArea;
  @override
  State<_FinishServiceForm> createState() => _FinishServiceFormState();
}

class _FinishServiceFormState extends State<_FinishServiceForm> {
  final _key = GlobalKey<FormState>();
  bool _submitted = false;
  final _end = TextEditingController();
  final _fuel = TextEditingController();
  final _area = TextEditingController();
  final _notes = TextEditingController();
  final List<_ProductConsumptionEntry> _consumptions = [];
  final _plannedTotals = <String, double>{};
  List<CoffeeInputPlan> _appliedSprayInputs = [];
  Map<String, double> _appliedTotals = {};
  String? _appliedError;
  DateTime _day = DateTime.now();
  bool _wholePlot = false;
  bool _plansNeedReview = false;

  double? get _remainingArea {
    final area = widget.plotArea;
    if (area == null ||
        widget.service.days.any((day) => day.areaHectares == null)) {
      return null;
    }
    final worked = widget.service.days.fold<double>(
      0,
      (sum, day) => sum + day.areaHectares!,
    );
    return (area - worked).clamp(0.0, area).toDouble();
  }

  @override
  void initState() {
    super.initState();
    _area.addListener(_refresh);
    _fuel.addListener(_refresh);
    if (!widget.pause) _fillPlannedConsumption();
  }

  void _fillPlannedConsumption() {
    final byProduct = <String, List<CoffeeInputPlan>>{};
    for (final plan in widget.service.plannedInputs) {
      (byProduct[plan.productId] ??= []).add(plan);
    }
    for (final entry in byProduct.entries) {
      final product =
          widget.products.where((p) => p.id == entry.key).firstOrNull;
      final quantities = <double>[];
      var complete = product != null;
      for (final plan in entry.value) {
        final quantity = plan.quantityInStockUnit;
        if (quantity == null || product?.unit != plan.stockUnit) {
          complete = false;
          break;
        }
        quantities.add(quantity);
      }
      final total = LocalOperationActions.sumStockQuantities(quantities);
      if (!complete || !total.isFinite || total <= 0) {
        _plansNeedReview = true;
        continue;
      }
      _consumptions.add(
          _ProductConsumptionEntry(product!, plannedQuantity: total)
            ..quantity.addListener(_refresh));
      _plannedTotals[product.id] = total;
    }
  }

  void _updateAppliedSpray(List<CoffeeInputPlan> inputs) {
    final byProduct = <String, List<double>>{};
    for (final input in inputs) {
      final quantity = input.quantityInStockUnit;
      if (quantity != null) {
        (byProduct[input.productId] ??= []).add(quantity);
      }
    }
    final totals = byProduct.map((id, quantities) =>
        MapEntry(id, LocalOperationActions.sumStockQuantities(quantities)));
    for (final id in {..._appliedTotals.keys, ...totals.keys}) {
      if (totals[id] == _appliedTotals[id]) continue;
      final existing =
          _consumptions.where((item) => item.product.id == id).firstOrNull;
      if (existing?.manuallyEdited == true) continue;
      final quantity = totals[id] ?? _plannedTotals[id];
      if (existing == null) {
        if (quantity != null) {
          final product = widget.products.firstWhere((item) => item.id == id);
          _consumptions.add(
              _ProductConsumptionEntry(product, plannedQuantity: quantity)
                ..quantity.addListener(_refresh));
        }
      } else if (quantity == null) {
        _consumptions.remove(existing);
        _disposeConsumption(existing);
      } else {
        existing.quantity.text = quantity.toString();
      }
    }
    setState(() {
      _appliedSprayInputs = inputs;
      _appliedTotals = totals;
      _appliedError = null;
    });
  }

  void _disposeConsumption(_ProductConsumptionEntry entry) {
    WidgetsBinding.instance
        .addPostFrameCallback((_) => entry.quantity.dispose());
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _end.dispose();
    _fuel.dispose();
    _area.dispose();
    _notes.dispose();
    for (final entry in _consumptions) {
      entry.quantity.dispose();
    }
    super.dispose();
  }

  double? _parse(String value) {
    final n = double.tryParse(value.trim().replaceAll(',', '.'));
    return n != null && n.isFinite ? n : null;
  }

  void _submit() {
    if (_submitted || !_key.currentState!.validate()) return;
    for (final entry in _appliedTotals.entries) {
      final confirmed = _consumptions
          .where((item) => item.product.id == entry.key)
          .firstOrNull;
      final quantity =
          confirmed == null ? null : _parse(confirmed.quantity.text);
      if (quantity == null ||
          LocalOperationActions.remainingStock(quantity, entry.value) == null) {
        final product =
            widget.products.firstWhere((item) => item.id == entry.key);
        setState(() => _appliedError =
            'Inclua no consumo de ${product.name} pelo menos ${entry.value} ${product.unit}, o total das cargas aplicadas.');
        return;
      }
    }
    _submitted = true;
    final area = _wholePlot && _remainingArea != null
        ? _remainingArea
        : _parse(_area.text);
    final day = widget.recordDay
        ? ServiceDay(
            date: DateUtils.dateOnly(_day),
            startMeter: widget.service.activeStartMeter,
            endMeter: _parse(_end.text),
            fuelLiters: _parse(_fuel.text),
            areaHectares: area,
          )
        : null;
    final userName = AuthService().currentUser?.name ?? '';
    final usages = _consumptions.map((entry) {
      return ProductUsage(
        id: const Uuid().v4(),
        productId: entry.product.id,
        serviceId: widget.service.id,
        productName: entry.product.name,
        quantity: _parse(entry.quantity.text)!,
        unit: entry.product.unit,
        date: day?.date ?? DateTime.now(),
        machine: widget.service.machineName,
        field: widget.service.fieldName,
        operatorName: widget.service.operatorName.isEmpty
            ? userName
            : widget.service.operatorName,
      );
    }).toList();
    Navigator.pop(
      context,
      _FinishServiceResult(
        day != null
            ? widget.service.copyWith(
                notes: _notes.text.trim(),
                plotCompleted: _wholePlot,
                appliedSprayInputs: _appliedSprayInputs,
              )
            : widget.service.finishWith(
                endMeter: _parse(_end.text),
                fuelLiters: _parse(_fuel.text),
                areaHectares: area,
                notes: _notes.text.trim(),
              ),
        usages,
        day,
      ),
    );
  }

  void _addProduct() {
    final usedIds = _consumptions.map((entry) => entry.product.id).toSet();
    final available = widget.products
        .where((product) => !usedIds.contains(product.id))
        .toList();
    if (available.isEmpty) return;
    setState(() {
      final entry = _ProductConsumptionEntry(available.first)
        ..quantity.addListener(_refresh);
      _consumptions.add(entry);
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(
          widget.pause
              ? 'Pausar operação'
              : FarmApiClient.standaloneLocalMode
                  ? 'Finalizar operação'
                  : 'Finalizar serviço',
        ),
        content: SizedBox(
          width: AppTheme.dialogWidth(context, maxWidth: 440),
          child: Form(
            key: _key,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.recordDay)
                    _ServiceDateField(
                      label: widget.pause ? 'Data da pausa' : 'Data de término',
                      date: _day,
                      firstDate: widget.service.activeSince,
                      onChanged: (date) => setState(() => _day = date),
                    ),
                  if (widget.service.tracksMeter) ...[
                    Text(
                      'Horímetro inicial: ${widget.service.activeStartMeter!.toStringAsFixed(1)} h',
                      style: const TextStyle(color: Colors.black54),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _end,
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: widget.pause
                            ? 'Horímetro da pausa'
                            : 'Horímetro final',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      validator: (value) {
                        final end = _parse(value ?? '');
                        return end == null ||
                                end < widget.service.activeStartMeter!
                            ? 'Deve ser maior ou igual ao horímetro inicial'
                            : null;
                      },
                    ),
                  ],
                  if (!widget.service.isManual) ...[
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _fuel,
                      decoration: const InputDecoration(
                        labelText: 'Consumo de combustível (L, opcional)',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? null : _nonNegative(v),
                    ),
                  ],
                  if (widget.recordDay && !widget.pause)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Talhão concluído'),
                      subtitle: Text(_remainingArea == null
                          ? 'A metragem fica em aberto quando não foi informada.'
                          : 'Área restante: ${_remainingArea!.toStringAsFixed(2)} ha'),
                      value: _wholePlot,
                      onChanged: (value) =>
                          setState(() => _wholePlot = value ?? false),
                    ),
                  const SizedBox(height: 10),
                  if ((!_wholePlot || _remainingArea == null) &&
                      (!widget.service.isManual || widget.pause))
                    TextFormField(
                      controller: _area,
                      decoration: InputDecoration(
                        labelText: widget.recordDay
                            ? 'Área trabalhada nesta etapa (ha)'
                            : 'Área trabalhada (ha, opcional)',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      validator: (value) {
                        if (widget.recordDay && (value ?? '').trim().isEmpty) {
                          return null;
                        }
                        final error = _nonNegative(value);
                        if (error != null) return error;
                        if (widget.recordDay &&
                            _remainingArea != null &&
                            _parse(value!)! > _remainingArea! + 0.000001) {
                          return 'A área supera o restante deste talhão.';
                        }
                        return null;
                      },
                    ),
                  if (!widget.pause) ...[
                    const SizedBox(height: 16),
                    if (FarmApiClient.standaloneLocalMode &&
                        widget.recordDay &&
                        widget.products.isNotEmpty)
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text('Registrar cargas aplicadas'),
                        children: [
                          CoffeeInputPlanning(
                            products: widget.products,
                            plot: const {},
                            plans: _appliedSprayInputs,
                            applied: true,
                            plannedSprays: widget.service.plannedInputs
                                .where((input) =>
                                    input.kind == CoffeeInputKind.spray &&
                                    widget.products.any((product) =>
                                        product.id == input.productId &&
                                        product.unit == input.stockUnit))
                                .toList(),
                            onChanged: _updateAppliedSpray,
                          ),
                        ],
                      ),
                    if (_appliedError != null)
                      Text(_appliedError!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Produtos consumidos neste serviço',
                            style: TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                        if (widget.products.isNotEmpty)
                          TextButton.icon(
                            onPressed:
                                _consumptions.length < widget.products.length
                                    ? _addProduct
                                    : null,
                            icon: const Icon(Icons.add),
                            label: const Text('Adicionar'),
                          ),
                      ],
                    ),
                    if (widget.service.plannedInputs.isNotEmpty)
                      const Text(
                          'Confira as quantidades reais antes de concluir. Edite ou remova o que não foi usado.'),
                    if (_plansNeedReview)
                      const Text(
                          'Há insumos planejados com cálculo pendente, unidade alterada ou saldo indisponível. Confira os produtos e informe o uso real.'),
                    if (widget.service.fieldName.isNotEmpty)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Talhão: ${widget.service.fieldName}',
                          style: const TextStyle(color: Colors.black54),
                        ),
                      ),
                    if (widget.products.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            FarmApiClient.standaloneLocalMode
                                ? 'Nenhum produto com saldo em estoque. Para registrar consumo, confira Produtos e Insumos.'
                                : 'Consulte Produtos e insumos. No módulo v2, registre o consumo nas Operações da propriedade.',
                          ),
                        ),
                      ),
                    ..._consumptions.asMap().entries.map((row) {
                      final index = row.key;
                      final entry = row.value;
                      final chosenIds = _consumptions
                          .where((candidate) => candidate != entry)
                          .map((candidate) => candidate.product.id)
                          .toSet();
                      final quantity = _parse(entry.quantity.text) ?? 0;
                      final balance = FarmApiClient.standaloneLocalMode
                          ? LocalOperationActions.remainingStock(
                              entry.product.quantity, quantity)
                          : entry.product.quantity - quantity;
                      return Padding(
                        key: ObjectKey(entry),
                        padding: const EdgeInsets.only(top: 8),
                        child: Column(
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: DropdownButtonFormField<FarmProduct>(
                                    isExpanded: true,
                                    initialValue: entry.product,
                                    decoration: const InputDecoration(
                                      labelText: 'Produto',
                                    ),
                                    items: widget.products
                                        .where(
                                          (product) =>
                                              !chosenIds.contains(product.id),
                                        )
                                        .map(
                                          (product) => DropdownMenuItem(
                                            value: product,
                                            child: Text(
                                              '${product.name} · ${product.quantity.toStringAsFixed(1)} ${product.unit} em estoque',
                                            ),
                                          ),
                                        )
                                        .toList(),
                                    onChanged: (product) {
                                      if (product != null) {
                                        setState(() {
                                          if (product.id != entry.product.id &&
                                              (widget.service.plannedInputs
                                                      .isNotEmpty ||
                                                  _appliedSprayInputs
                                                      .isNotEmpty)) {
                                            entry.quantity.clear();
                                          }
                                          entry.product = product;
                                          entry.manuallyEdited = true;
                                          _appliedError = null;
                                        });
                                      }
                                    },
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Remover produto',
                                  onPressed: () => setState(() {
                                    _disposeConsumption(
                                        _consumptions.removeAt(index));
                                    _appliedError = null;
                                  }),
                                  icon: const Icon(Icons.remove_circle_outline),
                                ),
                              ],
                            ),
                            TextFormField(
                              controller: entry.quantity,
                              onChanged: (_) {
                                entry.manuallyEdited = true;
                                if (_appliedError != null) {
                                  setState(() => _appliedError = null);
                                }
                              },
                              decoration: InputDecoration(
                                labelText:
                                    'Quantidade utilizada (${entry.product.unit})',
                              ),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              validator: (value) {
                                final usedQuantity = _parse(value ?? '');
                                if (usedQuantity == null || usedQuantity <= 0) {
                                  return 'Informe uma quantidade maior que zero';
                                }
                                final detailed =
                                    _appliedTotals[entry.product.id];
                                if (detailed != null &&
                                    LocalOperationActions.remainingStock(
                                            usedQuantity, detailed) ==
                                        null) {
                                  return 'Informe ao menos o total das cargas aplicadas';
                                }
                                if (FarmApiClient.standaloneLocalMode
                                    ? LocalOperationActions.remainingStock(
                                            entry.product.quantity,
                                            usedQuantity) ==
                                        null
                                    : usedQuantity > entry.product.quantity) {
                                  return 'Consumo excede o estoque disponível';
                                }
                                return null;
                              },
                            ),
                            Align(
                              alignment: Alignment.centerRight,
                              child: Text(
                                balance == null
                                    ? 'Consumo excede o estoque disponível'
                                    : 'Estoque após o uso: ${balance.toStringAsFixed(2)} ${entry.product.unit}',
                                textAlign: TextAlign.end,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _notes,
                      decoration:
                          const InputDecoration(labelText: 'Observações'),
                      maxLines: 2,
                    ),
                  ],
                  const SizedBox(height: 14),
                  if (!widget.recordDay)
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _end,
                      builder: (context, val, _) {
                        final start = widget.service.activeStartMeter!;
                        final end = _parse(val.text) ?? start;
                        final worked = (end - start).clamp(0.0, 9999.0);
                        final fuel = _parse(_fuel.text) ?? 0.0;
                        final area = _parse(_area.text) ?? 0.0;
                        final lph = worked > 0 ? (fuel / worked) : 0.0;
                        final hph = worked > 0 ? (area / worked) : 0.0;

                        return Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.primary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: AppTheme.primary.withValues(alpha: 0.2),
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Cálculos Automáticos:',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                  color: AppTheme.primary,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'Horas Trabalhadas:',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade700,
                                    ),
                                  ),
                                  Text(
                                    '${worked.toStringAsFixed(1)} h',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'Consumo Estimado:',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey.shade700,
                                    ),
                                  ),
                                  Text(
                                    '${lph.toStringAsFixed(1)} L/h',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                              if (area > 0) ...[
                                const SizedBox(height: 4),
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'Rendimento Operacional:',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade700,
                                      ),
                                    ),
                                    Text(
                                      '${hph.toStringAsFixed(2)} ha/h',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
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
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            onPressed: _submit,
            icon: const Icon(Icons.check),
            label: Text(widget.pause ? 'Salvar pausa' : 'Concluir'),
          ),
        ],
      );
  String? _nonNegative(String? value) {
    final n = _parse(value ?? '');
    return n == null || !n.isFinite || n < 0 ? 'Informe um valor válido' : null;
  }
}

class OperationCancellationDialog extends StatefulWidget {
  const OperationCancellationDialog({super.key});
  @override
  State<OperationCancellationDialog> createState() => _CancellationState();
}

class _CancellationState extends State<OperationCancellationDialog> {
  final _reason = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _closing = false;
  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Cancelar operação?'),
        content: Form(
          key: _form,
          child: TextFormField(
            controller: _reason,
            maxLength: 500,
            maxLines: 3,
            decoration:
                const InputDecoration(labelText: 'Motivo do cancelamento'),
            validator: (v) =>
                (v ?? '').trim().isEmpty ? 'Informe o motivo' : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Voltar'),
          ),
          FilledButton(
            onPressed: () {
              if (!_closing && _form.currentState!.validate()) {
                _closing = true;
                Navigator.pop(context, _reason.text.trim());
              }
            },
            child: const Text('Confirmar cancelamento'),
          ),
        ],
      );
}
