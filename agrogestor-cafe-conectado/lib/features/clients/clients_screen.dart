import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../app/app_theme.dart';
import 'client_record.dart';
import 'client_repository.dart';
import '../sync/sync_status_label.dart';
import '../licensing/write_gate.dart';

class ClientsScreen extends StatefulWidget {
  const ClientsScreen({super.key});
  @override
  State<ClientsScreen> createState() => _ClientsScreenState();
}

class _ClientsScreenState extends State<ClientsScreen> {
  final _repo = ClientRepository();
  final _search = TextEditingController();
  List<RuralClient> _clients = [];
  bool _loading = true;
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
    final result = await _repo.getAll();
    if (mounted) {
      setState(() {
        _clients = result;
        _loading = false;
      });
    }
  }

  Future<void> _save(List<RuralClient> items) async {
    if (await runLicensedWrite(
            context, () => _repo.saveAll(items, previous: _clients)) &&
        mounted) {
      setState(() => _clients = items);
    }
  }

  Future<List<String>?> _form(String title, List<_InputSpec> fields) =>
      showDialog<List<String>>(
          context: context,
          builder: (_) => _ValuesForm(title: title, fields: fields));

  Future<void> _client([RuralClient? original]) async {
    final values =
        await _form(original == null ? 'Novo cliente' : 'Editar cliente', [
      _InputSpec('Nome do cliente', original?.name ?? '', required: true),
      _InputSpec('CPF/CNPJ', original?.document ?? ''),
      _InputSpec('Telefone', original?.phone ?? ''),
      _InputSpec('Endereço', original?.address ?? ''),
    ]);
    if (values == null) return;
    final result = RuralClient(
        id: original?.id ?? const Uuid().v4(),
        name: values[0].trim(),
        document: values[1].trim(),
        phone: values[2].trim(),
        address: values[3].trim(),
        properties: original?.properties ?? const []);
    final list = [..._clients];
    final index = list.indexWhere((x) => x.id == result.id);
    if (index < 0) {
      list.insert(0, result);
    } else {
      list[index] = result;
    }
    await _save(list);
  }

  Future<void> _property(RuralClient client, [RuralProperty? original]) async {
    final values = await _form(
        original == null ? 'Nova propriedade' : 'Editar propriedade', [
      _InputSpec('Nome da propriedade', original?.name ?? '', required: true),
      _InputSpec('Localização', original?.location ?? ''),
      _InputSpec('Área total (ha)', original?.totalArea.toString() ?? '0',
          required: true, number: true),
    ]);
    if (values == null) return;
    final property = RuralProperty(
        id: original?.id ?? const Uuid().v4(),
        name: values[0].trim(),
        location: values[1].trim(),
        totalArea: double.parse(values[2].replaceAll(',', '.')),
        fields: original?.fields ?? const []);
    final updatedClient = client.copyWith(properties: [
      ...client.properties.where((x) => x.id != property.id),
      property
    ]);
    await _replaceClient(updatedClient);
  }

  Future<void> _field(RuralClient client, RuralProperty property,
      [RuralField? original]) async {
    final values =
        await _form(original == null ? 'Novo talhão' : 'Editar talhão', [
      _InputSpec('Nome do talhão', original?.name ?? '', required: true),
      _InputSpec('Área (ha)', original?.area.toString() ?? '',
          required: true, number: true),
      _InputSpec('Cultura', original?.crop ?? ''),
      _InputSpec('Observações', original?.notes ?? ''),
    ]);
    if (values == null) return;
    final field = RuralField(
        id: original?.id ?? const Uuid().v4(),
        name: values[0].trim(),
        area: double.parse(values[1].replaceAll(',', '.')),
        crop: values[2].trim(),
        notes: values[3].trim());
    final updatedProperty = property.copyWith(
        fields: [...property.fields.where((x) => x.id != field.id), field]);
    await _replaceClient(client.copyWith(
        properties: client.properties
            .map((x) => x.id == property.id ? updatedProperty : x)
            .toList()));
  }

  Future<void> _replaceClient(RuralClient client) async =>
      _save(_clients.map((x) => x.id == client.id ? client : x).toList());

  Future<void> _deleteClient(RuralClient client) async {
    final yes = await _confirm('Excluir cliente?',
        'As propriedades e talhões de ${client.name} também serão removidos.');
    if (yes) {
      await _save(_clients.where((x) => x.id != client.id).toList());
    }
  }

  Future<void> _deleteProperty(
      RuralClient client, RuralProperty property) async {
    final yes = await _confirm('Excluir propriedade?',
        'Os talhões associados também serão removidos.');
    if (yes) {
      await _replaceClient(client.copyWith(
          properties:
              client.properties.where((x) => x.id != property.id).toList()));
    }
  }

  Future<void> _deleteField(
      RuralClient client, RuralProperty property, RuralField field) async {
    final yes = await _confirm(
        'Excluir talhão?', 'Este talhão será removido da propriedade.');
    if (yes) {
      await _replaceClient(client.copyWith(
          properties: client.properties
              .map((x) => x.id == property.id
                  ? x.copyWith(
                      fields: x.fields.where((f) => f.id != field.id).toList())
                  : x)
              .toList()));
    }
  }

  Future<bool> _confirm(String title, String detail) async =>
      await showDialog<bool>(
          context: context,
          builder: (context) =>
              AlertDialog(title: Text(title), content: Text(detail), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancelar')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Excluir'))
              ])) ??
      false;

  @override
  Widget build(BuildContext context) {
    final term = _search.text.trim().toLowerCase();
    final visible = _clients
        .where((x) =>
            '${x.name} ${x.document} ${x.phone}'.toLowerCase().contains(term))
        .toList();
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
          onPressed: () => _client(),
          icon: const Icon(Icons.person_add_alt_1),
          label: const Text('Novo cliente')),
      body: SafeArea(
          child: Center(
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1000),
                  child: Padding(
                      padding: AppTheme.pagePadding(context),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Clientes e propriedades',
                                style: TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w800,
                                    color: AppTheme.forest)),
                            const SizedBox(height: 5),
                            const Text(
                                'Organize clientes, propriedades e talhões.',
                                style: TextStyle(color: Colors.black54)),
                            const SizedBox(height: 20),
                            TextField(
                                controller: _search,
                                onChanged: (_) => setState(() {}),
                                decoration: const InputDecoration(
                                    prefixIcon: Icon(Icons.search),
                                    hintText:
                                        'Buscar cliente, documento ou telefone')),
                            const SizedBox(height: 16),
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
                                                    Icons.groups_outlined,
                                                    size: 48,
                                                    color: AppTheme.leaf),
                                                const SizedBox(height: 12),
                                                Text(
                                                    _clients.isEmpty
                                                        ? 'Cadastre seu primeiro cliente'
                                                        : 'Nenhum cliente encontrado',
                                                    style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.w700)),
                                                const SizedBox(height: 12),
                                                OutlinedButton.icon(
                                                    onPressed: () => _client(),
                                                    icon: const Icon(Icons.add),
                                                    label: const Text(
                                                        'Cadastrar cliente'))
                                              ]))
                                        : ListView.separated(
                                            padding: const EdgeInsets.only(
                                                bottom: 88),
                                            itemCount: visible.length,
                                            separatorBuilder: (_, __) =>
                                                const SizedBox(height: 10),
                                            itemBuilder: (context, index) {
                                              final client = visible[index];
                                              return Card(
                                                  child: ExpansionTile(
                                                      leading: const CircleAvatar(
                                                          backgroundColor:
                                                              Color(0xFFE8F1E9),
                                                          foregroundColor:
                                                              AppTheme.leaf,
                                                          child: Icon(Icons
                                                              .person_outline)),
                                                      title: Row(children: [
                                                        Expanded(
                                                            child: Text(
                                                                client.name,
                                                                style: const TextStyle(
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w700))),
                                                        SyncStatusLabel(
                                                            module: 'clients',
                                                            recordId:
                                                                client.id),
                                                      ]),
                                                      subtitle: Text([
                                                        client.document,
                                                        client.phone
                                                      ]
                                                          .where((x) =>
                                                              x.isNotEmpty)
                                                          .join(' · ')),
                                                      children: [
                                                    Align(
                                                        alignment: Alignment
                                                            .centerRight,
                                                        child: Wrap(children: [
                                                          TextButton.icon(
                                                              onPressed: () =>
                                                                  _client(
                                                                      client),
                                                              icon: const Icon(Icons
                                                                  .edit_outlined),
                                                              label: const Text(
                                                                  'Editar cliente')),
                                                          TextButton.icon(
                                                              onPressed: () =>
                                                                  _deleteClient(
                                                                      client),
                                                              icon: const Icon(Icons
                                                                  .delete_outline),
                                                              label: const Text(
                                                                  'Excluir'))
                                                        ])),
                                                    if (client
                                                        .address.isNotEmpty)
                                                      ListTile(
                                                          dense: true,
                                                          leading: const Icon(Icons
                                                              .location_on_outlined),
                                                          title: Text(
                                                              client.address)),
                                                    ...client.properties.map(
                                                        (property) =>
                                                            _propertyTile(
                                                                client,
                                                                property)),
                                                    Align(
                                                        alignment: Alignment
                                                            .centerLeft,
                                                        child: Padding(
                                                            padding:
                                                                const EdgeInsets
                                                                    .only(
                                                                    left: 16,
                                                                    bottom: 12),
                                                            child: OutlinedButton.icon(
                                                                onPressed: () =>
                                                                    _property(
                                                                        client),
                                                                icon: const Icon(
                                                                    Icons
                                                                        .add_home_work_outlined),
                                                                label: const Text(
                                                                    'Adicionar propriedade')))),
                                                  ]));
                                            })),
                          ]))))),
    );
  }

  Widget _propertyTile(RuralClient client, RuralProperty property) => Padding(
      padding: const EdgeInsets.only(left: 18),
      child: ExpansionTile(
          leading: const Icon(Icons.agriculture_outlined, color: AppTheme.leaf),
          title: Text(property.name,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
              '${property.totalArea.toStringAsFixed(1)} ha${property.location.isEmpty ? '' : ' · ${property.location}'}'),
          children: [
            Align(
                alignment: Alignment.centerRight,
                child: Wrap(children: [
                  TextButton.icon(
                      onPressed: () => _property(client, property),
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Editar propriedade')),
                  TextButton.icon(
                      onPressed: () => _deleteProperty(client, property),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Excluir'))
                ])),
            ...property.fields.map((field) => ListTile(
                dense: true,
                leading: const Icon(Icons.crop_square, color: AppTheme.leaf),
                title: Text(field.name),
                subtitle: Text(
                    '${field.area.toStringAsFixed(1)} ha${field.crop.isEmpty ? '' : ' · ${field.crop}'}${field.notes.isEmpty ? '' : ' · ${field.notes}'}'),
                trailing: PopupMenuButton<String>(
                    onSelected: (action) => action == 'edit'
                        ? _field(client, property, field)
                        : _deleteField(client, property, field),
                    itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('Editar')),
                          PopupMenuItem(value: 'delete', child: Text('Excluir'))
                        ]))),
            Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                    padding: const EdgeInsets.only(left: 16, bottom: 12),
                    child: OutlinedButton.icon(
                        onPressed: () => _field(client, property),
                        icon: const Icon(Icons.add),
                        label: const Text('Adicionar talhão')))),
          ]));
}

class _InputSpec {
  const _InputSpec(this.label, this.initial,
      {this.required = false, this.number = false});
  final String label, initial;
  final bool required, number;
}

class _ValuesForm extends StatefulWidget {
  const _ValuesForm({required this.title, required this.fields});
  final String title;
  final List<_InputSpec> fields;
  @override
  State<_ValuesForm> createState() => _ValuesFormState();
}

class _ValuesFormState extends State<_ValuesForm> {
  final _key = GlobalKey<FormState>();
  late final _controllers =
      widget.fields.map((x) => TextEditingController(text: x.initial)).toList();
  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: Text(widget.title),
          content: SizedBox(
              width: AppTheme.dialogWidth(context, maxWidth: 440),
              child: Form(
                  key: _key,
                  child: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    for (var index = 0;
                        index < widget.fields.length;
                        index++) ...[
                      if (index > 0) const SizedBox(height: 10),
                      TextFormField(
                          controller: _controllers[index],
                          decoration: InputDecoration(
                              labelText: widget.fields[index].label),
                          keyboardType: widget.fields[index].number
                              ? const TextInputType.numberWithOptions(
                                  decimal: true)
                              : TextInputType.text,
                          maxLines: widget.fields[index].label == 'Observações'
                              ? 2
                              : 1,
                          validator: (value) {
                            final field = widget.fields[index];
                            final text = value?.trim() ?? '';
                            if (field.required && text.isEmpty) {
                              return 'Preencha este campo';
                            }
                            if (field.number &&
                                (double.tryParse(text.replaceAll(',', '.')) ==
                                        null ||
                                    double.parse(text.replaceAll(',', '.')) <
                                        0)) {
                              return 'Informe um número válido';
                            }
                            return null;
                          }),
                    ],
                  ])))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () {
                  if (_key.currentState!.validate()) {
                    Navigator.pop(
                        context, _controllers.map((x) => x.text).toList());
                  }
                },
                child: const Text('Salvar'))
          ]);
}
