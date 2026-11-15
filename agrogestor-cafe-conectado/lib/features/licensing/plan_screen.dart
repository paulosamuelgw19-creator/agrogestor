import 'package:flutter/material.dart';
import '../auth/auth_service.dart';
import '../auth/user_model.dart';
import '../operations_v2/v2_store.dart';
import '../sync/farm_api_client.dart';

const planResourceLabels = {
  'properties': 'Fazendas',
  'machines': 'Máquinas e veículos',
  'users': 'Contas de acesso',
  'devices': 'Aparelhos',
  'implements': 'Implementos',
};

String planQuantity(Object? value, {bool unlimited = false}) =>
    value == null ? (unlimited ? 'Sem limite' : 'Não informado') : '$value';

class PlanScreen extends StatefulWidget {
  const PlanScreen({super.key});
  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

class _PlanScreenState extends State<PlanScreen> {
  Json? _data;
  String? _error, _userId, _token, _base, _farm;
  bool _busy = true, _cached = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  bool get _sameSession =>
      AuthService().currentUser?.id == _userId &&
      AuthService().currentUser?.farmId == _farm &&
      AuthService().accessToken == _token &&
      AuthService().currentUser?.role == UserRole.admin;

  Future<void> _load() async {
    final auth = AuthService();
    final user = auth.currentUser;
    final token = auth.accessToken;
    if (user?.role != UserRole.admin || user?.farmId == null || token == null) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Entre com a conta do gestor conectada ao PC gestor.';
        });
      }
      return;
    }
    final base = await FarmApiClient.instance.baseUrl;
    if (base == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
      _data = null;
    });
    _userId = user!.id;
    _farm = user.farmId;
    _token = token;
    _base = base;
    final store = await V2Store.open(
        baseUrl: base, farmId: user.farmId!, userId: user.id, token: token);
    try {
      final data = await store.client.get('/licensing/plan');
      if (!_sameSession || await FarmApiClient.instance.baseUrl != base) return;
      if (data['farm_id'] != user.farmId) {
        throw StateError('A organização da contratação não confere.');
      }
      await store.cache('commercial-plan', data);
      if (mounted) {
        setState(() {
          _data = data;
          _cached = false;
        });
      }
    } catch (e) {
      final data = await store.cached('commercial-plan');
      if (!_sameSession || await FarmApiClient.instance.baseUrl != base) return;
      if (mounted) {
        setState(() {
          _data = data;
          _cached = data != null;
          _error = v2Error(e);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _date(Object? value) {
    final parsed = DateTime.tryParse('$value');
    if (parsed == null) return 'Não informado';
    final d = parsed.toLocal();
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (AuthService().currentUser?.role != UserRole.admin ||
        (_data != null && !_sameSession)) {
      return const Center(child: Text('Área exclusiva do gestor.'));
    }
    final contract = _data?['contract'] as Map? ?? {};
    final usage = _data?['usage'] as Map? ?? {};
    final limits = contract['limits'] as Map? ?? {};
    return ListView(padding: const EdgeInsets.all(16), children: [
      Wrap(
          spacing: 16,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Meu plano', style: Theme.of(context).textTheme.headlineSmall),
            TextButton.icon(
                onPressed: _busy ? null : _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Conferir contratação')),
          ]),
      if (_busy) const LinearProgressIndicator(),
      if (_error != null)
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_error!)),
      if (_cached)
        const Text(
            'Última consulta salva neste aparelho. Uso e condições podem estar desatualizados.'),
      if (_data != null) ...[
        Card(
            child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${contract['plan_name'] ?? 'Não informado'}',
                          style: Theme.of(context).textTheme.titleLarge),
                      Text('Situação comercial: ${{
                            'active': 'Ativa',
                            'trial': 'Teste',
                            'suspended': 'Suspensa',
                            'expired': 'Vencida'
                          }[contract['status']] ?? 'Não informada'}'),
                      Text(
                          'Validade: ${contract['expires_at'] == null ? 'Sem data contratual de término' : _date(contract['expires_at'])}'),
                      Text(
                          'Última confirmação central: ${_date(_data!['confirmed_at'])}'),
                      Text(
                          'Revisão aplicada no PC gestor: ${_data!['revision']}'),
                      if (_data!['compatibility'] == true)
                        const Text(
                            'Configuração de compatibilidade. A validade da licença continua sendo verificada separadamente.'),
                      if (_data!['communication_error'] != null)
                        Text('${_data!['communication_error']}'),
                    ]))),
        for (final entry in planResourceLabels.entries)
          Card(
              child: ListTile(
                  title: Text(entry.value),
                  subtitle: Text(
                    'Utilizado: ${planQuantity(usage[entry.key])} · Contratado: ${planQuantity(limits[entry.key], unlimited: limits.containsKey(entry.key))}'
                    '${entry.key == 'users' ? '\nConvites reservados: ${planQuantity(usage['reserved_users'])}' : ''}'
                    '${usage[entry.key] is int && limits[entry.key] is int && usage[entry.key] + (entry.key == 'users' ? usage['reserved_users'] ?? 0 : 0) > limits[entry.key] ? '\nAcima do contratado. Históricos e trabalho nos recursos existentes são preservados.' : ''}',
                  ))),
        const SizedBox(height: 12),
        Text('Recursos habilitados',
            style: Theme.of(context).textTheme.titleMedium),
        Wrap(spacing: 8, children: [
          for (final module in contract['modules'] as List? ?? [])
            Chip(
                label: Text('${const {
                      'properties': 'Fazendas e talhões',
                      'fleet': 'Frota',
                      'operations': 'Operações',
                      'inventory': 'Estoque',
                      'fuel': 'Combustível',
                      'workshop': 'Oficina',
                      'tasks': 'Tarefas',
                      'reports': 'Relatórios'
                    }[module] ?? module}'))
        ]),
        Text('${_data!['message'] ?? ''}'),
        const SizedBox(height: 8),
        const Text(
            'Para alterar quantidades ou recursos, entre em contato com o responsável pelo seu contrato.'),
        if (_base != null) const SizedBox(height: 8),
      ],
    ]);
  }
}
