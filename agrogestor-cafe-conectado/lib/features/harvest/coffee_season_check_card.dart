import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../licensing/write_gate.dart';
import 'coffee_season_check_repository.dart';

class CoffeeSeasonCheckCard extends StatefulWidget {
  const CoffeeSeasonCheckCard({
    super.key,
    required this.propertyId,
    required this.plotId,
    required this.seasonYear,
    required this.registeredLiters,
    required this.canEdit,
  });

  final String propertyId, plotId;
  final int seasonYear;
  final double? registeredLiters;
  final bool canEdit;

  @override
  State<CoffeeSeasonCheckCard> createState() => _CoffeeSeasonCheckCardState();
}

class _CoffeeSeasonCheckCardState extends State<CoffeeSeasonCheckCard> {
  final _repository = CoffeeSeasonCheckRepository();
  late Future<CoffeeSeasonCheck?> _data = _load();
  bool _busy = false;
  final _format = NumberFormat('#,##0.###', 'pt_BR');

  Future<CoffeeSeasonCheck?> _load() => _repository.get(
        propertyId: widget.propertyId,
        plotId: widget.plotId,
        seasonYear: widget.seasonYear,
      );

  @override
  void didUpdateWidget(covariant CoffeeSeasonCheckCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.seasonYear != widget.seasonYear ||
        oldWidget.plotId != widget.plotId ||
        oldWidget.propertyId != widget.propertyId) {
      _data = _load();
    }
  }

  Future<void> _edit(CoffeeSeasonCheck? current) async {
    final scope = (widget.propertyId, widget.plotId, widget.seasonYear);
    final value = await showDialog<double>(
      context: context,
      builder: (_) => _SeasonCheckDialog(initial: current?.liters),
    );
    if (!mounted || value == null) return;
    setState(() => _busy = true);
    try {
      final saved = await runLicensedWrite(
        context,
        () => _repository.save(CoffeeSeasonCheck(
          id: current?.id ?? const Uuid().v4(),
          propertyId: scope.$1,
          plotId: scope.$2,
          seasonYear: scope.$3,
          liters: value,
        )),
      );
      if (mounted && saved) {
        setState(() {
          _data = _load();
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<CoffeeSeasonCheck?>(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const LinearProgressIndicator();
          }
          if (snapshot.hasError) {
            return const Text(
                'Não foi possível carregar o subtotal do caderno.');
          }
          final recorded = widget.registeredLiters;
          final check = snapshot.data;
          final difference = check == null || recorded == null
              ? null
              : check.liters - recorded;
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Conferência com o caderno',
                      style: Theme.of(context).textTheme.titleMedium),
                  if (check != null)
                    Text('Anotado: ${_format.format(check.liters)} L'),
                  if (recorded != null)
                    Text('Lançado no app: ${_format.format(recorded)} L'),
                  if (recorded == null && check != null)
                    const Text('Nenhuma produção registrada nesta safra.'),
                  if (difference != null)
                    Text(difference.abs() < 0.0005
                        ? 'Os totais conferem.'
                        : 'Diferença: ${_format.format(difference.abs())} L '
                            '${difference > 0 ? 'a mais no caderno' : 'a mais no app'}'),
                  if (widget.canEdit)
                    TextButton(
                      onPressed: _busy ? null : () => _edit(check),
                      child: Text(check == null
                          ? 'Informar subtotal do caderno'
                          : 'Editar subtotal do caderno'),
                    ),
                ],
              ),
            ),
          );
        },
      );
}

class _SeasonCheckDialog extends StatefulWidget {
  const _SeasonCheckDialog({this.initial});

  final double? initial;

  @override
  State<_SeasonCheckDialog> createState() => _SeasonCheckDialogState();
}

class _SeasonCheckDialogState extends State<_SeasonCheckDialog> {
  final _form = GlobalKey<FormState>();
  late final _liters = TextEditingController(
      text: widget.initial?.toString().replaceAll('.', ','));

  double? _parse(String? value) =>
      double.tryParse((value ?? '').trim().replaceAll(',', '.'));

  @override
  void dispose() {
    _liters.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Subtotal anotado na safra'),
        content: Form(
          key: _form,
          child: TextFormField(
            controller: _liters,
            decoration: const InputDecoration(labelText: 'Subtotal em litros'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            validator: (text) {
              final value = _parse(text);
              return value == null ||
                      !value.isFinite ||
                      value < 0 ||
                      value > 1e12
                  ? 'Informe um volume válido.'
                  : null;
            },
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar')),
          FilledButton(
            onPressed: () {
              if (_form.currentState!.validate()) {
                Navigator.pop(context, _parse(_liters.text));
              }
            },
            child: const Text('Salvar subtotal'),
          ),
        ],
      );
}
