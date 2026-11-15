import 'package:flutter/material.dart';
import '../operations_v2/operations_screen.dart';
import '../operations_v2/v2_store.dart';
import 'product_catalog_mode.dart';
import 'products_screen.dart';

/// One entry point: the server chooses the authoritative catalog.
class ProductsArea extends StatefulWidget {
  const ProductsArea({super.key, this.usageOnly = false});
  final bool usageOnly;
  @override
  State<ProductsArea> createState() => _ProductsAreaState();
}

class _ProductsAreaState extends State<ProductsArea> {
  late Future<bool> _mode = usesUnifiedProductCatalog(refresh: true);
  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
        future: _mode,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
                child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text(v2Error(snapshot.error!)),
                      TextButton(
                          onPressed: () => setState(() =>
                              _mode = usesUnifiedProductCatalog(refresh: true)),
                          child: const Text('Tentar novamente')),
                    ])));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return snapshot.data!
              ? const OperationsScreen(section: OperationsSection.products)
              : ProductsScreen(usageOnly: widget.usageOnly);
        },
      );
}
