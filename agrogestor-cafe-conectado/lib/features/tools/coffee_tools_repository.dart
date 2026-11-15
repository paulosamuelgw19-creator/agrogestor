import '../auth/farm_access_policy.dart';
import '../coffee_finance/coffee_finance_repository.dart';
import '../sync/local_sync_collection_store.dart';
import '../sync/local_write_batch.dart';

class CoffeeTool {
  const CoffeeTool({
    required this.id,
    required this.name,
    this.categoryId,
    this.paidCents,
    this.notes = '',
    this.expenseId,
    this.photoPath,
  });

  final String id, name, notes;
  final String? categoryId, expenseId, photoPath;
  final int? paidCents;
  bool get isCategory => categoryId == null;

  static const defaults = [
    CoffeeTool(id: 'tools-manual', name: 'Ferramentas manuais'),
    CoffeeTool(id: 'tools-motor', name: 'Ferramentas motorizadas'),
    CoffeeTool(id: 'tools-material', name: 'Acessórios e materiais'),
  ];

  factory CoffeeTool.fromJson(Map<String, dynamic> json) => CoffeeTool(
        id: json['id'] as String,
        name: json['name'] as String,
        categoryId: json['categoryId'] as String?,
        paidCents: json['paidCents'] as int?,
        notes: json['notes'] as String? ?? '',
        expenseId: json['expenseId'] as String?,
        photoPath: json['photoPath'] as String?,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name.trim(),
        'notes': notes.trim(),
        if (categoryId != null) 'categoryId': categoryId,
        if (paidCents != null) 'paidCents': paidCents,
        if (expenseId != null) 'expenseId': expenseId,
        if (photoPath != null) 'photoPath': photoPath,
      };

  void validate() {
    if (id.trim().isEmpty ||
        name.trim().isEmpty ||
        name.length > 160 ||
        notes.length > 4000 ||
        categoryId == id ||
        (categoryId != null && categoryId!.trim().isEmpty) ||
        (expenseId != null && expenseId!.trim().isEmpty) ||
        (isCategory && (paidCents != null || expenseId != null)) ||
        (paidCents != null && (paidCents! < 0 || paidCents! > 1e12))) {
      throw const FormatException(
          'Confira a categoria, o nome e o valor pago.');
    }
  }
}

class CoffeeToolsRepository {
  static const module = 'coffeeTools';
  static const legacyKey = 'campo_gestor_coffee_tools_v1';
  static const _store = LocalSyncCollectionStore<CoffeeTool>(
    module: module,
    legacyKey: legacyKey,
  );

  Future<List<CoffeeTool>> getAll() async {
    FarmAccessPolicy.requireCoffeeManager();
    return [
      ...CoffeeTool.defaults,
      ...await _store.getAll(fromJson: CoffeeTool.fromJson),
    ];
  }

  Future<void> save(CoffeeTool item) async {
    FarmAccessPolicy.requireCoffeeManager();
    item.validate();
    await LocalWriteBatch.run(() async {
      final previous = await _store.getAll(fromJson: CoffeeTool.fromJson);
      if (CoffeeTool.defaults.any((category) => category.id == item.id) ||
          previous.any((old) =>
              old.id == item.id && old.isCategory != item.isCategory)) {
        throw const FormatException(
            'O tipo deste cadastro não pode ser alterado.');
      }
      if (!item.isCategory &&
          ![
            ...CoffeeTool.defaults,
            ...previous
          ].any((entry) => entry.isCategory && entry.id == item.categoryId)) {
        throw const FormatException('Escolha uma categoria disponível.');
      }
      if (item.expenseId case final String expenseId) {
        if (previous
            .any((old) => old.id != item.id && old.expenseId == expenseId)) {
          throw const FormatException(
              'Esta despesa já está vinculada a uma ferramenta.');
        }
        final available =
            await CoffeeFinanceRepository().toolExpenseCandidates();
        if (!available.any((expense) => expense.id == expenseId)) {
          throw const FormatException(
              'A despesa vinculada não está mais disponível.');
        }
      }
      await _store.saveAll(
        records: [...previous.where((old) => old.id != item.id), item],
        previousRecords: previous,
        idOf: (entry) => entry.id,
        toJson: (entry) => entry.toJson(),
        fromJson: CoffeeTool.fromJson,
      );
    });
  }
}
