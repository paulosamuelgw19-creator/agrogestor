import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../app/app_theme.dart';
import '../analyses/coffee_analysis_screen.dart';
import '../auth/auth_service.dart';
import '../auth/farm_access_policy.dart';
import '../harvest/coffee_harvest_screen.dart';
import '../licensing/write_gate.dart';
import '../services/farm_service.dart';
import '../services/service_repository.dart';
import '../services/services_screen.dart';
import '../sync/farm_api_client.dart';
import '../sync/sync_notice.dart';
import '../sync/sync_service.dart';
import '../sync/sync_settings_screen.dart';
import '../sync/sync_status_label.dart';
import 'coffee_planting.dart';
import 'plot_notebook_repository.dart';

typedef _NotebookData = ({List<PlotNote> notes, List<FarmService> services});

class PlotNotebookScreen extends StatefulWidget {
  const PlotNotebookScreen(
      {super.key, required this.property, required this.plot});

  final Map<String, dynamic> property, plot;

  @override
  State<PlotNotebookScreen> createState() => _PlotNotebookScreenState();
}

class _PlotNotebookScreenState extends State<PlotNotebookScreen> {
  final _repository = PlotNotebookRepository();
  late Future<_NotebookData> _data = _load();
  bool _saving = false;
  bool _wasSyncing = false;
  late final (String?, String?) _openedWith;

  bool get _connected => !FarmApiClient.standaloneLocalMode;
  bool get _allowed =>
      FarmAccessPolicy.canUsePlotNotebook &&
      _openedWith ==
          (AuthService().currentUser?.id, AuthService().currentUser?.farmId);

  @override
  void initState() {
    super.initState();
    _openedWith =
        (AuthService().currentUser?.id, AuthService().currentUser?.farmId);
    if (_connected) {
      _wasSyncing = SyncService().state == SyncState.syncing;
      SyncService().addListener(_onSync);
    }
  }

  @override
  void dispose() {
    if (_connected) SyncService().removeListener(_onSync);
    super.dispose();
  }

  void _onSync() {
    final running = SyncService().state == SyncState.syncing;
    final completed = _wasSyncing && !running;
    _wasSyncing = running;
    if (!mounted || !completed) return;
    if (_allowed) {
      _refresh();
    } else {
      setState(() {});
    }
  }

  String get _propertyId => widget.property['id'] as String;
  String get _plotId => widget.plot['id'] as String;
  String get _location => '${widget.property['name']} · ${widget.plot['name']}';
  bool get _active =>
      widget.property['archived'] != 1 && widget.plot['archived'] != 1;

  Future<_NotebookData> _load() async {
    final services = _connected
        ? <FarmService>[]
        : (await ServiceRepository().getAll())
            .where((service) =>
                service.propertyId == _propertyId && service.fieldId == _plotId)
            .toList()
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final notes =
        await _repository.list(propertyId: _propertyId, plotId: _plotId);
    return (notes: notes, services: services);
  }

  void _refresh() => setState(() {
        _data = _load();
      });

  Future<void> _syncSettings() async {
    await Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (_) => Scaffold(
                  appBar: AppBar(title: const Text('Sincronização')),
                  body: const SafeArea(child: SyncSettingsScreen()),
                )));
    if (mounted && _allowed) _refresh();
  }

  Future<void> _openOperations({String? serviceId}) async {
    await Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (_) => Scaffold(
                  appBar: AppBar(title: Text('${widget.plot['name']}')),
                  body: ServicesScreen(
                    propertyId: _propertyId,
                    fieldId: _plotId,
                    plotArea: plotAreaHectares(widget.plot['area_ha']),
                    locationLabel: _location,
                    serviceId: serviceId,
                    canStart: _active && serviceId == null,
                  ),
                )));
    if (mounted) _refresh();
  }

  Future<void> _addNote() async {
    final note = await showDialog<PlotNote>(
      context: context,
      builder: (_) => _PlotNoteDialog(propertyId: _propertyId, plotId: _plotId),
    );
    if (note != null && mounted && _allowed) {
      await _write(() => _repository.save(note));
    }
  }

  Future<void> _linkOperation(PlotNote note, List<FarmService> services) async {
    final completed =
        services.where((item) => item.isFinished && !item.isCancelled);
    final dates = MaterialLocalizations.of(context);
    final operationId = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Vincular serviço concluído'),
        children: [
          for (final service in completed)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, service.id),
              child: Text(
                  '${service.jobType} · ${dates.formatCompactDate(service.startedAt)}'),
            ),
        ],
      ),
    );
    if (!mounted || operationId == null) return;
    await _write(() => _repository.setStatus(
          propertyId: _propertyId,
          plotId: _plotId,
          id: note.id,
          status: PlotNoteStatus.resolved,
          operationId: operationId,
          expectedStatus: note.status,
        ));
  }

  Future<void> _write(Future<void> Function() write) async {
    if (_saving || !_allowed) return;
    setState(() => _saving = true);
    try {
      if (await runLicensedWrite(context, write) && mounted) _refresh();
    } on FileSystemException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Não foi possível salvar a foto.')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _status(FarmService service) {
    if (service.isCancelled) return 'Cancelado';
    if (service.isFinished) return 'Concluído';
    return service.isPaused ? 'Pausado' : 'Em andamento';
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: AuthService(),
      builder: (context, _) => Scaffold(
            appBar: AppBar(title: const Text('Caderno do talhão')),
            body: !_allowed
                ? const SafeArea(
                    child: Padding(
                        padding: EdgeInsets.all(16),
                        child: AppNotice(
                            message:
                                'Entre com uma sessão válida de gestor para consultar o caderno.')))
                : SafeArea(
                    child: FutureBuilder<_NotebookData>(
                      future: _data,
                      builder: (context, snapshot) {
                        final data = snapshot.data;
                        final last = data?.services.firstOrNull;
                        final dates = MaterialLocalizations.of(context);
                        final titles = Theme.of(context).textTheme.titleMedium;
                        return Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1000),
                            child: ListView(
                              padding: AppTheme.pagePadding(context),
                              children: [
                                Text(_location,
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineSmall),
                                if (plotAreaHectares(widget.plot['area_ha'])
                                    case final double area)
                                  Text(
                                      '${area.toStringAsFixed(2).replaceAll('.', ',')} ha'),
                                if (coffeePlantingLabel(widget.plot)
                                    case final String plants)
                                  Text(plants),
                                const SizedBox(height: 10),
                                if (_connected)
                                  AnimatedBuilder(
                                      animation: SyncService(),
                                      builder: (context, _) {
                                        final sync = SyncService();
                                        final running =
                                            sync.state == SyncState.syncing;
                                        return Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              SyncNotice(
                                                  state: sync.state,
                                                  message: sync.message),
                                              Wrap(
                                                  spacing: 8,
                                                  runSpacing: 4,
                                                  children: [
                                                    OutlinedButton.icon(
                                                        onPressed: running
                                                            ? null
                                                            : sync.syncNow,
                                                        icon: const Icon(
                                                            Icons.sync),
                                                        label: Text(running
                                                            ? 'Sincronizando'
                                                            : 'Sincronizar agora')),
                                                    TextButton(
                                                        onPressed:
                                                            _syncSettings,
                                                        child: const Text(
                                                            'Ver fila e conflitos')),
                                                  ]),
                                              if (running)
                                                const LinearProgressIndicator(),
                                            ]);
                                      }),
                                if (!_connected ||
                                    FarmAccessPolicy.canUseCoffeeHarvest)
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    children: [
                                      if (!_connected)
                                        OutlinedButton.icon(
                                          onPressed: _openOperations,
                                          icon: const Icon(
                                              Icons.agriculture_outlined),
                                          label: const Text(
                                              'Operações deste talhão'),
                                        ),
                                      if (FarmAccessPolicy.canUseCoffeeHarvest)
                                        OutlinedButton.icon(
                                          onPressed: () => Navigator.push<void>(
                                              context,
                                              MaterialPageRoute(
                                                  builder: (_) =>
                                                      CoffeeHarvestScreen(
                                                          property:
                                                              widget.property,
                                                          plot: widget.plot))),
                                          icon:
                                              const Icon(Icons.coffee_outlined),
                                          label: const Text('Colheita'),
                                        ),
                                      if (!_connected)
                                        OutlinedButton.icon(
                                          onPressed: () => Navigator.push<void>(
                                              context,
                                              MaterialPageRoute(
                                                  builder: (_) =>
                                                      CoffeeAnalysisScreen(
                                                          property:
                                                              widget.property,
                                                          plot: widget.plot))),
                                          icon: const Icon(
                                              Icons.science_outlined),
                                          label: const Text('Análises'),
                                        ),
                                    ],
                                  ),
                                if (snapshot.hasError) ...[
                                  AppNotice(
                                      message: snapshot.error
                                              is FarmAccessDenied
                                          ? '${snapshot.error}'
                                          : 'Não foi possível abrir o caderno.',
                                      tone: AppNoticeTone.error),
                                  TextButton(
                                      onPressed: _refresh,
                                      child: const Text('Tentar novamente')),
                                ] else if (data == null)
                                  const LinearProgressIndicator()
                                else ...[
                                  if (!_connected) ...[
                                    const SizedBox(height: 14),
                                    Text('Último serviço', style: titles),
                                    if (last == null)
                                      const Text('Nenhum serviço registrado.')
                                    else
                                      ListTile(
                                        contentPadding: EdgeInsets.zero,
                                        title: Text(last.jobType),
                                        subtitle: Text(
                                            '${dates.formatCompactDate(last.startedAt)} · ${_status(last)}'),
                                        onTap: () =>
                                            _openOperations(serviceId: last.id),
                                      ),
                                  ],
                                  const SizedBox(height: 14),
                                  Text('Serviços pausados', style: titles),
                                  if (!data.services.any((service) =>
                                      service.isPaused &&
                                      !service.isCancelled &&
                                      !service.isFinished))
                                    const Text('Nenhum serviço pausado.'),
                                  for (final service in data.services.where(
                                      (service) =>
                                          service.isPaused &&
                                          !service.isCancelled &&
                                          !service.isFinished))
                                    Card(
                                      child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(service.jobType,
                                                style: titles),
                                            Text(dates.formatCompactDate(
                                                service.startedAt)),
                                            TextButton(
                                              onPressed: () => _openOperations(
                                                  serviceId: service.id),
                                              child: const Text(
                                                  'Continuar serviço'),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  const SizedBox(height: 14),
                                  Text('Agenda, vistorias e notas',
                                      style: titles),
                                  if (_active)
                                    Align(
                                      alignment:
                                          AlignmentDirectional.centerStart,
                                      child: TextButton.icon(
                                        onPressed: _saving ? null : _addNote,
                                        icon: const Icon(Icons.add),
                                        label: const Text(
                                            'Adicionar nota ou pendência'),
                                      ),
                                    ),
                                  if (data.notes.isEmpty)
                                    const Text(
                                        'Nenhuma nota ou pendência registrada.'),
                                  for (final note in data.notes)
                                    Card(
                                      child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                                '${dates.formatCompactDate(note.date)} · ${switch (note.status) {
                                                  PlotNoteStatus.note => 'Nota',
                                                  PlotNoteStatus.open =>
                                                    'Pendência aberta',
                                                  PlotNoteStatus.resolved =>
                                                    'Pendência concluída',
                                                }}',
                                                style: titles),
                                            if (note.text.isNotEmpty)
                                              Text(note.text),
                                            if (_connected)
                                              SyncStatusLabel(
                                                  module: FarmAccessPolicy
                                                      .plotNotebookModule,
                                                  recordId: note.id),
                                            if (note.inspection)
                                              const Text('Vistoria'),
                                            if (note.followUpOn
                                                case final DateTime due)
                                              Text(
                                                  'Retorno previsto: ${dates.formatCompactDate(due)}'),
                                            if (!_connected &&
                                                note.operationId != null)
                                              TextButton(
                                                onPressed: () =>
                                                    _openOperations(
                                                        serviceId:
                                                            note.operationId),
                                                child: const Text(
                                                    'Ver serviço vinculado'),
                                              ),
                                            if (_connected &&
                                                note.photoPath == null &&
                                                note.photoAttachmentId != null)
                                              const Text(
                                                  'Foto indisponível neste aparelho.'),
                                            if (note.photoPath
                                                case final String path)
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                    top: 8),
                                                child: Image.file(
                                                  File(path),
                                                  height: 180,
                                                  width: double.infinity,
                                                  fit: BoxFit.contain,
                                                  errorBuilder: (_, __, ___) =>
                                                      const Text(
                                                          'Foto indisponível no aparelho.'),
                                                ),
                                              ),
                                            if (_active &&
                                                note.status !=
                                                    PlotNoteStatus.note)
                                              TextButton(
                                                onPressed: _saving
                                                    ? null
                                                    : () => _write(() =>
                                                        _repository.setStatus(
                                                          propertyId:
                                                              _propertyId,
                                                          plotId: _plotId,
                                                          id: note.id,
                                                          expectedStatus:
                                                              note.status,
                                                          status: note.status ==
                                                                  PlotNoteStatus
                                                                      .open
                                                              ? PlotNoteStatus
                                                                  .resolved
                                                              : PlotNoteStatus
                                                                  .open,
                                                        )),
                                                child: Text(note.status ==
                                                        PlotNoteStatus.open
                                                    ? 'Concluir pendência'
                                                    : 'Reabrir pendência'),
                                              ),
                                            if (!_connected &&
                                                _active &&
                                                note.status ==
                                                    PlotNoteStatus.open &&
                                                data.services.any((service) =>
                                                    service.isFinished &&
                                                    !service.isCancelled))
                                              TextButton(
                                                onPressed: _saving
                                                    ? null
                                                    : () => _linkOperation(
                                                        note, data.services),
                                                child: const Text(
                                                    'Concluir vinculando serviço'),
                                              ),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ));
}

class _PlotNoteDialog extends StatefulWidget {
  const _PlotNoteDialog({required this.propertyId, required this.plotId});

  final String propertyId, plotId;

  @override
  State<_PlotNoteDialog> createState() => _PlotNoteDialogState();
}

class _PlotNoteDialogState extends State<_PlotNoteDialog> {
  final _text = TextEditingController();
  PlotNoteStatus _status = PlotNoteStatus.note;
  DateTime? _followUpOn;
  bool _inspection = false;
  String? _photoPath;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto(ImageSource source) async {
    try {
      final photo = await ImagePicker()
          .pickImage(source: source, maxWidth: 1600, imageQuality: 85);
      if (mounted && photo != null) {
        setState(() {
          _photoPath = photo.path;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Não foi possível abrir a foto.');
    }
  }

  Future<void> _chooseFollowUp() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final day = await showDatePicker(
      context: context,
      initialDate: _followUpOn ?? today,
      firstDate: today,
      lastDate: DateTime(today.year + 5, 12, 31),
    );
    if (mounted && day != null) setState(() => _followUpOn = day);
  }

  void _save() {
    final text = _text.text.trim();
    if (text.isEmpty && _photoPath == null) {
      setState(() => _error = 'Escreva uma nota ou anexe uma foto.');
      return;
    }
    Navigator.pop(
        context,
        PlotNote(
            id: const Uuid().v4(),
            propertyId: widget.propertyId,
            plotId: widget.plotId,
            date: DateTime.now(),
            text: text,
            status: _status,
            followUpOn: _status == PlotNoteStatus.open ? _followUpOn : null,
            inspection: _inspection,
            photoPath: _photoPath));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Adicionar nota ou pendência'),
        content: SizedBox(
          width: AppTheme.dialogWidth(context, maxWidth: 440),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<PlotNoteStatus>(
                  isExpanded: true,
                  initialValue: _status,
                  decoration: const InputDecoration(labelText: 'Tipo'),
                  items: const [
                    DropdownMenuItem(
                        value: PlotNoteStatus.note, child: Text('Nota')),
                    DropdownMenuItem(
                        value: PlotNoteStatus.open, child: Text('Pendência')),
                  ],
                  onChanged: (value) =>
                      setState(() => _status = value ?? _status),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Registro de vistoria'),
                  value: _inspection,
                  onChanged: (value) =>
                      setState(() => _inspection = value ?? false),
                ),
                if (_status == PlotNoteStatus.open)
                  Wrap(
                    children: [
                      TextButton.icon(
                        onPressed: _chooseFollowUp,
                        icon: const Icon(Icons.event_outlined),
                        label: Text(_followUpOn == null
                            ? 'Agendar retorno'
                            : MaterialLocalizations.of(context)
                                .formatCompactDate(_followUpOn!)),
                      ),
                      if (_followUpOn != null)
                        IconButton(
                          tooltip: 'Remover data de retorno',
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() => _followUpOn = null),
                        ),
                    ],
                  ),
                const SizedBox(height: 10),
                TextField(
                  controller: _text,
                  decoration: const InputDecoration(labelText: 'Anotação'),
                  maxLines: 4,
                  maxLength: 4000,
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                        onPressed: () => _pickPhoto(ImageSource.gallery),
                        icon: const Icon(Icons.photo_outlined),
                        label: const Text('Escolher foto')),
                    TextButton.icon(
                        onPressed: () => _pickPhoto(ImageSource.camera),
                        icon: const Icon(Icons.photo_camera_outlined),
                        label: const Text('Tirar foto')),
                  ],
                ),
                if (_photoPath != null) ...[
                  const Text('Foto selecionada'),
                  TextButton(
                      onPressed: () => setState(() => _photoPath = null),
                      child: const Text('Remover foto')),
                ],
                if (_error case final String error)
                  Text(error,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar')),
          FilledButton(onPressed: _save, child: const Text('Salvar')),
        ],
      );
}
