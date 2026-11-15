import 'package:flutter/material.dart';
import 'product_categories.dart';

class ProductClassificationFields extends StatefulWidget {
  const ProductClassificationFields(
      {super.key,
      this.category = '',
      this.type = '',
      required this.onChanged,
      this.requireType = false});
  final String category, type;
  final bool requireType;
  final void Function(String category, String type) onChanged;

  @override
  State<ProductClassificationFields> createState() => _ClassificationState();
}

class _ClassificationState extends State<ProductClassificationFields> {
  late String _category = widget.category;
  late String _type = widget.type;

  @override
  Widget build(BuildContext context) {
    // Existing free-text categories/types remain available without rewriting them.
    final categories = {
      ...productCategories.keys,
      if (_category.isNotEmpty) _category
    };
    final types = {
      ...?productCategories[_category],
      if (_type.isNotEmpty) _type
    };
    return Column(mainAxisSize: MainAxisSize.min, children: [
      DropdownButtonFormField<String>(
        initialValue: _category.isEmpty ? null : _category,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Categoria'),
        items: categories
            .map((value) => DropdownMenuItem(
                value: value,
                child: Text(value, overflow: TextOverflow.ellipsis)))
            .toList(),
        validator: (value) => value == null ? 'Selecione a categoria' : null,
        onChanged: (value) {
          setState(() {
            _category = value!;
            _type = '';
          });
          widget.onChanged(_category, _type);
        },
      ),
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(
        key: ValueKey('product-type-$_category'),
        initialValue: _type.isEmpty ? null : _type,
        isExpanded: true,
        decoration: InputDecoration(
            labelText: 'Tipo de produto',
            helperText:
                widget.requireType ? null : 'Opcional para cadastros antigos.'),
        items: types
            .map((value) => DropdownMenuItem(
                value: value,
                child: Text(value, overflow: TextOverflow.ellipsis)))
            .toList(),
        validator: (value) => widget.requireType && value == null
            ? 'Selecione o tipo de produto'
            : null,
        onChanged: _category.isEmpty
            ? null
            : (value) {
                setState(() => _type = value ?? '');
                widget.onChanged(_category, _type);
              },
      ),
    ]);
  }
}
