import '../sync/local_sync_collection_store.dart';
import 'product_record.dart';
import 'product_catalog_mode.dart';

class ProductRepository {
  static const _products = LocalSyncCollectionStore<FarmProduct>(
    module: 'products',
    legacyKey: 'campo_gestor_products_v1',
  );
  static const _usage = LocalSyncCollectionStore<ProductUsage>(
    module: 'productUsage',
    legacyKey: 'campo_gestor_product_usage_v1',
  );

  Future<List<FarmProduct>> getProducts() async {
    if (await usesUnifiedProductCatalog()) return const [];
    return _products.getAll(fromJson: FarmProduct.fromJson);
  }

  Future<List<ProductUsage>> getUsage() =>
      _usage.getAll(fromJson: ProductUsage.fromJson);

  Future<void> saveProducts(List<FarmProduct> products,
      {required List<FarmProduct> previous}) async {
    if (await usesUnifiedProductCatalog()) {
      throw StateError(
          'Use Produtos e insumos e registre o consumo nas Operações.');
    }
    await _products.saveAll(
      records: products,
      previousRecords: previous,
      fromJson: FarmProduct.fromJson,
      idOf: (product) => product.id,
      toJson: (product) => product.toJson(),
    );
  }

  Future<void> saveUsage(List<ProductUsage> usage,
      {required List<ProductUsage> previous}) async {
    if (await usesUnifiedProductCatalog()) {
      throw StateError(
          'Registre o consumo no estoque por propriedade em Operações.');
    }
    await _usage.saveAll(
      records: usage,
      previousRecords: previous,
      fromJson: ProductUsage.fromJson,
      idOf: (entry) => entry.id,
      toJson: (entry) => entry.toJson(),
    );
  }
}
