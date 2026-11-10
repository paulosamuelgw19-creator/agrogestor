import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../../app/app_theme.dart';
import '../../app/responsive_summary.dart';
import '../auth/auth_service.dart';
import '../auth/user_model.dart';
import '../licensing/licensing_service.dart';
import '../operations_v2/operations_screen.dart';
import '../operations_v2/v2_store.dart';
import '../operations_v2/management_reports_screen.dart';
import '../sync/sync_service.dart';
import '../maintenance/maintenance_screen.dart';
import 'work_store.dart';

const workStatus = {
  'assigned': 'A fazer',
  'reported': 'Ocorrência recebida',
  'analysis': 'Em análise',
  'in_progress': 'Em execução',
  'blocked': 'Impedida',
  'waiting_parts': 'Aguardando peças',
  'testing': 'Em testes',
  'completed': 'Concluída',
  'cancelled': 'Cancelada'
};
const workPriority = {
  'low': 'Baixa',
  'normal': 'Normal',
  'high': 'Alta',
  'urgent': 'Urgente'
};
const workKinds = {
  'planting': 'Plantio',
  'application': 'Aplicação',
  'management': 'Manejo',
  'harvest': 'Colheita',
  'transport': 'Transporte',
  'other': 'Outra'
};
const orderTransitions = {
  'reported': ['analysis', 'cancelled'],
  'analysis': ['analysis', 'in_progress', 'waiting_parts', 'cancelled'],
  'in_progress': [
    'in_progress',
    'waiting_parts',
    'testing',
    'completed',
    'cancelled'
  ],
  'waiting_parts': ['waiting_parts', 'in_progress', 'cancelled'],
  'testing': ['testing', 'in_progress', 'completed'],
  'completed': ['completed'],
  'cancelled': <String>[]
};
String workDate() => DateTime.now().toIso8601String().substring(0, 10);
String workWhen(Object? raw) {
  final date = DateTime.tryParse('$raw')?.toLocal();
  if (date == null) return '$raw';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(date.day)}/${two(date.month)}/${date.year} ${two(date.hour)}:${two(date.minute)}';
}

String workMoney(Object? cents) => cents == null
    ? 'Não informado'
    : 'R\$ ${(num.parse('$cents') / 100).toStringAsFixed(2).replaceAll('.', ',')}';

class WorkScreen extends StatefulWidget {
  const WorkScreen({super.key, this.section = 'panel', this.store});
  final String section;
  final WorkStore? store;
  @override
  State<WorkScreen> createState() => _WorkScreenState();
}

class _WorkScreenState extends State<WorkScreen> with WidgetsBindingObserver {
  WorkStore? _store;
  Json _data = {};
  bool _busy = false, _dialog = false, _online = false;
  String? _notice;
  String _section = 'panel';
  Timer? _timer;
  bool get admin => _data['role'] == 'admin';
  bool get mechanic =>
      (_data['role'] ?? AuthService().currentUser?.role.name) == 'mechanic';
  bool get operator =>
      (_data['role'] ?? AuthService().currentUser?.role.name) == 'operator';
  @override
  void initState() {
    super.initState();
    _store = widget.store;
    _section = widget.section;
    WidgetsBinding.instance.addObserver(this);
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_dialog && !_busy) _sync();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_dialog) _sync();
  }

  Future<void> _load({bool network = true}) async {
    final auth = AuthService();
    final user = auth.currentUser;
    final token = auth.accessToken;
    try {
      _store ??= await WorkStore.open();
      final local = await _store!.workspace();
      if (mounted &&
          auth.currentUser?.id == user?.id &&
          auth.accessToken == token) {
        setState(() => _data = local ?? {});
      }
      if (network) await _sync();
    } catch (error) {
      if (mounted) setState(() => _notice = v2Error(error));
    }
  }

  Future<void> _sync() async {
    if (_busy || _dialog || _store == null) return;
    final user = AuthService().currentUser?.id;
    final token = AuthService().accessToken;
    setState(() => _busy = true);
    try {
      await _store!.sync();
      _online = true;
      _notice = null;
    } catch (error) {
      _online = false;
      _notice = v2Error(error);
    }
    final local = await _store!.workspace();
    if (mounted &&
        AuthService().currentUser?.id == user &&
        AuthService().accessToken == token) {
      setState(() {
        _data = local ?? {};
        _busy = false;
      });
    }
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<Json?> _form(String title, List<WorkField> fields,
      {bool photos = false, Map<String, String>? lineOptions}) async {
    _dialog = true;
    try {
      return await showDialog<Json>(
          context: context,
          barrierDismissible: false,
          builder: (_) => WorkForm(
              title: title,
              fields: fields,
              photos: photos,
              lineOptions: lineOptions));
    } finally {
      _dialog = false;
    }
  }

  Future<void> _save(String path, Json body) async {
    final request = {'id': const Uuid().v4(), ...body};
    final photos =
        List<String>.from(request.remove('_photoPaths') as List? ?? []);
    final userAtStart = AuthService().currentUser?.id;
    final tokenAtStart = AuthService().accessToken;
    try {
      final farm = AuthService().currentUser?.farmId;
      final user = AuthService().currentUser?.id;
      final token = AuthService().accessToken;
      if (farm == null || _store == null) {
        throw StateError('Entre na conta do PC gestor.');
      }
      await LicensingService().requireWriteAccess(farm);
      if (!mounted ||
          AuthService().currentUser?.id != user ||
          AuthService().accessToken != token) {
        throw StateError('Sua sessão mudou. Abra a área novamente.');
      }
      await _store!.queue(path, request, photoPaths: photos);
      _message('Salvo no aparelho. Aguardando confirmação do PC gestor.');
      await _load(network: false);
      SyncService().notifyLocalChange();
      unawaited(_sync());
    } catch (error) {
      if (_store != null &&
          AuthService().currentUser?.id == userAtStart &&
          AuthService().accessToken == tokenAtStart) {
        try {
          await _store!.saveDraft(path, request, photoPaths: photos);
          await _load(network: false);
          _message('Rascunho preservado no aparelho. ${v2Error(error)}');
          return;
        } catch (_) {}
      }
      _message(v2Error(error));
    }
  }

  Map<String, String> _options(String kind, {bool Function(Json)? filter}) => {
        for (final item
            in items(_data, kind).where((i) => filter == null || filter(i)))
          '${item['id']}':
              '${item['name'] ?? item['title'] ?? item['plot_name'] ?? item['id']}${kind == 'inputs' ? ' (${item['unit']})' : kind == 'cycles' ? ' · ${item['plot_name']} · ${item['crop_name']}' : ''}'
      };
  Future<void> _createTask({String? assigneeId}) async {
    final cycles = items(_data, 'cycles');
    final users =
        items(_data, 'users').where((u) => u['role'] == 'operator').toList();
    if (cycles.isEmpty || users.isEmpty) {
      _message(
          'Cadastre uma safra/talhão e convide um operador antes de criar a tarefa.');
      return;
    }
    final body = await _form(
        'Nova tarefa do operador',
        [
          const WorkField('title', 'Título da tarefa'),
          WorkField('cycle_id', 'Propriedade, talhão e safra', options: {
            for (final c in cycles)
              '${c['id']}':
                  '${items(_data, 'properties').where((p) => p['id'] == c['property_id']).firstOrNull?['name']} · ${c['plot_name']} · ${c['name']}'
          }),
          WorkField('assignee_id', 'Operador responsável',
              initial: assigneeId,
              options: {for (final u in users) '${u['id']}': '${u['name']}'}),
          const WorkField('kind', 'Operação',
              options: workKinds, initial: 'management'),
          WorkField('due_on', 'Data prevista (AAAA-MM-DD)',
              type: 'date', initial: workDate()),
          const WorkField('priority', 'Prioridade',
              options: workPriority, initial: 'normal'),
          WorkField('machine_id', 'Máquina prevista',
              options: _options('machines'), optional: true),
          const WorkField('planned_area_ha', 'Área planejada (ha)',
              type: 'decimal', optional: true),
          const WorkField('planned_hours', 'Horas previstas de máquina',
              type: 'decimal0', optional: true),
          const WorkField(
              'planned_cost_cents', 'Custo previsto (R\$), se conhecido',
              type: 'money', optional: true),
          const WorkField('notes', 'Orientações e observações',
              type: 'notes', optional: true),
        ],
        lineOptions: _options('inputs'));
    if (body == null) return;
    body['planned_inputs'] = body.remove('_items');
    await _save('/work/tasks', body);
  }

  Future<void> _taskProgress(Json task) async {
    final body = await _form('Andamento da tarefa', [
      WorkField('status', 'Situação',
          options: {
            'in_progress': 'Em execução',
            'blocked': 'Impedida',
            if (admin) 'cancelled': 'Cancelar tarefa'
          },
          initial: 'in_progress'),
      const WorkField('description', 'Descrição do andamento ou impedimento',
          type: 'notes'),
    ]);
    if (body != null) {
      await _save('/work/tasks/${task['id']}/progress',
          {'expected_version': task['version'], ...body});
    }
  }

  Future<void> _createOrder({String? mechanicId}) async {
    if (items(_data, 'machines').isEmpty ||
        items(_data, 'properties').isEmpty) {
      _message('É preciso ter uma máquina vinculada à propriedade.');
      return;
    }
    final body = await _form(
        admin ? 'Nova ordem de manutenção' : 'Comunicar problema na máquina',
        [
          WorkField('property_id', 'Propriedade',
              options: _options('properties')),
          WorkField('machine_id', 'Máquina', options: _options('machines')),
          const WorkField('title', 'Título / problema identificado'),
          const WorkField('description', 'Descrição do problema',
              type: 'notes'),
          const WorkField('priority', 'Prioridade',
              options: workPriority, initial: 'normal'),
          const WorkField('stop_machine', 'A máquina deve ficar parada?',
              options: {
                'yes': 'Sim, aguardar liberação',
                'no': 'Não, ocorrência sem parada'
              },
              initial: 'yes'),
          if (admin)
            WorkField('mechanic_id', 'Mecânico responsável',
                initial: mechanicId,
                options:
                    _options('users', filter: (u) => u['role'] == 'mechanic'),
                optional: true),
          if (admin)
            const WorkField('due_on', 'Prazo (AAAA-MM-DD)',
                type: 'date', optional: true),
        ],
        photos: true);
    if (body != null) {
      body['stop_machine'] = body['stop_machine'] == 'yes';
      await _save('/work/orders', body);
    }
  }

  Future<void> _assign(Json order) async {
    final options = _options('users', filter: (u) => u['role'] == 'mechanic');
    if (options.isEmpty) {
      _message('Convide uma conta com perfil de mecânico primeiro.');
      return;
    }
    final body = await _form('Encaminhar ao mecânico', [
      WorkField('mechanic_id', 'Mecânico', options: options),
      WorkField('priority', 'Prioridade',
          options: workPriority, initial: order['priority'] as String),
      WorkField('due_on', 'Prazo (AAAA-MM-DD)',
          type: 'date', optional: true, initial: order['due_on'] as String?),
    ]);
    if (body != null) {
      await _save('/work/orders/${order['id']}/assign',
          {'expected_version': order['version'], ...body});
    }
  }

  Future<void> _progress(Json order) async {
    final allowed = orderTransitions[order['status']] ?? [];
    final body = await _form(
        'Atualizar andamento da manutenção',
        [
          const WorkField('description', 'Descrição do andamento',
              type: 'notes'),
          WorkField('status', 'Situação da manutenção',
              options: {
                for (final s in allowed)
                  if (s != 'cancelled' || admin) s: workStatus[s]!
              },
              initial: order['status'] == 'reported'
                  ? 'analysis'
                  : order['status'] as String),
          const WorkField(
              'machine_released', 'Ao concluir, a máquina está liberada?',
              options: {
                'yes': 'Sim, máquina liberada',
                'no': 'Não, permanece parada'
              },
              optional: true),
          if (order['status'] != 'completed') ...[
            const WorkField('labor_hours', 'Horas trabalhadas pelo mecânico',
                type: 'decimal0', optional: true),
            const WorkField(
                'labor_cost_cents', 'Custo da mão de obra (R\$), se informado',
                type: 'money', optional: true),
            const WorkField('service_cost_cents',
                'Outros serviços (R\$), sem repetir peças ou mão de obra',
                type: 'money', optional: true),
          ],
          const WorkField(
              'next_due_on', 'Próxima revisão por data (AAAA-MM-DD)',
              type: 'date', optional: true),
          const WorkField('next_due_meter', 'Próxima revisão no horímetro (h)',
              type: 'decimal0', optional: true),
        ],
        photos: true,
        lineOptions: order['status'] == 'completed'
            ? null
            : _options('inputs',
                filter: (i) => items(_data, 'stock').any((s) =>
                    s['property_id'] == order['property_id'] &&
                    s['input_id'] == i['id'])));
    if (body == null) return;
    final release = body['machine_released'];
    body['machine_released'] = release == null ? null : release == 'yes';
    if (body['status'] == 'completed' && release == null) {
      _message('Ao concluir, informe se a máquina está liberada.');
      return;
    }
    if (body['status'] != 'completed' && release == 'yes') {
      _message('Só libere a máquina após concluir a manutenção.');
      return;
    }
    body['parts'] = body.remove('_items') ?? <Json>[];
    await _save('/work/orders/${order['id']}/progress',
        {'expected_version': order['version'], ...body});
  }

  Future<void> _checklist() async {
    if (items(_data, 'machines').isEmpty) {
      _message('Nenhuma máquina disponível para conferir.');
      return;
    }
    final props = {
      ..._options('properties'),
      for (final o in items(_data, 'orders'))
        '${o['property_id']}': '${o['property_name']}'
    };
    final body = await _form(
        'Conferência da máquina',
        [
          WorkField('property_id', 'Propriedade', options: props),
          WorkField('machine_id', 'Máquina', options: _options('machines')),
          const WorkField('phase', 'Momento',
              options: {
                'before': 'Antes do trabalho',
                'after': 'Depois do trabalho'
              },
              initial: 'before'),
          const WorkField('_visual', 'Condição visual',
              options: {
                'yes': 'Conferida, sem problema relatado',
                'no': 'Precisa de atenção'
              },
              initial: 'yes'),
          const WorkField('_leaks', 'Vazamentos observados',
              options: {
                'yes': 'Não observei vazamentos',
                'no': 'Observei vazamento'
              },
              initial: 'yes'),
          const WorkField('_use', 'Condições de funcionamento',
              options: {
                'yes': 'Sem problema relatado',
                'no': 'Precisa de avaliação'
              },
              initial: 'yes'),
          const WorkField('notes', 'Observações do checklist',
              type: 'notes', optional: true),
        ],
        photos: true);
    if (body != null) {
      body['items'] = [
        for (final pair in {
          '_visual': 'Condição visual',
          '_leaks': 'Vazamentos',
          '_use': 'Funcionamento'
        }.entries)
          {'label': pair.value, 'ok': body.remove(pair.key) == 'yes'}
      ];
      await _save('/work/checklists', body);
    }
  }

  Future<void> _limit() async {
    final body = await _form('Definir estoque mínimo', [
      WorkField('property_id', 'Propriedade', options: _options('properties')),
      WorkField('input_id', 'Produto / peça', options: _options('inputs')),
      const WorkField('minimum_quantity', 'Quantidade mínima desejada',
          type: 'decimal0'),
    ]);
    if (body != null) await _save('/work/stock-limits', body);
  }

  Future<void> _stockItem() async {
    final body = await _form('Cadastrar produto ou peça no estoque', [
      WorkField('property_id', 'Fazenda / local de estoque',
          options: _options('properties')),
      const WorkField('name', 'Nome do produto ou peça'),
      const WorkField('category', 'Categoria', options: {
        'Combustíveis e lubrificantes': 'Combustível',
        'Peças e materiais de máquinas e implementos': 'Peças',
        'Químicos e minerais': 'Químicos e minerais'
      }),
      const WorkField('product_type', 'Tipo de produto (ex.: Diesel)'),
      const WorkField('unit', 'Unidade',
          options: {
            'L': 'Litros (padrão para diesel)',
            'kg': 'Quilogramas',
            'un': 'Unidades'
          },
          initial: 'L'),
      const WorkField('quantity', 'Quantidade inicial conferida',
          type: 'decimal0'),
      const WorkField('minimum_quantity', 'Quantidade mínima desejada',
          type: 'decimal0'),
      const WorkField('value_cents', 'Valor total do saldo inicial (R\$)',
          type: 'money', optional: true),
      WorkField('occurred_on', 'Data da conferência (AAAA-MM-DD)',
          type: 'date', initial: workDate()),
      const WorkField('notes', 'Observações', type: 'notes', optional: true),
    ]);
    if (body == null) return;
    if ('${body['product_type']}'.toLowerCase() == 'diesel' &&
        body['unit'] != 'L') {
      _message('Use litros para cadastrar diesel.');
      return;
    }
    await _save('/admin/stock-items', body);
  }

  Future<void> _photo(String kind, String target, String id) async {
    try {
      final bytes = await _store!.core.client.workPhoto(kind, target, id);
      if (mounted) {
        await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
                    content: InteractiveViewer(
                        child: Image.memory(Uint8List.fromList(bytes))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Fechar'))
                    ]));
      }
    } catch (error) {
      _message(v2Error(error));
    }
  }

  Widget _photos(String kind, String id, List<Json> values) =>
      Wrap(spacing: 8, children: [
        for (final p in values)
          TextButton.icon(
              onPressed: () => _photo(kind, id, '${p['id']}'),
              icon: const Icon(Icons.photo),
              label: const Text('Ver foto'))
      ]);

  String _reviewDetails(Json data) {
    return <String>[
      if (data['labor_hours'] != null) 'Mão de obra: ${data['labor_hours']} h',
      if (data['labor_cost_cents'] != null)
        'Custo da mão de obra: ${workMoney(data['labor_cost_cents'])}',
      if (data['service_cost_cents'] != null)
        'Serviços: ${workMoney(data['service_cost_cents'])}',
      if (data['quantity'] != null) 'Quantidade: ${data['quantity']}',
      for (final part in items(data, 'parts'))
        '${items(_data, 'inputs').where((i) => i['id'] == part['input_id']).firstOrNull?['name'] ?? 'Produto'}: ${part['quantity']}'
    ].join('\n');
  }

  Future<void> _resubmit(Json row) async {
    try {
      await _store!.validateForReview(row);
    } catch (error) {
      _message(v2Error(error));
      return;
    }
    if (!mounted) return;
    final data =
        Map<String, dynamic>.from(jsonDecode(row['payload'] as String) as Map);
    final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Conferir antes de reapresentar'),
                content: SingleChildScrollView(
                    child: Text(
                        'Descrição salva: ${data['description'] ?? data['title'] ?? 'Alteração de ordem'}\n${_reviewDetails(data)}\nSituação: ${workStatus[data['status']] ?? 'Não alterada'}\n\nConfira o andamento e as quantidades para não repetir um serviço. O PC verificará se o lançamento já foi confirmado. Se não foi, os mesmos dados serão reapresentados sobre a versão atual, preservando o pedido anterior.')),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Voltar')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Conferi, reapresentar'))
                ]));
    if (yes == true) {
      try {
        await _store!.resubmit(row);
        await _load(network: false);
      } catch (error) {
        _message(v2Error(error));
      }
    }
  }

  Widget _panel() {
    final tasks = items(_data, 'tasks'), orders = items(_data, 'orders');
    final activeTasks = tasks
        .where((t) => !['completed', 'cancelled'].contains(t['status']))
        .length;
    final stopped =
        items(_data, 'machines').where((m) => m['blocked'] == true).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (admin &&
          _store != null &&
          AuthService().currentUser?.role == UserRole.admin)
        ManagerOverview(
            core: _store!.core, revision: '${_data['generated_at']}'),
      if (admin)
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => Scaffold(
                          appBar: AppBar(title: const Text('Tarefas')),
                          body: WorkScreen(section: 'tasks', store: _store)))),
              icon: const Icon(Icons.assignment),
              label: const Text('Tarefas')),
          OutlinedButton.icon(
              onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => Scaffold(
                          appBar: AppBar(title: const Text('Funcionários')),
                          body: WorkScreen(section: 'team', store: _store)))),
              icon: const Icon(Icons.people),
              label: const Text('Funcionários')),
        ]),
      ResponsiveSummary(values: [
        if (!mechanic)
          (
            label:
                admin ? 'Tarefas dos operadores' : 'Minhas tarefas pendentes',
            value: activeTasks
          ),
        if (admin)
          (
            label: 'Manutenções dos mecânicos',
            value: orders
                .where((o) => !['completed', 'cancelled'].contains(o['status']))
                .length
          ),
        if (!operator) (label: 'Máquinas paradas', value: stopped),
        if (!operator)
          (
            label: 'Ordens em andamento',
            value: orders
                .where((o) => !['completed', 'cancelled'].contains(o['status']))
                .length
          ),
        if (!operator)
          (
            label: 'Aguardando peças',
            value: orders.where((o) => o['status'] == 'waiting_parts').length
          )
      ]),
      if (admin)
        TextButton.icon(
            onPressed: _limit,
            icon: const Icon(Icons.inventory_2_outlined),
            label: const Text('Definir estoque mínimo')),
      if (admin)
        TextButton.icon(
            onPressed: _stockItem,
            icon: const Icon(Icons.add_box_outlined),
            label: const Text('Cadastrar produto ou peça no estoque')),
      if (admin)
        ExpansionTile(title: const Text('Estoque por fazenda'), children: [
          for (final row in items(_data, 'stock'))
            ListTile(
                title: Text(
                    '${items(_data, 'inputs').where((p) => p['id'] == row['input_id']).firstOrNull?['name'] ?? 'Produto'} · ${items(_data, 'properties').where((p) => p['id'] == row['property_id']).firstOrNull?['name'] ?? 'Fazenda'}'),
                subtitle: Text(
                    'Disponível: ${row['available_quantity'] ?? 'Não informado'} ${items(_data, 'inputs').where((p) => p['id'] == row['input_id']).firstOrNull?['unit'] ?? ''} · mínimo: ${row['minimum_quantity'] ?? 'Não definido'}')),
          const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                  'Itens sem inventário inicial não têm saldo conferido.')),
        ]),
      const SizedBox(height: 12),
      const Text('Alertas e pendências',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      if (items(_data, 'alerts').isEmpty)
        const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Nenhum alerta nos registros recebidos.')),
      for (final a in items(_data, 'alerts')
          .where((a) => !operator || a['kind'] == 'late_task'))
        Card(
            child: ListTile(
                leading: const Icon(Icons.warning_amber),
                title: Text('${{
                  'late_task': 'Tarefa atrasada',
                  'late_order': 'Manutenção atrasada',
                  'preventive_due': 'Revisão pendente',
                  'low_stock': 'Estoque abaixo do mínimo'
                }[a['kind']]}'),
                subtitle: Text(
                    '${a['title']}${a['kind'] == 'low_stock' ? ' · ${items(_data, 'properties').where((p) => p['id'] == a['property_id']).firstOrNull?['name'] ?? 'Fazenda não informada'} · disponível ${a['available_quantity']} / mínimo ${a['minimum_quantity']}' : ''}'))),
      if (!mechanic)
        const Text('Agenda das tarefas',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      for (final t in tasks
          .where((t) => !['completed', 'cancelled'].contains(t['status'])))
        ListTile(
            title: Text('${t['due_on']} · ${t['title']}'),
            subtitle: Text(
                '${t['assignee_name'] ?? t['assignee_id']} · ${workPriority[t['priority']]}'),
            onTap: () => setState(() => _section = 'tasks')),
    ]);
  }

  Widget _team() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final role in ['operator', 'mechanic']) ...[
          Text(role == 'operator' ? 'Operadores' : 'Mecânicos',
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          for (final user
              in items(_data, 'users').where((u) => u['role'] == role))
            Builder(builder: (context) {
              final jobs = items(_data, role == 'operator' ? 'tasks' : 'orders')
                  .where((j) =>
                      j[role == 'operator' ? 'assignee_id' : 'mechanic_id'] ==
                          user['id'] &&
                      !['completed', 'cancelled'].contains(j['status']))
                  .toList();
              final current =
                  jobs.where((j) => j['status'] == 'in_progress').firstOrNull;
              return Card(
                  child: ListTile(
                      title: Text('${user['name']}'),
                      subtitle: Text(
                          '${current == null ? 'Sem execução informada' : 'Em execução: ${current['title']}'}\n${jobs.length} tarefa(s)/ordem(ns) aberta(s)'),
                      trailing: IconButton(
                          icon: const Icon(Icons.add_task),
                          tooltip: 'Adicionar tarefa',
                          onPressed: () => role == 'operator'
                              ? _createTask(assigneeId: user['id'] as String)
                              : _createOrder(
                                  mechanicId: user['id'] as String))));
            }),
        ],
      ]);

  Widget _tasks() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (admin)
          FilledButton.icon(
              onPressed: _createTask,
              icon: const Icon(Icons.add),
              label: const Text('Nova tarefa')),
        for (final t in items(_data, 'tasks'))
          Card(
              child: ExpansionTile(
                  key: PageStorageKey('task-${t['id']}'),
                  title: Text('${t['title']}'),
                  subtitle: Text(
                      '${workStatus[t['status']]} · ${t['due_on']}${t['_pending'] == true ? ' · aguardando envio' : ''}'),
                  children: [
                Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              '${t['property_name'] ?? ''}\n${t['plot_name'] ?? ''} · ${t['cycle_name'] ?? ''}'),
                          Text(
                              'Responsável: ${t['assignee_name'] ?? t['assignee_id']}\n${t['notes'] ?? ''}'),
                          Text(
                              'Planejado: área ${t['planned_area_ha'] ?? 'não informada'} ha · horas de máquina ${t['planned_hours'] ?? 'não informadas'}'),
                          for (final i in items(t, 'planned_inputs'))
                            Text(
                                'Insumo previsto: ${items(_data, 'inputs').where((p) => p['id'] == i['input_id']).firstOrNull?['name'] ?? i['input_id']} · ${i['quantity']}'),
                          if (admin)
                            Text(
                                'Custo previsto: ${workMoney(t['planned_cost_cents'])}'),
                          if (t['actual'] != null) ...[
                            Text(
                                'Realizado: área ${t['actual']['area_ha'] ?? 'não informada'} ha · horas de máquina ${t['actual']['machine_hours'] ?? 'não informadas'}'),
                            for (final i in items(
                                Map<String, dynamic>.from(t['actual'] as Map),
                                'inputs'))
                              Text(
                                  '${i['name']}: ${i['quantity']} ${i['unit']}'),
                            for (final fuel in items(
                                Map<String, dynamic>.from(t['actual'] as Map),
                                'refuelings'))
                              Text(
                                  'Abastecimento: ${fuel['machine_name']} · ${fuel['liters']} L · ${fuel['hour_meter']} h · ${fuel['source'] == 'stock' ? 'estoque da propriedade' : 'posto'}'),
                            if (admin)
                              Text(
                                  'Custo registrado: ${workMoney(t['actual']['registered_cost']['value'])} · escopo: máquinas, insumos e abastecimentos lançados'),
                            if (t['actual']['voided'] == true)
                              const Text(
                                  'Atenção: a operação foi estornada; tarefa exige conferência.'),
                          ],
                          if (t['_operation_pending'] == true)
                            const Text(
                                'Realizado salvo no aparelho. Confira a confirmação ou conflito em Operações.'),
                          if (t['_operation_pending'] != true &&
                              !['completed', 'cancelled'].contains(t['status']))
                            Wrap(spacing: 8, children: [
                              TextButton(
                                  onPressed: () => _taskProgress(t),
                                  child: const Text('Informar andamento')),
                              FilledButton(
                                  onPressed: () => Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                              builder: (_) => Scaffold(
                                                  appBar: AppBar(
                                                      title: const Text(
                                                          'Finalizar operação')),
                                                  body: OperationsScreen(
                                                      initialPropertyId:
                                                          t['property_id']
                                                              as String,
                                                      initialTask: t)))).then(
                                          (_) {
                                        if (mounted) _load();
                                      }),
                                  child: const Text('Finalizar operação')),
                            ]),
                          for (final entry in items(t, 'history'))
                            Text(
                                '${workWhen(entry['created_at'])} · ${entry['actor_id']}\n${entry['description']}'),
                        ]))
              ]))
      ]);
  Widget _orders() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!mechanic)
          FilledButton.icon(
              onPressed: _createOrder,
              icon: const Icon(Icons.add),
              label: Text(
                  admin ? 'Nova ordem de manutenção' : 'Comunicar problema')),
        if (admin)
          TextButton(
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const MaintenanceScreen())),
              child:
                  const Text('Consultar registros anteriores de manutenção')),
        for (final o in items(_data, 'orders'))
          Card(
              child: ExpansionTile(
                  key: PageStorageKey('order-${o['id']}'),
                  title: Text('${o['title']}'),
                  subtitle: Text(
                      '${o['machine_name'] ?? ''} · ${workStatus[o['status']]}${o['_pending'] == true ? ' · aguardando envio' : ''}'),
                  children: [
                Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              '${o['property_name'] ?? ''}\n${o['description']}'),
                          Text(
                              'Mecânico: ${o['mechanic_name'] ?? o['mechanic_id'] ?? 'A definir'} · prioridade ${workPriority[o['priority']]}\nPrazo: ${o['due_on'] ?? 'Não informado'}'),
                          Text(
                              o['machine_released'] == 1 &&
                                      o['machine_blocked'] != true
                                  ? 'Máquina liberada'
                                  : 'Máquina parada, aguardando liberação',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                          if (o['next_due_on'] != null ||
                              o['next_due_meter'] != null)
                            Text(
                                'Próxima revisão: ${o['next_due_on'] ?? 'sem data'} · ${o['next_due_meter'] ?? 'sem horímetro'} h'),
                          _photos('order', '${o['id']}', items(o, 'photos')),
                          for (final r in items(o, 'reservations'))
                            Text(
                                'Reservado: ${r['name'] ?? items(_data, 'inputs').where((i) => i['id'] == r['input_id']).firstOrNull?['name']} · ${r['quantity']} ${r['unit'] ?? ''}'),
                          if (admin && o['registered_cost'] != null)
                            Text(
                                'Custos registrados da manutenção: ${workMoney(o['registered_cost']['value'])}${o['registered_cost']['status'] == 'incomplete' ? ' · subtotal conhecido: ${workMoney(o['registered_cost']['known_subtotal'])}; faltam valores' : ''}. Separados da tarifa da máquina.'),
                          Wrap(spacing: 8, children: [
                            if (admin &&
                                !['completed', 'cancelled']
                                    .contains(o['status']))
                              TextButton(
                                  onPressed: () => _assign(o),
                                  child: const Text('Designar mecânico')),
                            if ((admin || mechanic) &&
                                o['status'] != 'cancelled')
                              FilledButton(
                                  onPressed: () => _progress(o),
                                  child: const Text('Adicionar andamento')),
                          ]),
                          const Divider(),
                          const Text('Diário da manutenção',
                              style: TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.bold)),
                          for (final p in items(o, 'progress'))
                            Card(
                                child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                              '${workWhen(p['created_at'])} · ${p['actor_name'] ?? p['actor_id']} · ${workStatus[p['status']]}'),
                                          Text('${p['description']}'),
                                          if (p['_pending'] == true)
                                            const Text(
                                                'Salvo no aparelho, aguardando confirmação.'),
                                          if (p['labor_hours'] != null)
                                            Text(
                                                'Mão de obra: ${p['labor_hours']} h'),
                                          for (final part in items(p, 'parts'))
                                            Text(
                                                '${part['name'] ?? items(_data, 'inputs').where((i) => i['id'] == part['input_id']).firstOrNull?['name']}: ${part['quantity']} ${part['unit'] ?? ''}'),
                                          if (admin &&
                                              p['labor_cost_cents'] != null)
                                            Text(
                                                'Mão de obra: ${workMoney(p['labor_cost_cents'])}'),
                                          if (admin &&
                                              p['service_cost_cents'] != null)
                                            Text(
                                                'Outros serviços: ${workMoney(p['service_cost_cents'])}'),
                                          for (final photo in List<String>.from(
                                              p['photos'] as List? ?? []))
                                            TextButton(
                                                onPressed: () => _photo('order',
                                                    '${o['id']}', photo),
                                                child: const Text(
                                                    'Ver foto desta atualização')),
                                          for (final f
                                              in items(p, 'local_photos'))
                                            Image.file(
                                                File(f['path'] as String),
                                                height: 120,
                                                errorBuilder: (_, __, ___) =>
                                                    const Text(
                                                        'Foto local indisponível')),
                                        ]))),
                        ]))
              ]))
      ]);
  Widget _checks() =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        FilledButton.icon(
            onPressed: _checklist,
            icon: const Icon(Icons.fact_check),
            label: const Text('Novo checklist')),
        const Text(
            'O checklist registra uma conferência; não substitui avaliação técnica nem libera automaticamente uma máquina.'),
        for (final c in items(_data, 'checklists'))
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            '${items(_data, 'machines').where((m) => m['id'] == c['machine_id']).firstOrNull?['name'] ?? 'Máquina'} · ${c['phase'] == 'before' ? 'Antes' : 'Depois'}'),
                        Text('${workWhen(c['created_at'])} · ${c['actor_id']}'),
                        for (final i in items(c, 'items'))
                          Text(
                              '${i['ok'] == true ? 'Conferido' : 'Precisa de atenção'} · ${i['label']}'),
                        Text('${c['notes'] ?? ''}'),
                        _photos('checklist', '${c['id']}', items(c, 'photos')),
                      ])))
      ]);
  @override
  Widget build(BuildContext context) => Scaffold(
          body: SafeArea(
              child:
                  ListView(padding: AppTheme.pagePadding(context), children: [
        Text(
            mechanic
                ? 'Oficina e andamento'
                : operator
                    ? 'Minhas tarefas'
                    : widget.section == 'orders'
                        ? 'Oficina'
                        : widget.section == 'team'
                            ? 'Funcionários'
                            : widget.section == 'tasks'
                                ? 'Tarefas'
                                : 'Visão geral',
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
        const Text(
            'Acompanhe o trabalho, registre o realizado e preserve o histórico.'),
        SizedBox(
            height: 4, child: _busy ? const LinearProgressIndicator() : null),
        if (_notice != null) Text(_notice!),
        if ((_data['_pending'] as int? ?? 0) > 0)
          Text(
              '${_data['_pending']} lançamento(s) salvo(s) no aparelho aguardando confirmação. ${(_data['_conflicts'] as int? ?? 0) > 0 ? 'Há conflito para conferir.' : ''}'),
        Wrap(spacing: 8, runSpacing: 8, children: [
          OutlinedButton.icon(
              onPressed: _busy ? null : _sync,
              icon: const Icon(Icons.sync),
              label:
                  Text(_online ? 'Atualizar e sincronizar' : 'Tentar conexão'))
        ]),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final pair in {
            if (widget.section == 'panel') 'panel': 'Visão geral',
            if (widget.section != 'orders' &&
                widget.section != 'team' &&
                !mechanic)
              'tasks': 'Tarefas',
            if (widget.section == 'orders' || mechanic) 'orders': 'Oficina',
            if (widget.section == 'team' && admin) 'team': 'Funcionários',
            if (widget.section == 'orders' || mechanic) 'checks': 'Checklists'
          }.entries)
            ChoiceChip(
                label: Text(pair.value),
                selected: _section == pair.key,
                onSelected: (_) => setState(() => _section = pair.key))
        ]),
        const SizedBox(height: 12),
        if (_data.isEmpty)
          const Text(
              'Conecte ao PC gestor para receber os registros autorizados desta conta.')
        else if (_section == 'team' && admin)
          _team()
        else if (_section == 'tasks')
          _tasks()
        else if (_section == 'orders' && !operator)
          _orders()
        else if (_section == 'checks')
          _checks()
        else
          _panel(),
        FutureBuilder<List<Json>>(
            future: _store?.pending(),
            builder: (context, snapshot) => Column(children: [
                  for (final row in snapshot.data ?? <Json>[])
                    if (['conflict', 'draft'].contains(row['state']))
                      Card(
                          child: ListTile(
                              title: const Text(
                                  'Lançamento precisa de conferência'),
                              subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('${row['error']}'),
                                    Wrap(spacing: 8, runSpacing: 8, children: [
                                      TextButton(
                                          onPressed: () => _resubmit(row),
                                          child: const Text('Conferir')),
                                      TextButton(
                                          onPressed: row['state'] == 'draft'
                                              ? null
                                              : () async {
                                                  try {
                                                    await _store!.retry(
                                                        row['id'] as String);
                                                    await _load(network: false);
                                                  } catch (e) {
                                                    _message(v2Error(e));
                                                  }
                                                },
                                          child: const Text('Reenviar'))
                                    ])
                                  ])))
                ])),
      ])));
}

class WorkField {
  const WorkField(this.keyName, this.label,
      {this.type = 'text', this.options, this.initial, this.optional = false});
  final String keyName, label, type;
  final Map<String, String>? options;
  final String? initial;
  final bool optional;
}

class WorkForm extends StatefulWidget {
  const WorkForm(
      {super.key,
      required this.title,
      required this.fields,
      this.photos = false,
      this.lineOptions});
  final String title;
  final List<WorkField> fields;
  final bool photos;
  final Map<String, String>? lineOptions;
  @override
  State<WorkForm> createState() => _WorkFormState();
}

class _WorkFormState extends State<WorkForm> {
  final _form = GlobalKey<FormState>();
  final _values = <String, String?>{};
  final _controllers = <String, TextEditingController>{};
  final _photos = <String>[];
  final _lines = <_WorkLine>[];
  final _retiredLines = <_WorkLine>[];
  bool _submitted = false;
  @override
  void initState() {
    super.initState();
    for (final field in widget.fields) {
      if (field.options != null) {
        _values[field.keyName] = field.initial;
      } else {
        _controllers[field.keyName] =
            TextEditingController(text: field.initial);
      }
    }
  }

  @override
  void dispose() {
    for (final line in [..._lines, ..._retiredLines]) {
      line.quantity.dispose();
    }
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pick(ImageSource source) async {
    try {
      final picked = await ImagePicker()
          .pickImage(source: source, imageQuality: 75, maxWidth: 1800);
      if (picked != null && mounted) setState(() => _photos.add(picked.path));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Não foi possível abrir a foto.')));
      }
    }
  }

  void _save() {
    if (_submitted) return;
    if (!_form.currentState!.validate()) return;
    final result = <String, dynamic>{};
    for (final field in widget.fields) {
      final value = field.options != null
          ? _values[field.keyName]
          : _controllers[field.keyName]!.text.trim();
      if (value == null || value.isEmpty) {
        result[field.keyName] = field.type == 'notes' ? '' : null;
        continue;
      }
      result[field.keyName] = field.type == 'money'
          ? centsFromInput(value)
          : field.type.startsWith('decimal')
              ? value.replaceAll(',', '.')
              : value;
    }
    result['_photoPaths'] = List<String>.from(_photos);
    if (widget.lineOptions != null) {
      result['_items'] = [
        for (final line in _lines)
          {
            'input_id': line.id,
            'quantity': line.quantity.text.trim().replaceAll(',', '.')
          }
      ];
    }
    _submitted = true;
    FocusScope.of(context).unfocus();
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.title),
          content: SizedBox(
              width: AppTheme.dialogWidth(context, maxWidth: 560),
              child: SingleChildScrollView(
                  child: Form(
                      key: _form,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        for (final field in widget.fields)
                          Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: field.options != null
                                  ? DropdownButtonFormField<String>(
                                      initialValue: _values[field.keyName],
                                      isExpanded: true,
                                      isDense: false,
                                      itemHeight: null,
                                      decoration: InputDecoration(
                                          labelText: field.label),
                                      items: [
                                        for (final e in field.options!.entries)
                                          DropdownMenuItem(
                                              value: e.key,
                                              child: Text(e.value,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis))
                                      ],
                                      onChanged: (v) =>
                                          _values[field.keyName] = v,
                                      validator: (v) =>
                                          !field.optional && v == null
                                              ? 'Selecione uma opção.'
                                              : null)
                                  : TextFormField(
                                      controller: _controllers[field.keyName],
                                      decoration: InputDecoration(
                                          labelText: field.label),
                                      minLines: field.type == 'notes' ? 2 : 1,
                                      maxLines: field.type == 'notes' ? 4 : 1,
                                      maxLength: field.type == 'notes'
                                          ? 2000
                                          : field.type == 'text'
                                              ? 160
                                              : 24,
                                      keyboardType: field.type
                                                  .startsWith('decimal') ||
                                              field.type == 'money'
                                          ? const TextInputType
                                              .numberWithOptions(decimal: true)
                                          : TextInputType.text,
                                      validator: (raw) {
                                        final v = raw?.trim() ?? '';
                                        if (v.isEmpty) {
                                          return field.optional
                                              ? null
                                              : 'Informe o valor.';
                                        }
                                        if (field.type.startsWith('decimal')) {
                                          return decimalError(v,
                                              zero: field.type == 'decimal0',
                                              optional: field.optional);
                                        }
                                        if (field.type == 'money') {
                                          try {
                                            centsFromInput(v);
                                          } catch (_) {
                                            return 'Informe reais com até duas casas decimais.';
                                          }
                                        }
                                        if (field.type == 'date') {
                                          final d = DateTime.tryParse(v);
                                          if (d == null ||
                                              !RegExp(r'^\d{4}-\d{2}-\d{2}$')
                                                  .hasMatch(v) ||
                                              d
                                                      .toIso8601String()
                                                      .substring(0, 10) !=
                                                  v) {
                                            return 'Use uma data válida: AAAA-MM-DD.';
                                          }
                                        }
                                        return null;
                                      })),
                        if (widget.lineOptions != null) ...[
                          for (final line in _lines)
                            Card(
                                child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: Column(children: [
                                      DropdownButtonFormField<String>(
                                          initialValue: line.id,
                                          isExpanded: true,
                                          isDense: false,
                                          itemHeight: null,
                                          decoration: const InputDecoration(
                                              labelText:
                                                  'Produto / peça e unidade'),
                                          items: [
                                            for (final item
                                                in widget.lineOptions!.entries)
                                              DropdownMenuItem(
                                                  value: item.key,
                                                  child: Text(item.value,
                                                      maxLines: 2,
                                                      overflow: TextOverflow
                                                          .ellipsis))
                                          ],
                                          onChanged: (value) => line.id = value,
                                          validator: (value) => value == null
                                              ? 'Selecione o item.'
                                              : null),
                                      TextFormField(
                                          controller: line.quantity,
                                          decoration: const InputDecoration(
                                              labelText:
                                                  'Quantidade na unidade do item'),
                                          keyboardType: const TextInputType
                                              .numberWithOptions(decimal: true),
                                          validator: (value) =>
                                              decimalError(value ?? '')),
                                      TextButton(
                                          onPressed: () => setState(() {
                                                _lines.remove(line);
                                                _retiredLines.add(line);
                                              }),
                                          child: const Text('Remover item')),
                                    ]))),
                          if (_lines.length < 100)
                            TextButton.icon(
                                onPressed: widget.lineOptions!.isEmpty
                                    ? null
                                    : () =>
                                        setState(() => _lines.add(_WorkLine())),
                                icon: const Icon(Icons.add),
                                label: const Text('Adicionar produto / peça')),
                        ],
                        if (widget.photos) ...[
                          const Text(
                              'Fotos opcionais (até 5). Ficam no aparelho até serem enviadas ao PC gestor.'),
                          if (_photos.length < 5)
                            PopupMenuButton<ImageSource>(
                                onSelected: _pick,
                                itemBuilder: (_) => const [
                                      PopupMenuItem(
                                          value: ImageSource.camera,
                                          child: Text('Tirar foto')),
                                      PopupMenuItem(
                                          value: ImageSource.gallery,
                                          child: Text('Escolher da galeria'))
                                    ],
                                child: const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: Text('Adicionar foto'))),
                          for (final path in _photos)
                            Row(children: [
                              Expanded(
                                  child: Image.file(File(path), height: 100)),
                              IconButton(
                                  onPressed: () =>
                                      setState(() => _photos.remove(path)),
                                  icon: const Icon(Icons.close))
                            ]),
                        ]
                      ])))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: _save, child: const Text('Salvar no aparelho'))
          ]);
}

class _WorkLine {
  String? id;
  final quantity = TextEditingController();
}
