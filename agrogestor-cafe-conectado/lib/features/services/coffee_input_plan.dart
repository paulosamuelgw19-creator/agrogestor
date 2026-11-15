enum CoffeeInputKind { direct, fertilizer, bags, spray }

/// A saved plan preserves the quantities and units selected before work starts.
class CoffeeInputPlan {
  const CoffeeInputPlan({
    required this.productId,
    required this.productName,
    required this.stockUnit,
    required this.kind,
    required this.quantity,
    required this.inputUnit,
    this.treatedPlants,
    this.estimatedPlants = false,
    this.bagWeightKg,
    this.capacityLiters,
    this.appliedLiters,
    this.coveredHectares,
    this.loadCount,
    this.litersPerLoad,
    this.doseQuantity,
    this.doseReference = '',
  });

  final String productId, productName, stockUnit, inputUnit;
  final CoffeeInputKind kind;
  final double quantity;
  final int? treatedPlants;
  final bool estimatedPlants;
  final double? bagWeightKg, capacityLiters, appliedLiters, coveredHectares;
  final int? loadCount;
  final double? litersPerLoad;
  final double? doseQuantity;
  final String doseReference;

  double? get quantityInStockUnit =>
      validationError == null ? _stockQuantity : null;

  double? get productPerHectare =>
      kind == CoffeeInputKind.spray && validationError == null
          ? _ratio(quantity, coveredHectares)
          : null;

  double? get sprayLitersPerHectare =>
      kind == CoffeeInputKind.spray && validationError == null
          ? _ratio(appliedLiters, coveredHectares)
          : null;

  String? get validationError {
    if (productId.trim().isEmpty ||
        productName.trim().isEmpty ||
        stockUnit.trim().isEmpty ||
        inputUnit.trim().isEmpty) {
      return 'Selecione um produto e confira suas unidades.';
    }
    if (!_positive(quantity)) return 'Informe uma quantidade maior que zero.';
    final dose = doseQuantity;
    final reference = doseReference.trim();
    if ((dose == null) != reference.isEmpty ||
        (dose != null && (!_positive(dose) || reference.length > 120))) {
      return 'Informe a dose e a referência da aplicação juntas.';
    }
    switch (kind) {
      case CoffeeInputKind.direct:
        if (_factor(inputUnit, stockUnit) == null) return _unitError;
      case CoffeeInputKind.fertilizer:
        if (!const {'g', 'g/pé', 'g/pe', 'g por pé', 'g por pe'}
                .contains(inputUnit.trim().toLowerCase()) ||
            _factor('g', stockUnit) == null) {
          return 'Para usar gramas por pé, o produto precisa estar em g ou kg.';
        }
        if (treatedPlants != null && treatedPlants! <= 0) {
          return 'Informe uma quantidade de pés maior que zero.';
        }
        if (estimatedPlants && treatedPlants == null) {
          return 'Informe a quantidade estimada de pés tratados.';
        }
      case CoffeeInputKind.bags:
        if (_unit(inputUnit) != 'bag' ||
            (_unit(stockUnit) != 'bag' && _factor('kg', stockUnit) == null)) {
          return 'Para usar sacos, o produto precisa estar em sacos, kg ou g.';
        }
        if (bagWeightKg != null && !_positive(bagWeightKg!)) {
          return 'Informe um peso por saco maior que zero.';
        }
      case CoffeeInputKind.spray:
        if (_factor(inputUnit, stockUnit) == null) return _unitError;
        for (final value in [capacityLiters, appliedLiters, coveredHectares]) {
          if (value != null && !_positive(value)) {
            return 'Informe capacidade, calda e área maiores que zero.';
          }
        }
        final loads = loadCount;
        final volume = litersPerLoad;
        if (loads != null || volume != null) {
          if (loads == null ||
              loads < 1 ||
              loads > 99999 ||
              volume == null ||
              !_positive(volume) ||
              appliedLiters != loads * volume) {
            return 'Confira o número de cargas e os litros por carga.';
          }
        }
        final singleLoadLiters = volume ?? appliedLiters;
        if (capacityLiters != null &&
            singleLoadLiters != null &&
            singleLoadLiters > capacityLiters!) {
          return 'A calda aplicada supera a capacidade desta carga.';
        }
        if (coveredHectares != null &&
            (_ratio(quantity, coveredHectares) == null ||
                (appliedLiters != null &&
                    _ratio(appliedLiters, coveredHectares) == null))) {
          return 'Os valores por hectare estão fora do limite de cálculo.';
        }
    }
    final total = _stockQuantity;
    return total != null && !_positive(total)
        ? 'A quantidade calculada está fora do limite permitido.'
        : null;
  }

  double? get _stockQuantity {
    switch (kind) {
      case CoffeeInputKind.direct:
      case CoffeeInputKind.spray:
        final factor = _factor(inputUnit, stockUnit);
        return factor == null ? null : quantity * factor;
      case CoffeeInputKind.fertilizer:
        final factor = _factor('g', stockUnit);
        return treatedPlants == null || factor == null
            ? null
            : quantity * (treatedPlants! * factor);
      case CoffeeInputKind.bags:
        if (_unit(stockUnit) == 'bag') return quantity;
        final factor = _factor('kg', stockUnit);
        return bagWeightKg == null || factor == null
            ? null
            : quantity * bagWeightKg! * factor;
    }
  }

  static const _unitError = 'A unidade informada é incompatível com o estoque.';

  static bool _positive(double value) => value.isFinite && value > 0;

  static double? _ratio(double? quantity, double? area) {
    if (quantity == null || area == null || !_positive(area)) return null;
    final ratio = quantity / area;
    return _positive(ratio) ? ratio : null;
  }

  static String _unit(String value) => switch (value.trim().toLowerCase()) {
        'grama' || 'gramas' => 'g',
        'quilo' || 'quilos' || 'quilograma' || 'quilogramas' => 'kg',
        'litro' || 'litros' => 'l',
        'mililitro' || 'mililitros' => 'ml',
        'saco' || 'sacos' || 'saca' || 'sacas' || 'sc' => 'bag',
        final unit => unit,
      };

  static double? _factor(String from, String to) =>
      switch ((_unit(from), _unit(to))) {
        ('g', 'kg') || ('ml', 'l') => 0.001,
        ('kg', 'g') || ('l', 'ml') => 1000,
        (final source, final target) when source == target => 1,
        _ => null,
      };

  Map<String, Object?> toJson() => {
        'productId': productId,
        'productName': productName,
        'stockUnit': stockUnit,
        'kind': kind.name,
        'quantity': quantity,
        'inputUnit': inputUnit,
        if (treatedPlants != null) 'treatedPlants': treatedPlants,
        if (estimatedPlants) 'estimatedPlants': true,
        if (bagWeightKg != null) 'bagWeightKg': bagWeightKg,
        if (capacityLiters != null) 'capacityLiters': capacityLiters,
        if (appliedLiters != null) 'appliedLiters': appliedLiters,
        if (coveredHectares != null) 'coveredHectares': coveredHectares,
        if (loadCount != null) 'loadCount': loadCount,
        if (litersPerLoad != null) 'litersPerLoad': litersPerLoad,
        if (doseQuantity != null) 'doseQuantity': doseQuantity,
        if (doseReference.isNotEmpty) 'doseReference': doseReference,
      };

  factory CoffeeInputPlan.fromJson(Map<String, dynamic> json) {
    final kind = CoffeeInputKind.values
        .where((kind) => kind.name == json['kind'])
        .firstOrNull;
    if (kind == null) {
      throw const FormatException(
          'O tipo de planejamento de insumo é inválido.');
    }
    return CoffeeInputPlan(
      productId: json['productId'] as String,
      productName: json['productName'] as String,
      stockUnit: json['stockUnit'] as String,
      kind: kind,
      quantity: (json['quantity'] as num).toDouble(),
      inputUnit: json['inputUnit'] as String,
      treatedPlants: json['treatedPlants'] as int?,
      estimatedPlants: json['estimatedPlants'] as bool? ?? false,
      bagWeightKg: (json['bagWeightKg'] as num?)?.toDouble(),
      capacityLiters: (json['capacityLiters'] as num?)?.toDouble(),
      appliedLiters: (json['appliedLiters'] as num?)?.toDouble(),
      coveredHectares: (json['coveredHectares'] as num?)?.toDouble(),
      loadCount: json['loadCount'] as int?,
      litersPerLoad: (json['litersPerLoad'] as num?)?.toDouble(),
      doseQuantity: (json['doseQuantity'] as num?)?.toDouble(),
      doseReference: json['doseReference'] as String? ?? '',
    );
  }
}
