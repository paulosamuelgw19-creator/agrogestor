import '../properties/catalog_review.dart';
import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../app/app_theme.dart';
import 'package:uuid/uuid.dart';
import '../auth/auth_service.dart';
import '../auth/user_model.dart';
import '../licensing/licensing_service.dart';
import '../sync/farm_api_client.dart';
import 'v2_store.dart';
import '../machines/catalog_photos.dart';
import 'v2_export.dart';
import 'management_reports_screen.dart';
import '../products/product_categories.dart';
import '../products/product_details_dialog.dart';
import '../properties/catalog_store.dart';
import '../work/work_store.dart';

const _kinds = {
  'planting': 'Plantio',
  'application': 'Aplicação',
  'management': 'Manejo',
  'harvest': 'Colheita',
  'transport': 'Transporte',
  'other': 'Outra operação'
};
const _roles = {
  'owner': 'Proprietário',
  'manager': 'Gerente',
  'employee': 'Funcionário',
  'consultant': 'Consultor',
  'administrator': 'Administrador'
};
String _today() => DateTime.now().toIso8601String().substring(0, 10);

String? decimalError(String raw, {bool zero = false, bool optional = false}) {
  if (raw.trim().isEmpty) return optional ? null : 'Informe o valor.';
  final value = raw.trim().replaceAll(',', '.');
  if (!RegExp(r'^\d{1,12}(\.\d{1,6})?$').hasMatch(value)) {
    return 'Use até 6 casas decimais, sem separador de milhar.';
  }
  if (!zero && BigInt.parse(value.replaceAll('.', '')) == BigInt.zero) {
    return 'Informe um valor maior que zero.';
  }
  return null;
}

int centsFromInput(String raw) {
  final value = raw.trim().replaceAll(',', '.');
  if (!RegExp(r'^\d{1,10}(\.\d{1,2})?$').hasMatch(value)) {
    throw const FormatException(
        'Informe reais com até 2 casas, sem separador de milhar.');
  }
  final parts = value.split('.');
  return int.parse(parts[0]) * 100 +
      int.parse(parts.length == 1 ? '0' : parts[1].padRight(2, '0'));
}

enum OperationsSection {
  operations,
  products,
  fleet,
  catalogs,
  reports,
  refuelings
}

class OperationsScreen extends StatefulWidget {
  const OperationsScreen(
      {super.key,
      this.section = OperationsSection.operations,
      this.initialTask,
      this.initialPropertyId});
  final OperationsSection section;
  final String? initialPropertyId;
  final Json? initialTask;
  @override
  State<OperationsScreen> createState() => _OperationsScreenState();
}

class _OperationsScreenState extends State<OperationsScreen>
    with WidgetsBindingObserver {
  V2Store? _store;
  Json _data = {};
  String? _property, _cycle;
  String? _notice;
  bool _busy = false,
      _online = false,
      _exporting = false,
      _operationDialogOpen = false;
  Json? _report;
  List<Json> _pending = [];
  String? _productCategory;
  Timer? _timer;
  final _from = TextEditingController(), _until = TextEditingController();

  bool get _admin => _data['administrator'] == true;
  String? get _role => items(_data, 'properties')
      .where((p) => p['id'] == _property)
      .firstOrNull?['access_role'] as String?;
  bool get _operate =>
      ['administrator', 'owner', 'manager', 'employee'].contains(_role);
  bool get _stock => AuthService().currentUser?.role == UserRole.admin;
  bool get _finance => AuthService().currentUser?.role == UserRole.admin;

  @override
  void initState() {
    super.initState();
    _property = widget.initialPropertyId;
    WidgetsBinding.instance.addObserver(this);
    _load();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!_busy && !_exporting && !_operationDialogOpen) _load(quiet: true);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_operationDialogOpen) {
      _load(quiet: true);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _from.dispose();
    _until.dispose();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final auth = AuthService();
      final user = auth.currentUser;
      final token = auth.accessToken;
      final base = await FarmApiClient.instance.baseUrl;
      final catalog = await CatalogStore.open();
      if (user?.farmId == null || token == null || base == null) {
        final local = await catalog.workspace(_property);
        if (mounted) {
          setState(() {
            _data = local;
            _online = false;
            _notice =
                'Cadastre as áreas no aparelho. Entre na conta do PC gestor para compartilhar e registrar operações.';
          });
        }
        return;
      }
      _store ??= await V2Store.open(
          baseUrl: base, farmId: user!.farmId!, userId: user.id, token: token);
      Json root;
      _online = true;
      try {
        root = await _store!.refresh();
      } on DioException catch (error) {
        if ([401, 403].contains(error.response?.statusCode)) {
          await catalog.invalidateServerCache();
          rethrow;
        }
        final cached = await _store!.cached('root');
        root = cached ?? await catalog.workspace();
        _online = false;
      }
      final localRoot = await catalog.workspace();
      final mergedProperties = {
        for (final p in items(root, 'properties')) p['id']: p
      };
      for (final p in items(localRoot, 'properties')) {
        mergedProperties[p['id']] = {...?mergedProperties[p['id']], ...p};
      }
      root = {...root, 'properties': mergedProperties.values.toList()};
      final properties = items(root, 'properties');
      if (!properties.any((p) => p['id'] == _property)) {
        _property = properties.firstOrNull?['id'] as String?;
      }
      var data = root;
      if (_property != null) {
        final chosen = items(root, 'properties')
            .where((p) => p['id'] == _property)
            .firstOrNull;
        final draft = chosen != null &&
            chosen['_sync_state'] != null &&
            chosen['_sync_state'] != 'synced';
        if (_online && !draft) {
          if (widget.initialTask != null) await (await WorkStore.open()).sync();
          await _store!.sync();
          data = await _store!.refresh(_property);
        } else {
          data = await _store!.cached(_property!) ??
              await catalog.workspace(_property);
          if (draft) {
            data = await catalog.workspace(_property);
            _online = false;
          }
        }
      }
      final localSelected = await catalog.workspace(_property);
      data = {...data, 'properties': mergedProperties.values.toList()};
      if (catalog.canCreate) {
        for (final kind in [
          'clients',
          'crops',
          'plots',
          'cycles',
          'machines'
        ]) {
          final merged = {
            for (final value in items(data, kind)) value['id']: value
          };
          for (final value in items(localSelected, kind)) {
            merged[value['id']] = {...?merged[value['id']], ...value};
          }
          data[kind] = merged.values.toList();
        }
      }
      if (!items(data, 'cycles').any((c) => c['id'] == _cycle)) {
        _cycle = items(data, 'cycles').firstOrNull?['id'] as String?;
        _report = null;
      }
      final pending = await _store!.pending(_property);
      final catalogNotice = await catalog.notice();
      if (mounted &&
          auth.currentUser?.id == user!.id &&
          auth.accessToken == token) {
        setState(() {
          _data = data;
          _pending = pending;
          if (!quiet || !_online) {
            _notice = _online
                ? null
                : '$catalogNotice Operações e estoque dependem dos cadastros confirmados no PC.';
          }
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _notice = v2Error(error);
          _online = false;
          if (error is DioException &&
              [401, 403, 404].contains(error.response?.statusCode)) {
            _data = {};
            _report = null;
          }
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
    }
  }

  Future<void> _change(String method, String path, Json body) async {
    if (method == 'POST' &&
        ['/clients', '/properties', '/plots', '/crops', '/cycles', '/machines']
            .contains(path)) {
      try {
        final catalog = await CatalogStore.open();
        await catalog.save(method, path, body);
        _message(
            'Cadastro salvo no aparelho. A disponibilidade de vaga será confirmada pelo PC gestor.');
        unawaited(catalog.sync().then((_) {
          if (mounted) _load();
        }));
        await _load();
      } catch (error) {
        _message(v2Error(error));
      }
      return;
    }
    if (!_online || _store == null) {
      _message(
          'Conecte ao PC gestor para alterar cadastros, estoque ou permissões.');
      return;
    }
    try {
      await _store!.client.v2(method, path, data: body);
      await _load();
      _report = null;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(v2Error(error)),
            action: SnackBarAction(
                label: 'Tentar novamente',
                onPressed: () => _change(method, path, body))));
      }
    }
  }

  Future<Json?> _form(String title, List<_Field> fields) => showDialog<Json>(
      context: context,
      builder: (_) => _DataDialog(title: title, fields: fields));

  Future<void> _create(String type) async {
    if (type == 'inputs') {
      final data = await showDialog<Json>(
          context: context, builder: (_) => const ProductDetailsDialog());
      if (data != null && mounted) {
        await _change('POST', '/inputs', {'id': const Uuid().v4(), ...data});
      }
      return;
    }
    List<_Field> fields;
    final clientOptions = {
      for (final c in items(_data, 'clients')) '${c['id']}': '${c['name']}'
    };
    final plotOptions = {
      for (final p in items(_data, 'plots')) '${p['id']}': '${p['name']}'
    };
    final cropOptions = {
      for (final c in items(_data, 'crops')) '${c['id']}': '${c['name']}'
    };
    switch (type) {
      case 'clients':
        fields = [const _Field('name', 'Nome do cliente')];
      case 'properties':
        fields = [
          const _Field('name', 'Nome da propriedade'),
          _Field('client_id', 'Cliente', options: clientOptions),
          const _Field('area_ha', 'Área total (ha)',
              type: 'decimal', optional: true)
        ];
      case 'plots':
        fields = [
          const _Field('name', 'Nome do talhão'),
          const _Field('area_ha', 'Área (ha)', type: 'decimal', optional: true)
        ];
      case 'crops':
        fields = [
          const _Field('name', 'Nome da cultura'),
          const _Field('kind', 'Grupo',
              options: {'coffee': 'Café', 'grain': 'Grãos', 'other': 'Outra'})
        ];
      case 'cycles':
        fields = [
          const _Field('name', 'Nome da safra/ciclo'),
          _Field('plot_id', 'Talhão', options: plotOptions),
          _Field('crop_id', 'Cultura', options: cropOptions),
          const _Field('area_ha', 'Área cultivada (ha)',
              type: 'decimal', optional: true),
          _Field('starts_on', 'Data inicial (AAAA-MM-DD)',
              type: 'date', initial: _today()),
          const _Field('ends_on', 'Data final (AAAA-MM-DD)',
              type: 'date', optional: true)
        ];
      case 'machines':
        fields = [
          const _Field('name', 'Nome da máquina'),
          const _Field('hour_meter', 'Horímetro atual (h)',
              type: 'nonnegative'),
          if (_admin)
            const _Field('hourly_cost_cents',
                'Custo da máquina (R\$/h), sem combustível/mão de obra',
                type: 'money', optional: true)
        ];
      default:
        fields = [
          const _Field('name', 'Nome do insumo'),
          const _Field('unit', 'Unidade', options: {
            'L': 'Litros (L)',
            'kg': 'Quilos (kg)',
            'un': 'Unidades (un)'
          })
        ];
    }
    final data = await _form('Novo cadastro', fields);
    if (data == null) return;
    if (type == 'plots') data['property_id'] = _property;
    if (type == 'machines') data['property_ids'] = [_property];
    await _change('POST', '/$type', {'id': const Uuid().v4(), ...data});
  }

  Future<void> _receive(Json input, Json? stock,
      {bool correction = false}) async {
    final initialized = stock?['initialized'] == true;
    final data = await _form(
        correction
            ? 'Conferir e ajustar estoque'
            : initialized
                ? 'Entrada de insumo'
                : 'Inventário inicial conferido',
        [
          _Field('quantity',
              '${correction ? 'Saldo físico após conferência' : 'Quantidade'} (${input['unit']})',
              type: initialized && !correction ? 'decimal' : 'nonnegative'),
          _Field(
              'value_cents',
              correction
                  ? 'Valor TOTAL do saldo corrigido (R\$)'
                  : 'Valor TOTAL desta entrada/saldo (R\$)',
              type: 'money',
              optional: true),
          _Field('occurred_on', 'Data (AAAA-MM-DD)',
              type: 'date', initial: _today()),
          if (correction) const _Field('reason', 'Motivo do ajuste'),
        ]);
    if (data == null) return;
    await _change(
        'POST',
        '/properties/$_property/${correction ? 'inventory-corrections' : 'inventory'}',
        {
          'id': const Uuid().v4(),
          'input_id': input['id'],
          ...data,
          if (!correction) 'kind': initialized ? 'receipt' : 'opening',
          if (correction) 'expected_movement_id': stock!['last_movement_id'],
        });
  }

  Future<void> _newOperation() async {
    if (_operationDialogOpen) return;
    setState(() => _operationDialogOpen = true);
    try {
      await _openNewOperation();
    } finally {
      if (mounted) setState(() => _operationDialogOpen = false);
    }
  }

  Future<void> _openNewOperation() async {
    try {
      final farm = AuthService().currentUser?.farmId;
      if (farm != null) await LicensingService().requireWriteAccess(farm);
      if (_store == null ||
          _property == null ||
          await _store!.cached(_property!) == null) {
        throw StateError(
            'Conecte ao PC gestor para renovar o acesso antes de registrar.');
      }
    } catch (error) {
      _message(v2Error(error));
      return;
    }
    if (!mounted) return;
    final body = await showDialog<Json>(
        context: context,
        barrierDismissible: false,
        builder: (_) => OperationDialog(
            data: _data, cycleId: _cycle, task: widget.initialTask));
    if (body == null || _store == null || _property == null) return;
    try {
      await _store!.queueOperation(_property!, body);
      _message(
          'Finalização salva neste aparelho. Aguardando confirmação do PC gestor.');
      await _load();
      if (mounted && widget.initialTask != null) Navigator.of(context).pop();
    } catch (error) {
      _message(v2Error(error));
    }
  }

  Future<void> _void(Json operation) async {
    final body = await _form('Estornar operação', [
      const _Field('reason', 'Motivo do estorno'),
      _Field('occurred_on', 'Data (AAAA-MM-DD)',
          type: 'date', initial: _today())
    ]);
    if (body != null) {
      await _change('POST', '/operations/${operation['id']}/void',
          {'id': const Uuid().v4(), ...body});
    }
  }

  Future<void> _access() async {
    try {
      final users = await _store!.client.get('/auth/users');
      if (!mounted) return;
      final body = await _form('Acesso a esta propriedade', [
        _Field('user_id', 'Conta', options: {
          for (final u in items(users, 'users'))
            '${u['id']}': '${u['displayName']} — ${u['email']}'
        }),
        const _Field('role', 'Permissão',
            options: {..._roles, 'revoke': 'Revogar acesso à propriedade'}),
      ]);
      if (body != null) {
        if (body['role'] == 'revoke') body['role'] = null;
        await _change('PUT', '/properties/$_property/access', body);
      }
    } catch (error) {
      _message(v2Error(error));
    }
  }

  Future<void> _editMachine(Json machine, String action) async {
    if (action == 'archive') {
      try {
        await _store!.client
            .patch('/licensing/machines/${machine['id']}/archive', data: {
          'archived': machine['archived'] != 1,
          'expected_version': machine['version'] ?? 1
        });
        await _load();
      } catch (e) {
        _message(v2Error(e));
      }
      return;
    }
    final assignments = List<String>.from(machine['property_ids'] as List);
    Json? body;
    if (action == 'assign') {
      final choice = await _form('Vincular máquina', [
        _Field('property_id', 'Outra propriedade', options: {
          for (final p in items(_data, 'properties'))
            if (!assignments.contains(p['id'])) '${p['id']}': '${p['name']}'
        })
      ]);
      if (choice == null) return;
      assignments.add(choice['property_id'] as String);
      body = {
        'name': machine['name'],
        'hourly_cost_cents': machine['hourly_cost_cents']
      };
    } else {
      body = await _form('Editar máquina', [
        _Field('name', 'Nome', initial: machine['name'] as String),
        _Field('hourly_cost_cents',
            'Nova tarifa (R\$/h), sem combustível e mão de obra',
            type: 'money',
            optional: true,
            initial: machine['hourly_cost_cents'] == null
                ? ''
                : (machine['hourly_cost_cents'] / 100).toStringAsFixed(2)),
      ]);
      if (body == null) return;
    }
    await _change('PATCH', '/machines/${machine['id']}', {
      'id': const Uuid().v4(),
      ...body,
      'property_ids': assignments,
      'expected_property_ids': machine['property_ids'],
      'expected_name': machine['name'],
      'expected_hour_meter': machine['hour_meter'],
      'expected_hourly_cost_cents': machine['hourly_cost_cents'],
    });
  }

  Future<void> _generate() async {
    if (_store == null || _cycle == null || _busy) return;
    final from = _from.text.trim(), until = _until.text.trim();
    for (final date in [from, until]) {
      if (date.isNotEmpty && !_validDate(date)) {
        _message('Use uma data válida no formato AAAA-MM-DD.');
        return;
      }
    }
    setState(() {
      _busy = true;
      _report = null;
    });
    final key = 'report:$_cycle:$from:$until';
    try {
      Json data;
      try {
        data = await _store!.client.v2('GET', '/cycles/$_cycle/report', query: {
          if (from.isNotEmpty) 'starts_on': from,
          if (until.isNotEmpty) 'ends_on': until
        });
        await _store!.cache(key, data);
      } on DioException catch (error) {
        if (error.response != null) rethrow;
        final cached = await _store!.cached(key);
        if (cached == null) rethrow;
        data = cached;
        _message(
            'Exibindo o último relatório confirmado. Confira a data de geração.');
      }
      data = {
        ...data,
        'pending_count': (await _store!.pending(_property)).length
      };
      if (mounted) setState(() => _report = data);
    } catch (error) {
      _message(v2Error(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export(bool pdf) async {
    final report = _report;
    if (report == null) return;
    setState(() => _exporting = true);
    try {
      final bytes =
          pdf ? await reportPdf(report) : await compute(reportXlsx, report);
      final destination = await FilePicker.saveFile(
          fileName:
              'AgroGestor-${report['cycle']['id']}.${pdf ? 'pdf' : 'xlsx'}',
          bytes: bytes,
          mimeType: pdf
              ? 'application/pdf'
              : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet');
      if (destination != null) _message('Relatório salvo.');
    } catch (error) {
      _message(v2Error(error));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final properties = items(_data, 'properties');
    return NestedScrollView(
        headerSliverBuilder: (context, innerScrolled) => [
              SliverToBoxAdapter(
                  child: Column(children: [
                if (_busy || _exporting) const LinearProgressIndicator(),
                if (_exporting)
                  const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text('Preparando arquivo…')),
                Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(children: [
                            Expanded(
                                child: Text(
                                    _online
                                        ? 'Confirmado no PC gestor'
                                        : 'Conexão indisponível',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold))),
                            IconButton(
                                onPressed: _busy ? null : () => _load(),
                                icon: const Icon(Icons.sync),
                                tooltip: 'Atualizar e enviar pendentes')
                          ]),
                          if (_notice != null)
                            Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(_notice!,
                                    style: const TextStyle(
                                        color: Colors.deepOrange))),
                          DropdownButtonFormField<String>(
                              key: ValueKey('property-$_property'),
                              initialValue: _property,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                  labelText: 'Propriedade',
                                  border: OutlineInputBorder()),
                              items: properties
                                  .map((p) => DropdownMenuItem(
                                      value: '${p['id']}',
                                      child: Text('${p['name']}',
                                          overflow: TextOverflow.ellipsis)))
                                  .toList(),
                              onChanged: _busy
                                  ? null
                                  : (value) {
                                      setState(() {
                                        _property = value;
                                        _cycle = null;
                                        _report = null;
                                      });
                                      _load();
                                    }),
                          if (_role != null)
                            Text('Permissão: ${_roles[_role] ?? _role}'),
                          if (_pending.isNotEmpty)
                            Text(
                                '${_pending.length} operação(ões) pendente(s). Custos e saldo abaixo incluem apenas confirmações.',
                                style:
                                    const TextStyle(color: Colors.deepOrange)),
                        ])),
              ])),
            ],
        body: switch (widget.section) {
          OperationsSection.operations => _operations(),
          OperationsSection.products => _inventory(),
          OperationsSection.fleet => _fleet(),
          OperationsSection.catalogs => _catalogs(),
          OperationsSection.reports => _reports(),
          OperationsSection.refuelings => _refuelingHistory(),
        });
  }

  Widget _operations() =>
      ListView(padding: const EdgeInsets.all(12), children: [
        const Text('Operações',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const Text(
            'Finalize o trabalho realizado e consulte o histórico. O consumo de insumos é informado na finalização.'),
        if (_operate)
          FilledButton.icon(
              onPressed: _busy || _operationDialogOpen ? null : _newOperation,
              icon: const Icon(Icons.add),
              label: const Text('Finalizar operação')),
        for (final row in _pending)
          Card(
              color: Colors.orange.shade50,
              child: ListTile(
                  title: Text(row['state'] == 'conflict'
                      ? 'Precisa de conferência'
                      : 'Aguardando confirmação'),
                  subtitle: Text(
                      '${(jsonDecode(row['payload'] as String) as Map)['performed_on']}\n${row['error'] ?? 'Salvo somente neste aparelho.'}'),
                  onTap: () => _pendingDetails(row))),
        if (items(_data, 'operations').isEmpty)
          const ListTile(
              title: Text('Nenhuma operação confirmada para este acesso.')),
        for (final operation in items(_data, 'operations'))
          _operationCard(operation),
        if (_data['operations_truncated'] == true)
          const Text(
              'Exibindo as 200 operações mais recentes. O relatório por ciclo consulta o período completo.'),
      ]);

  Future<void> _pendingDetails(Json row) async {
    final body =
        Map<String, dynamic>.from(jsonDecode(row['payload'] as String) as Map);
    final details = [
      '${row['error'] ?? ''}',
      '${_kinds[body['kind']] ?? body['kind']} | ${body['performed_on']}',
      'Área: ${body['area_ha'] ?? 'não informada'} ha',
      for (final m in items(body, 'machines'))
        '${_name('machines', m['machine_id'])}: ${m['start_meter']} a ${m['end_meter']} h',
      for (final f in items(body, 'refuelings'))
        'Abastecimento: ${f['liters']} L, horímetro ${f['hour_meter']} h, ${f['source'] == 'stock' ? 'estoque da propriedade' : 'posto'}',
      for (final i in items(body, 'inputs'))
        '${_name('inputs', i['input_id'])}: ${i['quantity']} na unidade cadastrada',
      '${body['notes'] ?? ''}',
    ].join('\n');
    final action = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: const Text('Lançamento pendente'),
                content: SingleChildScrollView(child: Text(details)),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Fechar')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, 'discard'),
                      child:
                          const Text('Conferir no servidor e retirar da fila')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, 'retry'),
                      child: const Text('Tentar novamente'))
                ]));
    if (action == null) return;
    try {
      if (action == 'retry') {
        await _store!.retry(row['id'] as String);
      } else {
        await _store!.discardUnconfirmed(row);
      }
      await _load();
    } catch (error) {
      _message(v2Error(error));
    }
  }

  Widget _operationCard(Json operation) {
    final voided = operation['void'] != null;
    return Card(
        child: ExpansionTile(
            title: Text(
                '${_kinds[operation['kind']] ?? operation['kind']} — ${operation['performed_on']}${voided ? ' (estornada)' : ''}'),
            subtitle: Text(
                'Área: ${operation['area_ha'] ?? 'não informada'} ha | Autor: ${operation['actor_id']}'),
            childrenPadding: const EdgeInsets.all(12),
            children: [
          SelectableText('Registro: ${operation['id']}\n${operation['notes']}'),
          if (voided) Text('Estorno: ${operation['void']['reason']}'),
          for (final m in items(operation, 'machines'))
            ListTile(
                dense: true,
                title: Text(
                    '${_name('machines', m['machine_id'])}: ${m['start_meter']} → ${m['end_meter']} (${m['hours']} h)'),
                subtitle: Text(
                    'Intervalo sem apontamento: ${m['meter_gap_hours']} h${m.containsKey('cost_cents') ? ' | Custo: ${_money(m['cost_cents'])}' : ''}')),
          for (final i in items(operation, 'inputs'))
            ListTile(
                dense: true,
                title:
                    Text('${_name('inputs', i['input_id'])}: ${i['quantity']}'),
                subtitle: Text(
                    'Movimento: ${i['id']}${i.containsKey('value_cents') ? '\nCusto: ${_money(i['value_cents'])}' : ''}')),
          for (final fuel in items(operation, 'refuelings'))
            ListTile(
                dense: true,
                leading: const Icon(Icons.local_gas_station),
                title: Text(
                    '${fuel['machine_name']} · ${fuel['liters']} L de ${fuel['fuel_name']}'),
                subtitle: Text(
                    'Abastecido em ${fuel['occurred_on']} · ${fuel['hour_meter']} h · ${fuel['source'] == 'stock' ? 'Estoque da propriedade (baixa única)' : 'Compra em posto'}\n${fuel['location'] ?? ''}${fuel.containsKey('total_cost_cents') ? '\nValor: ${_money(fuel['total_cost_cents'])}' : ''}')),
          if (_stock && !voided)
            TextButton(
                onPressed: _online && !_busy ? () => _void(operation) : null,
                child: const Text('Estornar com motivo')),
        ]));
  }

  Widget _refuelingHistory() {
    final records = <Json>[
      for (final operation
          in items(_data, 'operations').where((o) => o['void'] == null))
        for (final fuel in items(operation, 'refuelings'))
          {...fuel, 'operation_id': operation['id']}
    ];
    return ListView(padding: const EdgeInsets.all(12), children: [
      const Text('Abastecimentos das operações',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
      const Text(
          'Registre ao finalizar o serviço do dia. Litros abastecidos não medem o consumo real da máquina durante o serviço.'),
      if (_operate)
        FilledButton.icon(
            onPressed: _busy || _operationDialogOpen ? null : _newOperation,
            icon: const Icon(Icons.local_gas_station),
            label: const Text('Finalizar operação do dia')),
      if (records.isEmpty)
        const Text('Nenhum abastecimento confirmado nesta propriedade.'),
      for (final fuel in records)
        Card(
            child: ListTile(
                title: Text('${fuel['occurred_on']} · ${fuel['machine_name']}'),
                subtitle: Text(
                    '${fuel['liters']} L de ${fuel['fuel_name']} · horímetro ${fuel['hour_meter']} h\n${fuel['source'] == 'stock' ? 'Estoque da propriedade' : 'Compra em posto'} · ${fuel['actor_name']}\n${fuel['location'] ?? ''}${fuel.containsKey('total_cost_cents') ? '\nValor: ${_money(fuel['total_cost_cents'])}' : ''}'))),
    ]);
  }

  String _name(String collection, Object? id) =>
      items(_data, collection).where((m) => m['id'] == id).firstOrNull?['name']
          as String? ??
      '$id';
  String _money(Object? cents) => cents == null
      ? 'Não informado'
      : 'R\$ ${(num.parse('$cents') / 100).toStringAsFixed(2).replaceAll('.', ',')}';

  Widget _inventory() => ListView(padding: const EdgeInsets.all(12), children: [
        const Text('Produtos e insumos',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const Text(
            'Cadastro e estoque dos produtos e insumos. Informe o consumo somente ao finalizar uma operação.'),
        if (_admin)
          FilledButton.icon(
              onPressed: _online && !_busy ? () => _create('inputs') : null,
              icon: const Icon(Icons.add),
              label: const Text('Cadastrar produto / insumo')),
        DropdownButtonFormField<String>(
            key: ValueKey('category-filter-$_productCategory'),
            initialValue: _productCategory ?? '',
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Filtrar categoria'),
            items: [
              const DropdownMenuItem(
                  value: '', child: Text('Todas as categorias')),
              for (final category in {
                ...productCategories.keys,
                ...items(_data, 'inputs')
                    .map((p) => p['category'] as String? ?? '')
              }.where((v) => v.isNotEmpty))
                DropdownMenuItem(
                    value: category,
                    child: Text(category, overflow: TextOverflow.ellipsis))
            ],
            onChanged: (value) =>
                setState(() => _productCategory = value == '' ? null : value)),
        const Text(
            'O saldo confirmado não reserva consumos pendentes de outros aparelhos. O PC valida cada envio.'),
        for (final input in items(_data, 'inputs').where((p) =>
            _productCategory == null || p['category'] == _productCategory))
          Builder(builder: (_) {
            final stock = items(_data, 'inventory')
                .where((s) => s['input_id'] == input['id'])
                .firstOrNull;
            return Card(
                child: ListTile(
                    title: Text('${input['name']} (${input['unit']})'),
                    subtitle: Text(
                        '${productClassification(input['category'] as String? ?? '', input['product_type'] as String? ?? '')}\n${stock?['initialized'] != true ? 'Inventário inicial não conferido' : 'Saldo: ${stock!['quantity']} ${input['unit']}${stock.containsKey('value_cents') ? '\nValor: ${_money(stock['value_cents'])}' : ''}'}'),
                    trailing: _stock || _admin
                        ? PopupMenuButton<String>(
                            enabled: _online && !_busy,
                            onSelected: (action) => action == 'edit'
                                ? _editProduct(input)
                                : _receive(input, stock,
                                    correction: action == 'correct'),
                            itemBuilder: (_) => [
                                  if (_admin)
                                    const PopupMenuItem(
                                        value: 'edit',
                                        child: Text('Editar cadastro')),
                                  if (_stock)
                                    PopupMenuItem(
                                        value: 'receive',
                                        child: Text(
                                            stock?['initialized'] == true
                                                ? 'Registrar entrada'
                                                : 'Conferir saldo inicial')),
                                  if (_stock && stock?['initialized'] == true)
                                    const PopupMenuItem(
                                        value: 'correct',
                                        child: Text('Ajustar saldo com motivo'))
                                ])
                        : null));
          }),
        if (items(_data, 'inputs').isEmpty)
          const ListTile(
              title: Text(
                  'O administrador precisa cadastrar insumos e conferir o estoque desta propriedade.')),
      ]);

  Future<void> _editProduct(Json input) async {
    final data = await showDialog<Json>(
        context: context, builder: (_) => ProductDetailsDialog(product: input));
    if (!mounted || data == null) return;
    data.remove('unit');
    await _change('PATCH', '/inputs/${input['id']}', {
      'id': const Uuid().v4(),
      ...data,
      'expected_name': input['name'],
      'expected_category': input['category'] ?? '',
      'expected_product_type': input['product_type'] ?? '',
    });
  }

  Widget _fleet() => ListView(padding: const EdgeInsets.all(12), children: [
        OutlinedButton.icon(
            onPressed: () async {
              await reviewCatalogDrafts(context);
              if (mounted) await _load();
            },
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('Conferir cadastros salvos')),
        if (_data['can_create_catalog'] == true && _property != null)
          FilledButton.icon(
              onPressed: _busy ? null : () => _create('machines'),
              icon: const Icon(Icons.add),
              label: const Text('Nova máquina')),
        if (!_admin)
          const Text(
              'A tarifa e as alterações cadastrais ficam com o gerente.'),
        const Text(
            'Tarifa de máquina sem combustível e mão de obra. Informe esses consumos separadamente.'),
        for (final m in items(_data, 'machines'))
          Card(
              child: ListTile(
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                          builder: (_) => CatalogPhotosScreen(
                              kind: 'machine',
                              targetId: m['id'] as String,
                              name: m['name'] as String))),
                  leading: const Icon(Icons.agriculture),
                  trailing: _admin &&
                          (m['_sync_state'] == null ||
                              m['_sync_state'] == 'synced')
                      ? PopupMenuButton<String>(
                          enabled: _online && !_busy,
                          onSelected: (action) => action == 'history'
                              ? Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => ManagementReportsScreen(
                                          type: 'machines',
                                          machineId: m['id'] as String)))
                              : _editMachine(m, action),
                          itemBuilder: (_) => [
                                PopupMenuItem(
                                    value: 'archive',
                                    child: Text(m['archived'] == 1
                                        ? 'Reativar máquina'
                                        : 'Arquivar máquina')),
                                const PopupMenuItem(
                                    value: 'history',
                                    child: Text('Histórico e custos')),
                                const PopupMenuItem(
                                    value: 'edit',
                                    child: Text('Editar nome e tarifa')),
                                const PopupMenuItem(
                                    value: 'assign',
                                    child:
                                        Text('Vincular a outra propriedade')),
                              ])
                      : null,
                  title: Text('${m['name']}'),
                  subtitle: Text(
                      '${m['_sync_state'] != null && m['_sync_state'] != 'synced' ? 'Rascunho aguardando confirmação · ' : ''}${m['archived'] == 1 ? 'Arquivada · ' : ''}Horímetro confirmado: ${m['hour_meter']} h${m.containsKey('hourly_cost_cents') ? '\nTarifa: ${_money(m['hourly_cost_cents'])}/h' : ''}'))),
        if (items(_data, 'machines').isEmpty)
          const ListTile(
              title: Text('Nenhuma máquina vinculada a esta propriedade.')),
      ]);

  Widget _catalogs() => ListView(padding: const EdgeInsets.all(12), children: [
        if (!_admin)
          const ListTile(
              title: Text(
                  'Cadastros e concessão de acessos são administrados pelo responsável da organização.')),
        if (_admin) ...[
          const Text(
              'Cadastre cliente → propriedade → talhão → cultura → safra/ciclo. Dados anteriores ficam preservados nos módulos existentes.'),
          for (final entry in {
            'clients': 'Cliente',
            'properties': 'Propriedade',
            'plots': 'Talhão',
            'crops': 'Cultura',
            'cycles': 'Safra/ciclo',
            'machines': 'Máquina'
          }.entries)
            ListTile(
                title: Text('Cadastrar ${entry.value.toLowerCase()}'),
                trailing: const Icon(Icons.add_circle_outline),
                onTap: (!_online && entry.key == 'machines') ||
                        _busy ||
                        (_property == null &&
                            ['plots', 'cycles', 'machines'].contains(entry.key))
                    ? null
                    : () => _create(entry.key)),
          if (_property != null)
            ListTile(
                title: const Text('Permissões da propriedade'),
                trailing: const Icon(Icons.manage_accounts),
                onTap: _online && !_busy ? _access : null),
        ],
        if (_admin)
          ListTile(
              title: const Text('Produtos e insumos'),
              subtitle: const Text(
                  'Cadastrar produtos, conferir estoque e registrar entradas'),
              trailing: const Icon(Icons.inventory_2_outlined),
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                      builder: (_) => Scaffold(
                          appBar:
                              AppBar(title: const Text('Produtos e insumos')),
                          body: const OperationsScreen(
                              section: OperationsSection.products))))),
        const Divider(),
        const Text('Talhões'),
        for (final p in items(_data, 'plots'))
          ListTile(
              title: Text('${p['name']}'),
              subtitle: Text('Área: ${p['area_ha'] ?? 'não informada'} ha')),
        const Text('Safras e ciclos'),
        for (final c in items(_data, 'cycles'))
          ListTile(
              title: Text('${c['name']}'),
              subtitle: Text(
                  '${_name('plots', c['plot_id'])} | ${_name('crops', c['crop_id'])}\n${c['starts_on']} a ${c['ends_on'] ?? 'em aberto'}')),
      ]);

  Widget _reports() => !_finance
      ? const Center(
          child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                  'Seu acesso não permite consultar custos e relatórios desta propriedade.')))
      : ListView(padding: const EdgeInsets.all(12), children: [
          DropdownButtonFormField<String>(
              key: ValueKey('cycle-$_cycle'),
              initialValue: _cycle,
              isExpanded: true,
              decoration: const InputDecoration(
                  labelText: 'Safra/ciclo — talhão e cultura'),
              items: items(_data, 'cycles')
                  .map((c) => DropdownMenuItem(
                      value: '${c['id']}',
                      child: Text(
                          '${c['name']} — ${_name('plots', c['plot_id'])} / ${_name('crops', c['crop_id'])}',
                          overflow: TextOverflow.ellipsis)))
                  .toList(),
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                        _cycle = value;
                        _report = null;
                      })),
          TextField(
              controller: _from,
              enabled: !_busy,
              decoration:
                  const InputDecoration(labelText: 'De (AAAA-MM-DD), opcional'),
              onChanged: (_) => setState(() => _report = null)),
          TextField(
              controller: _until,
              enabled: !_busy,
              decoration: const InputDecoration(
                  labelText: 'Até (AAAA-MM-DD), opcional'),
              onChanged: (_) => setState(() => _report = null)),
          FilledButton.icon(
              onPressed: _busy || _cycle == null ? null : _generate,
              icon: const Icon(Icons.bar_chart),
              label: Text(_busy ? 'Preparando relatório…' : 'Gerar relatório')),
          if (_report != null) ...[
            Text('Pronto | Gerado em ${_report!['generated_at']}'),
            Text('${_report!['scope']}'),
            if (_report!['pending_count'] != 0)
              Text(
                  '${_report!['pending_count']} pendente(s) neste aparelho não incluído(s).',
                  style: const TextStyle(color: Colors.deepOrange)),
            for (final entry in (_report!['metrics'] as Map).entries)
              ListTile(
                  title: Text(metricNames[entry.key] ?? '${entry.key}'),
                  trailing: Text(displayMetric(
                      Map<String, dynamic>.from(entry.value as Map))),
                  subtitle: Text(
                      '${metricStatus(entry.value['status'])} | Sem informação: ${entry.value['missing'] ?? '—'}${entry.value['value'] == null && entry.value['known_subtotal'] != null ? ' | Subtotal conhecido: ${subtotalLabel(entry.value as Map)}' : ''}')),
            _costChart(),
            Wrap(spacing: 12, children: [
              OutlinedButton.icon(
                  onPressed: _exporting ? null : () => _export(true),
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text('Salvar PDF')),
              OutlinedButton.icon(
                  onPressed: _exporting ? null : () => _export(false),
                  icon: const Icon(Icons.table_chart),
                  label: const Text('Salvar Excel'))
            ]),
            const Text('Lançamentos que originaram os totais',
                style: TextStyle(fontWeight: FontWeight.bold)),
            for (final operation in items(_report!, 'operations'))
              _operationCard(operation),
          ],
        ]);

  Widget _costChart() {
    final metrics = _report!['metrics'] as Map;
    final keys = [
      'machine_cost',
      'input_cost',
      if (metrics.containsKey('fuel_cost')) 'fuel_cost'
    ];
    final values = keys
        .map((key) => num.tryParse('${metrics[key]['known_subtotal']}'))
        .toList();
    final max = values.whereType<num>().fold<num>(1, (a, b) => a > b ? a : b);
    return Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text(
              'Custos conhecidos por categoria (não inclui valores ausentes)'),
          for (var i = 0; i < values.length; i++)
            Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(i == 0
                          ? 'Máquinas'
                          : i == 1
                              ? 'Insumos'
                              : 'Combustível'),
                      if (values[i] == null)
                        const Text('Sem custo conhecido')
                      else
                        LinearProgressIndicator(
                            value: (values[i]! / max).toDouble(),
                            minHeight: 12),
                    ])),
        ]));
  }
}

bool _validDate(String text) {
  final date = DateTime.tryParse(text);
  return RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text) &&
      date != null &&
      date.toIso8601String().startsWith(text);
}

class _Field {
  const _Field(this.key, this.label,
      {this.type = 'text', this.optional = false, this.options, this.initial});
  final String key, label, type;
  final bool optional;
  final Map<String, String>? options;
  final String? initial;
}

class _DataDialog extends StatefulWidget {
  const _DataDialog({required this.title, required this.fields});
  final String title;
  final List<_Field> fields;
  @override
  State<_DataDialog> createState() => _DataDialogState();
}

class _DataDialogState extends State<_DataDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _values = {
    for (final f in widget.fields) f.key: TextEditingController(text: f.initial)
  };
  @override
  void dispose() {
    for (final c in _values.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final result = <String, dynamic>{};
    for (final f in widget.fields) {
      final raw = _values[f.key]!.text.trim();
      result[f.key] = raw.isEmpty && f.optional
          ? null
          : f.type == 'money'
              ? centsFromInput(raw)
              : ['decimal', 'nonnegative'].contains(f.type)
                  ? raw.replaceAll(',', '.')
                  : raw;
    }
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.title),
          content: SizedBox(
              width: AppTheme.dialogWidth(context),
              child: SingleChildScrollView(
                  child: Form(
                      key: _formKey,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        for (final f in widget.fields)
                          Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: f.options != null
                                  ? DropdownButtonFormField<String>(
                                      isExpanded: true,
                                      decoration:
                                          InputDecoration(labelText: f.label),
                                      items: f.options!.entries
                                          .map((e) => DropdownMenuItem(
                                              value: e.key,
                                              child: Text(e.value,
                                                  overflow:
                                                      TextOverflow.ellipsis)))
                                          .toList(),
                                      onChanged: (value) =>
                                          _values[f.key]!.text = value ?? '',
                                      validator: (value) => value == null
                                          ? 'Selecione uma opção.'
                                          : null)
                                  : TextFormField(
                                      controller: _values[f.key],
                                      maxLength: f.type == 'text' ? 160 : 24,
                                      keyboardType: [
                                        'decimal',
                                        'nonnegative',
                                        'money'
                                      ].contains(f.type)
                                          ? const TextInputType
                                              .numberWithOptions(decimal: true)
                                          : TextInputType.text,
                                      decoration: InputDecoration(
                                          labelText: f.label,
                                          helperText: f.optional
                                              ? 'Opcional. Deixe vazio se não souber.'
                                              : null),
                                      validator: (value) {
                                        final raw = value!.trim();
                                        if (raw.isEmpty) {
                                          return f.optional
                                              ? null
                                              : 'Preencha este campo.';
                                        }
                                        if (['decimal', 'nonnegative']
                                            .contains(f.type)) {
                                          return decimalError(raw,
                                              zero: f.type == 'nonnegative');
                                        }
                                        if (f.type == 'money') {
                                          try {
                                            centsFromInput(raw);
                                          } catch (_) {
                                            return 'Use reais com até 2 casas, sem milhar.';
                                          }
                                        }
                                        if (f.type == 'date' &&
                                            !_validDate(raw)) {
                                          return 'Use uma data válida: AAAA-MM-DD.';
                                        }
                                        return null;
                                      })),
                      ])))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar')),
            FilledButton(onPressed: _submit, child: const Text('Salvar'))
          ]);
}

bool isFuelInput(Json item) {
  final type = '${item['product_type'] ?? ''}'.trim().toLowerCase();
  final category = '${item['category'] ?? ''}';
  return item['unit'] == 'L' &&
      (['diesel', 'gasolina', 'etanol', 'combustível', 'combustivel']
              .contains(type) ||
          type.isEmpty &&
              category.isEmpty &&
              ['diesel', 'gasolina', 'etanol'].any((prefix) =>
                  '${item['name']}'.toLowerCase().startsWith(prefix)));
}

class _RefuelingLine {
  _RefuelingLine({required this.source});
  final id = const Uuid().v4();
  String source;
  String? machine, input;
  final liters = TextEditingController(),
      meter = TextEditingController(),
      price = TextEditingController(),
      name = TextEditingController(text: 'Diesel'),
      location = TextEditingController();
  void dispose() {
    for (final c in [liters, meter, price, name, location]) {
      c.dispose();
    }
  }
}

class _UseLine {
  String? id;
  final first = TextEditingController(), second = TextEditingController();
  void dispose() {
    first.dispose();
    second.dispose();
  }
}

class OperationDialog extends StatefulWidget {
  const OperationDialog(
      {super.key, required this.data, this.cycleId, this.task});
  final Json data;
  final Json? task;
  final String? cycleId;
  @override
  State<OperationDialog> createState() => OperationDialogState();
}

class OperationDialogState extends State<OperationDialog> {
  String? _harvestNumber(String text, {bool zero = false}) {
    final value = double.tryParse(text.trim().replaceAll(',', '.'));
    return value == null || !value.isFinite || (zero ? value < 0 : value <= 0)
        ? 'Informe uma quantidade válida.'
        : null;
  }

  final _key = GlobalKey<FormState>();
  late String? _cycle = widget.task?['cycle_id'] as String? ?? widget.cycleId;
  late String _kind = widget.task?['kind'] as String? ?? 'management';
  final _date = TextEditingController(text: _today()),
      _area = TextEditingController(),
      _labor = TextEditingController(),
      _notes = TextEditingController();
  final _laborCost = TextEditingController();
  final _harvestQuantity = TextEditingController(),
      _harvestWeight = TextEditingController();
  String _harvestUnit = 'kg';
  final _implementIds = <String>{};
  final _consumed = TextEditingController(),
      _coverage = TextEditingController();
  String? _plan;
  DateTime? _started, _ended;
  List<Json> get _plans => items(widget.data, 'activity_plans')
      .where((p) => p['cycle_id'] == _cycle && p['activity'] == _kind)
      .toList();
  Future<void> _pickTime(bool start) async {
    final day = DateTime.tryParse(_date.text) ?? DateTime.now();
    final time = await showTimePicker(
        context: context,
        initialTime:
            TimeOfDay.fromDateTime(start ? _started ?? day : _ended ?? day));
    if (time == null || !mounted) return;
    setState(() {
      final value =
          DateTime(day.year, day.month, day.day, time.hour, time.minute);
      if (start) {
        _started = value;
      } else {
        _ended = value;
      }
    });
  }

  final _machines = <_UseLine>[],
      _inputs = <_UseLine>[],
      _retiredUses = <_UseLine>[];
  final _refuelings = <_RefuelingLine>[],
      _retiredRefuelings = <_RefuelingLine>[];
  bool _submitted = false;
  @override
  void initState() {
    super.initState();
    final machineId = widget.task?['machine_id'];
    final assigned = items(widget.data, 'machines')
        .where((machine) => machine['id'] == machineId)
        .firstOrNull;
    if (assigned != null) {
      final line = _UseLine()..id = assigned['id'] as String;
      line.first.text = '${assigned['hour_meter']}';
      _machines.add(line);
    }
  }

  @override
  void dispose() {
    for (final c in [
      _date,
      _area,
      _labor,
      _notes,
      _consumed,
      _coverage,
      _laborCost,
      _harvestQuantity,
      _harvestWeight
    ]) {
      c.dispose();
    }
    for (final line in [..._machines, ..._inputs, ..._retiredUses]) {
      line.dispose();
    }
    for (final line in [..._refuelings, ..._retiredRefuelings]) {
      line.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (_submitted || !_key.currentState!.validate()) return;
    if (_started != null && _ended != null && _ended!.isBefore(_started!)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('O término deve ser posterior ao início.')));
      return;
    }
    final duplicate = _refuelings
        .where((r) => r.source == 'stock')
        .any((r) => _inputs.any((i) => i.id == r.input));
    if (duplicate) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Não repita o combustível do abastecimento nos insumos consumidos.')));
      return;
    }
    _submitted = true;
    Navigator.pop(context, <String, dynamic>{
      'id': const Uuid().v4(),
      if (widget.task != null) ...{
        'task_id': widget.task!['id'],
        'task_expected_version': widget.task!['version']
      },
      'cycle_id': _cycle,
      'kind': _kind,
      if (_implementIds.isNotEmpty) 'implement_ids': _implementIds.toList(),
      if (_kind == 'harvest' && _harvestQuantity.text.trim().isNotEmpty)
        'harvest_output': {
          'quantity': _harvestQuantity.text.trim().replaceAll(',', '.'),
          'unit': _harvestUnit,
          'kg_per_unit': ['saca', 'caixa'].contains(_harvestUnit) &&
                  _harvestWeight.text.trim().isNotEmpty
              ? _harvestWeight.text.trim().replaceAll(',', '.')
              : null,
        },
      'performed_on': _date.text.trim(),
      'area_ha': _area.text.trim().isEmpty
          ? null
          : _area.text.trim().replaceAll(',', '.'),
      'labor_hours': _labor.text.trim().isEmpty
          ? null
          : _labor.text.trim().replaceAll(',', '.'),
      'notes': _notes.text.trim(),
      if (AuthService().currentUser?.role == UserRole.admin)
        'labor_cost_cents': _laborCost.text.trim().isEmpty
            ? null
            : centsFromInput(_laborCost.text.trim()),
      'started_at': _started?.toUtc().toIso8601String(),
      'ended_at': _ended?.toUtc().toIso8601String(),
      'consumed_fuel_liters': _consumed.text.trim().isEmpty
          ? null
          : _consumed.text.replaceAll(',', '.'),
      if (_plan != null) ...{
        'plan_id': _plan,
        'plan_expected_version':
            _plans.firstWhere((p) => p['plan_id'] == _plan)['version'],
        'coverage_total_ha': _coverage.text.replaceAll(',', '.'),
      },
      'machines': [
        for (final line in _machines)
          {
            'machine_id': line.id,
            'start_meter': line.first.text.replaceAll(',', '.'),
            'end_meter': line.second.text.replaceAll(',', '.')
          }
      ],
      if (_refuelings.isNotEmpty)
        'refuelings': [
          for (final line in _refuelings)
            {
              'id': line.id,
              'machine_id': line.machine,
              'source': line.source,
              'input_id': line.source == 'stock' ? line.input : null,
              'liters': line.liters.text.trim().replaceAll(',', '.'),
              'hour_meter': line.meter.text.trim().replaceAll(',', '.'),
              'unit_price_cents':
                  line.source == 'external' && line.price.text.trim().isNotEmpty
                      ? centsFromInput(line.price.text.trim())
                      : null,
              'fuel_name': line.name.text.trim(),
              'location': line.location.text.trim()
            }
        ],
      'inputs': [
        for (final line in _inputs)
          {
            'input_id': line.id,
            'quantity': line.first.text.replaceAll(',', '.')
          }
      ],
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('Finalizar operação'),
          content: SizedBox(
              width: AppTheme.dialogWidth(context, maxWidth: 560),
              child: SingleChildScrollView(
                  child: Form(
                      key: _key,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Text(
                            'O PC confirma estoque, custos e horímetro. Sem conexão, o lançamento fica pendente neste aparelho.'),
                        if (widget.task != null)
                          Text(
                              'Tarefa: ${widget.task!['title']}. Área prevista: ${widget.task!['planned_area_ha'] ?? 'não informada'} ha. Registre abaixo o que realmente foi feito.'),
                        DropdownButtonFormField<String>(
                            initialValue: _cycle,
                            isExpanded: true,
                            isDense: false,
                            itemHeight: null,
                            decoration: const InputDecoration(
                                labelText: 'Talhão e safra'),
                            items: items(widget.data, 'cycles')
                                .map((c) => DropdownMenuItem(
                                    value: '${c['id']}',
                                    child: Text(
                                        '${items(widget.data, 'plots').where((p) => p['id'] == c['plot_id']).firstOrNull?['name'] ?? 'Talhão'} · ${c['name']}',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis)))
                                .toList(),
                            onChanged: (v) => setState(() {
                                  _cycle = v;
                                  _plan = null;
                                  _coverage.clear();
                                }),
                            validator: (v) =>
                                v == null ? 'Selecione a safra/ciclo.' : null),
                        DropdownButtonFormField<String>(
                            initialValue: _kind,
                            isExpanded: true,
                            decoration:
                                const InputDecoration(labelText: 'Operação'),
                            items: _kinds.entries
                                .map((e) => DropdownMenuItem(
                                    value: e.key, child: Text(e.value)))
                                .toList(),
                            onChanged: (v) => setState(() {
                                  _kind = v!;
                                  _plan = null;
                                  _coverage.clear();
                                })),
                        if (items(widget.data, 'implements').isNotEmpty)
                          ExpansionTile(
                              title: Text(
                                  'Implementos utilizados (${_implementIds.length})'),
                              children: [
                                for (final implement
                                    in items(widget.data, 'implements'))
                                  CheckboxListTile(
                                      title: Text('${implement['name']}'),
                                      subtitle:
                                          Text('${implement['type'] ?? ''}'),
                                      value: _implementIds
                                          .contains(implement['id']),
                                      onChanged: (selected) => setState(() {
                                            if (selected == true) {
                                              _implementIds.add(
                                                  implement['id'] as String);
                                            } else {
                                              _implementIds
                                                  .remove(implement['id']);
                                            }
                                          }))
                              ]),
                        if (_kind == 'harvest') ...[
                          TextFormField(
                              controller: _harvestQuantity,
                              decoration: const InputDecoration(
                                  labelText:
                                      'Quantidade efetivamente colhida (opcional)',
                                  helperText:
                                      'Em branco = não informado. Zero = medição de produção zero.'),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              validator: (v) => v == null || v.trim().isEmpty
                                  ? null
                                  : _harvestNumber(v, zero: true)),
                          DropdownButtonFormField<String>(
                              initialValue: _harvestUnit,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                  labelText: 'Unidade da produção'),
                              items: const ['kg', 't', 'saca', 'caixa']
                                  .map((u) => DropdownMenuItem(
                                      value: u, child: Text(u)))
                                  .toList(),
                              onChanged: (v) =>
                                  setState(() => _harvestUnit = v!)),
                          if (['saca', 'caixa'].contains(_harvestUnit))
                            TextFormField(
                                controller: _harvestWeight,
                                decoration: const InputDecoration(
                                    labelText:
                                        'Peso de cada unidade em kg (opcional)',
                                    helperText:
                                        'Sem esse peso, o sistema mantém a unidade original e não converte para kg.'),
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                        decimal: true),
                                validator: (v) => v == null || v.trim().isEmpty
                                    ? null
                                    : _harvestNumber(v)),
                        ],
                        if (_plans.isNotEmpty)
                          DropdownButtonFormField<String>(
                              key: ValueKey('$_cycle:$_kind'),
                              isExpanded: true,
                              decoration: const InputDecoration(
                                  labelText: 'Programação da safra (opcional)'),
                              items: [
                                const DropdownMenuItem<String>(
                                    value: '', child: Text('Sem programação')),
                                for (final p in _plans)
                                  DropdownMenuItem(
                                      value: '${p['plan_id']}',
                                      child: Text(
                                          '${p['title']} · ${p['completed_ha']}/${p['planned_ha']} ha'))
                              ],
                              onChanged: (v) => setState(() {
                                    _plan = v == '' ? null : v;
                                    _coverage.clear();
                                  })),
                        if (_plan != null)
                          TextFormField(
                              controller: _coverage,
                              decoration: const InputDecoration(
                                  labelText:
                                      'Área única acumulada concluída (ha)',
                                  helperText:
                                      'Inclua o que já estava concluído. Retrabalho não aumenta esta área.'),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              validator: (v) =>
                                  decimalError(v ?? '', zero: true)),
                        TextFormField(
                            controller: _date,
                            decoration: const InputDecoration(
                                labelText: 'Data (AAAA-MM-DD)'),
                            validator: (v) => _validDate(v!.trim())
                                ? null
                                : 'Informe data válida.'),
                        TextFormField(
                            controller: _area,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            decoration: const InputDecoration(
                                labelText: 'Área trabalhada (ha), se medida'),
                            validator: (v) => decimalError(v!, optional: true)),
                        TextFormField(
                            controller: _labor,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            decoration: const InputDecoration(
                                labelText: 'Horas de mão de obra, se medidas'),
                            validator: (v) =>
                                decimalError(v!, optional: true, zero: true)),
                        Wrap(spacing: 8, children: [
                          TextButton(
                              onPressed: () => _pickTime(true),
                              child: Text(_started == null
                                  ? 'Informar início'
                                  : 'Início: ${TimeOfDay.fromDateTime(_started!).format(context)}')),
                          TextButton(
                              onPressed: () => _pickTime(false),
                              child: Text(_ended == null
                                  ? 'Informar término'
                                  : 'Término: ${TimeOfDay.fromDateTime(_ended!).format(context)}')),
                        ]),
                        TextFormField(
                            controller: _consumed,
                            decoration: const InputDecoration(
                                labelText:
                                    'Combustível efetivamente consumido (L, se medido)',
                                helperText:
                                    'Não copie os litros abastecidos. Deixe vazio quando o consumo não foi medido.'),
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            validator: (v) => decimalError(v ?? '',
                                optional: true, zero: true)),
                        if (AuthService().currentUser?.role == UserRole.admin)
                          TextFormField(
                              controller: _laborCost,
                              decoration: const InputDecoration(
                                  labelText:
                                      'Custo total de mão de obra (R\$, opcional)'),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              validator: (v) {
                                if (v == null || v.trim().isEmpty) return null;
                                try {
                                  centsFromInput(v);
                                  return null;
                                } catch (_) {
                                  return 'Informe um valor válido.';
                                }
                              }),
                        for (final line in _machines) _line(line, true),
                        TextButton.icon(
                            onPressed: _machines.length >= 20
                                ? null
                                : () =>
                                    setState(() => _machines.add(_UseLine())),
                            icon: const Icon(Icons.agriculture),
                            label: const Text('Adicionar máquina')),
                        const Divider(),
                        const Text('Insumos utilizados nesta operação',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        const Text(
                            'Informe a quantidade realmente usada de cada produto. O PC gestor confirma a baixa do estoque uma única vez.'),
                        for (final line in _inputs) _line(line, false),
                        TextButton.icon(
                            onPressed: _inputs.length >= 100
                                ? null
                                : () => setState(() => _inputs.add(_UseLine())),
                            icon: const Icon(Icons.inventory_2),
                            label: const Text('Adicionar insumo consumido')),
                        const Divider(),
                        const Text('Abastecimento do dia (opcional)',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                        const Text(
                            'Use a data da operação. Abastecimento do estoque já será baixado e incluído no custo uma única vez.'),
                        for (final fuel in _refuelings) _fuelLine(fuel),
                        TextButton.icon(
                            onPressed: _refuelings.length >= 20
                                ? null
                                : () => setState(() => _refuelings.add(
                                    _RefuelingLine(
                                        source: items(widget.data, 'inputs')
                                                .any(isFuelInput)
                                            ? 'stock'
                                            : 'external'))),
                            icon: const Icon(Icons.local_gas_station),
                            label: const Text('Adicionar abastecimento')),
                        TextFormField(
                            controller: _notes,
                            maxLength: 2000,
                            minLines: 2,
                            maxLines: 4,
                            decoration: const InputDecoration(
                                labelText: 'Observações')),
                        const Text(
                            'Responsável: sua conta autenticada. Custos não informados permanecem desconhecidos.'),
                      ])))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: _save, child: const Text('Finalizar e salvar'))
          ]);

  Widget _fuelLine(_RefuelingLine line) {
    final machines = items(widget.data, 'machines')
        .where((m) => m['archived'] != 1)
        .toList();
    final fuels = items(widget.data, 'inputs').where(isFuelInput).toList();
    return Card(
        key: ObjectKey(line),
        child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(children: [
              Row(children: [
                const Expanded(child: Text('Abastecimento')),
                IconButton(
                    tooltip: 'Retirar abastecimento',
                    onPressed: () => setState(() {
                          _refuelings.remove(line);
                          _retiredRefuelings.add(line);
                        }),
                    icon: const Icon(Icons.close))
              ]),
              DropdownButtonFormField<String>(
                  initialValue: line.machine,
                  isExpanded: true,
                  decoration:
                      const InputDecoration(labelText: 'Máquina abastecida'),
                  items: machines
                      .map((m) => DropdownMenuItem(
                          value: '${m['id']}',
                          child: Text('${m['name']}',
                              overflow: TextOverflow.ellipsis)))
                      .toList(),
                  validator: (v) => v == null ? 'Selecione a máquina.' : null,
                  onChanged: (v) {
                    line.machine = v;
                    if (v != null) {
                      final use = _machines.where((m) => m.id == v).firstOrNull;
                      line.meter.text = use?.second.text.isNotEmpty == true
                          ? use!.second.text
                          : '${machines.firstWhere((m) => m['id'] == v)['hour_meter']}';
                    }
                  }),
              DropdownButtonFormField<String>(
                  initialValue: line.source,
                  isExpanded: true,
                  decoration:
                      const InputDecoration(labelText: 'Origem do combustível'),
                  items: const [
                    DropdownMenuItem(
                        value: 'stock', child: Text('Estoque da propriedade')),
                    DropdownMenuItem(
                        value: 'external', child: Text('Compra em posto'))
                  ],
                  onChanged: (v) => setState(() => line.source = v!)),
              if (line.source == 'stock')
                DropdownButtonFormField<String>(
                    key: ValueKey('${line.id}-stock'),
                    initialValue: line.input,
                    isExpanded: true,
                    decoration: const InputDecoration(
                        labelText: 'Combustível do estoque (L)'),
                    items: fuels
                        .map((f) => DropdownMenuItem(
                            value: '${f['id']}',
                            child: Text('${f['name']}',
                                overflow: TextOverflow.ellipsis)))
                        .toList(),
                    validator: (v) => v == null
                        ? 'Selecione o combustível cadastrado em litros.'
                        : null,
                    onChanged: (v) => line.input = v),
              if (line.source == 'external')
                TextFormField(
                    controller: line.name,
                    decoration: const InputDecoration(
                        labelText: 'Combustível comprado'),
                    maxLength: 160,
                    validator: (v) =>
                        v!.trim().isEmpty ? 'Informe o combustível.' : null),
              TextFormField(
                  controller: line.liters,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration:
                      const InputDecoration(labelText: 'Litros abastecidos'),
                  validator: (v) => decimalError(v!)),
              TextFormField(
                  controller: line.meter,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                      labelText: 'Horímetro no abastecimento'),
                  validator: (v) => decimalError(v!, zero: true)),
              if (line.source == 'external')
                TextFormField(
                    controller: line.price,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                        labelText: 'Preço por litro (R\$), se conhecido'),
                    validator: (v) {
                      if (v!.trim().isEmpty) return null;
                      try {
                        centsFromInput(v.trim());
                        return null;
                      } catch (_) {
                        return 'Informe reais com até duas casas decimais.';
                      }
                    }),
              TextFormField(
                  controller: line.location,
                  maxLength: 500,
                  decoration: const InputDecoration(
                      labelText: 'Local ou posto, se informado')),
              Text(line.source == 'stock'
                  ? 'Custo calculado pelo estoque. Não lance estes mesmos litros novamente em insumos.'
                  : 'Não baixa o estoque da propriedade. Sem preço, o custo fica não informado.'),
            ])));
  }

  Widget _line(_UseLine line, bool machine) {
    final options = items(widget.data, machine ? 'machines' : 'inputs')
        .where((m) =>
            !machine ||
            (m['archived'] != 1 &&
                (m['_sync_state'] == null || m['_sync_state'] == 'synced')))
        .toList();
    return Card(
        key: ObjectKey(line),
        child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(children: [
              Row(children: [
                Expanded(
                    child: DropdownButtonFormField<String>(
                        initialValue: line.id,
                        isExpanded: true,
                        decoration: InputDecoration(
                            labelText:
                                machine ? 'Máquina' : 'Insumo e unidade'),
                        items: options
                            .map((i) => DropdownMenuItem(
                                value: '${i['id']}',
                                child: Text(
                                    '${i['name']}${machine ? '' : ' (${i['unit']})'}',
                                    overflow: TextOverflow.ellipsis)))
                            .toList(),
                        onChanged: (value) {
                          line.id = value;
                          if (machine && value != null) {
                            line.first.text =
                                '${options.firstWhere((i) => i['id'] == value)['hour_meter']}';
                          }
                        },
                        validator: (value) =>
                            value == null ? 'Selecione uma opção.' : null)),
                IconButton(
                    onPressed: () => setState(() {
                          (machine ? _machines : _inputs).remove(line);
                          _retiredUses.add(line);
                        }),
                    icon: const Icon(Icons.close),
                    tooltip: 'Retirar linha')
              ]),
              TextFormField(
                  controller: line.first,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                      labelText: machine
                          ? 'Horímetro inicial'
                          : 'Quantidade consumida'),
                  validator: (v) => decimalError(v!, zero: machine)),
              if (machine)
                TextFormField(
                    controller: line.second,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration:
                        const InputDecoration(labelText: 'Horímetro final'),
                    validator: (v) => decimalError(v!, zero: true)),
            ])));
  }
}
