import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../app/app_theme.dart';
import '../machines/machine.dart';
import '../machines/machine_repository.dart';
import '../operators/operator.dart';
import '../operators/operator_repository.dart';
import 'fuel_record.dart';
import 'fuel_repository.dart';
import '../sync/sync_status_label.dart';
import '../licensing/write_gate.dart';

class FuelScreen extends StatefulWidget {
  const FuelScreen({super.key});
  @override
  State<FuelScreen> createState() => _FuelScreenState();
}

class _FuelScreenState extends State<FuelScreen> {
  final _repo = FuelRepository();
  List<FuelRecord> _records = [];
  List<Machine> _machines = [];
  List<Operator> _operators = [];
  bool _loading = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final records = await _repo.getAll();
    final machines = await MachineRepository().getAll();
    final operators = await OperatorRepository().getAll();
    if (mounted) {
      setState(() {
        _records = records;
        _machines = machines;
        _operators = operators;
        _loading = false;
      });
    }
  }

  Future<void> _save(List<FuelRecord> items) async {
    if (await runLicensedWrite(
            context, () => _repo.saveAll(items, previous: _records)) &&
        mounted) {
      setState(() => _records = items);
    }
  }

  Future<void> _add() async {
    if (_machines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cadastre uma máquina primeiro.')));
      return;
    }
    final record = await showDialog<FuelRecord>(
        context: context,
        builder: (_) => _FuelForm(machines: _machines, operators: _operators));
    if (record != null) await _save([record, ..._records]);
  }

  Future<void> _delete(FuelRecord record) async {
    final yes = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const Text('Excluir abastecimento?'),
                content:
                    const Text('Este registro será removido deste aparelho.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Cancelar')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Excluir'))
                ]));
    if (yes == true) {
      await _save(_records.where((item) => item.id != record.id).toList());
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalLiters =
        _records.fold<double>(0, (sum, item) => sum + item.liters);
    final totalCost =
        _records.fold<double>(0, (sum, item) => sum + item.totalCost);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
          onPressed: _add,
          icon: const Icon(Icons.add),
          label: const Text('Registrar abastecimento')),
      body: SafeArea(
          child: Center(
              child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1000),
                  child: Padding(
                      padding: AppTheme.pagePadding(context),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Combustível',
                                style: TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w800,
                                    color: AppTheme.forest)),
                            const SizedBox(height: 5),
                            const Text(
                                'Abastecimentos e custos registrados por máquina.',
                                style: TextStyle(color: Colors.black54)),
                            const SizedBox(height: 18),
                            if (!_loading)
                              Wrap(spacing: 12, runSpacing: 12, children: [
                                _FuelSummary(
                                    label: 'Total abastecido',
                                    value:
                                        '${totalLiters.toStringAsFixed(1)} L',
                                    icon: Icons.local_gas_station_outlined),
                                _FuelSummary(
                                    label: 'Custo acumulado',
                                    value:
                                        'R\$ ${totalCost.toStringAsFixed(2)}',
                                    icon: Icons.payments_outlined),
                                _FuelSummary(
                                    label: 'Registros',
                                    value: '${_records.length}',
                                    icon: Icons.receipt_long_outlined),
                              ]),
                            const SizedBox(height: 16),
                            Expanded(
                                child: _loading
                                    ? const Center(
                                        child: CircularProgressIndicator())
                                    : _records.isEmpty
                                        ? Center(
                                            child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                const Icon(
                                                    Icons
                                                        .local_gas_station_outlined,
                                                    size: 48,
                                                    color: AppTheme.leaf),
                                                const SizedBox(height: 12),
                                                const Text(
                                                    'Nenhum abastecimento registrado',
                                                    style: TextStyle(
                                                        fontWeight:
                                                            FontWeight.w700)),
                                                const SizedBox(height: 12),
                                                OutlinedButton.icon(
                                                    onPressed: _add,
                                                    icon: const Icon(Icons.add),
                                                    label: const Text(
                                                        'Registrar abastecimento'))
                                              ]))
                                        : ListView.separated(
                                            padding: const EdgeInsets.only(
                                                bottom: 88),
                                            itemCount: _records.length,
                                            separatorBuilder: (_, __) =>
                                                const SizedBox(height: 10),
                                            itemBuilder: (context, index) {
                                              final r = _records[index];
                                              return Card(
                                                  child: ListTile(
                                                      contentPadding:
                                                          const EdgeInsets
                                                              .symmetric(
                                                              horizontal: 18,
                                                              vertical: 6),
                                                      leading: const CircleAvatar(
                                                          backgroundColor:
                                                              Color(0xFFE8F1E9),
                                                          foregroundColor:
                                                              AppTheme.leaf,
                                                          child: Icon(Icons
                                                              .local_gas_station_outlined)),
                                                      title: Row(children: [
                                                        Expanded(
                                                            child: Text(
                                                                r.machineName,
                                                                style: const TextStyle(
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w700))),
                                                        SyncStatusLabel(
                                                            module: 'fuel',
                                                            recordId: r.id),
                                                      ]),
                                                      subtitle: Text(
                                                          '${r.liters.toStringAsFixed(1)} L · R\$ ${r.pricePerLiter.toStringAsFixed(2)}/L · ${r.hourMeter.toStringAsFixed(1)} h\n${_date(r.date)}${r.location.isEmpty ? '' : ' · ${r.location}'}${r.operatorName.isEmpty ? '' : ' · ${r.operatorName}'}'),
                                                      isThreeLine: true,
                                                      trailing: Row(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            Text(
                                                                'R\$ ${r.totalCost.toStringAsFixed(2)}',
                                                                style: const TextStyle(
                                                                    fontWeight:
                                                                        FontWeight
                                                                            .w700)),
                                                            PopupMenuButton<
                                                                    String>(
                                                                onSelected:
                                                                    (_) =>
                                                                        _delete(
                                                                            r),
                                                                itemBuilder:
                                                                    (_) =>
                                                                        const [
                                                                          PopupMenuItem(
                                                                              value: 'delete',
                                                                              child: Text('Excluir'))
                                                                        ])
                                                          ])));
                                            })),
                          ]))))),
    );
  }

  String _date(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

class _FuelSummary extends StatelessWidget {
  const _FuelSummary(
      {required this.label, required this.value, required this.icon});
  final String label, value;
  final IconData icon;
  @override
  Widget build(BuildContext context) => SizedBox(
      width: 220,
      child: Card(
          child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(children: [
                Icon(icon, color: AppTheme.leaf),
                const SizedBox(width: 12),
                Expanded(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      Text(label,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.black54)),
                      const SizedBox(height: 3),
                      Text(value,
                          style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.forest))
                    ]))
              ]))));
}

class _FuelForm extends StatefulWidget {
  const _FuelForm({required this.machines, required this.operators});
  final List<Machine> machines;
  final List<Operator> operators;
  @override
  State<_FuelForm> createState() => _FuelFormState();
}

class _FuelFormState extends State<_FuelForm> {
  final _key = GlobalKey<FormState>();
  final _meter = TextEditingController();
  final _liters = TextEditingController();
  final _price = TextEditingController();
  final _location = TextEditingController();
  late Machine _machine = widget.machines.first;
  Operator? _operator;
  @override
  void dispose() {
    _meter.dispose();
    _liters.dispose();
    _price.dispose();
    _location.dispose();
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
        FuelRecord(
            id: const Uuid().v4(),
            machineId: _machine.id,
            machineName: '${_machine.brand} ${_machine.model}',
            operatorName: _operator?.name ?? '',
            date: DateTime.now(),
            hourMeter: _number(_meter.text)!,
            liters: _number(_liters.text)!,
            pricePerLiter: _number(_price.text)!,
            location: _location.text.trim()));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
          title: const Text('Registrar abastecimento'),
          content: SizedBox(
              width: AppTheme.dialogWidth(context, maxWidth: 440),
              child: Form(
                  key: _key,
                  child: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    DropdownButtonFormField<Machine>(
                        initialValue: _machine,
                        decoration: const InputDecoration(labelText: 'Máquina'),
                        items: widget.machines
                            .map((m) => DropdownMenuItem(
                                value: m, child: Text('${m.brand} ${m.model}')))
                            .toList(),
                        onChanged: (v) =>
                            setState(() => _machine = v ?? _machine)),
                    if (widget.operators.any((o) => o.active)) ...[
                      const SizedBox(height: 10),
                      DropdownButtonFormField<Operator>(
                          decoration: const InputDecoration(
                              labelText: 'Operador (opcional)'),
                          items: widget.operators
                              .where((o) => o.active)
                              .map((o) => DropdownMenuItem(
                                  value: o, child: Text(o.name)))
                              .toList(),
                          onChanged: (v) => setState(() => _operator = v))
                    ],
                    const SizedBox(height: 10),
                    TextFormField(
                        controller: _meter,
                        decoration:
                            const InputDecoration(labelText: 'Horímetro'),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        validator: _valid),
                    const SizedBox(height: 10),
                    TextFormField(
                        controller: _liters,
                        decoration: const InputDecoration(
                            labelText: 'Litros abastecidos'),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        validator: _valid),
                    const SizedBox(height: 10),
                    TextFormField(
                        controller: _price,
                        decoration: const InputDecoration(
                            labelText: 'Preço por litro (R\$)'),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        validator: _valid),
                    const SizedBox(height: 10),
                    TextFormField(
                        controller: _location,
                        decoration: const InputDecoration(
                            labelText: 'Posto/local (opcional)')),
                  ])))),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancelar')),
            FilledButton(onPressed: _submit, child: const Text('Salvar'))
          ]);
}
