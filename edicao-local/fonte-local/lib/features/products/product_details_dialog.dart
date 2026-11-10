import 'package:flutter/material.dart';
import 'product_classification_fields.dart';

class ProductDetailsDialog extends StatefulWidget {
  const ProductDetailsDialog({super.key, this.product});
  final Map<String, dynamic>? product;
  @override
  State<ProductDetailsDialog> createState() => _ProductDetailsState();
}

class _ProductDetailsState extends State<ProductDetailsDialog> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.product?['name']);
  late String _unit = widget.product?['unit'] as String? ?? 'kg';
  late String _category = widget.product?['category'] as String? ?? '';
  late String _type = widget.product?['product_type'] as String? ?? '';
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.product == null
            ? 'Novo produto / insumo'
            : 'Editar produto / insumo'),
        content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
                child: Form(
                    key: _form,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextFormField(
                          controller: _name,
                          maxLength: 160,
                          decoration: const InputDecoration(
                              labelText: 'Nome do produto'),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                                  ? 'Informe o nome'
                                  : null),
                      ProductClassificationFields(
                          requireType: widget.product == null,
                          category: _category,
                          type: _type,
                          onChanged: (category, type) {
                            _category = category;
                            _type = type;
                          }),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                          initialValue: _unit,
                          isExpanded: true,
                          decoration: const InputDecoration(
                              labelText: 'Unidade de estoque'),
                          items: const [
                            DropdownMenuItem(
                                value: 'kg', child: Text('Quilos (kg)')),
                            DropdownMenuItem(
                                value: 'L', child: Text('Litros (L)')),
                            DropdownMenuItem(
                                value: 'un', child: Text('Unidades (un)'))
                          ],
                          onChanged: widget.product == null
                              ? (value) => _unit = value!
                              : null),
                      const SizedBox(height: 12),
                      const Text(
                          'Registre quantidades e valores nas entradas de estoque da propriedade.'),
                    ])))),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () {
                if (!_form.currentState!.validate()) return;
                FocusScope.of(context).unfocus();
                Navigator.pop(context, <String, dynamic>{
                  'name': _name.text.trim(),
                  'unit': _unit,
                  'category': _category,
                  'product_type': _type
                });
              },
              child: const Text('Salvar'))
        ],
      );
}
