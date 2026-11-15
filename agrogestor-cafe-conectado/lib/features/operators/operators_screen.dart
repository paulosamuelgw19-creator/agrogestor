import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../app/app_theme.dart';
import 'operator.dart';
import 'operator_repository.dart';
import '../sync/sync_status_label.dart';
import '../licensing/write_gate.dart';
import '../local_backup/local_photo.dart';
import '../operations_v2/v2_store.dart' show Json;
import '../properties/catalog_store.dart';
import '../services/coffee_manual_labor_repository.dart';
import '../sync/farm_api_client.dart';

final _money = NumberFormat.currency(locale: 'pt_BR', symbol: 'R\$');
final _date = DateFormat('dd/MM/yyyy');

String _rate(int? cents) =>
    cents == null ? 'Não informada' : _money.format(cents / 100);

int? _cents(String? value) {
  final match =
      RegExp(r'^(\d+)(?:[,.](\d{1,2}))?$').firstMatch(value?.trim() ?? '');
  if (match == null) return null;
  final whole = int.tryParse(match.group(1)!);
  if (whole == null || whole > 10000000000) return null;
  final cents =
      whole * 100 + int.parse((match.group(2) ?? '').padRight(2, '0'));
  return cents <= 1000000000000 ? cents : null;
}

class OperatorsScreen extends StatefulWidget {
  const OperatorsScreen({super.key});
  @override
  State<OperatorsScreen> createState() => _OperatorsScreenState();
}

class _OperatorsScreenState extends State<OperatorsScreen> {
  final _repository = OperatorRepository();
  final _search = TextEditingController();
  List<Operator> _operators = [];
  bool _loading = true;
  bool? _activeFilter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final result = await _repository.getAll();
    if (mounted) {
      setState(() {
        _operators = result;
        _loading = false;
      });
    }
  }

  Future<void> _save(List<Operator> result) async {
    if (await runLicensedWrite(
            context, () => _repository.saveAll(result, previous: _operators)) &&
        mounted) {
      setState(() => _operators = result);
    }
  }

  Future<void> _edit([Operator? operator]) async {
    final result = await showDialog<Operator>(
        context: context, builder: (_) => _OperatorForm(operator: operator));
    if (result == null) return;
    final items = [..._operators];
    final index = items.indexWhere((item) => item.id == result.id);
    if (index < 0) {
      items.insert(0, result);
    } else {
      items[index] = result;
    }
    await _save(items);
  }

  Future<void> _delete(Operator operator) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir operador?'),
        content: Text('“${operator.name}” será removido deste aparelho.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Excluir')),
        ],
      ),
    );
    if (confirm == true) {
      await _save(_operators.where((item) => item.id != operator.id).toList());
    }
  }

  @override
  Widget build(BuildContext context) {
    final term = _search.text.trim().toLowerCase();
    final visible = _operators.where((item) {
      final matches = '${item.name} ${item.role} ${item.phone}'
          .toLowerCase()
          .contains(term);
      return matches && (_activeFilter == null || item.active == _activeFilter);
    }).toList();
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _edit(),
          icon: const Icon(Icons.person_add_alt_1),
          label: const Text(FarmApiClient.standaloneLocalMode
              ? 'Novo funcionário'
              : 'Novo operador')),
      body: SafeArea(
          child: Center(
              child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000),
        child: Padding(
            padding: AppTheme.pagePadding(context),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text(
                  FarmApiClient.standaloneLocalMode
                      ? 'Funcionários'
                      : 'Operadores',
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.forest)),
              const SizedBox(height: 5),
              const Text('Gerencie a equipe e os contatos dos operadores.',
                  style: TextStyle(color: Colors.black54)),
              const SizedBox(height: 20),
              TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Buscar nome, função ou telefone')),
              const SizedBox(height: 12),
              Wrap(spacing: 8, children: [
                ChoiceChip(
                    label: const Text('Todos'),
                    selected: _activeFilter == null,
                    onSelected: (_) => setState(() => _activeFilter = null)),
                ChoiceChip(
                    label: const Text('Ativos'),
                    selected: _activeFilter == true,
                    onSelected: (_) => setState(() => _activeFilter = true)),
                ChoiceChip(
                    label: const Text('Inativos'),
                    selected: _activeFilter == false,
                    onSelected: (_) => setState(() => _activeFilter = false)),
              ]),
              const SizedBox(height: 12),
              Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : visible.isEmpty
                          ? Center(
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                  const Icon(Icons.engineering_outlined,
                                      size: 48, color: AppTheme.leaf),
                                  const SizedBox(height: 12),
                                  Text(
                                      _operators.isEmpty
                                          ? 'Cadastre o primeiro operador'
                                          : 'Nenhum operador encontrado',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w700)),
                                  const SizedBox(height: 12),
                                  OutlinedButton.icon(
                                      onPressed: () => _edit(),
                                      icon: const Icon(Icons.add),
                                      label: const Text('Cadastrar operador')),
                                ]))
                          : ListView.separated(
                              padding: const EdgeInsets.only(bottom: 88),
                              itemCount: visible.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (context, index) {
                                final item = visible[index];
                                final tone =
                                    item.active ? AppTheme.leaf : Colors.grey;
                                return Card(
                                    child: ListTile(
                                  onTap: FarmApiClient.standaloneLocalMode
                                      ? () => Navigator.push<void>(
                                          context,
                                          MaterialPageRoute(
                                              builder: (_) =>
                                                  _OperatorLaborScreen(
                                                      operator: item)))
                                      : null,
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 18, vertical: 6),
                                  leading: CircleAvatar(
                                      backgroundColor:
                                          tone.withValues(alpha: .12),
                                      foregroundColor: tone,
                                      child: item.photoPath == null
                                          ? Text(item.name.isEmpty
                                              ? '?'
                                              : item.name[0].toUpperCase())
                                          : ClipOval(
                                              child: Image.file(
                                                  File(item.photoPath!),
                                                  width: 40,
                                                  height: 40,
                                                  fit: BoxFit.cover,
                                                  errorBuilder: (_, __, ___) =>
                                                      const Icon(Icons
                                                          .person_outline)))),
                                  title: Row(children: [
                                    Expanded(
                                        child: Text(item.name,
                                            style:
                                                AppTheme.nameStyle(context))),
                                    SyncStatusLabel(
                                        module: 'operators', recordId: item.id),
                                  ]),
                                  subtitle: Text(
                                      '${item.role}${item.phone.isEmpty ? '' : ' · ${item.phone}'}${FarmApiClient.standaloneLocalMode ? '\nDiária: ${_rate(item.dailyRateCents)}' : ''}'),
                                  trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Chip(
                                            label: Text(item.active
                                                ? 'Ativo'
                                                : 'Inativo'),
                                            backgroundColor:
                                                tone.withValues(alpha: .12),
                                            side: BorderSide.none,
                                            labelStyle: TextStyle(
                                                color: tone, fontSize: 11)),
                                        PopupMenuButton<String>(
                                            onSelected: (action) =>
                                                action == 'edit'
                                                    ? _edit(item)
                                                    : _delete(item),
                                            itemBuilder: (_) => const [
                                                  PopupMenuItem(
                                                      value: 'edit',
                                                      child: Text('Editar')),
                                                  PopupMenuItem(
                                                      value: 'delete',
                                                      child: Text('Excluir'))
                                                ]),
                                      ]),
                                ));
                              })),
            ])),
      ))),
    );
  }
}

class _OperatorForm extends StatefulWidget {
  const _OperatorForm({this.operator});
  final Operator? operator;
  @override
  State<_OperatorForm> createState() => _OperatorFormState();
}

class _OperatorFormState extends State<_OperatorForm> {
  final _key = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.operator?.name ?? '');
  late final _phone = TextEditingController(text: widget.operator?.phone ?? '');
  late final _role =
      TextEditingController(text: widget.operator?.role ?? 'Operador');
  late final _dailyRate = TextEditingController(
      text: widget.operator?.dailyRateCents == null
          ? ''
          : (widget.operator!.dailyRateCents! / 100)
              .toStringAsFixed(2)
              .replaceAll('.', ','));
  late String? _photoPath = widget.operator?.photoPath;
  late bool _active = widget.operator?.active ?? true;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _role.dispose();
    _dailyRate.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_key.currentState!.validate()) return;
    Navigator.pop(
        context,
        Operator(
          id: widget.operator?.id ?? const Uuid().v4(),
          name: _name.text.trim(),
          phone: _phone.text.trim(),
          role: _role.text.trim(),
          active: _active,
          dailyRateCents: FarmApiClient.standaloneLocalMode
              ? _cents(_dailyRate.text)
              : widget.operator?.dailyRateCents,
          photoPath: _photoPath,
        ));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(FarmApiClient.standaloneLocalMode
            ? (widget.operator == null
                ? 'Novo funcionário'
                : 'Editar funcionário')
            : (widget.operator == null ? 'Novo operador' : 'Editar operador')),
        content: SizedBox(
            width: AppTheme.dialogWidth(context, maxWidth: 420),
            child: Form(
                key: _key,
                child: SingleChildScrollView(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextFormField(
                      controller: _name,
                      decoration:
                          const InputDecoration(labelText: 'Nome completo'),
                      textCapitalization: TextCapitalization.words,
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                              ? 'Informe o nome'
                              : null),
                  const SizedBox(height: 10),
                  TextFormField(
                      controller: _phone,
                      decoration: const InputDecoration(
                          labelText: 'Telefone (opcional)'),
                      keyboardType: TextInputType.phone),
                  const SizedBox(height: 10),
                  TextFormField(
                      controller: _role,
                      decoration:
                          const InputDecoration(labelText: 'Cargo/função'),
                      validator: (value) =>
                          value == null || value.trim().isEmpty
                              ? 'Informe a função'
                              : null),
                  SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Operador ativo'),
                      value: _active,
                      onChanged: (value) => setState(() => _active = value)),
                  if (FarmApiClient.standaloneLocalMode) ...[
                    TextFormField(
                        controller: _dailyRate,
                        decoration: const InputDecoration(
                            labelText: 'Diária padrão (R\$, opcional)'),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        validator: (value) => (value ?? '').trim().isEmpty ||
                                _cents(value) != null
                            ? null
                            : 'Informe um valor com até duas casas decimais.'),
                    LocalPhotoField(
                        photoPath: _photoPath,
                        onChanged: (path) => setState(() => _photoPath = path)),
                  ],
                ])))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar')),
          FilledButton(onPressed: _submit, child: const Text('Salvar'))
        ],
      );
}

class _OperatorLaborScreen extends StatefulWidget {
  const _OperatorLaborScreen({required this.operator});

  final Operator operator;

  @override
  State<_OperatorLaborScreen> createState() => _OperatorLaborScreenState();
}

typedef _LaborData = ({
  CoffeeManualLaborSummary summary,
  List<Json> farms,
  List<Json> plots
});

class _OperatorLaborScreenState extends State<_OperatorLaborScreen> {
  final _repository = CoffeeManualLaborRepository();
  late Future<_LaborData> _data = _load();
  bool _busy = false;

  Future<_LaborData> _load() async {
    final catalog = await CatalogStore.open();
    final summary = await _repository.summary(workerId: widget.operator.id);
    return (
      summary: summary,
      farms: await catalog.records('properties'),
      plots: await catalog.records('plots')
    );
  }

  void _reload() => setState(() {
        _data = _load();
      });

  Future<void> _record(List<Json> farms) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final payment = await showDialog<CoffeeManualLaborPayment>(
          context: context,
          builder: (_) =>
              _LaborPaymentDialog(worker: widget.operator, farms: farms));
      if (!mounted || payment == null) return;
      final saved = await runLicensedWrite(
          context, () => _repository.savePayment(payment));
      if (mounted && saved) _reload();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Ficha do funcionário')),
        body: SafeArea(
            child: FutureBuilder<_LaborData>(
                future: _data,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(
                        child: TextButton(
                            onPressed: _reload,
                            child: const Text(
                                'Não foi possível abrir a ficha. Tentar novamente')));
                  }
                  if (snapshot.connectionState != ConnectionState.done ||
                      snapshot.data == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final data = snapshot.data!;
                  final summary = data.summary;
                  final farms = {
                    for (final farm in data.farms) farm['id']: '${farm['name']}'
                  };
                  final plots = {
                    for (final plot in data.plots) plot['id']: '${plot['name']}'
                  };
                  final titles = Theme.of(context).textTheme.titleMedium;
                  return Center(
                      child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 860),
                          child: ListView(
                              padding: AppTheme.pagePadding(context),
                              children: [
                                Text(widget.operator.name,
                                    style: AppTheme.nameStyle(context)
                                        .copyWith(fontSize: 24)),
                                Text(
                                    'Diária padrão: ${_rate(widget.operator.dailyRateCents)}'),
                                const SizedBox(height: 12),
                                Text(
                                    'Total devido: ${_rate(summary.dueCents)}'),
                                if (summary.unknownRateCount > 0)
                                  AppNotice(
                                      message:
                                          '${summary.unknownRateCount} jornada(s) sem diária. Total conhecido: ${_rate(summary.knownDueCents)}.'),
                                Text(
                                    'Adiantamentos: ${_rate(summary.advancesCents)}'),
                                Text(
                                    'Pagamentos: ${_rate(summary.paymentsCents)}'),
                                Text(
                                    'Saldo restante: ${_rate(summary.balanceCents)}'),
                                if (data.farms.isNotEmpty)
                                  Align(
                                      alignment:
                                          AlignmentDirectional.centerStart,
                                      child: OutlinedButton.icon(
                                          onPressed: _busy
                                              ? null
                                              : () => _record(data.farms),
                                          icon: const Icon(
                                              Icons.payments_outlined),
                                          label: const Text(
                                              'Registrar acerto de diária'))),
                                const Divider(height: 32),
                                Text('Jornadas de serviço manual',
                                    style: titles),
                                if (summary.days.isEmpty)
                                  const Text('Nenhuma jornada registrada.'),
                                for (final day in summary.days)
                                  ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(
                                          '${_date.format(day.date)} · ${day.serviceType}'),
                                      subtitle: Text('${[
                                        farms[day.propertyId],
                                        plots[day.plotId]
                                      ].nonNulls.join(' · ')}\nDiária: ${_rate(day.dailyRateCents)}')),
                                const Divider(height: 32),
                                Text('Adiantamentos e pagamentos',
                                    style: titles),
                                if (summary.payments.isEmpty)
                                  const Text('Nenhum acerto registrado.'),
                                for (final payment in summary.payments)
                                  ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(
                                          '${payment.kind == CoffeeManualLaborPaymentKind.advance ? 'Adiantamento' : 'Pagamento'} · ${_rate(payment.amountCents)}'),
                                      subtitle: Text([
                                        _date.format(payment.date),
                                        if (farms[payment.propertyId]
                                            case final String name)
                                          name,
                                        if (payment.notes.isNotEmpty)
                                          payment.notes,
                                      ].join(' · '))),
                              ])));
                })),
      );
}

class _LaborPaymentDialog extends StatefulWidget {
  const _LaborPaymentDialog({required this.worker, required this.farms});

  final Operator worker;
  final List<Json> farms;

  @override
  State<_LaborPaymentDialog> createState() => _LaborPaymentDialogState();
}

class _LaborPaymentDialogState extends State<_LaborPaymentDialog> {
  final _form = GlobalKey<FormState>();
  final _value = TextEditingController();
  final _notes = TextEditingController();
  late String? _farmId =
      widget.farms.length == 1 ? widget.farms.single['id'] as String : null;
  DateTime _day = DateUtils.dateOnly(DateTime.now());
  CoffeeManualLaborPaymentKind _kind = CoffeeManualLaborPaymentKind.advance;
  bool _submitted = false;

  @override
  void dispose() {
    _value.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _save() {
    if (_submitted || !_form.currentState!.validate()) return;
    _submitted = true;
    Navigator.pop(
        context,
        CoffeeManualLaborPayment(
            id: const Uuid().v4(),
            propertyId: _farmId!,
            workerId: widget.worker.id,
            date: _day,
            kind: _kind,
            amountCents: _cents(_value.text)!,
            notes: _notes.text.trim()));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Registrar acerto de diária'),
        content: SizedBox(
            width: AppTheme.dialogWidth(context, maxWidth: 440),
            child: Form(
                key: _form,
                child: SingleChildScrollView(
                    child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(widget.worker.name,
                        style: AppTheme.nameStyle(context)),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                        initialValue: _farmId,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Fazenda'),
                        items: [
                          for (final farm in widget.farms)
                            DropdownMenuItem(
                                value: farm['id'] as String,
                                child: Text('${farm['name']}',
                                    overflow: TextOverflow.ellipsis))
                        ],
                        onChanged: (value) => _farmId = value,
                        validator: (value) =>
                            value == null ? 'Selecione a fazenda.' : null),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<CoffeeManualLaborPaymentKind>(
                        initialValue: _kind,
                        isExpanded: true,
                        decoration:
                            const InputDecoration(labelText: 'Tipo de acerto'),
                        items: const [
                          DropdownMenuItem(
                              value: CoffeeManualLaborPaymentKind.advance,
                              child: Text('Adiantamento')),
                          DropdownMenuItem(
                              value: CoffeeManualLaborPaymentKind.payment,
                              child: Text('Pagamento'))
                        ],
                        onChanged: (value) => _kind = value ?? _kind),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                        onPressed: () async {
                          final day = await showDatePicker(
                              context: context,
                              firstDate: DateTime(1900),
                              lastDate: DateTime.now(),
                              initialDate: _day);
                          if (mounted && day != null) {
                            setState(() => _day = day);
                          }
                        },
                        icon: const Icon(Icons.calendar_today_outlined),
                        label: Text('Data: ${_date.format(_day)}')),
                    const SizedBox(height: 8),
                    TextFormField(
                        controller: _value,
                        decoration: const InputDecoration(
                            labelText: 'Valor pago (R\$)'),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        validator: (value) => (_cents(value) ?? 0) <= 0
                            ? 'Informe um valor maior que zero.'
                            : null),
                    const SizedBox(height: 8),
                    TextFormField(
                        controller: _notes,
                        maxLength: 4000,
                        decoration: const InputDecoration(
                            labelText: 'Observações', counterText: '')),
                  ],
                )))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar')),
          FilledButton(onPressed: _save, child: const Text('Salvar acerto')),
        ],
      );
}
