import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../app/app_theme.dart';
import '../machines/machine.dart';
import '../machines/machine_repository.dart';
import 'maintenance_record.dart';
import 'maintenance_repository.dart';
import '../sync/sync_status_label.dart';
import '../licensing/write_gate.dart';

class MaintenanceScreen extends StatefulWidget {
  const MaintenanceScreen({super.key});
  @override
  State<MaintenanceScreen> createState() => _MaintenanceScreenState();
}

class _MaintenanceScreenState extends State<MaintenanceScreen> {
  final _repo = MaintenanceRepository();
  List<MaintenanceRecord> _records = [];
  List<Machine> _machines = [];
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final records = await _repo.getAll();
    final machines = await MachineRepository().getAll();
    if (mounted) {
      setState(() {
        _records = records;
        _machines = machines;
        _loading = false;
      });
    }
  }

  Future<void> _save(List<MaintenanceRecord> records) async {
    if (await runLicensedWrite(
            context, () => _repo.saveAll(records, previous: _records)) &&
        mounted) {
      setState(() => _records = records);
    }
  }

  Future<void> _edit([MaintenanceRecord? original]) async {
    if (_machines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cadastre uma máquina primeiro.')),
      );
      return;
    }
    final record = await showDialog<MaintenanceRecord>(
      context: context,
      builder: (_) => _MaintenanceForm(machines: _machines, record: original),
    );
    if (record == null) return;
    final updated = [..._records];
    final index = updated.indexWhere((item) => item.id == record.id);
    if (index < 0) {
      updated.insert(0, record);
    } else {
      updated[index] = record;
    }
    await _save(updated);
  }

  Future<void> _add() => _edit();

  Future<void> _delete(MaintenanceRecord record) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Excluir manutenção?'),
        content: const Text('Este registro será removido deste aparelho.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (yes == true) {
      await _save(_records.where((item) => item.id != record.id).toList());
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _add,
          icon: const Icon(Icons.add),
          label: const Text('Registrar manutenção'),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: Padding(
                padding: AppTheme.pagePadding(context),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Manutenção',
                      style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.forest,
                      ),
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      'Histórico, custos e próxima revisão por horímetro.',
                      style: TextStyle(color: Colors.black54),
                    ),
                    const SizedBox(height: 20),
                    Expanded(
                      child: _loading
                          ? const Center(child: CircularProgressIndicator())
                          : _records.isEmpty
                              ? Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.build_circle_outlined,
                                        size: 48,
                                        color: AppTheme.leaf,
                                      ),
                                      const SizedBox(height: 12),
                                      const Text(
                                        'Nenhuma manutenção registrada',
                                        style: TextStyle(
                                            fontWeight: FontWeight.w700),
                                      ),
                                      const SizedBox(height: 12),
                                      OutlinedButton.icon(
                                        onPressed: _add,
                                        icon: const Icon(Icons.add),
                                        label:
                                            const Text('Registrar manutenção'),
                                      ),
                                    ],
                                  ),
                                )
                              : ListView.separated(
                                  padding: const EdgeInsets.only(bottom: 88),
                                  itemCount: _records.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 10),
                                  itemBuilder: (context, index) {
                                    final r = _records[index];
                                    final machine = _machines
                                        .where((item) => item.id == r.machineId)
                                        .firstOrNull;
                                    final remaining = r.nextDueMeter -
                                        (machine?.hourMeter ?? r.hourMeter);
                                    final overdue = remaining <= 0;
                                    final soon =
                                        remaining > 0 && remaining <= 25;
                                    final color = overdue
                                        ? const Color(0xFFCF5B51)
                                        : soon
                                            ? const Color(0xFFC4852C)
                                            : AppTheme.leaf;
                                    final due = overdue
                                        ? 'Revisão atrasada'
                                        : soon
                                            ? 'Revisão próxima'
                                            : 'Próxima em ${remaining.toStringAsFixed(0)} h';
                                    return Card(
                                      child: ListTile(
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                          horizontal: 18,
                                          vertical: 8,
                                        ),
                                        leading: CircleAvatar(
                                          backgroundColor:
                                              color.withValues(alpha: .12),
                                          foregroundColor: color,
                                          child:
                                              const Icon(Icons.build_outlined),
                                        ),
                                        title: Row(children: [
                                          Expanded(
                                              child: Text(r.type,
                                                  style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w700))),
                                          SyncStatusLabel(
                                              module: 'maintenance',
                                              recordId: r.id),
                                        ]),
                                        subtitle: Text(
                                          '${r.machineName}\n${r.hourMeter.toStringAsFixed(1)} h · ${_date(r.date)}\n$due · ${r.nextDueMeter.toStringAsFixed(0)} h',
                                          style: const TextStyle(height: 1.5),
                                        ),
                                        isThreeLine: true,
                                        trailing: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                                'R\$ ${r.cost.toStringAsFixed(2)}'),
                                            PopupMenuButton<String>(
                                              onSelected: (action) =>
                                                  action == 'edit'
                                                      ? _edit(r)
                                                      : _delete(r),
                                              itemBuilder: (_) => const [
                                                PopupMenuItem(
                                                  value: 'edit',
                                                  child: Text('Editar'),
                                                ),
                                                PopupMenuItem(
                                                  value: 'delete',
                                                  child: Text('Excluir'),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
  String _date(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
}

class _MaintenanceForm extends StatefulWidget {
  const _MaintenanceForm({required this.machines, this.record});
  final List<Machine> machines;
  final MaintenanceRecord? record;
  @override
  State<_MaintenanceForm> createState() => _MaintenanceFormState();
}

class _MaintenanceFormState extends State<_MaintenanceForm> {
  final _key = GlobalKey<FormState>();
  late final _meter = TextEditingController(
    text: widget.record?.hourMeter.toString() ?? '0',
  );
  late final _cost = TextEditingController(
    text: widget.record?.cost.toString() ?? '0',
  );
  late final _description = TextEditingController(
    text: widget.record?.description ?? '',
  );
  late final _parts = TextEditingController(text: widget.record?.parts ?? '');
  late final _interval = TextEditingController(
    text: widget.record?.intervalHours.toString() ?? '250',
  );
  late Machine _machine = widget.machines.firstWhere(
    (machine) => machine.id == widget.record?.machineId,
    orElse: () => widget.machines.first,
  );
  late String _type = widget.record?.type ?? 'Preventiva';
  @override
  void dispose() {
    _meter.dispose();
    _cost.dispose();
    _description.dispose();
    _parts.dispose();
    _interval.dispose();
    super.dispose();
  }

  double? _number(String value) =>
      double.tryParse(value.trim().replaceAll(',', '.'));
  String? _valid(String? value) {
    final n = _number(value ?? '');
    return n == null || n < 0 ? 'Informe um valor válido' : null;
  }

  void _submit() {
    if (!_key.currentState!.validate()) return;
    Navigator.pop(
      context,
      MaintenanceRecord(
        id: widget.record?.id ?? const Uuid().v4(),
        machineId: _machine.id,
        machineName: '${_machine.brand} ${_machine.model}',
        date: widget.record?.date ?? DateTime.now(),
        hourMeter: _number(_meter.text)!,
        type: _type,
        description: _description.text.trim(),
        parts: _parts.text.trim(),
        cost: _number(_cost.text)!,
        intervalHours: _number(_interval.text)!,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(
          widget.record == null ? 'Registrar manutenção' : 'Editar manutenção',
        ),
        content: SizedBox(
          width: AppTheme.dialogWidth(context, maxWidth: 460),
          child: Form(
            key: _key,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<Machine>(
                    initialValue: _machine,
                    decoration: const InputDecoration(labelText: 'Máquina'),
                    items: widget.machines
                        .map(
                          (m) => DropdownMenuItem(
                            value: m,
                            child: Text('${m.brand} ${m.model}'),
                          ),
                        )
                        .toList(),
                    onChanged: (value) =>
                        setState(() => _machine = value ?? _machine),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: _type,
                    decoration: const InputDecoration(labelText: 'Tipo'),
                    items: const [
                      'Preventiva',
                      'Corretiva',
                      'Troca de óleo',
                      'Troca de filtros',
                      'Outro',
                    ]
                        .map((x) => DropdownMenuItem(value: x, child: Text(x)))
                        .toList(),
                    onChanged: (value) =>
                        setState(() => _type = value ?? _type),
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _meter,
                    decoration:
                        const InputDecoration(labelText: 'Horímetro atual'),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    validator: _valid,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _interval,
                    decoration: const InputDecoration(
                      labelText: 'Intervalo até próxima manutenção (h)',
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    validator: _valid,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _cost,
                    decoration: const InputDecoration(
                      labelText: 'Custo total (R\$)',
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    validator: _valid,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _description,
                    decoration: const InputDecoration(
                      labelText: 'Diagnóstico/serviço',
                    ),
                    maxLines: 2,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _parts,
                    decoration: const InputDecoration(
                      labelText: 'Peças, óleo e filtros',
                    ),
                    maxLines: 2,
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar'),
          ),
          FilledButton(onPressed: _submit, child: const Text('Salvar')),
        ],
      );
}
