import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../app/app_theme.dart';
import '../coffee_finance/coffee_finance_repository.dart';
import '../licensing/write_gate.dart';
import '../local_backup/local_photo.dart';
import 'coffee_tools_repository.dart';

final _money = NumberFormat.simpleCurrency(locale: 'pt_BR');

class CoffeeToolsScreen extends StatefulWidget {
  const CoffeeToolsScreen({super.key});

  @override
  State<CoffeeToolsScreen> createState() => _CoffeeToolsScreenState();
}

class _CoffeeToolsScreenState extends State<CoffeeToolsScreen> {
  final _repository = CoffeeToolsRepository();
  late Future<List<CoffeeTool>> _items = _repository.getAll();

  void _reload() => setState(() {
        _items = _repository.getAll();
      });

  Future<void> _edit({CoffeeTool? category, CoffeeTool? tool}) async {
    final expenses = category == null
        ? const <CoffeeFinanceEntry>[]
        : await CoffeeFinanceRepository().toolExpenseCandidates();
    if (!mounted) return;
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _ToolEditor(
        category: category,
        tool: tool,
        expenses: expenses,
        repository: _repository,
      ),
    );
    if (mounted && saved == true) _reload();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<CoffeeTool>>(
        future: _items,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
                child: TextButton(
                    onPressed: _reload,
                    child:
                        const Text('Tentar carregar ferramentas novamente')));
          }
          final items = snapshot.data;
          if (items == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: AppTheme.pagePadding(context),
            children: [
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: FilledButton.icon(
                  onPressed: () => _edit(),
                  icon: const Icon(Icons.add),
                  label: const Text('Nova categoria'),
                ),
              ),
              for (final category in items.where((item) => item.isCategory))
                Card(
                  child: ExpansionTile(
                    title:
                        Text(category.name, style: AppTheme.nameStyle(context)),
                    children: [
                      for (final item in items
                          .where((item) => item.categoryId == category.id))
                        ListTile(
                          title: Text(item.name,
                              style: AppTheme.nameStyle(context)),
                          subtitle: Text([
                            if (item.paidCents != null)
                              'Valor pago: ${_money.format(item.paidCents! / 100)}',
                            if (item.expenseId != null) 'Despesa vinculada',
                            if (item.notes.isNotEmpty) item.notes,
                          ].join('\n')),
                          trailing: const Icon(Icons.edit_outlined),
                          onTap: () => _edit(category: category, tool: item),
                        ),
                      TextButton.icon(
                        onPressed: () => _edit(category: category),
                        icon: const Icon(Icons.add),
                        label: const Text('Adicionar ferramenta'),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      );
}

class _ToolEditor extends StatefulWidget {
  const _ToolEditor({
    required this.category,
    required this.tool,
    required this.expenses,
    required this.repository,
  });
  final CoffeeTool? category, tool;
  final List<CoffeeFinanceEntry> expenses;
  final CoffeeToolsRepository repository;

  @override
  State<_ToolEditor> createState() => _ToolEditorState();
}

class _ToolEditorState extends State<_ToolEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.tool?.name);
  late final _notes = TextEditingController(text: widget.tool?.notes);
  late final _paid = TextEditingController(
      text: widget.tool?.paidCents == null
          ? ''
          : (widget.tool!.paidCents! / 100)
              .toStringAsFixed(2)
              .replaceAll('.', ','));
  late String? _photo = widget.tool?.photoPath;
  late String? _expense = widget.tool?.expenseId;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _notes.dispose();
    _paid.dispose();
    super.dispose();
  }

  int? _cents(String input) {
    final normalized = input.trim().replaceAll(',', '.');
    if (!RegExp(r'^\d+(?:\.\d{1,2})?$').hasMatch(normalized)) return null;
    final value = double.tryParse(normalized);
    return value == null || !value.isFinite || value > 1e10
        ? null
        : (value * 100).round();
  }

  Future<void> _save() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final saved = await runLicensedWrite(
          context,
          () => widget.repository.save(CoffeeTool(
                id: widget.tool?.id ?? const Uuid().v4(),
                name: _name.text.trim(),
                notes: _notes.text.trim(),
                categoryId: widget.category?.id,
                paidCents: _cents(_paid.text),
                photoPath: _photo,
                expenseId: _expense,
              )));
      if (saved && mounted) Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.category == null
            ? 'Nova categoria'
            : widget.tool == null
                ? 'Nova ferramenta'
                : 'Editar ferramenta'),
        content: SizedBox(
          width: AppTheme.dialogWidth(context, maxWidth: 440),
          child: Form(
            key: _form,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (widget.category case final CoffeeTool category)
                  Text(category.name, style: AppTheme.nameStyle(context)),
                TextFormField(
                  controller: _name,
                  maxLength: 160,
                  decoration:
                      const InputDecoration(labelText: 'Nome', counterText: ''),
                  validator: (text) =>
                      (text ?? '').trim().isEmpty ? 'Informe o nome.' : null,
                ),
                if (widget.category != null) ...[
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _paid,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration:
                        const InputDecoration(labelText: r'Valor pago (R$)'),
                    validator: (text) =>
                        (text ?? '').trim().isNotEmpty && _cents(text!) == null
                            ? 'Informe um valor válido.'
                            : null,
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _expense ?? '',
                    decoration: const InputDecoration(
                        labelText: 'Vincular despesa existente'),
                    items: [
                      const DropdownMenuItem(
                          value: '', child: Text('Sem vínculo')),
                      for (final expense in widget.expenses)
                        DropdownMenuItem(
                            value: expense.id,
                            child: Text(expense.description,
                                overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: _saving
                        ? null
                        : (value) => setState(() {
                              _expense = value == '' ? null : value;
                              final amount = widget.expenses
                                  .where((entry) => entry.id == _expense)
                                  .firstOrNull
                                  ?.totalCents;
                              if (amount != null) {
                                _paid.text = (amount / 100)
                                    .toStringAsFixed(2)
                                    .replaceAll('.', ',');
                              }
                            }),
                  ),
                ],
                const SizedBox(height: 8),
                TextFormField(
                    controller: _notes,
                    maxLines: 3,
                    maxLength: 4000,
                    decoration:
                        const InputDecoration(labelText: 'Observações')),
                LocalPhotoField(
                    photoPath: _photo,
                    enabled: !_saving,
                    onChanged: (value) => setState(() => _photo = value)),
              ]),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: _saving ? null : () => Navigator.pop(context),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: _saving ? null : _save, child: const Text('Salvar')),
        ],
      );
}
