import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:printing/printing.dart';
import 'package:uuid/uuid.dart';

import '../../app/app_theme.dart';
import '../auth/farm_access_policy.dart';
import '../licensing/write_gate.dart';
import '../services/farm_service.dart';
import '../coffee_finance/coffee_finance_repository.dart';
import '../coffee_finance/coffee_finance_screen.dart'
    show openCoffeeFinanceEntry;
import 'coffee_analysis_repository.dart';

final _date = DateFormat('dd/MM/yyyy');

String _typeName(CoffeeAnalysisType type) => switch (type) {
      CoffeeAnalysisType.soil => 'Solo',
      CoffeeAnalysisType.leaf => 'Folha',
    };

String _analysisName(CoffeeAnalysis entry) =>
    '${_typeName(entry.type)} · ${_date.format(entry.collectedAt)} · ${entry.sampleId}';
String _operationName(FarmService operation) =>
    '${operation.jobType} · ${_date.format(operation.endedAt ?? operation.startedAt)}';
String _number(double value) =>
    value.toString().replaceFirst(RegExp(r'\.0$'), '').replaceAll('.', ',');
String _difference(double value) =>
    _number(double.parse(value.toStringAsPrecision(12)));
String _resultValue(CoffeeAnalysisResult result) =>
    '${_number(result.value)} ${result.unit}';

typedef _Analyses = ({
  List<CoffeeAnalysis> entries,
  List<FarmService> operations
});

class CoffeeAnalysisScreen extends StatefulWidget {
  const CoffeeAnalysisScreen(
      {super.key, required this.property, required this.plot});

  final Map<String, dynamic> property, plot;

  @override
  State<CoffeeAnalysisScreen> createState() => _CoffeeAnalysisScreenState();
}

class _CoffeeAnalysisScreenState extends State<CoffeeAnalysisScreen> {
  final _repository = CoffeeAnalysisRepository();
  late Future<_Analyses> _data = _load();
  CoffeeAnalysisType? _type;

  String get _propertyId => widget.property['id'] as String;
  String get _plotId => widget.plot['id'] as String;
  String get _location => '${widget.property['name']} · ${widget.plot['name']}';
  bool get _active =>
      widget.property['archived'] != 1 && widget.plot['archived'] != 1;

  Future<_Analyses> _load() async => (
        entries:
            await _repository.list(propertyId: _propertyId, plotId: _plotId),
        operations: await _repository.completedOperations(
            propertyId: _propertyId, plotId: _plotId),
      );

  void _reload() => setState(() {
        _data = _load();
      });

  Future<void> _edit(List<FarmService> operations,
      {CoffeeAnalysis? entry}) async {
    final saved = await Navigator.push<bool>(
        context,
        MaterialPageRoute(
            builder: (_) => _AnalysisEditor(
                  repository: _repository,
                  propertyId: _propertyId,
                  plotId: _plotId,
                  location: _location,
                  operations: operations,
                  defaultType: _type ?? CoffeeAnalysisType.soil,
                  existing: entry,
                )));
    if (mounted && saved == true) _reload();
  }

  Future<void> _compare(
      List<CoffeeAnalysis> entries, List<FarmService> operations) async {
    final pair =
        await showDialog<({CoffeeAnalysis first, CoffeeAnalysis second})>(
      context: context,
      builder: (_) => _ChooseComparison(entries: entries),
    );
    if (!mounted || pair == null) return;
    await Navigator.push<void>(
        context,
        MaterialPageRoute(
            builder: (_) => _ComparisonScreen(
                location: _location,
                property: widget.property,
                plot: widget.plot,
                first: pair.first,
                second: pair.second,
                operations: operations)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Análises')),
        body: SafeArea(
            child: FutureBuilder<_Analyses>(
          future: _data,
          builder: (context, snapshot) {
            final data = snapshot.connectionState == ConnectionState.done
                ? snapshot.data
                : null;
            final entries = data?.entries
                    .where((entry) => _type == null || entry.type == _type)
                    .toList() ??
                [];
            final groups = <int, List<CoffeeAnalysis>>{};
            for (final entry in entries) {
              (groups[entry.collectedAt.year] ??= []).add(entry);
            }
            final titles = Theme.of(context).textTheme.titleMedium;
            return Center(
                child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child:
                  ListView(padding: AppTheme.pagePadding(context), children: [
                Text(_location,
                    style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 12),
                if (snapshot.hasError) ...[
                  Text(snapshot.error is FarmAccessDenied
                      ? '${snapshot.error}'
                      : 'Não foi possível carregar as análises.'),
                  TextButton(
                      onPressed: _reload,
                      child: const Text('Tentar novamente')),
                ] else if (data == null)
                  const LinearProgressIndicator()
                else ...[
                  Wrap(spacing: 8, runSpacing: 4, children: [
                    if (_active)
                      FilledButton.icon(
                          onPressed: () => _edit(data.operations),
                          icon: const Icon(Icons.add),
                          label: const Text('Adicionar análise')),
                    if (entries.length >= 2)
                      OutlinedButton.icon(
                          onPressed: () => _compare(entries, data.operations),
                          icon: const Icon(Icons.compare_arrows),
                          label: const Text('Comparar coletas')),
                  ]),
                  Wrap(spacing: 8, children: [
                    ChoiceChip(
                        label: const Text('Todas'),
                        selected: _type == null,
                        onSelected: (_) => setState(() => _type = null)),
                    for (final type in CoffeeAnalysisType.values)
                      ChoiceChip(
                          label: Text(_typeName(type)),
                          selected: _type == type,
                          onSelected: (_) => setState(() => _type = type)),
                  ]),
                  if (entries.isEmpty)
                    const Text('Nenhuma análise registrada neste talhão.'),
                  for (final group in groups.entries) ...[
                    const SizedBox(height: 12),
                    Text('${group.key}', style: titles),
                    for (final entry in group.value)
                      Card(
                          child: ListTile(
                        title: Text(_analysisName(entry)),
                        subtitle: Text(entry.laboratory),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () async {
                          final edit = await Navigator.push<bool>(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => _AnalysisDetails(
                                        location: _location,
                                        property: widget.property,
                                        plot: widget.plot,
                                        entry: entry,
                                        operation: data.operations
                                            .where((operation) =>
                                                operation.id ==
                                                entry.operationId)
                                            .firstOrNull,
                                        canEdit: _active,
                                      )));
                          if (mounted && edit == true) {
                            await _edit(data.operations, entry: entry);
                          }
                        },
                      )),
                  ],
                ],
              ]),
            ));
          },
        )),
      );
}

class _AnalysisEditor extends StatefulWidget {
  const _AnalysisEditor(
      {required this.repository,
      required this.propertyId,
      required this.plotId,
      required this.location,
      required this.operations,
      required this.defaultType,
      this.existing});

  final CoffeeAnalysisRepository repository;
  final String propertyId, plotId, location;
  final List<FarmService> operations;
  final CoffeeAnalysisType defaultType;
  final CoffeeAnalysis? existing;

  @override
  State<_AnalysisEditor> createState() => _AnalysisEditorState();
}

class _AnalysisEditorState extends State<_AnalysisEditor> {
  final _key = GlobalKey<FormState>();
  late final _id = widget.existing?.id ?? const Uuid().v4();
  late var _day =
      widget.existing?.collectedAt ?? DateUtils.dateOnly(DateTime.now());
  late var _type = widget.existing?.type ?? widget.defaultType;
  late var _operationId = widget.existing?.operationId;
  late var _path = widget.existing?.pdfPath;
  late final _laboratory =
      TextEditingController(text: widget.existing?.laboratory);
  late final _sample = TextEditingController(text: widget.existing?.sampleId);
  late final _guidance =
      TextEditingController(text: widget.existing?.agronomistGuidance);
  late final _depth = TextEditingController(text: _soilContext('Profundidade'));
  late final _place = TextEditingController(text: _soilContext('Local'));
  late final _phase = TextEditingController(
      text: widget.existing?.type == CoffeeAnalysisType.leaf
          ? widget.existing?.context
          : null);
  late final _results = [...?widget.existing?.results];
  Uint8List? _pickedPdf;
  String? _pickedName, _pdfError;
  bool _busy = false;

  String _soilContext(String field) {
    final entry = widget.existing;
    if (entry == null || entry.type != CoffeeAnalysisType.soil) return '';
    final context = entry.context.split('\n');
    final prefix = '$field: ';
    final line = context.where((line) => line.startsWith(prefix)).firstOrNull;
    return line?.substring(prefix.length) ??
        (field == 'Local' && !entry.context.startsWith('Profundidade: ')
            ? entry.context
            : '');
  }

  @override
  void dispose() {
    for (final controller in [
      _laboratory,
      _sample,
      _guidance,
      _depth,
      _place,
      _phase
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _chooseDay() async {
    final day = await showDatePicker(
        context: context,
        initialDate: _day,
        firstDate: DateTime(1900),
        lastDate: DateTime.now(),
        helpText: 'Data da coleta');
    if (mounted && day != null) setState(() => _day = day);
  }

  Future<void> _pickPdf() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _pdfError = null;
    });
    try {
      final file = await FilePicker.pickFile(
          dialogTitle: 'Escolher PDF da análise',
          type: FileType.custom,
          allowedExtensions: ['pdf']);
      if (file == null) return;
      final length = await file.length();
      if (length != null && length > coffeeAnalysisPdfMaxBytes) {
        throw const FormatException('O arquivo PDF excede 8 MB.');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in file.readAsByteStream()) {
        if (builder.length + chunk.length > coffeeAnalysisPdfMaxBytes) {
          throw const FormatException('O arquivo PDF excede 8 MB.');
        }
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      validateCoffeeAnalysisPdf(bytes);
      if (mounted) {
        setState(() {
          _pickedPdf = bytes;
          _pickedName = file.name;
        });
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _pdfError = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _pdfError = 'Não foi possível importar o PDF.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editResult([int? index]) async {
    final result = await showDialog<CoffeeAnalysisResult>(
      context: context,
      builder: (_) => _ResultDialog(
        existing: index == null ? null : _results[index],
        otherIndicators: [
          for (final (i, result) in _results.indexed)
            if (i != index) result.indicator
        ],
      ),
    );
    if (mounted && result != null) {
      setState(() {
        if (index == null) {
          _results.add(result);
        } else {
          _results[index] = result;
        }
      });
    }
  }

  Future<void> _save() async {
    if (_busy || !_key.currentState!.validate()) return;
    final depth = _depth.text.trim();
    final place = _place.text.trim();
    final sampleContext = _type == CoffeeAnalysisType.leaf
        ? _phase.text.trim()
        : depth.isEmpty && place.isEmpty
            ? ''
            : 'Profundidade: $depth\nLocal: $place';
    final entry = CoffeeAnalysis(
        id: _id,
        propertyId: widget.propertyId,
        plotId: widget.plotId,
        type: _type,
        collectedAt: _day,
        laboratory: _laboratory.text.trim(),
        sampleId: _sample.text.trim(),
        context: sampleContext,
        pdfPath: _path,
        results: List.unmodifiable(_results),
        agronomistGuidance: _guidance.text.trim(),
        operationId: _operationId);
    setState(() => _busy = true);
    try {
      final saved = await runLicensedWrite(
          context,
          () => widget.repository
              .save(entry, pickedPdf: _pickedPdf, pickedPdfName: _pickedName));
      if (mounted && saved) Navigator.pop(context, true);
    } on FileSystemException {
      if (mounted) {
        setState(
            () => _pdfError = 'Não foi possível salvar o PDF no aparelho.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _required(String? value) =>
      (value ?? '').trim().isEmpty ? 'Preencha este campo.' : null;

  @override
  Widget build(BuildContext context) {
    final existingOperation =
        widget.operations.any((operation) => operation.id == _operationId);
    final titles = Theme.of(context).textTheme.titleMedium;
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.existing == null
              ? 'Adicionar análise'
              : 'Editar análise')),
      body: SafeArea(
          child: Center(
              child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 750),
        child: Form(
            key: _key,
            child: ListView(padding: AppTheme.pagePadding(context), children: [
              Text(widget.location, style: titles),
              const SizedBox(height: 12),
              DropdownButtonFormField<CoffeeAnalysisType>(
                initialValue: _type,
                decoration: const InputDecoration(labelText: 'Tipo de análise'),
                items: [
                  for (final type in CoffeeAnalysisType.values)
                    DropdownMenuItem(value: type, child: Text(_typeName(type)))
                ],
                onChanged: _busy || widget.existing != null
                    ? null
                    : (value) => setState(() => _type = value ?? _type),
              ),
              const SizedBox(height: 8),
              Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: OutlinedButton.icon(
                      onPressed: _busy ? null : _chooseDay,
                      icon: const Icon(Icons.calendar_today_outlined),
                      label: Text('Data da coleta: ${_date.format(_day)}'))),
              const SizedBox(height: 8),
              TextFormField(
                  controller: _laboratory,
                  enabled: !_busy,
                  maxLength: 160,
                  decoration: const InputDecoration(
                      labelText: 'Laboratório', counterText: ''),
                  validator: _required),
              const SizedBox(height: 8),
              TextFormField(
                  controller: _sample,
                  enabled: !_busy,
                  maxLength: 160,
                  decoration: const InputDecoration(
                      labelText: 'Código da amostra', counterText: ''),
                  validator: _required),
              const SizedBox(height: 8),
              if (_type == CoffeeAnalysisType.soil) ...[
                TextFormField(
                    controller: _depth,
                    enabled: !_busy,
                    maxLength: 480,
                    decoration: const InputDecoration(
                        labelText: 'Profundidade', counterText: ''),
                    validator: (text) =>
                        _place.text.trim().isEmpty ? null : _required(text)),
                const SizedBox(height: 8),
                TextFormField(
                    controller: _place,
                    enabled: !_busy,
                    maxLength: 480,
                    decoration: const InputDecoration(
                        labelText: 'Local da coleta', counterText: ''),
                    validator: (text) =>
                        _depth.text.trim().isEmpty ? null : _required(text)),
              ] else
                TextFormField(
                    controller: _phase,
                    enabled: !_busy,
                    maxLength: 1000,
                    decoration: const InputDecoration(
                        labelText: 'Fase da planta', counterText: '')),
              const Divider(height: 30),
              Text('Laudo em PDF', style: titles),
              if (_pickedName case final String name)
                Text(name)
              else if (_path != null)
                const Text('PDF anexado'),
              Wrap(spacing: 8, children: [
                OutlinedButton.icon(
                    onPressed: _busy ? null : _pickPdf,
                    icon: const Icon(Icons.attach_file),
                    label: const Text('Importar PDF')),
                if (_pickedPdf != null || _path != null)
                  TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _pickedPdf = null;
                                _pickedName = null;
                                _path = null;
                                _pdfError = null;
                              }),
                      child: const Text('Remover PDF')),
              ]),
              if (_pdfError case final String error)
                Text(error,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              const Divider(height: 30),
              Text('Resultados informados', style: titles),
              for (final (index, result) in _results.indexed)
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    title:
                        Text('${result.indicator} · ${_resultValue(result)}'),
                    subtitle: Text(result.method.isEmpty
                        ? 'Método não informado'
                        : result.method),
                    onTap: _busy ? null : () => _editResult(index),
                    trailing: IconButton(
                        tooltip: 'Remover resultado',
                        onPressed: _busy
                            ? null
                            : () => setState(() => _results.removeAt(index)),
                        icon: const Icon(Icons.delete_outline))),
              Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                      onPressed: _busy || _results.length >= 100
                          ? null
                          : () => _editResult(),
                      icon: const Icon(Icons.add),
                      label: const Text('Adicionar resultado'))),
              const Divider(height: 30),
              TextFormField(
                  controller: _guidance,
                  enabled: !_busy,
                  maxLength: 4000,
                  maxLines: 3,
                  decoration: const InputDecoration(
                      labelText: 'Orientação do agrônomo')),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: _operationId ?? '',
                isExpanded: true,
                decoration: const InputDecoration(
                    labelText: 'Serviço executado (opcional)'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('Sem vínculo')),
                  if (_operationId != null && !existingOperation)
                    DropdownMenuItem(
                        value: _operationId,
                        child: const Text('Serviço vinculado indisponível')),
                  for (final operation in widget.operations)
                    DropdownMenuItem(
                        value: operation.id,
                        child: Text(_operationName(operation),
                            overflow: TextOverflow.ellipsis)),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _operationId =
                        value?.isNotEmpty == true ? value : null),
              ),
              const SizedBox(height: 12),
              if (_busy) const LinearProgressIndicator(),
              Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton(
                      onPressed: _busy ? null : _save,
                      child: const Text('Salvar análise'))),
            ])),
      ))),
    );
  }
}

class _ResultDialog extends StatefulWidget {
  const _ResultDialog({this.existing, required this.otherIndicators});

  final CoffeeAnalysisResult? existing;
  final List<String> otherIndicators;

  @override
  State<_ResultDialog> createState() => _ResultDialogState();
}

class _ResultDialogState extends State<_ResultDialog> {
  final _form = GlobalKey<FormState>();
  late final _indicator =
      TextEditingController(text: widget.existing?.indicator);
  late final _unit = TextEditingController(text: widget.existing?.unit);
  late final _value = TextEditingController(
      text: widget.existing == null ? '' : _number(widget.existing!.value));
  late final _method = TextEditingController(text: widget.existing?.method);
  late bool _hasReference = widget.existing?.referenceMin != null;
  late final _referenceMin = TextEditingController(
      text: _optionalNumber(widget.existing?.referenceMin));
  late final _referenceMax = TextEditingController(
      text: _optionalNumber(widget.existing?.referenceMax));
  late final _referenceSource =
      TextEditingController(text: widget.existing?.referenceSource);

  String _optionalNumber(double? value) => value == null ? '' : _number(value);

  @override
  void dispose() {
    for (final controller in [
      _indicator,
      _unit,
      _value,
      _method,
      _referenceMin,
      _referenceMax,
      _referenceSource,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  String _normalize(String text) =>
      text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  double? _parse(String? text) {
    final value = double.tryParse((text ?? '').trim().replaceAll(',', '.'));
    return value != null && value.isFinite ? value : null;
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    Navigator.pop(
        context,
        CoffeeAnalysisResult(
            indicator: _indicator.text.trim(),
            unit: _unit.text.trim(),
            value: _parse(_value.text)!,
            method: _method.text.trim(),
            referenceMin: _hasReference ? _parse(_referenceMin.text) : null,
            referenceMax: _hasReference ? _parse(_referenceMax.text) : null,
            referenceSource:
                _hasReference ? _referenceSource.text.trim() : ''));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.existing == null
            ? 'Adicionar resultado'
            : 'Editar resultado'),
        content: SizedBox(
          width: AppTheme.dialogWidth(context, maxWidth: 460),
          child: Form(
              key: _form,
              child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextFormField(
                    controller: _indicator,
                    maxLength: 160,
                    decoration: const InputDecoration(
                        labelText: 'Indicador', counterText: ''),
                    validator: (text) {
                      final key = _normalize(text ?? '');
                      if (key.isEmpty) return 'Informe o indicador.';
                      if (widget.otherIndicators
                          .any((item) => _normalize(item) == key)) {
                        return 'Este indicador já foi informado.';
                      }
                      return null;
                    }),
                const SizedBox(height: 8),
                TextFormField(
                    controller: _unit,
                    maxLength: 80,
                    decoration: const InputDecoration(
                        labelText: 'Unidade', counterText: ''),
                    validator: (text) => (text ?? '').trim().isEmpty
                        ? 'Informe a unidade.'
                        : null),
                const SizedBox(height: 8),
                TextFormField(
                    controller: _value,
                    decoration: const InputDecoration(labelText: 'Valor'),
                    keyboardType: const TextInputType.numberWithOptions(
                        signed: true, decimal: true),
                    validator: (text) => _parse(text) == null
                        ? 'Informe um valor numérico.'
                        : null),
                const SizedBox(height: 8),
                TextFormField(
                    controller: _method,
                    maxLength: 160,
                    decoration: const InputDecoration(
                        labelText: 'Método', counterText: '')),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Informar faixa de referência'),
                  subtitle: const Text(
                      'Use a faixa do laudo ou a indicada pelo agrônomo, na mesma unidade.'),
                  value: _hasReference,
                  onChanged: (value) =>
                      setState(() => _hasReference = value ?? false),
                ),
                if (_hasReference) ...[
                  TextFormField(
                    controller: _referenceMin,
                    decoration:
                        const InputDecoration(labelText: 'Limite inferior'),
                    keyboardType: const TextInputType.numberWithOptions(
                        signed: true, decimal: true),
                    validator: (text) => _parse(text) == null
                        ? 'Informe o limite inferior.'
                        : null,
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _referenceMax,
                    decoration:
                        const InputDecoration(labelText: 'Limite superior'),
                    keyboardType: const TextInputType.numberWithOptions(
                        signed: true, decimal: true),
                    validator: (text) {
                      final upper = _parse(text);
                      final lower = _parse(_referenceMin.text);
                      return upper == null || (lower != null && upper <= lower)
                          ? 'Informe um limite maior que o inferior.'
                          : null;
                    },
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _referenceSource,
                    maxLength: 240,
                    decoration:
                        const InputDecoration(labelText: 'Fonte da faixa'),
                    validator: (text) => (text ?? '').trim().isEmpty
                        ? 'Informe o laudo, a tabela ou o agrônomo.'
                        : null,
                  ),
                ],
              ]))),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar')),
          FilledButton(onPressed: _save, child: const Text('Salvar resultado')),
        ],
      );
}

class _AnalysisDetails extends StatefulWidget {
  const _AnalysisDetails(
      {required this.location,
      required this.entry,
      required this.property,
      required this.plot,
      required this.operation,
      required this.canEdit});

  final String location;
  final Map<String, dynamic> property, plot;
  final CoffeeAnalysis entry;
  final FarmService? operation;
  final bool canEdit;

  @override
  State<_AnalysisDetails> createState() => _AnalysisDetailsState();
}

class _AnalysisDetailsState extends State<_AnalysisDetails> {
  bool _opening = false;
  late final _expenses =
      CoffeeFinanceRepository().expensesForAnalysis(widget.entry);

  Future<void> _pdf({bool share = false}) async {
    if (_opening) return;
    final path = widget.entry.pdfPath;
    if (path == null) return;
    setState(() => _opening = true);
    try {
      FarmAccessPolicy.requireCoffeeManager();
      final bytes = await readCoffeeAnalysisPdf(File(path));
      if (!mounted) return;
      FarmAccessPolicy.requireCoffeeManager();
      final filename =
          'analise-${widget.entry.type.name}-${DateFormat('yyyyMMdd').format(widget.entry.collectedAt)}.pdf';
      if (share) {
        await Printing.sharePdf(bytes: bytes, filename: filename);
      } else {
        await Navigator.push<void>(
            context,
            MaterialPageRoute(
                builder: (_) =>
                    _AnalysisPdf(bytes: bytes, filename: filename)));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Não foi possível abrir ou compartilhar o PDF da análise.')));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final titles = Theme.of(context).textTheme.titleMedium;
    return Scaffold(
      appBar: AppBar(
          title: Text('Análise de ${_typeName(entry.type).toLowerCase()}')),
      body: SafeArea(
          child: Center(
              child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: ListView(padding: AppTheme.pagePadding(context), children: [
          Text(widget.location, style: titles),
          const SizedBox(height: 8),
          Text('Data da coleta: ${_date.format(entry.collectedAt)}'),
          Text('Laboratório: ${entry.laboratory}'),
          Text('Código da amostra: ${entry.sampleId}'),
          if (entry.context.isEmpty)
            const Text('Contexto da coleta não informado.')
          else if (entry.type == CoffeeAnalysisType.leaf)
            Text('Fase da planta: ${entry.context}')
          else
            Text(entry.context),
          const Divider(height: 30),
          Text('Laudo em PDF', style: titles),
          if (entry.pdfPath == null)
            const Text('Nenhum PDF anexado.')
          else
            Wrap(spacing: 8, children: [
              OutlinedButton.icon(
                  onPressed: _opening ? null : _pdf,
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('Abrir PDF')),
              TextButton.icon(
                  onPressed: _opening ? null : () => _pdf(share: true),
                  icon: const Icon(Icons.share_outlined),
                  label: const Text('Compartilhar PDF')),
            ]),
          if (_opening) const LinearProgressIndicator(),
          const Divider(height: 30),
          Text('Resultados informados', style: titles),
          if (entry.results.isEmpty) const Text('Nenhum resultado informado.'),
          for (final result in entry.results)
            ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${result.indicator} · ${_resultValue(result)}'),
                subtitle: Text([
                  result.method.isEmpty
                      ? 'Método não informado'
                      : result.method,
                  if (result.referencePosition case final String position)
                    '$position · ${_number(result.referenceMin!)} a ${_number(result.referenceMax!)} ${result.unit}',
                  if (result.referenceSource.isNotEmpty)
                    'Fonte: ${result.referenceSource}',
                ].join('\n'))),
          const Divider(height: 30),
          Text('Orientação do agrônomo', style: titles),
          Text(entry.agronomistGuidance.isEmpty
              ? 'Não informada.'
              : entry.agronomistGuidance),
          const SizedBox(height: 8),
          Text('Serviço executado', style: titles),
          Text(widget.operation == null
              ? (entry.operationId == null
                  ? 'Sem vínculo.'
                  : 'Serviço vinculado indisponível.')
              : _operationName(widget.operation!)),
          const SizedBox(height: 12),
          Text('Despesas vinculadas', style: titles),
          FutureBuilder<List<CoffeeFinanceEntry>>(
            future: _expenses,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const Text('Não foi possível consultar as despesas.');
              }
              final expenses = snapshot.data;
              if (expenses == null) return const LinearProgressIndicator();
              if (expenses.isEmpty) {
                return const Text('Nenhuma despesa vinculada a este laudo.');
              }
              return Column(children: [
                for (final expense in expenses)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(expense.description),
                    subtitle: Text('Safra ${expense.seasonYear}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => openCoffeeFinanceEntry(context,
                        farm: widget.property,
                        plot: widget.plot,
                        entry: expense),
                  ),
              ]);
            },
          ),
          if (widget.canEdit)
            Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                    onPressed:
                        _opening ? null : () => Navigator.pop(context, true),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Editar análise'))),
        ]),
      ))),
    );
  }
}

class _AnalysisPdf extends StatelessWidget {
  const _AnalysisPdf({required this.bytes, required this.filename});

  final Uint8List bytes;
  final String filename;

  Future<void> _share(BuildContext context) async {
    try {
      FarmAccessPolicy.requireCoffeeManager();
      await Printing.sharePdf(bytes: bytes, filename: filename);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Não foi possível compartilhar o PDF.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Laudo em PDF'), actions: [
          IconButton(
              tooltip: 'Compartilhar PDF',
              onPressed: () => _share(context),
              icon: const Icon(Icons.share_outlined))
        ]),
        body: SafeArea(
            child: PdfPreview(
          build: (_) => bytes,
          canChangeOrientation: false,
          canChangePageFormat: false,
          allowPrinting: false,
          allowSharing: false,
          useActions: false,
          onError: (context, _) => Center(
              child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('A prévia do PDF está indisponível neste aparelho.'),
              TextButton(
                  onPressed: () => _share(context),
                  child: const Text('Compartilhar PDF')),
            ]),
          )),
        )),
      );
}

class _ChooseComparison extends StatefulWidget {
  const _ChooseComparison({required this.entries});

  final List<CoffeeAnalysis> entries;

  @override
  State<_ChooseComparison> createState() => _ChooseComparisonState();
}

class _ChooseComparisonState extends State<_ChooseComparison> {
  late CoffeeAnalysis _first = widget.entries[1];
  late CoffeeAnalysis _second = widget.entries.first;

  Widget _choice(String label, CoffeeAnalysis selected,
          ValueChanged<CoffeeAnalysis> choose) =>
      DropdownButtonFormField<CoffeeAnalysis>(
        isExpanded: true,
        initialValue: selected,
        decoration: InputDecoration(labelText: label),
        items: [
          for (final entry in widget.entries)
            DropdownMenuItem(
                value: entry,
                child:
                    Text(_analysisName(entry), overflow: TextOverflow.ellipsis))
        ],
        onChanged: (value) {
          if (value != null) setState(() => choose(value));
        },
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Comparar coletas'),
        content: SizedBox(
            width: AppTheme.dialogWidth(context, maxWidth: 460),
            child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              _choice('Primeira coleta', _first, (entry) => _first = entry),
              const SizedBox(height: 12),
              _choice('Segunda coleta', _second, (entry) => _second = entry),
              if (_first.id == _second.id)
                const Text('Selecione duas coletas diferentes.'),
            ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: _first.id == _second.id
                  ? null
                  : () =>
                      Navigator.pop(context, (first: _first, second: _second)),
              child: const Text('Comparar')),
        ],
      );
}

class _ComparisonScreen extends StatelessWidget {
  const _ComparisonScreen(
      {required this.location,
      required this.first,
      required this.property,
      required this.plot,
      required this.second,
      required this.operations});

  final String location;
  final Map<String, dynamic> property, plot;
  final CoffeeAnalysis first, second;
  final List<FarmService> operations;

  String _value(CoffeeAnalysisResult? result) => result == null
      ? 'Não informado'
      : '${_resultValue(result)} · ${result.method.isEmpty ? 'Método não informado' : result.method}';

  @override
  Widget build(BuildContext context) {
    final comparison = compareCoffeeAnalyses(first, second);
    final titles = Theme.of(context).textTheme.titleMedium;
    return Scaffold(
      appBar: AppBar(title: const Text('Comparação de coletas')),
      body: SafeArea(
          child: Center(
              child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800),
        child: ListView(padding: AppTheme.pagePadding(context), children: [
          Text(location, style: titles),
          const SizedBox(height: 8),
          Text('Primeira coleta · ${_analysisName(first)}'),
          if (first.context.isNotEmpty) Text(first.context),
          const SizedBox(height: 8),
          Text('Segunda coleta · ${_analysisName(second)}'),
          if (second.context.isNotEmpty) Text(second.context),
          const SizedBox(height: 8),
          if (!comparison.contextsCompatible)
            Text(
                'Contextos incompatíveis ou não informados. As diferenças não podem ser calculadas.',
                style: TextStyle(color: Theme.of(context).colorScheme.error))
          else
            const Text(
                'Diferença calculada da segunda coleta menos a primeira.'),
          const Divider(height: 30),
          Text('Orientações e serviços registrados', style: titles),
          for (final entry in [first, second])
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(_analysisName(entry)),
              subtitle: Text([
                if (entry.agronomistGuidance.isNotEmpty)
                  entry.agronomistGuidance,
                if (operations
                        .where((op) => op.id == entry.operationId)
                        .firstOrNull
                    case final FarmService operation)
                  _operationName(operation)
                else
                  'Sem serviço vinculado disponível',
              ].join('\n')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(
                builder: (_) => _AnalysisDetails(
                  location: location,
                  property: property,
                  plot: plot,
                  entry: entry,
                  operation: operations
                      .where((op) => op.id == entry.operationId)
                      .firstOrNull,
                  canEdit: false,
                ),
              )),
            ),
          const Divider(height: 30),
          if (comparison.rows.isEmpty)
            const Text('Nenhum indicador informado nas duas coletas.'),
          for (final row in comparison.rows)
            Card(
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(row.indicator, style: titles),
                          Text('Primeira: ${_value(row.first)}'),
                          Text('Segunda: ${_value(row.second)}'),
                          if (row.difference case final double difference)
                            Text(
                                'Diferença: ${difference > 0 ? '+' : ''}${_difference(difference)} ${row.second!.unit}')
                          else if (comparison.contextsCompatible)
                            const Text(
                                'Diferença indisponível. Confira valores, unidades e métodos.'),
                        ]))),
        ]),
      ))),
    );
  }
}
