import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../app/app_theme.dart';
import '../auth/auth_service.dart';
import '../auth/user_model.dart';
import '../reports/reports_screen.dart';
import '../sync/farm_api_client.dart';
import 'v2_store.dart';
import 'v2_export.dart';

const managementNames = {
  'overview': 'Visão geral',
  'operations': 'Operações agrícolas',
  'plots': 'Histórico dos talhões',
  'machines': 'Histórico das máquinas',
  'maintenance': 'Oficina e mecânicos',
  'stock': 'Estoque e movimentações',
  'season': 'Acompanhamento da safra',
  'costs': 'Custos por categoria',
  'production': 'Produção e produtividade agrícola',
  'implements': 'Histórico dos implementos',
};

class KnownCostChart extends StatelessWidget {
  const KnownCostChart({super.key, required this.categories});
  final Json categories;
  @override
  Widget build(BuildContext context) {
    final values = {
      for (final entry in categories.entries)
        entry.key: num.tryParse('${(entry.value as Map)['known_subtotal']}')
    };
    final maximum =
        values.values.whereType<num>().fold<num>(0, (a, b) => a > b ? a : b);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text('Custos conhecidos por categoria',
              style: TextStyle(fontWeight: FontWeight.bold))),
      const Text(
          'Barras com subtotais conhecidos. Valores ausentes não são zero; não representam custo integral.'),
      for (final entry in categories.entries)
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                      '${entry.key}: ${subtotalLabel(entry.value as Map)}${(entry.value as Map)['missing'] == 0 ? '' : ' · informações incompletas'}'),
                  if (values[entry.key] != null)
                    LinearProgressIndicator(
                        minHeight: 10,
                        value: maximum > 0
                            ? (values[entry.key]! / maximum)
                                .clamp(0, 1)
                                .toDouble()
                            : 0,
                        semanticsLabel:
                            '${entry.key}: subtotal conhecido ${subtotalLabel(entry.value as Map)}'),
                ])),
    ]);
  }
}

class ManagerOverview extends StatefulWidget {
  const ManagerOverview(
      {super.key, required this.core, required this.revision});
  final V2Store core;
  final String revision;
  @override
  State<ManagerOverview> createState() => _ManagerOverviewState();
}

class _ManagerOverviewState extends State<ManagerOverview> {
  Json? _data;
  Json _options = {};
  String? _property, _plot;
  DateTimeRange? _period;
  String? _error;
  bool _loading = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ManagerOverview old) {
    super.didUpdateWidget(old);
    if (old.revision != widget.revision) _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    final query = <String, dynamic>{
      if (_property != null) 'property_id': _property,
      if (_plot != null) 'plot_id': _plot,
      if (_period != null)
        'starts_on': _period!.start.toIso8601String().substring(0, 10),
      if (_period != null)
        'ends_on': _period!.end.toIso8601String().substring(0, 10),
    };
    final cacheKey = 'management/summary/${jsonEncode(query)}';
    try {
      _options = await widget.core.client.v2('GET', '/admin/reports/options');
      await widget.core.cache('management/summary-options', _options);
      final value = await widget.core.client
          .v2('GET', '/admin/reports/overview', query: query);
      // Cache only the compact overview; detail reports are loaded on demand.
      final compact = {
        for (final key in [
          'generated_at',
          'counts',
          'metrics',
          'programs',
          'categories',
          'filters'
        ])
          key: value[key]
      };
      await widget.core.cache(cacheKey, compact);
      if (mounted) {
        setState(() {
          _data = compact;
          _error = null;
        });
      }
    } catch (error) {
      if (error is DioException &&
          [401, 403].contains(error.response?.statusCode)) {
        if (mounted) {
          setState(() {
            _data = null;
            _error = v2Error(error);
          });
        }
      } else {
        final cached = await widget.core.cached(cacheKey);
        _options = await widget.core.cached('management/summary-options') ?? {};
        if (mounted) {
          setState(() {
            _data = cached;
            _error = 'Resumo sem atualização. ${v2Error(error)}';
          });
        }
      }
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) => Card(
      child: Padding(
          padding: const EdgeInsets.all(12),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Resumo da gestão',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            ExpansionTile(
                title: const Text('Filtrar fazenda, talhão e período'),
                children: [
                  DropdownButtonFormField<String>(
                      key: ValueKey('overview:$_property'),
                      initialValue: _property ?? '',
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Fazenda'),
                      items: [
                        const DropdownMenuItem(
                            value: '', child: Text('Todas as fazendas')),
                        for (final p in items(_options, 'properties'))
                          DropdownMenuItem(
                              value: '${p['id']}',
                              child: Text('${p['name']}',
                                  overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: _loading
                          ? null
                          : (v) {
                              setState(() {
                                _property = v == '' ? null : v;
                                _plot = null;
                                _data = null;
                              });
                              _load();
                            }),
                  DropdownButtonFormField<String>(
                      key: ValueKey('overview:$_property:$_plot'),
                      initialValue: _plot ?? '',
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Talhão'),
                      items: [
                        const DropdownMenuItem(
                            value: '', child: Text('Todos os talhões')),
                        for (final p in items(_options, 'plots').where((p) =>
                            _property == null || p['property_id'] == _property))
                          DropdownMenuItem(
                              value: '${p['id']}',
                              child: Text('${p['name']}',
                                  overflow: TextOverflow.ellipsis)),
                      ],
                      onChanged: _loading
                          ? null
                          : (v) {
                              setState(() {
                                _plot = v == '' ? null : v;
                                _data = null;
                              });
                              _load();
                            }),
                  Wrap(spacing: 8, children: [
                    OutlinedButton.icon(
                        onPressed: _loading
                            ? null
                            : () async {
                                final range = await showDateRangePicker(
                                    context: context,
                                    firstDate: DateTime(2000),
                                    lastDate: DateTime(2100),
                                    initialDateRange: _period);
                                if (range != null && mounted) {
                                  setState(() {
                                    _period = range;
                                    _data = null;
                                  });
                                  await _load();
                                }
                              },
                        icon: const Icon(Icons.date_range),
                        label: Text(_period == null
                            ? 'Selecionar período'
                            : '${_period!.start.toIso8601String().substring(0, 10)} a ${_period!.end.toIso8601String().substring(0, 10)}')),
                    if (_period != null)
                      TextButton(
                          onPressed: _loading
                              ? null
                              : () {
                                  setState(() {
                                    _period = null;
                                    _data = null;
                                  });
                                  _load();
                                },
                          child: const Text('Todo o período')),
                  ]),
                ]),
            if (_error != null) Text(_error!),
            if (_data == null && _loading) const LinearProgressIndicator(),
            if (_data != null) ...[
              Text('Atualizado em ${managementTime(_data!['generated_at'])}'),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final e in (_data!['counts'] as Map).entries.where((e) =>
                    !e.key.toString().startsWith('programs_') ||
                    items(_data!, 'programs').isNotEmpty))
                  Chip(
                      label: Text('${managementField('${e.key}')}: ${e.value}'))
              ]),
              for (final key in [
                'registered_area',
                'machine_hours',
                'consumed_fuel',
                'registered_cost'
              ])
                Text(
                    '${metricNames[key] ?? key}: ${displayMetric(Map<String, dynamic>.from((_data!['metrics'] as Map)[key] as Map))}'),
              KnownCostChart(
                  categories: Map<String, dynamic>.from(
                      _data!['categories'] as Map? ?? {})),
              for (final p in items(_data!, 'programs'))
                Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                              '${p['season_name']} · ${p['activity']} · ${p['percent']}%'),
                          LinearProgressIndicator(
                              value:
                                  ((num.tryParse('${p['percent']}') ?? 0) / 100)
                                      .clamp(0, 1)
                                      .toDouble()),
                        ])),
            ],
            TextButton.icon(
                onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const ManagementReportsScreen())),
                icon: const Icon(Icons.bar_chart),
                label: const Text('Abrir relatórios detalhados')),
          ])));
}

class ManagementReportsScreen extends StatefulWidget {
  const ManagementReportsScreen(
      {super.key,
      this.type = 'overview',
      this.propertyId,
      this.plotId,
      this.machineId,
      this.embedded = false});
  final String type;
  final String? propertyId, plotId, machineId;
  final bool embedded;
  @override
  State<ManagementReportsScreen> createState() => _ManagementReportsState();
}

class _ManagementReportsState extends State<ManagementReportsScreen> {
  late String _type = widget.type;
  late final Json _filters = {
    'property_id': widget.propertyId,
    'plot_id': widget.plotId,
    'machine_id': widget.machineId
  };
  Json _options = {}, _report = {};
  V2Store? _store;
  String? _sessionToken, _sessionUser, _sessionFarm, _sessionBase, _reportKey;
  String? _notice;
  bool _busy = false;
  bool _supports(String key) => !(switch (_type) {
        'stock' => [
            'plot_id',
            'cycle_id',
            'machine_id',
            'operator_id',
            'mechanic_id',
            'kind',
            'status'
          ],
        'maintenance' => ['plot_id', 'cycle_id', 'operator_id', 'kind'],
        'season' => ['machine_id', 'mechanic_id'],
        _ => <String>[],
      })
          .contains(key);
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final user = AuthService().currentUser;
      final token = AuthService().accessToken;
      final base = await FarmApiClient.instance.baseUrl;
      if (user == null ||
          user.role != UserRole.admin ||
          token == null ||
          base == null ||
          user.farmId == null) {
        throw StateError(
            'Entre como gestor e configure a conexão com o PC gestor.');
      }
      if (_sessionToken != token ||
          _sessionUser != user.id ||
          _sessionFarm != user.farmId ||
          _sessionBase != base) {
        _store = await V2Store.open(
            baseUrl: base, farmId: user.farmId!, userId: user.id, token: token);
        _sessionToken = token;
        _sessionUser = user.id;
        _sessionFarm = user.farmId;
        _sessionBase = base;
        _report = {};
        _options = {};
        _reportKey = null;
      }
      final query = {
        for (final e in _filters.entries)
          if (e.value != null && e.value != '') e.key: e.value
      };
      final key = 'management/$_type/${jsonEncode(query)}';
      Json report, options;
      try {
        options = await _store!.client.v2('GET', '/admin/reports/options');
        report = await _store!.client
            .v2('GET', '/admin/reports/$_type', query: query);
        await _store!.cache(key, report);
        await _store!.cache('management/options', options);
      } catch (error) {
        if (error is DioException &&
            [401, 403].contains(error.response?.statusCode)) {
          await _store!.db.delete('v2_mobile_cache',
              where: 'scope=?', whereArgs: [_store!.scope]);
          rethrow;
        }
        final cached = await _store!.cached(key);
        final choices = await _store!.cached('management/options');
        if (cached == null || choices == null) rethrow;
        report = cached;
        options = choices;
        _notice =
            'Sem atualização: exibindo relatório salvo em ${report['generated_at']}. ${v2Error(error)}';
      }
      if (AuthService().currentUser?.id != user.id ||
          AuthService().accessToken != token ||
          await FarmApiClient.instance.baseUrl != base) {
        throw StateError('Sua sessão mudou. Abra os relatórios novamente.');
      }
      if (mounted) {
        setState(() {
          _report = report;
          _reportKey = key;
          _options = options;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _notice = v2Error(error);
          _report = {};
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _choiceName(String key, Json row) {
    if (key == 'cycle_id') {
      return '${items(_options, 'plots').where((p) => p['id'] == row['plot_id']).firstOrNull?['name'] ?? 'Talhão'} · ${row['name']}';
    }
    if (key == 'plot_id') {
      return '${items(_options, 'properties').where((p) => p['id'] == row['property_id']).firstOrNull?['name'] ?? 'Fazenda'} · ${row['name']}';
    }
    return '${row['name']}';
  }

  Widget _filter(String key, String label, List<Json> choices) =>
      !_supports(key)
          ? const SizedBox.shrink()
          : SizedBox(
              width: 230,
              child: DropdownButtonFormField<String>(
                  key: ValueKey('$key:${_filters[key]}'),
                  initialValue: choices.any((c) => c['id'] == _filters[key])
                      ? _filters[key] as String?
                      : null,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: label),
                  items: [
                    const DropdownMenuItem<String>(
                        value: '', child: Text('Todos')),
                    ...choices.map((r) => DropdownMenuItem(
                        value: '${r['id']}',
                        child: Text(_choiceName(key, r),
                            maxLines: 2, overflow: TextOverflow.ellipsis)))
                  ],
                  onChanged: _busy
                      ? null
                      : (v) {
                          setState(() {
                            _filters[key] = v == '' ? null : v;
                            if (key == 'property_id') {
                              _filters['plot_id'] = null;
                              _filters['cycle_id'] = null;
                            } else if (key == 'plot_id') {
                              _filters['cycle_id'] = null;
                            }
                          });
                          _load();
                        }));

  Future<void> _export(bool pdf) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _checkSession();
      if (_reportKey == null || await _store!.cached(_reportKey!) == null) {
        throw StateError(
            'Atualize o relatório antes de exportar. Seu acesso offline venceu.');
      }
      final snapshot =
          Map<String, dynamic>.from(jsonDecode(jsonEncode(_report)) as Map);
      final bytes = pdf ? await reportPdf(snapshot) : reportXlsx(snapshot);
      await _checkSession();
      await FilePicker.saveFile(
          fileName:
              'AgroGestor-${snapshot['report_type']}.${pdf ? 'pdf' : 'xlsx'}',
          mimeType: pdf
              ? 'application/pdf'
              : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
          bytes: bytes);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(v2Error(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkSession() async {
    final user = AuthService().currentUser;
    if (user?.role != UserRole.admin ||
        user?.id != _sessionUser ||
        user?.farmId != _sessionFarm ||
        AuthService().accessToken != _sessionToken ||
        await FarmApiClient.instance.baseUrl != _sessionBase) {
      throw StateError('Sua sessão mudou. Abra os relatórios novamente.');
    }
  }

  Future<void> _program() async {
    final body = await showDialog<Json>(
        context: context,
        builder: (_) => ActivityPlanDialog(options: _options));
    if (body == null || !mounted) return;
    try {
      await _checkSession();
      await _store!.client.v2('POST', '/activity-plans', data: body);
      await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(v2Error(error))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (AuthService().currentUser?.role != UserRole.admin ||
        _sessionUser != null &&
            (AuthService().currentUser?.id != _sessionUser ||
                AuthService().currentUser?.farmId != _sessionFarm)) {
      return const Center(
          child: Text('Relatórios administrativos exclusivos do gestor.'));
    }
    final content = ListView(padding: AppTheme.pagePadding(context), children: [
      Text(managementNames[_type]!,
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
      if (_busy)
        const Column(children: [
          LinearProgressIndicator(),
          Text('Preparando relatório…')
        ]),
      if (_notice != null)
        Text(_notice!, style: const TextStyle(color: Colors.deepOrange)),
      ExpansionTile(
          title: const Text('Selecionar relatório e filtros'),
          subtitle: Text(
              '${_filters.values.where((v) => v != null && v != "").length} filtro(s) selecionado(s)'),
          children: [
            Wrap(spacing: 12, runSpacing: 12, children: [
              SizedBox(
                  width: 260,
                  child: DropdownButtonFormField<String>(
                      initialValue: _type,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Relatório'),
                      items: managementNames.entries
                          .map((e) => DropdownMenuItem(
                              value: e.key, child: Text(e.value)))
                          .toList(),
                      onChanged: _busy
                          ? null
                          : (v) {
                              setState(() {
                                _type = v!;
                                _filters.removeWhere(
                                    (key, value) => !_supports(key));
                              });
                              _load();
                            })),
              _filter('property_id', 'Fazenda', items(_options, 'properties')),
              _filter(
                  'plot_id',
                  'Talhão',
                  items(_options, 'plots')
                      .where((p) =>
                          _filters['property_id'] == null ||
                          p['property_id'] == _filters['property_id'])
                      .toList()),
              _filter(
                  'cycle_id',
                  'Safra / ciclo',
                  items(_options, 'cycles')
                      .where((c) =>
                          _filters['plot_id'] == null ||
                          c['plot_id'] == _filters['plot_id'])
                      .toList()),
              _filter('machine_id', 'Máquina', items(_options, 'machines')),
              _filter(
                  'operator_id',
                  'Operador',
                  items(_options, 'users')
                      .where((u) => u['role'] == 'operator')
                      .toList()),
              _filter(
                  'mechanic_id',
                  'Mecânico',
                  items(_options, 'users')
                      .where((u) => u['role'] == 'mechanic')
                      .toList()),
              _filter('kind', 'Atividade', [
                for (final e in {
                  'planting': 'Plantio',
                  'application': 'Aplicação',
                  'management': 'Manejo',
                  'harvest': 'Colheita',
                  'transport': 'Transporte',
                  'other': 'Outras'
                }.entries)
                  {'id': e.key, 'name': e.value}
              ]),
              _filter('status', 'Status', [
                for (final e in {
                  'pending': 'Pendente',
                  'in_progress': 'Em andamento',
                  'completed': 'Concluída',
                  'reported': 'Relatada',
                  'analysis': 'Diagnóstico',
                  'waiting_parts': 'Aguardando peças',
                  'testing': 'Em teste',
                  'cancelled': 'Cancelada'
                }.entries)
                  {'id': e.key, 'name': e.value}
              ]),
            ]),
          ]),
      Wrap(spacing: 8, children: [
        TextButton.icon(
            onPressed: _busy
                ? null
                : () async {
                    final range = await showDateRangePicker(
                        context: context,
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100));
                    if (range == null || !mounted) return;
                    setState(() {
                      _filters['starts_on'] =
                          range.start.toIso8601String().substring(0, 10);
                      _filters['ends_on'] =
                          range.end.toIso8601String().substring(0, 10);
                    });
                    _load();
                  },
            icon: const Icon(Icons.date_range),
            label: Text(_filters['starts_on'] == null
                ? 'Selecionar período'
                : '${_filters['starts_on']} a ${_filters['ends_on']}')),
        TextButton(
            onPressed: _busy
                ? null
                : () {
                    setState(_filters.clear);
                    _load();
                  },
            child: const Text('Limpar filtros')),
        OutlinedButton.icon(
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
            label: const Text('Atualizar')),
        TextButton(
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const ReportsScreen())),
            child: const Text('Relatórios dos registros anteriores')),
        if (_report.isNotEmpty) ...[
          TextButton(
              onPressed: _busy ? null : () => _export(true),
              child: const Text('Exportar PDF')),
          TextButton(
              onPressed: _busy ? null : () => _export(false),
              child: const Text('Exportar Excel')),
          if (_type == 'season' || _type == 'overview')
            FilledButton.icon(
                onPressed: _busy ? null : _program,
                icon: const Icon(Icons.add_task),
                label: const Text('Programar atividade da safra')),
        ]
      ]),
      if (_report.isNotEmpty) ...[
        Text('Gerado em: ${managementTime(_report['generated_at'])}'),
        const Text(
            'Somente custos registrados. Valores ausentes não são zero.'),
        ExpansionTile(
            title: const Text('Como interpretar este relatório'),
            children: [Text('${_report['scope']}')]),
        Wrap(spacing: 12, runSpacing: 8, children: [
          for (final e in (_report['counts'] as Map? ?? {}).entries)
            Chip(label: Text('${managementField('${e.key}')}: ${e.value}'))
        ]),
        for (final e in (_report['metrics'] as Map? ?? {}).entries)
          ListTile(
              title: Text(metricNames[e.key] ?? managementField('${e.key}')),
              subtitle: Text(
                  '${displayMetric(Map<String, dynamic>.from(e.value as Map))} · ${metricStatus((e.value as Map)['status'])}')),
        for (final e in (_report['categories'] as Map? ?? {}).entries)
          ListTile(
              title: Text('${e.key}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (context) => SafeArea(
                      child: SizedBox(
                          height: MediaQuery.sizeOf(context).height * .7,
                          child: ListView(
                              padding: const EdgeInsets.all(16),
                              children: [
                                Text('Origem dos custos: ${e.key}',
                                    style: const TextStyle(
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold)),
                                for (final line in items(_report, 'ledger')
                                    .where((l) => l['category'] == e.key))
                                  Padding(
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 8),
                                      child: SelectableText(
                                          managementDetails(line))),
                                if (!items(_report, 'ledger')
                                    .any((l) => l['category'] == e.key))
                                  const Text(
                                      'Nenhum custo registrado nesta categoria.'),
                              ])))),
              subtitle: Text(
                  '${displayMetric(Map<String, dynamic>.from(e.value as Map))} · subtotal conhecido ${subtotalLabel(e.value as Map)}')),
        for (final group in items(_report, 'programs'))
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                            '${group['season_name']} · ${managementDetails(group['activity'])}'),
                        LinearProgressIndicator(
                            value: ((num.tryParse('${group['percent']}') ?? 0) /
                                    100)
                                .clamp(0, 1)
                                .toDouble()),
                        Text(
                            '${group['completed_ha']} / ${group['planned_ha']} ha · ${group['percent']}%'),
                        for (final p in items(group, 'plots'))
                          Text(
                              '${p['property_name']} · ${p['plot_name']}: ${p['completed_ha']} / ${p['planned_ha']} ha'),
                        Text(
                            'Talhões concluídos: ${group['completed_plots']} · pendentes: ${group['pending_plots']}'),
                        if (group['forecast'] != null)
                          Text(
                              'Estimativa de término: ${(group['forecast'] as Map)['completion_date']}. ${(group['forecast'] as Map)['assumption']}')
                        else
                          const Text(
                              'Previsão de término não disponível com os registros atuais.'),
                      ]))),
        if (_report['productivity'] != null &&
            ['operations', 'machines', 'plots'].contains(_type))
          ExpansionTile(
              title: const Text('Produtividade registrada'),
              children: [
                Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                        managementDetails(_report['productivity'])))
              ]),
        for (final section in switch (_type) {
          'overview' => ['properties', 'plots'],
          'operations' => ['operations'],
          'plots' => ['plots', 'operations', 'harvest'],
          'production' => ['harvest', 'operations'],
          'machines' => ['machines', 'operations', 'maintenance'],
          'implements' => ['implements'],
          'maintenance' => ['maintenance'],
          'stock' => ['stock'],
          'season' => ['programs', 'operations'],
          _ => ['ledger']
        }) ...[
          Text(managementField(section),
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          if (items(_report, section).isEmpty)
            const Text('Nenhum registro corresponde aos filtros.'),
          for (final r in items(_report, section))
            Card(
                child: ExpansionTile(
                    title: Text(
                        '${r['title'] ?? r['name'] ?? r['property_name'] ?? r['description'] ?? r['id'] ?? 'Registro'}'),
                    subtitle: Text(
                        '${r['performed_on'] ?? r['created_at'] ?? r['date'] ?? ''} ${r['plot_name'] ?? r['machine_name'] ?? ''}'),
                    children: [
                  Padding(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(managementDetails(r)))
                ])),
        ],
      ],
    ]);
    return widget.embedded
        ? content
        : Scaffold(
            appBar: AppBar(title: const Text('Relatórios')), body: content);
  }
}

class ActivityPlanDialog extends StatefulWidget {
  const ActivityPlanDialog({super.key, required this.options});
  final Json options;
  @override
  State<ActivityPlanDialog> createState() => _ActivityPlanDialogState();
}

class _ActivityPlanDialogState extends State<ActivityPlanDialog> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController(),
      _season = TextEditingController(),
      _notes = TextEditingController();
  final Map<String, TextEditingController> _selected = {};
  String _activity = 'harvest';
  @override
  void dispose() {
    for (final c in [_title, _season, _notes, ..._selected.values]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('Programar atividade da safra'),
          content: SizedBox(
              width: AppTheme.dialogWidth(context),
              child: SingleChildScrollView(
                  child: Form(
                      key: _form,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        TextFormField(
                            controller: _title,
                            decoration: const InputDecoration(
                                labelText: 'Nome da programação'),
                            validator: (v) => v == null || v.trim().isEmpty
                                ? 'Informe o nome'
                                : null),
                        TextFormField(
                            controller: _season,
                            decoration: const InputDecoration(
                                labelText: 'Safra (ex.: Café 2026)'),
                            validator: (v) => v == null || v.trim().isEmpty
                                ? 'Informe a safra'
                                : null),
                        DropdownButtonFormField<String>(
                            initialValue: _activity,
                            items: [
                              for (final e in {
                                'harvest': 'Colheita',
                                'planting': 'Plantio',
                                'application': 'Aplicação',
                                'management': 'Manejo',
                                'other': 'Outras'
                              }.entries)
                                DropdownMenuItem(
                                    value: e.key, child: Text(e.value))
                            ],
                            onChanged: (v) => _activity = v!),
                        const Text(
                            'Selecione apenas os talhões/ciclos programados. O progresso começa em zero nesta programação; operações antigas não são convertidas automaticamente.'),
                        for (final c in items(widget.options, 'cycles')) ...[
                          CheckboxListTile(
                              title: Text('${c['name']}'),
                              value: _selected.containsKey(c['id']),
                              onChanged: (v) => setState(() {
                                    if (v == true) {
                                      _selected[c['id'] as String] =
                                          TextEditingController(
                                              text: c['area_ha']?.toString());
                                    } else {
                                      _selected.remove(c['id'])?.dispose();
                                    }
                                  })),
                          if (_selected.containsKey(c['id']))
                            TextFormField(
                                controller: _selected[c['id']],
                                decoration: const InputDecoration(
                                    labelText: 'Área programada (ha)'),
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                        decimal: true),
                                validator: (v) => (num.tryParse((v ?? '')
                                                .replaceAll(',', '.')) ??
                                            0) >
                                        0
                                    ? null
                                    : 'Informe uma área positiva'),
                        ],
                        TextFormField(
                            controller: _notes,
                            decoration: const InputDecoration(
                                labelText: 'Observações')),
                      ])))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () {
                  if (!_form.currentState!.validate() || _selected.isEmpty) {
                    return;
                  }
                  Navigator.pop(context, {
                    'id': const Uuid().v4(),
                    'title': _title.text.trim(),
                    'season_name': _season.text.trim(),
                    'activity': _activity,
                    'notes': _notes.text.trim(),
                    'plots': [
                      for (final e in _selected.entries)
                        {
                          'cycle_id': e.key,
                          'planned_ha': e.value.text.replaceAll(',', '.')
                        }
                    ]
                  });
                },
                child: const Text('Salvar programação'))
          ]);
}
