import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../app/app_theme.dart';
import 'operator.dart';
import 'operator_repository.dart';
import '../sync/sync_status_label.dart';
import '../licensing/write_gate.dart';

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
          label: const Text('Novo operador')),
      body: SafeArea(
          child: Center(
              child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000),
        child: Padding(
            padding: AppTheme.pagePadding(context),
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Operadores',
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
                                  contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 18, vertical: 6),
                                  leading: CircleAvatar(
                                      backgroundColor:
                                          tone.withValues(alpha: .12),
                                      foregroundColor: tone,
                                      child: Text(item.name.isEmpty
                                          ? '?'
                                          : item.name[0].toUpperCase())),
                                  title: Row(children: [
                                    Expanded(
                                        child: Text(item.name,
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w700))),
                                    SyncStatusLabel(
                                        module: 'operators', recordId: item.id),
                                  ]),
                                  subtitle: Text(
                                      '${item.role}${item.phone.isEmpty ? '' : ' · ${item.phone}'}'),
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
  late bool _active = widget.operator?.active ?? true;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _role.dispose();
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
        ));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title:
            Text(widget.operator == null ? 'Novo operador' : 'Editar operador'),
        content: SizedBox(
            width: AppTheme.dialogWidth(context, maxWidth: 420),
            child: Form(
                key: _key,
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
                ]))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar')),
          FilledButton(onPressed: _submit, child: const Text('Salvar'))
        ],
      );
}
