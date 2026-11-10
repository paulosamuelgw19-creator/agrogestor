import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../app/app_theme.dart';
import 'machine.dart';
import 'machine_repository.dart';
import 'machine_timeline_screen.dart';
import '../sync/sync_status_label.dart';
import '../licensing/write_gate.dart';

class MachinesScreen extends StatefulWidget {
  const MachinesScreen({super.key});

  @override
  State<MachinesScreen> createState() => _MachinesScreenState();
}

class _MachinesScreenState extends State<MachinesScreen> {
  final _repository = MachineRepository();
  final _searchController = TextEditingController();
  List<Machine> _machines = [];
  MachineStatus? _filter;
  bool _loading = true;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final machines = await _repository.getAll();
      if (!mounted) return;
      setState(() {
        _machines = machines;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = error.toString();
      });
    }
  }

  Future<void> _persist(List<Machine> machines) async {
    try {
      if (await runLicensedWrite(context,
              () => _repository.saveAll(machines, previous: _machines)) &&
          mounted) {
        setState(() {
          _machines = machines;
          _loadError = null;
          _loading = false;
        });
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Não foi possível salvar a máquina: $error')),
      );
    }
  }

  Future<void> _edit([Machine? machine]) async {
    final result = await showDialog<Machine>(
      context: context,
      builder: (_) => _MachineForm(machine: machine),
    );
    if (result == null) return;
    final index = _machines.indexWhere((item) => item.id == result.id);
    final updated = [..._machines];
    if (index < 0) {
      updated.insert(0, result);
    } else {
      updated[index] = result;
    }
    await _persist(updated);
  }

  Future<void> _delete(Machine machine) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir máquina?'),
        content: Text('“${machine.name}” será removida deste aparelho.'),
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
    if (confirmed == true) {
      await _persist(_machines.where((item) => item.id != machine.id).toList());
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim().toLowerCase();
    final visible = _machines.where((machine) {
      final matchesQuery = '${machine.name} ${machine.brand} ${machine.model}'
          .toLowerCase()
          .contains(query);
      return matchesQuery && (_filter == null || machine.status == _filter);
    }).toList();

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Nova máquina'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Padding(
              padding: AppTheme.pagePadding(context),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Máquinas',
                        style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.forest)),
                    const SizedBox(height: 5),
                    const Text('Cadastre e acompanhe sua frota agrícola.',
                        style: TextStyle(color: Colors.black54)),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _searchController,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Buscar por nome, marca ou modelo',
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 42,
                      child:
                          ListView(scrollDirection: Axis.horizontal, children: [
                        _filterChip('Todas', null),
                        ...MachineStatus.values
                            .map((status) => _filterChip(status.label, status)),
                      ]),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: _loading
                          ? const Center(child: CircularProgressIndicator())
                          : _loadError != null
                              ? Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.error_outline,
                                          size: 40, color: Colors.deepOrange),
                                      const SizedBox(height: 8),
                                      const Text(
                                          'Não foi possível carregar as máquinas.'),
                                      const SizedBox(height: 8),
                                      Text(_loadError!,
                                          textAlign: TextAlign.center),
                                      const SizedBox(height: 12),
                                      OutlinedButton.icon(
                                        onPressed: _load,
                                        icon: const Icon(Icons.refresh),
                                        label: const Text('Tentar novamente'),
                                      ),
                                    ],
                                  ),
                                )
                              : visible.isEmpty
                                  ? _EmptyMachines(onAdd: () => _edit())
                                  : ListView.separated(
                                      padding:
                                          const EdgeInsets.only(bottom: 88),
                                      itemCount: visible.length,
                                      separatorBuilder: (_, __) =>
                                          const SizedBox(height: 10),
                                      itemBuilder: (context, index) =>
                                          _MachineCard(
                                        machine: visible[index],
                                        onEdit: () => _edit(visible[index]),
                                        onDelete: () => _delete(visible[index]),
                                      ),
                                    ),
                    ),
                  ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _filterChip(String label, MachineStatus? status) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: _filter == status,
          onSelected: (_) => setState(() => _filter = status),
        ),
      );
}

class _MachineCard extends StatelessWidget {
  const _MachineCard(
      {required this.machine, required this.onEdit, required this.onDelete});
  final Machine machine;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final tone = switch (machine.status) {
      MachineStatus.disponivel => AppTheme.leaf,
      MachineStatus.emOperacao => const Color(0xFF4779B5),
      MachineStatus.emManutencao => const Color(0xFFC4852C),
      MachineStatus.parada => const Color(0xFFCF5B51),
      MachineStatus.inativa => Colors.grey,
    };
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => MachineTimelineScreen(machine: machine),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
          child: Row(children: [
            machine.photoPath != null && machine.photoPath!.isNotEmpty
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Image.file(
                        File(machine.photoPath!),
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => CircleAvatar(
                          backgroundColor: tone.withValues(alpha: .12),
                          child: Icon(Icons.agriculture_rounded, color: tone),
                        ),
                      ),
                    ),
                  )
                : CircleAvatar(
                    backgroundColor: tone.withValues(alpha: .12),
                    child: Icon(Icons.agriculture_rounded, color: tone),
                  ),
            const SizedBox(width: 14),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Row(children: [
                    Expanded(
                        child: Text(machine.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w700, fontSize: 16))),
                    SyncStatusLabel(module: 'machines', recordId: machine.id),
                  ]),
                  Text('${machine.brand} ${machine.model} · ${machine.year}',
                      style: const TextStyle(color: Colors.black54)),
                  const SizedBox(height: 5),
                  Text(
                      '${machine.hourMeter.toStringAsFixed(1)} h  ·  ${machine.fuelType}',
                      style: const TextStyle(fontSize: 12)),
                ])),
            Chip(
                label: Text(machine.status.label),
                backgroundColor: tone.withValues(alpha: .12),
                side: BorderSide.none,
                labelStyle: TextStyle(color: tone, fontSize: 11)),
            PopupMenuButton<String>(
              onSelected: (action) => action == 'edit' ? onEdit() : onDelete(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('Editar')),
                PopupMenuItem(value: 'delete', child: Text('Excluir')),
              ],
            ),
          ]),
        ),
      ),
    );
  }
}

class _EmptyMachines extends StatelessWidget {
  const _EmptyMachines({required this.onAdd});
  final VoidCallback onAdd;
  @override
  Widget build(BuildContext context) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.agriculture_outlined, size: 48, color: AppTheme.leaf),
        const SizedBox(height: 12),
        const Text('Nenhuma máquina encontrada',
            style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 5),
        const Text('Cadastre uma máquina ou ajuste a busca.',
            style: TextStyle(color: Colors.black54)),
        const SizedBox(height: 14),
        OutlinedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Cadastrar máquina')),
      ]));
}

class _MachineForm extends StatefulWidget {
  const _MachineForm({this.machine});
  final Machine? machine;
  @override
  State<_MachineForm> createState() => _MachineFormState();
}

class _MachineFormState extends State<_MachineForm> {
  final _formKey = GlobalKey<FormState>();
  bool _submitted = false;
  late final _name = TextEditingController(text: widget.machine?.name ?? '');
  late final _brand = TextEditingController(text: widget.machine?.brand ?? '');
  late final _model = TextEditingController(text: widget.machine?.model ?? '');
  late final _year =
      TextEditingController(text: widget.machine?.year.toString() ?? '');
  late final _meter =
      TextEditingController(text: widget.machine?.hourMeter.toString() ?? '');
  late final _fuel =
      TextEditingController(text: widget.machine?.fuelType ?? 'Diesel');
  late final _identification =
      TextEditingController(text: widget.machine?.identificationNumber ?? '');
  late final _plate = TextEditingController(text: widget.machine?.plate ?? '');
  late final _serial =
      TextEditingController(text: widget.machine?.serialNumber ?? '');
  late final _tankCapacity = TextEditingController(
      text: widget.machine?.tankCapacity.toString() ?? '0');
  late final _consumption = TextEditingController(
      text: widget.machine?.averageConsumption.toString() ?? '0');
  late final _acquisitionValue = TextEditingController(
      text: widget.machine?.acquisitionValue.toString() ?? '0');
  late DateTime? _acquisitionDate = widget.machine?.acquisitionDate;
  late String? _photoPath = widget.machine?.photoPath;
  late String? _photoAttachmentId = widget.machine?.photoAttachmentId;
  late MachineStatus _status =
      widget.machine?.status ?? MachineStatus.disponivel;

  @override
  void dispose() {
    _name.dispose();
    _brand.dispose();
    _model.dispose();
    _year.dispose();
    _meter.dispose();
    _fuel.dispose();
    _identification.dispose();
    _plate.dispose();
    _serial.dispose();
    _tankCapacity.dispose();
    _consumption.dispose();
    _acquisitionValue.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto(ImageSource source) async {
    try {
      final picker = ImagePicker();
      final image = await picker.pickImage(
          source: source, maxWidth: 1024, maxHeight: 1024, imageQuality: 85);
      if (image != null && mounted) {
        final root = await getApplicationSupportDirectory();
        final folder =
            Directory('${root.path}${Platform.pathSeparator}attachments');
        await folder.create(recursive: true);
        final attachmentId = const Uuid().v4();
        final extension =
            image.path.contains('.') ? image.path.split('.').last : 'jpg';
        final savedPath =
            '${folder.path}${Platform.pathSeparator}$attachmentId.$extension';
        await File(image.path).copy(savedPath);
        setState(() {
          _photoPath = savedPath;
          _photoAttachmentId = attachmentId;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Não foi possível carregar a imagem: $e')),
        );
      }
    }
  }

  void _showPhotoOptions() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Tirar foto com a câmera'),
              onTap: () {
                Navigator.pop(ctx);
                _pickPhoto(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Escolher da galeria'),
              onTap: () {
                Navigator.pop(ctx);
                _pickPhoto(ImageSource.gallery);
              },
            ),
            if (_photoPath != null)
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: const Text('Remover foto',
                    style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() {
                    _photoPath = null;
                    _photoAttachmentId = null;
                  });
                },
              ),
          ],
        ),
      ),
    );
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Preencha este campo' : null;

  double _optionalNumber(String value) =>
      double.tryParse(value.trim().replaceAll(',', '.')) ?? 0;

  String? _validateOptionalNumber(String? value) {
    if (value == null || value.trim().isEmpty) return null;
    final number = double.tryParse(value.trim().replaceAll(',', '.'));
    return number == null || number < 0 ? 'Informe um valor válido' : null;
  }

  Future<void> _selectAcquisitionDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _acquisitionDate ?? DateTime.now(),
      firstDate: DateTime(1950),
      lastDate: DateTime.now(),
    );
    if (picked != null && mounted) {
      setState(() => _acquisitionDate = picked);
    }
  }

  void _save() {
    if (_submitted || !_formKey.currentState!.validate()) return;
    _submitted = true;
    final normalizedMeter = _meter.text.trim().replaceAll(',', '.');
    Navigator.pop(
        context,
        Machine(
          id: widget.machine?.id ?? const Uuid().v4(),
          name: _name.text.trim(),
          brand: _brand.text.trim(),
          model: _model.text.trim(),
          year: int.parse(_year.text),
          hourMeter: double.parse(normalizedMeter),
          fuelType: _fuel.text.trim(),
          status: _status,
          identificationNumber: _identification.text.trim(),
          plate: _plate.text.trim(),
          serialNumber: _serial.text.trim(),
          tankCapacity: _optionalNumber(_tankCapacity.text),
          averageConsumption: _optionalNumber(_consumption.text),
          acquisitionValue: _optionalNumber(_acquisitionValue.text),
          acquisitionDate: _acquisitionDate,
          photoPath: _photoPath,
          photoAttachmentId: _photoAttachmentId,
        ));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.machine == null ? 'Nova máquina' : 'Editar máquina'),
        content: SizedBox(
          width: AppTheme.dialogWidth(context, maxWidth: 460),
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Visualizador / Botão de Foto da Máquina
              Center(
                child: InkWell(
                  onTap: _showPhotoOptions,
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: double.infinity,
                    height: 120,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: _photoPath != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(
                              File(_photoPath!),
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Center(
                                child: Icon(Icons.broken_image,
                                    color: Colors.grey),
                              ),
                            ),
                          )
                        : const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.add_a_photo_outlined,
                                  size: 36, color: AppTheme.primary),
                              SizedBox(height: 6),
                              Text('Adicionar Foto da Máquina',
                                  style: TextStyle(
                                      fontSize: 12, color: Colors.black54)),
                            ],
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                  controller: _name,
                  decoration:
                      const InputDecoration(labelText: 'Nome da máquina'),
                  validator: _required,
                  textCapitalization: TextCapitalization.words),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: TextFormField(
                        controller: _brand,
                        decoration: const InputDecoration(labelText: 'Marca'),
                        validator: _required)),
                const SizedBox(width: 10),
                Expanded(
                    child: TextFormField(
                        controller: _model,
                        decoration: const InputDecoration(labelText: 'Modelo'),
                        validator: _required)),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: TextFormField(
                        controller: _identification,
                        decoration: const InputDecoration(
                            labelText: 'Número de identificação'))),
                const SizedBox(width: 10),
                Expanded(
                    child: TextFormField(
                        controller: _plate,
                        decoration: const InputDecoration(labelText: 'Placa'))),
              ]),
              const SizedBox(height: 10),
              TextFormField(
                  controller: _serial,
                  decoration:
                      const InputDecoration(labelText: 'Número de série')),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: TextFormField(
                        controller: _year,
                        decoration: const InputDecoration(labelText: 'Ano'),
                        keyboardType: TextInputType.number,
                        validator: (value) {
                          final year = int.tryParse(value ?? '');
                          return year == null ||
                                  year < 1950 ||
                                  year > DateTime.now().year + 1
                              ? 'Ano inválido'
                              : null;
                        })),
                const SizedBox(width: 10),
                Expanded(
                    child: TextFormField(
                        controller: _meter,
                        decoration:
                            const InputDecoration(labelText: 'Horímetro (h)'),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        validator: (value) {
                          final meter = double.tryParse(
                              (value ?? '').replaceAll(',', '.'));
                          return meter == null || meter < 0
                              ? 'Valor inválido'
                              : null;
                        })),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: TextFormField(
                        controller: _tankCapacity,
                        decoration:
                            const InputDecoration(labelText: 'Tanque (litros)'),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        validator: _validateOptionalNumber)),
                const SizedBox(width: 10),
                Expanded(
                    child: TextFormField(
                        controller: _consumption,
                        decoration: const InputDecoration(
                            labelText: 'Consumo médio (L/h)'),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        validator: _validateOptionalNumber)),
              ]),
              const SizedBox(height: 10),
              TextFormField(
                  controller: _acquisitionValue,
                  decoration: const InputDecoration(
                      labelText: 'Valor de aquisição (R\$)'),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  validator: _validateOptionalNumber),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _selectAcquisitionDate,
                  icon: const Icon(Icons.event_outlined),
                  label: Text(_acquisitionDate == null
                      ? 'Data de aquisição (opcional)'
                      : 'Adquirida em ${_acquisitionDate!.day.toString().padLeft(2, '0')}/${_acquisitionDate!.month.toString().padLeft(2, '0')}/${_acquisitionDate!.year}'),
                ),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                    child: TextFormField(
                        controller: _fuel,
                        decoration:
                            const InputDecoration(labelText: 'Combustível'),
                        validator: _required)),
                const SizedBox(width: 10),
                Expanded(
                    child: DropdownButtonFormField<MachineStatus>(
                  initialValue: _status,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: MachineStatus.values
                      .map((status) => DropdownMenuItem(
                          value: status, child: Text(status.label)))
                      .toList(),
                  onChanged: (value) =>
                      setState(() => _status = value ?? _status),
                )),
              ]),
            ])),
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
