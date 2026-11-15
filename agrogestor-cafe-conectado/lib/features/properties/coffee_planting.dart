import 'package:flutter/material.dart';

const coffeePlantCount = 'coffee_plant_count';
const coffeePlantDensity = 'coffee_plants_per_hectare';

double? plotAreaHectares(Object? raw) {
  final value = double.tryParse('$raw'.replaceAll(',', '.'));
  return value != null && value.isFinite && value > 0 ? value : null;
}

String? coffeePlantingError(Map<String, dynamic> plot) {
  final count = plot[coffeePlantCount];
  final density = plot[coffeePlantDensity];
  if (count != null && density != null) {
    return 'Informe o total ou os pés por hectare.';
  }
  for (final value in [count, density]) {
    if (value != null && (value is! int || value <= 0 || value > 1000000000)) {
      return 'Informe uma quantidade inteira válida de pés de café.';
    }
  }
  return null;
}

int? plotCoffeePlants(Map<String, dynamic> plot) {
  final count = plot[coffeePlantCount] as int?;
  if (count != null) return count;
  final area = plotAreaHectares(plot['area_ha']);
  final density = plot[coffeePlantDensity] as int?;
  if (area == null || density == null) return null;
  final estimated = area * density;
  return estimated.isFinite && estimated >= 0.5 && estimated <= 1000000000
      ? estimated.round()
      : null;
}

String? coffeePlantingLabel(Map<String, dynamic> plot) {
  final plants = plotCoffeePlants(plot);
  final area = plotAreaHectares(plot['area_ha']);
  final density = plot[coffeePlantDensity] as int?;
  final perHa =
      density ?? (plants != null && area != null ? plants / area : null);
  if (plants == null && perHa == null) return null;
  return [
    if (plants != null)
      '$plants pés de café${density == null ? '' : ' (estimativa)'}',
    if (perHa != null && perHa.isFinite)
      '${perHa == perHa.roundToDouble() ? perHa.toStringAsFixed(0) : perHa.toStringAsFixed(2)} pés/ha',
    if (plants == null && density != null)
      'Informe a área para estimar o total',
  ].join(' · ');
}

class CoffeePlantingFields extends StatefulWidget {
  const CoffeePlantingFields({
    super.key,
    required this.area,
    required this.values,
    required this.onChanged,
  });
  final Object? area;
  final Map<String, dynamic> values;
  final ValueChanged<Map<String, int?>> onChanged;

  @override
  State<CoffeePlantingFields> createState() => _CoffeePlantingFieldsState();
}

class _CoffeePlantingFieldsState extends State<CoffeePlantingFields> {
  late String _field = widget.values[coffeePlantDensity] != null
      ? coffeePlantDensity
      : coffeePlantCount;
  late final _value = TextEditingController(
    text: '${widget.values[_field] ?? ''}',
  );

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  Map<String, int?> get _values => {
        coffeePlantCount: _field == coffeePlantCount
            ? int.tryParse(_value.text.trim())
            : null,
        coffeePlantDensity: _field == coffeePlantDensity
            ? int.tryParse(_value.text.trim())
            : null,
      };

  @override
  Widget build(BuildContext context) {
    final values = _values;
    final summary = coffeePlantingError(values) == null
        ? coffeePlantingLabel({...values, 'area_ha': widget.area})
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _field,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Como informar os pés de café',
          ),
          items: const [
            DropdownMenuItem(
              value: coffeePlantCount,
              child: Text('Total de pés'),
            ),
            DropdownMenuItem(
              value: coffeePlantDensity,
              child: Text('Pés por hectare'),
            ),
          ],
          onChanged: (value) {
            if (value == null || value == _field) return;
            setState(() {
              _field = value;
              _value.clear();
            });
            widget.onChanged(_values);
          },
        ),
        TextFormField(
          controller: _value,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: _field == coffeePlantCount
                ? 'Total de pés de café (opcional)'
                : 'Pés de café por hectare (opcional)',
          ),
          validator: (raw) {
            if ((raw ?? '').trim().isEmpty) return null;
            return int.tryParse(raw!.trim()) == null
                ? 'Informe um número inteiro.'
                : coffeePlantingError(_values);
          },
          onChanged: (_) {
            setState(() {});
            widget.onChanged(_values);
          },
        ),
        if (summary != null)
          Padding(padding: const EdgeInsets.only(top: 6), child: Text(summary)),
      ],
    );
  }
}
