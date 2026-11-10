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
import '../auth/auth_service.dart';

class ServicesScreen extends StatefulWidget {
  const ServicesScreen({super.key, this.propertyId, this.fieldId});
  final String? propertyId, fieldId;
  @override
  State<ServicesScreen> createState() => _ServicesScreenState();
}

class _ServicesScreenState extends State<ServicesScreen> {
  final _repo = ServiceRepository();
  List<FarmService> _items = [];
  bool _loading = true;
  bool? _finishedFilter;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await _repo.getAll();
    if (mounted) {
      setState(() {
        _items = items;
        _loading = false;
      });
    }
  }

  Future<void> _start() async {
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
    if (machines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Não há máquinas disponíveis. Verifique o status e os serviços em andamento.',
          ),
        ),
      );
      return;
    }
    final result = await showDialog<FarmService>(
      context: context,
      builder: (_) => _StartServiceForm(
        machines: machines,
        operators: operators,
        clients: clients,
        localProperties: properties,
        localPlots: plots,
        implements: implements,
      ),
    );
    if (result != null && mounted) {
      final repository = MachineRepository();
      final current = await repository.getAll();
      if (!mounted) return;
      final saved = await runLicensedWrite(
          context,
          () => LocalWriteBatch.run(() async {
                await _repo.saveAll([result, ..._items], previous: _items);
                await repository.saveAll(
                  current
                      .map((machine) => machine.id == result.machineId
                          ? machine.copyWith(
                              status: MachineStatus.emOperacao,
                              hourMeter: FarmApiClient.standaloneLocalMode
                                  ? result.startMeter
                                  : null)
                          : machine)
                      .toList(),
                  previous: current,
                );
              }));
      if (saved && mounted) await _load();
    }
  }

  Future<void> _finish(FarmService service) async {
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
      ),
    );
    if (result == null) return;
    if (FarmApiClient.standaloneLocalMode) {
      if (!mounted) return;
      final saved = await runLicensedWrite(context,
          () => LocalOperationActions.finish(result.service, result.usages));
      if (saved && mounted) await _load();
      return;
    }
    final currentProducts = await productRepository.getProducts();
    final quantities = <String, double>{};
    for (final usage in result.usages) {
      quantities.update(usage.productId, (value) => value + usage.quantity,
          ifAbsent: () => usage.quantity);
    }
    for (final entry in quantities.entries) {
      final product =
          currentProducts.where((item) => item.id == entry.key).firstOrNull;
      if (product == null || product.quantity < entry.value) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Estoque alterado ou insuficiente. Sincronize e tente finalizar novamente.'),
          ));
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
                      .map((product) => quantities.containsKey(product.id)
                          ? product.copyWith(
                              quantity:
                                  product.quantity - quantities[product.id]!)
                          : product)
                      .toList(),
                  previous: currentProducts,
                );
                await productRepository.saveUsage(
                    [...result.usages, ...existingUsage],
                    previous: existingUsage);
              }
              await _repo.saveAll(
                  _items
                      .map((item) => item.id == finishedService.id
                          ? finishedService
                          : item)
                      .toList(),
                  previous: _items);
              if (endMeter != null) {
                await repository.saveAll(
                  currentMachines
                      .map((machine) => machine.id == finishedService.machineId
                          ? machine.copyWith(
                              hourMeter: endMeter > machine.hourMeter
                                  ? endMeter
                                  : machine.hourMeter,
                              status: machine.status == MachineStatus.emOperacao
                                  ? MachineStatus.disponivel
                                  : machine.status,
                            )
                          : machine)
                      .toList(),
                  previous: currentMachines,
                );
              }
            }));
    if (saved && mounted) await _load();
  }

  Future<void> _delete(FarmService service) async {
    if (service.isFinished || service.isCancelled) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('O historico desta operacao sera preservado.')));
      return;
    }
    final text = await showDialog<String>(
        context: context, builder: (_) => const OperationCancellationDialog());
    if (text == null || !mounted) return;
    if (FarmApiClient.standaloneLocalMode) {
      final saved = await runLicensedWrite(
          context, () => LocalOperationActions.cancel(service.id, text));
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
                    'A operacao ja foi encerrada. Atualize a tela.');
              }
              await _repo.saveAll(
                  services
                      .map((x) => x.id == current.id ? x.cancel(text) : x)
                      .toList(),
                  previous: services);
              final repo = MachineRepository();
              final machines = await repo.getAll();
              await repo.saveAll(
                  machines
                      .map((m) => m.id == current.machineId &&
                              m.status == MachineStatus.emOperacao
                          ? m.copyWith(status: MachineStatus.disponivel)
                          : m)
                      .toList(),
                  previous: machines);
            }));
    if (saved && mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _items
        .where((item) =>
            (widget.propertyId == null ||
                item.propertyId == widget.propertyId) &&
            (widget.fieldId == null || item.fieldId == widget.fieldId))
        .where(
          (item) =>
              _finishedFilter == null ||
              item.isFinished == _finishedFilter && !item.isCancelled,
        )
        .toList();
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _start,
        icon: const Icon(Icons.play_arrow_rounded),
        label: const Text(FarmApiClient.standaloneLocalMode
            ? 'Iniciar operação'
            : 'Iniciar serviço'),
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
                                    OutlinedButton.icon(
                                      onPressed: _start,
                                      icon: const Icon(Icons.play_arrow),
                                      label: const Text(
                                          FarmApiClient.standaloneLocalMode
                                              ? 'Iniciar operação'
                                              : 'Iniciar serviço'),
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
                                                Row(children: [
                                                  Expanded(
                                                      child: Text(item.jobType,
                                                          style:
                                                              const TextStyle(
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w700,
                                                                  fontSize:
                                                                      16))),
                                                  SyncStatusLabel(
                                                      module: 'services',
                                                      recordId: item.id),
                                                ]),
                                                Text(
                                                  '${item.machineName}${item.operatorName.isEmpty ? '' : ' · ${item.operatorName}'}',
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
                                                Text(
                                                  item.isFinished
                                                      ? '${item.workedHours!.toStringAsFixed(1)} h trabalhadas · Área: ${item.areaHectares?.toStringAsFixed(1) ?? 'Não informada'} · Consumo: ${item.fuelLiters?.toStringAsFixed(1) ?? 'Não informado'} L'
                                                      : item.isCancelled
                                                          ? 'Cancelada: ${item.cancellationReason}'
                                                          : 'Início ${item.startMeter.toStringAsFixed(1)} h · ${_date(item.startedAt)}',
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (!item.isFinished &&
                                              !item.isCancelled)
                                            TextButton(
                                              onPressed: () => _finish(item),
                                              child: const Text('Finalizar'),
                                            ),
                                          PopupMenuButton<String>(
                                            onSelected: (_) => _delete(item),
                                            itemBuilder: (_) => const [
                                              PopupMenuItem(
                                                value: 'delete',
                                                child: Text(
                                                    'Cancelar / preservar histórico'),
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
  });
  final List<Machine> machines;
  final List<Operator> operators;
  final List<RuralClient> clients;
  final List<Json> localProperties, localPlots;
  final List<FarmImplement> implements;
  @override
  State<_StartServiceForm> createState() => _StartServiceFormState();
}

class _StartServiceFormState extends State<_StartServiceForm> {
  final _key = GlobalKey<FormState>();
  bool _submitted = false;
  late final _meter = TextEditingController(
    text: widget.machines.first.hourMeter.toStringAsFixed(1),
  );
  final _job = TextEditingController(text: 'Plantio');
  late Machine _machine = widget.machines.first;
  Operator? _operator;
  FarmImplement? _implement;
  RuralClient? _client;
  RuralProperty? _property;
  RuralField? _field;
  Json? _localProperty, _localPlot;
  @override
  void dispose() {
    _meter.dispose();
    _job.dispose();
    super.dispose();
  }

  void _submit() {
    if (_submitted || !_key.currentState!.validate()) return;
    _submitted = true;
    Navigator.pop(
      context,
      FarmService(
        id: const Uuid().v4(),
        machineId: _machine.id,
        machineName: '${_machine.name} · ${_machine.brand} ${_machine.model}',
        operatorName: _operator?.name ?? '',
        customer: _client?.name ?? '',
        clientId: _client?.id ?? '',
        property: _localProperty?['name'] as String? ?? _property?.name ?? '',
        propertyId: _localProperty?['id'] as String? ?? _property?.id ?? '',
        fieldName: _localPlot?['name'] as String? ?? _field?.name ?? '',
        fieldId: _localPlot?['id'] as String? ?? _field?.id ?? '',
        jobType: _job.text.trim(),
        implementId: _implement?.id ?? '',
        implementName: _implement?.name ?? '',
        startedAt: DateTime.now(),
        startMeter: double.parse(_meter.text.replaceAll(',', '.')),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text(FarmApiClient.standaloneLocalMode
            ? 'Iniciar operação'
            : 'Iniciar serviço'),
        content: SizedBox(
          width: AppTheme.dialogWidth(context, maxWidth: 450),
          child: Form(
            key: _key,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<Machine>(
                    isExpanded: true,
                    initialValue: _machine,
                    decoration: const InputDecoration(labelText: 'Máquina'),
                    items: widget.machines
                        .map(
                          (item) => DropdownMenuItem(
                            value: item,
                            child: Text(
                                '${item.name} · ${item.brand} ${item.model}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                          ),
                        )
                        .toList(),
                    onChanged: (value) => setState(() {
                      _machine = value ?? _machine;
                      _meter.text = _machine.hourMeter.toStringAsFixed(1);
                    }),
                  ),
                  if (widget.implements.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<FarmImplement>(
                      isExpanded: true,
                      decoration: const InputDecoration(
                          labelText: 'Implemento (opcional)'),
                      items: widget.implements
                          .map((i) => DropdownMenuItem(
                              value: i,
                              child: Text(i.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis)))
                          .toList(),
                      onChanged: (i) => _implement = i,
                    ),
                  ],
                  if (widget.operators.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<Operator>(
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
                  TextFormField(
                    controller: _job,
                    decoration:
                        const InputDecoration(labelText: 'Tipo de serviço'),
                    validator: _required,
                  ),
                  const SizedBox(height: 10),
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
                  if (FarmApiClient.standaloneLocalMode) ...[
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Fazenda'),
                      items: widget.localProperties
                          .map((p) => DropdownMenuItem(
                              value: p['id'] as String,
                              child: Text(p['name'] as String,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis)))
                          .toList(),
                      validator: (v) => v == null
                          ? 'Cadastre e selecione uma fazenda.'
                          : null,
                      onChanged: (v) => setState(() {
                        _localProperty = widget.localProperties
                            .firstWhere((p) => p['id'] == v);
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
                          .map((p) => DropdownMenuItem(
                              value: p['id'] as String,
                              child: Text(p['name'] as String,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis)))
                          .toList(),
                      validator: (v) =>
                          v == null ? 'Cadastre e selecione um talhão.' : null,
                      onChanged: (v) => _localPlot =
                          widget.localPlots.firstWhere((p) => p['id'] == v),
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
            icon: const Icon(Icons.play_arrow),
            label: const Text('Iniciar'),
          ),
        ],
      );
  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Preencha este campo' : null;
  String? _number(String? value) {
    final n = double.tryParse((value ?? '').replaceAll(',', '.'));
    return n == null || n < _machine.hourMeter
        ? 'O horímetro deve ser pelo menos ${_machine.hourMeter.toStringAsFixed(1)} h'
        : null;
  }
}

class _FinishServiceResult {
  const _FinishServiceResult(this.service, this.usages);
  final FarmService service;
  final List<ProductUsage> usages;
}

class _ProductConsumptionEntry {
  _ProductConsumptionEntry(this.product) : quantity = TextEditingController();
  FarmProduct product;
  final TextEditingController quantity;
}

class _FinishServiceForm extends StatefulWidget {
  const _FinishServiceForm({required this.service, required this.products});
  final FarmService service;
  final List<FarmProduct> products;
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

  @override
  void initState() {
    super.initState();
    _area.addListener(_refresh);
    _fuel.addListener(_refresh);
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
    _submitted = true;
    final area = _parse(_area.text);
    final userName = AuthService().currentUser?.name ?? '';
    final usages = _consumptions.map((entry) {
      return ProductUsage(
        id: const Uuid().v4(),
        productId: entry.product.id,
        serviceId: widget.service.id,
        productName: entry.product.name,
        quantity: _parse(entry.quantity.text)!,
        unit: entry.product.unit,
        date: DateTime.now(),
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
        widget.service.finishWith(
          endMeter: _parse(_end.text)!,
          fuelLiters: _parse(_fuel.text),
          areaHectares: area,
          notes: _notes.text.trim(),
        ),
        usages,
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
        title: const Text(FarmApiClient.standaloneLocalMode
            ? 'Finalizar operação'
            : 'Finalizar serviço'),
        content: SizedBox(
          width: AppTheme.dialogWidth(context, maxWidth: 440),
          child: Form(
            key: _key,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Horímetro inicial: ${widget.service.startMeter.toStringAsFixed(1)} h',
                    style: const TextStyle(color: Colors.black54),
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _end,
                    autofocus: true,
                    decoration:
                        const InputDecoration(labelText: 'Horímetro final'),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    validator: (value) {
                      final end = _parse(value ?? '');
                      return end == null || end < widget.service.startMeter
                          ? 'Deve ser maior ou igual ao horímetro inicial'
                          : null;
                    },
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _fuel,
                    decoration: const InputDecoration(
                      labelText: 'Consumo medido (L, opcional)',
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    validator: (v) =>
                        (v ?? '').trim().isEmpty ? null : _nonNegative(v),
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _area,
                    decoration: const InputDecoration(
                      labelText: 'Área trabalhada (ha, opcional)',
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    validator: (value) {
                      final error = _nonNegative(value);
                      if (error != null) return error;
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Expanded(
                        child: Text('Produtos consumidos neste serviço',
                            style: TextStyle(fontWeight: FontWeight.w700)),
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
                  if (widget.service.fieldName.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Talhão: ${widget.service.fieldName}',
                          style: const TextStyle(color: Colors.black54)),
                    ),
                  if (widget.products.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                            'Consulte Produtos e insumos. No módulo v2, registre o consumo nas Operações da propriedade.'),
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
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Column(
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<FarmProduct>(
                                  initialValue: entry.product,
                                  decoration: const InputDecoration(
                                      labelText: 'Produto'),
                                  items: widget.products
                                      .where((product) =>
                                          !chosenIds.contains(product.id))
                                      .map((product) => DropdownMenuItem(
                                            value: product,
                                            child: Text(
                                                '${product.name} · ${product.quantity.toStringAsFixed(1)} ${product.unit} em estoque'),
                                          ))
                                      .toList(),
                                  onChanged: (product) {
                                    if (product != null) {
                                      setState(() => entry.product = product);
                                    }
                                  },
                                ),
                              ),
                              IconButton(
                                tooltip: 'Remover produto',
                                onPressed: () => setState(() {
                                  _consumptions
                                      .removeAt(index)
                                      .quantity
                                      .dispose();
                                }),
                                icon: const Icon(Icons.remove_circle_outline),
                              ),
                            ],
                          ),
                          TextFormField(
                            controller: entry.quantity,
                            decoration: InputDecoration(
                              labelText:
                                  'Quantidade utilizada (${entry.product.unit})',
                            ),
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            validator: (value) {
                              final usedQuantity = _parse(value ?? '');
                              if (usedQuantity == null || usedQuantity <= 0) {
                                return 'Informe uma quantidade maior que zero';
                              }
                              if (usedQuantity > entry.product.quantity) {
                                return 'Consumo excede o estoque disponível';
                              }
                              return null;
                            },
                          ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: Text(
                              'Estoque após o uso: ${(entry.product.quantity - quantity).toStringAsFixed(2)} ${entry.product.unit}',
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
                    decoration: const InputDecoration(labelText: 'Observações'),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 14),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _end,
                    builder: (context, val, _) {
                      final end = _parse(val.text) ?? widget.service.startMeter;
                      final worked =
                          (end - widget.service.startMeter).clamp(0.0, 9999.0);
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
                              color: AppTheme.primary.withValues(alpha: 0.2)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Cálculos Automáticos:',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                  color: AppTheme.primary),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Horas Trabalhadas:',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade700)),
                                Text('${worked.toStringAsFixed(1)} h',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13)),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Consumo Estimado:',
                                    style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade700)),
                                Text('${lph.toStringAsFixed(1)} L/h',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13)),
                              ],
                            ),
                            if (area > 0) ...[
                              const SizedBox(height: 4),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text('Rendimento Operacional:',
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.grey.shade700)),
                                  Text('${hph.toStringAsFixed(2)} ha/h',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13)),
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
            label: const Text('Concluir'),
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
                    (v ?? '').trim().isEmpty ? 'Informe o motivo' : null)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Voltar')),
          FilledButton(
              onPressed: () {
                if (!_closing && _form.currentState!.validate()) {
                  _closing = true;
                  Navigator.pop(context, _reason.text.trim());
                }
              },
              child: const Text('Confirmar cancelamento'))
        ],
      );
}
