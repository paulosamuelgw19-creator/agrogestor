import 'catalog_review.dart';
import '../services/services_screen.dart';
import 'geography_screen.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';
import '../../app/app_theme.dart';
import '../auth/auth_service.dart';
import '../operations_v2/operations_screen.dart';
import '../operations_v2/management_reports_screen.dart';
import '../operations_v2/v2_store.dart';
import '../sync/farm_api_client.dart';
import '../sync/sync_service.dart';
import 'catalog_store.dart';

class CatalogConnection {
  CatalogConnection(this.store, this.base, this.userId, this.token);
  final CatalogStore store;
  final String userId;
  final String? base, token;
  static Future<CatalogConnection> open() async {
    final user = AuthService().currentUser;
    final token = AuthService().accessToken;
    final base = await FarmApiClient.instance.baseUrl;
    if (user == null) {
      throw StateError('Entre no aplicativo para acessar os cadastros.');
    }
    return CatalogConnection(await CatalogStore.open(), base, user.id, token);
  }

  Future<Json> request(String method, String path,
      {Json? data, Json? query}) async {
    Future<void> check() async {
      if (await FarmApiClient.instance.baseUrl != base ||
          AuthService().currentUser?.id != userId ||
          AuthService().accessToken != token) {
        throw StateError('Sua sessão mudou. Abra a área novamente.');
      }
    }

    await check();
    Json result;
    if (method != 'GET') {
      result = await store.save(method, path, data!);
      if (!FarmApiClient.standaloneLocalMode) {
        SyncService().notifyLocalChange();
        unawaited(store.sync());
      }
    } else if (path == '/capabilities') {
      result = {'propertyCatalog': true, 'offlineCatalog': true};
    } else if (path == '/workspace') {
      result = await store.workspace();
    } else if (path == '/properties') {
      result = {
        'items': await store.records('properties',
            archived: query?['include_archived'] == true)
      };
    } else {
      final segments = path.split('/').where((s) => s.isNotEmpty).toList();
      final kind = segments.last;
      result = {
        'items': (await store.records(kind,
                archived: query?['include_archived'] == true))
            .where((r) => r['property_id'] == segments[1])
            .toList()
      };
    }
    await check();
    return result;
  }
}

class PropertiesScreen extends StatefulWidget {
  const PropertiesScreen({super.key});
  @override
  State<PropertiesScreen> createState() => _PropertiesState();
}

class _PropertiesState extends State<PropertiesScreen> {
  CatalogConnection? _connection;
  Json _root = {};
  List<Json> _properties = [];
  bool _busy = false, _archived = false;
  String? _error;
  Timer? _timer;
  bool _initialSync = false;
  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_busy) _load();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final connection = await CatalogConnection.open();
      final caps = await connection.request('GET', '/capabilities');
      if (caps['propertyCatalog'] != true) {
        throw StateError(
            'Atualize e habilite o servidor do piloto para usar Propriedades e Talhões.');
      }
      final responses = await Future.wait([
        connection.request('GET', '/workspace'),
        connection.request('GET', '/properties',
            query: {'include_archived': _archived}),
      ]);
      if (!mounted) return;
      setState(() {
        _connection = connection;
        _root = responses[0];
        _properties = items(responses[1], 'items');
      });
      if (!_initialSync) {
        _initialSync = true;
        unawaited(connection.store.sync().then((_) {
          if (mounted) _load();
        }));
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = v2Error(error);
          _root = {};
          _properties = [];
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _create() async {
    final data = await showDialog<Json>(
        context: context,
        builder: (_) =>
            CatalogEntityDialog(responsibles: items(_root, 'responsibles')));
    if (data == null || !mounted || _connection == null) return;
    setState(() => _busy = true);
    try {
      await _connection!.request('POST', '/properties',
          data: {'id': const Uuid().v4(), ...data});
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(v2Error(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
          body: SafeArea(
              child:
                  ListView(padding: AppTheme.pagePadding(context), children: [
        const Text('Propriedades e Talhões',
            style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: AppTheme.forest)),
        const Text(FarmApiClient.standaloneLocalMode
            ? 'Cadastre sua fazenda e seus talhões. Os dados ficam salvos neste aparelho.'
            : 'Gerente e operador podem cadastrar no aparelho. O PC sincroniza os dados conforme as permissões de cada conta.'),
        if (_root['_notice'] != null)
          Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text('${_root['_notice']}')),
        if (_busy) const LinearProgressIndicator(),
        if ((_root['_archived_count'] as int? ?? 0) > 0)
          SwitchListTile(
              title: const Text('Mostrar também arquivadas'),
              value: _archived,
              onChanged: _busy
                  ? null
                  : (value) {
                      setState(() => _archived = value);
                      _load();
                    }),
        if (_error != null)
          Card(
              child: Padding(
                  padding: const EdgeInsets.all(16), child: Text(_error!))),
        Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                  onPressed: _busy ? null : _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Atualizar')),
              if (!FarmApiClient.standaloneLocalMode)
                IconButton(
                    onPressed: _connection == null || _busy
                        ? null
                        : () async {
                            await _connection!.store.sync();
                            if (mounted) await _load();
                          },
                    icon: const Icon(Icons.sync),
                    tooltip: 'Sincronizar com o PC gestor'),
              if ((_root['_pending'] as int? ?? 0) > 0)
                OutlinedButton.icon(
                    onPressed: () async {
                      await reviewCatalogDrafts(context);
                      if (mounted) await _load();
                    },
                    icon: const Icon(Icons.fact_check_outlined),
                    label: const Text('Conferir cadastros salvos')),
              if (_root['can_create_catalog'] == true) ...[
                FilledButton.icon(
                    onPressed: _busy ? null : _create,
                    icon: const Icon(Icons.add),
                    label: const Text('Adicionar Fazenda')),
              ]
            ]),
        for (final property in _properties)
          Card(
              child: ListTile(
                  leading: Icon(property['archived'] == 1
                      ? Icons.archive_outlined
                      : Icons.landscape_outlined),
                  title: Text('${property['name']}'),
                  subtitle: Text(
                      '${_area(property['area_ha'])}\n${property['location'] ?? ''}${property['archived'] == 1 ? '\nArquivada' : ''}\n${FarmApiClient.standaloneLocalMode ? 'Salva neste aparelho' : property['_sync_state'] == 'synced' ? 'Compartilhada no PC' : property['_sync_state'] == 'conflict' ? 'Precisa de conferência' : 'Salva no aparelho · aguardando sincronização'}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy
                      ? null
                      : () async {
                          await Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => PropertyDetailsScreen(
                                      connection: _connection!,
                                      property: property,
                                      canCreate:
                                          _root['can_create_catalog'] == true,
                                      admin: _root['administrator'] == true)));
                          if (mounted) await _load();
                        })),
        if (!_busy && _error == null && _properties.isEmpty)
          const Padding(
              padding: EdgeInsets.all(20),
              child: Text('Nenhuma propriedade disponível para esta conta.')),
      ])));
}

String _area(Object? area) => area == null ? 'Área não informada' : '$area ha';

class PropertyDetailsScreen extends StatefulWidget {
  const PropertyDetailsScreen(
      {super.key,
      required this.connection,
      required this.property,
      this.canCreate = false,
      required this.admin});
  final CatalogConnection connection;
  final Json property;
  final bool admin;
  final bool canCreate;
  @override
  State<PropertyDetailsScreen> createState() => _PropertyDetailsState();
}

class _PropertyDetailsState extends State<PropertyDetailsScreen> {
  Json? _property;
  List<Json> _plots = [], _cycles = [];
  bool _busy = false, _showArchived = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _property = widget.property;
    _load();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final connection = widget.connection;
      final properties = await connection
          .request('GET', '/properties', query: {'include_archived': true});
      final property = items(properties, 'items')
          .where((p) => p['id'] == widget.property['id'])
          .firstOrNull;
      if (property == null) {
        throw StateError('Propriedade indisponível para esta conta.');
      }
      final results = await Future.wait([
        connection.request('GET', '/properties/${property['id']}/plots',
            query: {'include_archived': _showArchived}),
        connection.request('GET', '/properties/${property['id']}/cycles'),
      ]);
      if (mounted) {
        setState(() {
          _property = property;
          _plots = items(results[0], 'items');
          _cycles = items(results[1], 'items');
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = v2Error(error);
          _property = null;
          _plots = [];
          _cycles = [];
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(String method, String path, Json data) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.connection
          .request(method, path, data: {'id': const Uuid().v4(), ...data});
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(v2Error(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (mounted) await _load();
  }

  Future<void> _edit({Json? plot, bool newPlot = false}) async {
    final entity = newPlot ? null : plot ?? _property;
    final people = await widget.connection.store.records('responsibles');
    if (!mounted) return;
    final data = await showDialog<Json>(
        context: context,
        builder: (_) => CatalogEntityDialog(
            entity: entity,
            plot: plot != null || newPlot,
            responsibles: people));
    if (!mounted || data == null || _property == null) return;
    if (newPlot) {
      await _save('POST', '/plots', {...data, 'property_id': _property!['id']});
    } else {
      await _save('PATCH',
          '/${plot == null ? 'properties' : 'plots'}/${entity!['id']}', {
        ...data,
        'expected_version': entity['version'],
        'archived': entity['archived'] == 1
      });
    }
  }

  Future<void> _archive(Json entity, {bool plot = false}) async {
    final archived = entity['archived'] == 1;
    final accepted = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(
                    '${archived ? 'Reativar' : 'Arquivar'} ${entity['name']}?'),
                content: const Text(
                    'O histórico permanece vinculado. Cadastros arquivados não recebem novas operações. Ao reativar um talhão, sua área será conferida.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancelar')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Confirmar'))
                ]));
    if (!mounted || accepted != true) return;
    await _save('PATCH', '/${plot ? 'plots' : 'properties'}/${entity['id']}', {
      'expected_version': entity['version'],
      'name': entity['name'],
      'area_ha': entity['area_ha'],
      'notes': entity['notes'] ?? '',
      if (!plot) 'location': entity['location'] ?? '',
      'archived': !archived,
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const Text('Fazenda e talhões')),
      body: ListView(padding: AppTheme.pagePadding(context), children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.deepOrange)),
        OutlinedButton.icon(
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
            label: const Text('Atualizar')),
        if (_property != null) ...[
          Text('${_property!['name']}',
              style:
                  const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
          if (!FarmApiClient.standaloneLocalMode)
            OutlinedButton.icon(
                onPressed: _busy ||
                        (_property!['_sync_state'] != null &&
                            _property!['_sync_state'] != 'synced')
                    ? null
                    : () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                            builder: (_) => GeographyScreen(
                                propertyId: _property!['id'] as String))),
                icon: const Icon(Icons.map_outlined),
                label: const Text('Mapa e demarcações')),
          if (!FarmApiClient.standaloneLocalMode &&
              _property!['_sync_state'] != null &&
              _property!['_sync_state'] != 'synced')
            const Text(
                'Sincronize o cadastro da fazenda para habilitar suas demarcações compartilhadas.'),
          Text(
              '${_area(_property!['area_ha'])}\n${_property!['location']}\n${_property!['notes']}'),
          Text(
              'Responsável: ${_property!['responsible_name'] ?? 'Não informado'}'),
          Text(
              'Área informada dos talhões: ${_plots.where((p) => p['archived'] != 1).fold<double>(0, (sum, p) => sum + (double.tryParse('${p['area_ha']}') ?? 0)).toStringAsFixed(4)} ha${_plots.any((p) => p['area_ha'] == null) ? ' (há áreas não informadas)' : ''}'),
          if (_property!['archived'] == 1) const Text('Propriedade arquivada'),
          if (widget.canCreate && !widget.admin)
            FilledButton.icon(
                onPressed: _busy || _property!['archived'] == 1
                    ? null
                    : () => _edit(newPlot: true),
                icon: const Icon(Icons.add),
                label: const Text('Novo talhão')),
          if (widget.admin)
            Wrap(spacing: 8, children: [
              TextButton.icon(
                  onPressed: _busy ? null : () => _edit(),
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('Editar fazenda')),
              TextButton(
                  onPressed: _busy ? null : () => _archive(_property!),
                  child: Text(_property!['archived'] == 1
                      ? 'Reativar propriedade'
                      : 'Arquivar propriedade')),
              FilledButton.icon(
                  onPressed: _busy || _property!['archived'] == 1
                      ? null
                      : () => _edit(newPlot: true),
                  icon: const Icon(Icons.add),
                  label: const Text('Novo talhão')),
              if (!FarmApiClient.standaloneLocalMode)
                OutlinedButton(
                    onPressed: _busy || _property!['archived'] == 1
                        ? null
                        : () async {
                            await Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => Scaffold(
                                        appBar: AppBar(
                                            title: const Text(
                                                'Culturas e safras')),
                                        body: OperationsScreen(
                                            initialPropertyId:
                                                _property!['id'] as String,
                                            section:
                                                OperationsSection.catalogs))));
                            if (mounted) await _load();
                          },
                    child: const Text('Culturas e safras')),
            ]),
          SwitchListTile(
              title: const Text('Mostrar também talhões arquivados'),
              value: _showArchived,
              onChanged: _busy
                  ? null
                  : (value) {
                      setState(() => _showArchived = value);
                      _load();
                    }),
          for (final plot in _plots)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              '${plot['name']}${plot['archived'] == 1 ? ' — Arquivado' : ''}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold)),
                          Text('${_area(plot['area_ha'])}\n${plot['notes']}'),
                          for (final cycle in _cycles
                              .where((c) => c['plot_id'] == plot['id']))
                            Text(
                                '${cycle['name']} · ${cycle['crop_name']} · ${cycle['starts_on']} até ${cycle['ends_on'] ?? 'sem data final'}'),
                          if (!_cycles.any((c) => c['plot_id'] == plot['id']))
                            const Text('Cultura/safra ainda não informada.'),
                          if (FarmApiClient.standaloneLocalMode)
                            TextButton.icon(
                              onPressed: () => Navigator.push(
                                  context,
                                  MaterialPageRoute<void>(
                                      builder: (_) => Scaffold(
                                          appBar: AppBar(
                                              title: Text(
                                                  'Histórico: ${plot['name']}')),
                                          body: ServicesScreen(
                                              propertyId:
                                                  _property!['id'] as String,
                                              fieldId: plot['id'] as String)))),
                              icon: const Icon(Icons.history),
                              label: const Text('Operações deste talhão'),
                            ),
                          if (widget.admin)
                            Wrap(spacing: 8, children: [
                              if (!FarmApiClient.standaloneLocalMode)
                                TextButton.icon(
                                    onPressed: () => Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                            builder: (_) =>
                                                ManagementReportsScreen(
                                                    type: 'plots',
                                                    propertyId: _property!['id']
                                                        as String,
                                                    plotId:
                                                        plot['id'] as String))),
                                    icon: const Icon(Icons.history),
                                    label: const Text(
                                        'Histórico e custos do talhão')),
                              TextButton(
                                  onPressed:
                                      _busy ? null : () => _edit(plot: plot),
                                  child: const Text('Editar talhão')),
                              TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _archive(plot, plot: true),
                                  child: Text(plot['archived'] == 1
                                      ? 'Reativar talhão'
                                      : 'Arquivar talhão')),
                            ]),
                        ]))),
          if (!_busy && _plots.isEmpty) const Text('Nenhum talhão disponível.'),
        ],
      ]));
}

class CatalogEntityDialog extends StatefulWidget {
  const CatalogEntityDialog(
      {super.key,
      this.entity,
      this.plot = false,
      this.clients = const [],
      this.responsibles = const []});
  final Json? entity;
  final bool plot;
  final List<Json> clients;
  final List<Json> responsibles;
  @override
  State<CatalogEntityDialog> createState() => _CatalogEntityDialogState();
}

class ResponsibleDialog extends StatefulWidget {
  const ResponsibleDialog({super.key});
  @override
  State<ResponsibleDialog> createState() => _ResponsibleDialogState();
}

class _ResponsibleDialogState extends State<ResponsibleDialog> {
  final _name = TextEditingController();
  final _form = GlobalKey<FormState>();
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('Responsável pela propriedade'),
          content: Form(
              key: _form,
              child: TextFormField(
                  controller: _name,
                  maxLength: 160,
                  decoration: const InputDecoration(
                      labelText: 'Nome do responsável ou cliente'),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Informe o nome'
                      : null)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () {
                  if (_form.currentState!.validate()) {
                    FocusScope.of(context).unfocus();
                    Navigator.pop(context, _name.text.trim());
                  }
                },
                child: const Text('Salvar'))
          ]);
}

class _CatalogEntityDialogState extends State<CatalogEntityDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.entity?['name']);
  late final _area =
      TextEditingController(text: widget.entity?['area_ha']?.toString());
  late final _location =
      TextEditingController(text: widget.entity?['location']);
  late final _notes = TextEditingController(text: widget.entity?['notes']);
  late String? _responsible = widget.entity?['responsible_user_id'] as String?;
  final List<Json> _plots = [];
  String? _bundleError;
  Widget _plotEditor(int index) {
    final p = _plots[index];
    return Card(
        child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(children: [
              TextFormField(
                  initialValue: '${p['name'] ?? ''}',
                  decoration:
                      InputDecoration(labelText: 'Nome do talhão ${index + 1}'),
                  maxLength: 160,
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Informe o nome' : null,
                  onChanged: (v) => p['name'] = v.trim()),
              TextFormField(
                  initialValue: p['area_ha'] as String?,
                  decoration: const InputDecoration(
                      labelText: 'Área do talhão (ha, opcional)'),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  validator: (v) => decimalError(v ?? '', optional: true),
                  onChanged: (v) => setState(() => p['area_ha'] =
                      v.trim().isEmpty ? null : v.trim().replaceAll(',', '.'))),
              TextFormField(
                  initialValue: '${p['notes'] ?? ''}',
                  decoration:
                      const InputDecoration(labelText: 'Observações do talhão'),
                  maxLength: 2000,
                  onChanged: (v) => p['notes'] = v.trim()),
              TextButton(
                  onPressed: () => setState(() => _plots.removeAt(index)),
                  child: const Text('Remover este talhão do formulário'))
            ])));
  }

  String get _areaSummary {
    final sum = _plots.fold<double>(
        0, (s, p) => s + (double.tryParse('${p['area_ha']}') ?? 0));
    final total = double.tryParse(_area.text.replaceAll(',', '.'));
    return 'Soma das áreas informadas: ${sum.toStringAsFixed(4)} ha. '
        '${total == null ? 'Área total da fazenda não informada.' : 'Diferença para a área da fazenda: ${(total - sum).toStringAsFixed(4)} ha.'}'
        '${_plots.any((p) => p['area_ha'] == null) ? ' Há talhões sem área informada.' : ''}';
  }

  @override
  void dispose() {
    for (final controller in [_name, _area, _location, _notes]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(
              '${widget.entity == null ? 'Cadastrar' : 'Editar'} ${widget.plot ? 'talhão' : 'fazenda'}'),
          content: SizedBox(
              width: AppTheme.dialogWidth(context),
              child: SingleChildScrollView(
                  child: Form(
                      key: _form,
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        TextFormField(
                            controller: _name,
                            maxLength: 160,
                            decoration: const InputDecoration(
                                labelText: 'Nome ou identificação'),
                            validator: (value) =>
                                value == null || value.trim().isEmpty
                                    ? 'Informe o nome'
                                    : null),
                        if (!widget.plot)
                          DropdownButtonFormField<String>(
                              isExpanded: true,
                              initialValue: widget.responsibles
                                      .any((p) => p['id'] == _responsible)
                                  ? _responsible
                                  : null,
                              decoration: const InputDecoration(
                                  labelText:
                                      'Responsável pela propriedade (opcional)'),
                              items: [
                                const DropdownMenuItem<String>(
                                    value: '', child: Text('Não informado')),
                                ...widget.responsibles.map((c) =>
                                    DropdownMenuItem(
                                        value: '${c['id']}',
                                        child: Text('${c['name']}',
                                            overflow: TextOverflow.ellipsis)))
                              ],
                              onChanged: (value) =>
                                  _responsible = value == '' ? null : value),
                        TextFormField(
                            controller: _area,
                            onChanged: (_) => setState(() {}),
                            maxLength: 24,
                            keyboardType: const TextInputType.numberWithOptions(
                                decimal: true),
                            decoration: const InputDecoration(
                                labelText: 'Área (ha)',
                                helperText:
                                    'Deixe vazio se ainda não foi conferida.'),
                            validator: (value) =>
                                decimalError(value ?? '', optional: true)),
                        if (!widget.plot)
                          TextFormField(
                              controller: _location,
                              maxLength: 500,
                              decoration: const InputDecoration(
                                  labelText: 'Localização')),
                        TextFormField(
                            controller: _notes,
                            maxLength: 2000,
                            minLines: 2,
                            maxLines: 4,
                            decoration: const InputDecoration(
                                labelText: 'Observações')),
                        if (widget.plot)
                          const Text(
                              'As culturas ficam registradas por safra, preservando o histórico do talhão.'),
                        if (!widget.plot && widget.entity == null) ...[
                          for (var i = 0; i < _plots.length; i++)
                            KeyedSubtree(
                                key: ValueKey(_plots[i]['id']),
                                child: _plotEditor(i)),
                          Text(_areaSummary),
                          if (_bundleError != null)
                            Text(_bundleError!,
                                style:
                                    const TextStyle(color: Colors.deepOrange)),
                          OutlinedButton.icon(
                              onPressed: () => setState(() => _plots.add({
                                    'id': const Uuid().v4(),
                                    'name': '',
                                    'area_ha': null,
                                    'notes': ''
                                  })),
                              icon: const Icon(Icons.add),
                              label: const Text('Adicionar talhão')),
                        ],
                      ])))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () {
                  if (!_form.currentState!.validate()) return;
                  if (!widget.plot &&
                      widget.entity == null &&
                      _area.text.trim().isNotEmpty) {
                    BigInt units(String raw) {
                      final parts = raw.replaceAll(',', '.').split('.');
                      return BigInt.parse(parts[0]) * BigInt.from(1000000) +
                          BigInt.parse(parts.length == 1
                              ? '0'
                              : parts[1].padRight(6, '0'));
                    }

                    final sum = _plots.fold<BigInt>(
                        BigInt.zero,
                        (s, p) =>
                            s +
                            (p['area_ha'] == null
                                ? BigInt.zero
                                : units('${p['area_ha']}')));
                    if (sum > units(_area.text.trim())) {
                      setState(() => _bundleError =
                          'A soma dos talhões excede a área da fazenda. Confira as áreas antes de salvar.');
                      return;
                    }
                  }
                  FocusScope.of(context).unfocus();
                  Navigator.pop(context, <String, dynamic>{
                    'name': _name.text.trim(),
                    'area_ha': _area.text.trim().isEmpty
                        ? null
                        : _area.text.trim().replaceAll(',', '.'),
                    if (!widget.plot) 'location': _location.text.trim(),
                    'notes': _notes.text.trim(),
                    if (!widget.plot) 'responsible_user_id': _responsible,
                    if (!widget.plot && widget.entity == null) 'plots': _plots
                  });
                },
                child: const Text('Salvar'))
          ]);
}
