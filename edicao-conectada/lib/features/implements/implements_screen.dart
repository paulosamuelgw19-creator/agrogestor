import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../app/app_theme.dart';
import 'farm_implement.dart';
import '../machines/catalog_photos.dart';
import 'implement_repository.dart';
import '../sync/sync_status_label.dart';
import '../licensing/write_gate.dart';

class ImplementsScreen extends StatefulWidget {
  const ImplementsScreen({super.key});
  @override
  State<ImplementsScreen> createState() => _ImplementsScreenState();
}

class _ImplementsScreenState extends State<ImplementsScreen> {
  final _repo = ImplementRepository();
  final _search = TextEditingController();
  List<FarmImplement> _items = [];
  bool _loading = true;
  bool? _active;
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
    final items = await _repo.getAll();
    if (mounted) {
      setState(() {
        _items = items;
        _loading = false;
      });
    }
  }

  Future<void> _save(List<FarmImplement> items) async {
    if (await runLicensedWrite(
            context, () => _repo.saveAll(items, previous: _items)) &&
        mounted) {
      setState(() => _items = items);
    }
  }

  Future<void> _edit([FarmImplement? item]) async {
    final result = await showDialog<FarmImplement>(
        context: context, builder: (_) => _ImplementForm(item: item));
    if (result == null) return;
    final list = [..._items];
    final index = list.indexWhere((entry) => entry.id == result.id);
    if (index < 0) {
      list.insert(0, result);
    } else {
      list[index] = result;
    }
    await _save(list);
  }

  Future<void> _delete(FarmImplement item) async {
    final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Excluir implemento?'),
              content: Text('“${item.name}” será removido deste aparelho.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancelar')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Excluir'))
              ],
            ));
    if (yes == true) {
      await _save(_items.where((entry) => entry.id != item.id).toList());
    }
  }

  @override
  Widget build(BuildContext context) {
    final term = _search.text.toLowerCase().trim();
    final visible = _items
        .where((item) =>
            '${item.name} ${item.type} ${item.brand} ${item.model}'
                .toLowerCase()
                .contains(term) &&
            (_active == null || item.active == _active))
        .toList();
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _edit(),
          icon: const Icon(Icons.add),
          label: const Text('Novo implemento')),
      body: SafeArea(
          child: Center(
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1000),
                  child: Padding(
                      padding: AppTheme.pagePadding(context),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Implementos',
                                style: TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w800,
                                    color: AppTheme.forest)),
                            const SizedBox(height: 5),
                            const Text(
                                'Controle equipamentos e máquinas compatíveis.',
                                style: TextStyle(color: Colors.black54)),
                            const SizedBox(height: 20),
                            TextField(
                                controller: _search,
                                onChanged: (_) => setState(() {}),
                                decoration: const InputDecoration(
                                    prefixIcon: Icon(Icons.search),
                                    hintText:
                                        'Buscar implemento, tipo ou marca')),
                            const SizedBox(height: 12),
                            Wrap(spacing: 8, children: [
                              ChoiceChip(
                                  label: const Text('Todos'),
                                  selected: _active == null,
                                  onSelected: (_) =>
                                      setState(() => _active = null)),
                              ChoiceChip(
                                  label: const Text('Ativos'),
                                  selected: _active == true,
                                  onSelected: (_) =>
                                      setState(() => _active = true)),
                              ChoiceChip(
                                  label: const Text('Inativos'),
                                  selected: _active == false,
                                  onSelected: (_) =>
                                      setState(() => _active = false)),
                            ]),
                            const SizedBox(height: 12),
                            Expanded(
                                child: _loading
                                    ? const Center(
                                        child: CircularProgressIndicator())
                                    : visible.isEmpty
                                        ? Center(
                                            child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                const Icon(
                                                    Icons.handyman_outlined,
                                                    size: 48,
                                                    color: AppTheme.leaf),
                                                const SizedBox(height: 12),
                                                Text(
                                                    _items.isEmpty
                                                        ? 'Cadastre o primeiro implemento'
                                                        : 'Nenhum implemento encontrado',
                                                    style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w700)),
                                                const SizedBox(height: 12),
                                                OutlinedButton.icon(
                                                    onPressed: () => _edit(),
                                                    icon: const Icon(Icons.add),
                                                    label: const Text(
                                                        'Cadastrar implemento'))
                                              ]))
                                        : ListView.separated(
                                            padding: const EdgeInsets.only(
                                                bottom: 88),
                                            itemCount: visible.length,
                                            separatorBuilder: (_, __) =>
                                                const SizedBox(height: 10),
                                            itemBuilder: (context, index) {
                                              final item = visible[index];
                                              final tone = item.active
                                                  ? AppTheme.leaf
                                                  : Colors.grey;
                                              return Card(
                                                  child: ListTile(
                                                onTap: () => Navigator.push(
                                                    context,
                                                    MaterialPageRoute<void>(
                                                        builder: (_) =>
                                                            CatalogPhotosScreen(
                                                                kind:
                                                                    'implement',
                                                                targetId:
                                                                    item.id,
                                                                name: item
                                                                    .name))),
                                                contentPadding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 18,
                                                        vertical: 6),
                                                leading: CircleAvatar(
                                                    backgroundColor: tone
                                                        .withValues(alpha: .12),
                                                    foregroundColor: tone,
                                                    child: const Icon(Icons
                                                        .handyman_outlined)),
                                                title: Row(children: [
                                                  Expanded(
                                                      child: Text(item.name,
                                                          style: const TextStyle(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w700))),
                                                  SyncStatusLabel(
                                                      module: 'implements',
                                                      recordId: item.id),
                                                ]),
                                                subtitle: Text(
                                                    '${item.type} · ${item.brand} ${item.model}${item.compatibleMachine.isEmpty ? '' : ' · ${item.compatibleMachine}'}\n${item.hours.toStringAsFixed(1)} h de uso'),
                                                isThreeLine: true,
                                                trailing: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Chip(
                                                          label: Text(
                                                              item.active
                                                                  ? 'Ativo'
                                                                  : 'Inativo'),
                                                          backgroundColor:
                                                              tone.withValues(
                                                                  alpha: .12),
                                                          side: BorderSide.none,
                                                          labelStyle: TextStyle(
                                                              color: tone,
                                                              fontSize: 11)),
                                                      PopupMenuButton<String>(
                                                          onSelected:
                                                              (action) =>
                                                                  action ==
                                                                          'edit'
                                                                      ? _edit(
                                                                          item)
                                                                      : _delete(
                                                                          item),
                                                          itemBuilder: (_) =>
                                                              const [
                                                                PopupMenuItem(
                                                                    value:
                                                                        'edit',
                                                                    child: Text(
                                                                        'Editar')),
                                                                PopupMenuItem(
                                                                    value:
                                                                        'delete',
                                                                    child: Text(
                                                                        'Excluir'))
                                                              ])
                                                    ]),
                                              ));
                                            })),
                          ]))))),
    );
  }
}

class _ImplementForm extends StatefulWidget {
  const _ImplementForm({this.item});
  final FarmImplement? item;
  @override
  State<_ImplementForm> createState() => _ImplementFormState();
}

class _ImplementFormState extends State<_ImplementForm> {
  final _key = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.item?.name ?? '');
  late final _type = TextEditingController(text: widget.item?.type ?? '');
  late final _brand = TextEditingController(text: widget.item?.brand ?? '');
  late final _model = TextEditingController(text: widget.item?.model ?? '');
  late final _hours =
      TextEditingController(text: widget.item?.hours.toString() ?? '0');
  late final _compatible =
      TextEditingController(text: widget.item?.compatibleMachine ?? '');
  late bool _active = widget.item?.active ?? true;
  @override
  void dispose() {
    _name.dispose();
    _type.dispose();
    _brand.dispose();
    _model.dispose();
    _hours.dispose();
    _compatible.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_key.currentState!.validate()) return;
    Navigator.pop(
        context,
        FarmImplement(
            id: widget.item?.id ?? const Uuid().v4(),
            name: _name.text.trim(),
            type: _type.text.trim(),
            brand: _brand.text.trim(),
            model: _model.text.trim(),
            hours: double.parse(_hours.text.replaceAll(',', '.')),
            compatibleMachine: _compatible.text.trim(),
            active: _active));
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Preencha este campo' : null;
  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(
              widget.item == null ? 'Novo implemento' : 'Editar implemento'),
          content: SizedBox(
              width: AppTheme.dialogWidth(context, maxWidth: 450),
              child: Form(
                  key: _key,
                  child: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextFormField(
                        controller: _name,
                        decoration: const InputDecoration(labelText: 'Nome'),
                        validator: _required),
                    const SizedBox(height: 10),
                    TextFormField(
                        controller: _type,
                        decoration: const InputDecoration(
                            labelText: 'Tipo (ex.: plantadeira, grade)'),
                        validator: _required),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                          child: TextFormField(
                              controller: _brand,
                              decoration:
                                  const InputDecoration(labelText: 'Marca'))),
                      const SizedBox(width: 10),
                      Expanded(
                          child: TextFormField(
                              controller: _model,
                              decoration:
                                  const InputDecoration(labelText: 'Modelo')))
                    ]),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                          child: TextFormField(
                              controller: _hours,
                              decoration: const InputDecoration(
                                  labelText: 'Horas de uso'),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              validator: (v) {
                                final n = double.tryParse(
                                    (v ?? '').replaceAll(',', '.'));
                                return n == null || n < 0
                                    ? 'Valor inválido'
                                    : null;
                              })),
                      const SizedBox(width: 10),
                      Expanded(
                          child: TextFormField(
                              controller: _compatible,
                              decoration: const InputDecoration(
                                  labelText: 'Máquina compatível')))
                    ]),
                    SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Implemento ativo'),
                        value: _active,
                        onChanged: (value) => setState(() => _active = value)),
                  ])))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar')),
            FilledButton(onPressed: _submit, child: const Text('Salvar'))
          ]);
}
