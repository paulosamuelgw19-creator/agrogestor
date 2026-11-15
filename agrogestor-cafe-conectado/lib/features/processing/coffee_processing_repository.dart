import 'dart:convert';
import 'dart:math' as math;

import '../auth/farm_access_policy.dart';
import '../harvest/coffee_harvest_repository.dart';
import '../harvest/coffee_receipt_repository.dart';
import '../properties/catalog_store.dart';
import '../properties/plot_notebook_repository.dart';
import '../sync/local_sync_collection_store.dart';
import '../sync/local_write_batch.dart';
import '../sync/farm_api_client.dart';

enum CoffeeLotSourceKind { picked, raked }

enum CoffeeLotOrigin { confirmed, partial, unknown }

enum CoffeeProcessingStage { reception, washed, dried, cleaned, other }

enum CoffeeCleaningInputBase { ripe, dry, washed }

enum CoffeeProcessedUnit { bags, kilograms }

class CoffeeLotInput {
  const CoffeeLotInput({
    required this.id,
    required this.kind,
    required this.origin,
    this.volumeLiters,
    this.plotId,
    this.harvestDate,
    this.linkedLiters,
    this.receiptId,
    this.notes = '',
  });

  final String id;
  final CoffeeLotSourceKind kind;
  final CoffeeLotOrigin origin;
  final double? volumeLiters, linkedLiters;
  final String? plotId, receiptId;
  final DateTime? harvestDate;
  final String notes;

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.name,
        'origin': origin.name,
        if (receiptId != null) 'receiptId': receiptId,
        if (volumeLiters != null) 'volumeLiters': volumeLiters,
        if (plotId != null) 'plotId': plotId,
        if (harvestDate != null)
          'harvestDate': coffeeCivilDate(harvestDate!).toIso8601String(),
        if (linkedLiters != null) 'linkedLiters': linkedLiters,
        'notes': notes.trim(),
      };

  factory CoffeeLotInput.fromJson(Map<String, dynamic> json) => CoffeeLotInput(
        id: json['id'] as String,
        kind: CoffeeLotSourceKind.values.byName(json['kind'] as String),
        origin: CoffeeLotOrigin.values.byName(json['origin'] as String),
        receiptId: json['receiptId'] as String?,
        volumeLiters: (json['volumeLiters'] as num?)?.toDouble(),
        plotId: json['plotId'] as String?,
        harvestDate: _optionalDate(json['harvestDate']),
        linkedLiters: (json['linkedLiters'] as num?)?.toDouble(),
        notes: json['notes'] as String,
      );

  void validate() {
    final plot = plotId;
    final volume = volumeLiters;
    final linked = linkedLiters;
    if (!_validId(id) ||
        (plot != null && !_validId(plot)) ||
        (volume != null && !_positive(volume)) ||
        (linked != null && !_positive(linked)) ||
        notes.length > 4000 ||
        (harvestDate != null && plot == null) ||
        ((harvestDate != null) != (linked != null)) ||
        (volume != null && linked != null && _exceeds(linked, volume))) {
      throw const FormatException(
          'Confira o talhão, a data e os litros da origem.');
    }
    switch (origin) {
      case CoffeeLotOrigin.confirmed:
        if (volume == null || linked == null || _exceeds(volume, linked)) {
          throw const FormatException(
            'Para confirmar a origem, vincule todo o volume à colheita de um talhão.',
          );
        }
      case CoffeeLotOrigin.unknown:
        if (plot != null || harvestDate != null || linked != null) {
          throw const FormatException(
              'Use origem parcial para registrar um vínculo conhecido.');
        }
      case CoffeeLotOrigin.partial:
        if (plot == null && notes.trim().isEmpty) {
          throw const FormatException(
              'Indique o talhão ou descreva a origem parcial.');
        }
    }
  }
}

class CoffeeLotMeasurement {
  const CoffeeLotMeasurement({
    required this.id,
    required this.date,
    required this.stage,
    this.volumeLiters,
    this.location = '',
    this.state = '',
    this.notes = '',
  });

  final String id, location, state, notes;
  final DateTime date;
  final CoffeeProcessingStage stage;
  final double? volumeLiters;

  Map<String, Object?> toJson() => {
        'id': id,
        'date': coffeeCivilDate(date).toIso8601String(),
        'stage': stage.name,
        if (volumeLiters != null) 'volumeLiters': volumeLiters,
        'location': location.trim(),
        'state': state.trim(),
        'notes': notes.trim(),
      };

  factory CoffeeLotMeasurement.fromJson(Map<String, dynamic> json) =>
      CoffeeLotMeasurement(
        id: json['id'] as String,
        date: DateTime.parse(json['date'] as String),
        stage: CoffeeProcessingStage.values.byName(json['stage'] as String),
        volumeLiters: (json['volumeLiters'] as num?)?.toDouble(),
        location: json['location'] as String,
        state: json['state'] as String,
        notes: json['notes'] as String,
      );

  void validate() {
    final measured = volumeLiters;
    if (!_validId(id) ||
        (measured != null &&
            (!measured.isFinite || measured < 0 || measured > 1e12)) ||
        location.length > 300 ||
        state.length > 300 ||
        notes.length > 4000) {
      throw const FormatException('Confira os dados da medição.');
    }
  }
}

class CoffeeLotCleaning {
  const CoffeeLotCleaning({
    required this.id,
    required this.date,
    required this.unit,
    required this.quantity,
    this.kgPerBag,
    this.remainderKg,
    this.inputLiters,
    this.inputBase,
    this.notes = '',
  });

  final String id, notes;
  final DateTime date;
  final CoffeeProcessedUnit unit;
  final double quantity;
  final double? kgPerBag, remainderKg, inputLiters;
  final CoffeeCleaningInputBase? inputBase;

  double get outputKg => _weight(unit, quantity, kgPerBag, remainderKg);
  double? get litersPerSack60 {
    final rate = yieldKgPerLiter;
    return rate == null || rate <= 0 ? null : 60 / rate;
  }

  double? get yieldKgPerLiter {
    final liters = inputLiters;
    if (liters == null || inputBase == null || !_positive(liters)) return null;
    final result = outputKg / liters;
    return result.isFinite ? result : null;
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'date': coffeeCivilDate(date).toIso8601String(),
        'unit': unit.name,
        'quantity': quantity,
        if (kgPerBag != null) 'kgPerBag': kgPerBag,
        if (remainderKg != null) 'remainderKg': remainderKg,
        if (inputLiters != null) 'inputLiters': inputLiters,
        if (inputBase != null) 'inputBase': inputBase!.name,
        'notes': notes.trim(),
      };

  factory CoffeeLotCleaning.fromJson(Map<String, dynamic> json) =>
      CoffeeLotCleaning(
        id: json['id'] as String,
        date: DateTime.parse(json['date'] as String),
        unit: CoffeeProcessedUnit.values.byName(json['unit'] as String),
        quantity: (json['quantity'] as num).toDouble(),
        kgPerBag: (json['kgPerBag'] as num?)?.toDouble(),
        remainderKg: (json['remainderKg'] as num?)?.toDouble(),
        inputLiters: (json['inputLiters'] as num?)?.toDouble(),
        inputBase: json['inputBase'] == null
            ? null
            : CoffeeCleaningInputBase.values
                .byName(json['inputBase'] as String),
        notes: json['notes'] as String,
      );

  void validate() {
    _validateWeight(unit, quantity, kgPerBag, remainderKg);
    final liters = inputLiters;
    if (!_validId(id) ||
        (liters != null &&
            (!_positive(liters) ||
                (inputBase != null && yieldKgPerLiter == null))) ||
        notes.length > 4000) {
      throw const FormatException(
          'Confira os litros de entrada e as observações da limpa.');
    }
  }
}

class CoffeeLotSale {
  const CoffeeLotSale({
    required this.id,
    required this.date,
    required this.unit,
    required this.quantity,
    this.kgPerBag,
    this.remainderKg,
    required this.totalPriceCents,
    this.buyer = '',
    this.notes = '',
  });

  final String id, buyer, notes;
  final DateTime date;
  final CoffeeProcessedUnit unit;
  final double quantity;
  final double? kgPerBag, remainderKg;
  final int totalPriceCents;

  double get outputKg => _weight(unit, quantity, kgPerBag, remainderKg);

  Map<String, Object?> toJson() => {
        'id': id,
        'date': coffeeCivilDate(date).toIso8601String(),
        'unit': unit.name,
        'quantity': quantity,
        if (kgPerBag != null) 'kgPerBag': kgPerBag,
        if (remainderKg != null) 'remainderKg': remainderKg,
        'totalPriceCents': totalPriceCents,
        'buyer': buyer.trim(),
        'notes': notes.trim(),
      };

  factory CoffeeLotSale.fromJson(Map<String, dynamic> json) => CoffeeLotSale(
        id: json['id'] as String,
        date: DateTime.parse(json['date'] as String),
        unit: CoffeeProcessedUnit.values.byName(json['unit'] as String),
        quantity: (json['quantity'] as num).toDouble(),
        kgPerBag: (json['kgPerBag'] as num?)?.toDouble(),
        remainderKg: (json['remainderKg'] as num?)?.toDouble(),
        totalPriceCents: json['totalPriceCents'] as int,
        buyer: json['buyer'] as String,
        notes: json['notes'] as String,
      );

  void validate() {
    _validateWeight(unit, quantity, kgPerBag, remainderKg);
    if (!_validId(id) ||
        totalPriceCents <= 0 ||
        totalPriceCents > 1000000000000 ||
        buyer.length > 300 ||
        notes.length > 4000) {
      throw const FormatException('Confira o preço total e os dados da venda.');
    }
  }
}

class CoffeeLot {
  const CoffeeLot({
    required this.id,
    required this.propertyId,
    required this.seasonYear,
    required this.code,
    required this.date,
    this.location = '',
    this.notes = '',
    required this.inputs,
    this.measurements = const [],
    this.cleanings = const [],
    this.sales = const [],
  });

  final String id, propertyId, code, location, notes;
  final int seasonYear;
  final DateTime date;
  final List<CoffeeLotInput> inputs;
  final List<CoffeeLotMeasurement> measurements;
  final List<CoffeeLotCleaning> cleanings;
  final List<CoffeeLotSale> sales;

  String? get confirmedPlotId {
    if (inputs.isEmpty ||
        inputs.any((input) =>
            input.origin != CoffeeLotOrigin.confirmed ||
            input.plotId == null)) {
      return null;
    }
    final plots = inputs.map((input) => input.plotId).toSet();
    return plots.length == 1 ? plots.single : null;
  }

  bool get hasMixedOrigins =>
      inputs.map((input) => input.plotId).toSet().length > 1;

  double get producedKg =>
      cleanings.fold(0.0, (sum, item) => sum + item.outputKg);
  double get soldKg => sales.fold(0.0, (sum, item) => sum + item.outputKg);
  double get stockKg => _available(producedKg, soldKg);

  Map<String, Object?> toJson() => {
        'id': id,
        'propertyId': propertyId,
        'seasonYear': seasonYear,
        'code': code.trim(),
        'date': coffeeCivilDate(date).toIso8601String(),
        'location': location.trim(),
        'notes': notes.trim(),
        'inputs': [for (final item in inputs) item.toJson()],
        'measurements': [for (final item in measurements) item.toJson()],
        'cleanings': [for (final item in cleanings) item.toJson()],
        'sales': [for (final item in sales) item.toJson()],
      };

  factory CoffeeLot.fromJson(Map<String, dynamic> json) => CoffeeLot(
        id: json['id'] as String,
        propertyId: json['propertyId'] as String,
        seasonYear: json['seasonYear'] as int,
        code: json['code'] as String,
        date: DateTime.parse(json['date'] as String),
        location: json['location'] as String,
        notes: json['notes'] as String,
        inputs:
            List.unmodifiable(_decode(json['inputs'], CoffeeLotInput.fromJson)),
        measurements: List.unmodifiable(
          _decode(json['measurements'], CoffeeLotMeasurement.fromJson),
        ),
        cleanings: List.unmodifiable(
            _decode(json['cleanings'], CoffeeLotCleaning.fromJson)),
        sales:
            List.unmodifiable(_decode(json['sales'], CoffeeLotSale.fromJson)),
      );

  CoffeeLot _withHistory({
    List<CoffeeLotMeasurement>? measurements,
    List<CoffeeLotCleaning>? cleanings,
    List<CoffeeLotSale>? sales,
  }) =>
      CoffeeLot(
        id: id,
        propertyId: propertyId,
        seasonYear: seasonYear,
        code: code,
        date: date,
        location: location,
        notes: notes,
        inputs: inputs,
        measurements: measurements ?? this.measurements,
        cleanings: cleanings ?? this.cleanings,
        sales: sales ?? this.sales,
      );

  void validate() {
    if (!_validId(id) ||
        !_validId(propertyId) ||
        code.trim().isEmpty ||
        code.length > 160 ||
        seasonYear < 1900 ||
        seasonYear > 9999 ||
        location.length > 300 ||
        notes.length > 4000 ||
        inputs.isEmpty) {
      throw const FormatException(
          'Informe a fazenda, a safra, o código e uma entrada para o lote.');
    }
    final inputIds = <String>{};
    for (final input in inputs) {
      input.validate();
      if (!inputIds.add(input.id)) {
        throw const FormatException('Há uma entrada repetida neste lote.');
      }
    }
    final movementIds = <String>{};
    void validateMovement(String id, DateTime movementDate) {
      if (!movementIds.add(id) ||
          coffeeCivilDate(movementDate).isBefore(coffeeCivilDate(date))) {
        throw const FormatException(
            'Há um movimento repetido ou anterior à abertura do lote.');
      }
    }

    for (final measurement in measurements) {
      measurement.validate();
      validateMovement(measurement.id, measurement.date);
    }
    final knownRipeInput = inputs.every((item) => item.receiptId != null)
        ? inputs
            .where((item) => item.kind == CoffeeLotSourceKind.picked)
            .fold(0.0, (sum, item) => sum + (item.volumeLiters ?? 0))
        : inputs.every((item) =>
                item.kind == CoffeeLotSourceKind.picked &&
                item.volumeLiters != null)
            ? inputs.fold(0.0, (sum, item) => sum + item.volumeLiters!)
            : null;
    var cleanedRipeInput = 0.0;
    final producedByDay = <DateTime, double>{};
    for (final cleaning in cleanings) {
      cleaning.validate();
      validateMovement(cleaning.id, cleaning.date);
      final inputLiters = cleaning.inputLiters;
      if (cleaning.inputBase == CoffeeCleaningInputBase.ripe &&
          inputLiters != null) {
        cleanedRipeInput += inputLiters;
      }
      final day = coffeeCivilDate(cleaning.date);
      producedByDay.update(day, (sum) => sum + cleaning.outputKg,
          ifAbsent: () => cleaning.outputKg);
    }
    if (knownRipeInput != null && _exceeds(cleanedRipeInput, knownRipeInput)) {
      throw const FormatException(
          'As limpas excedem os litros de café maduro das entradas do lote.');
    }
    final soldByDay = <DateTime, double>{};
    for (final sale in sales) {
      sale.validate();
      validateMovement(sale.id, sale.date);
      final day = coffeeCivilDate(sale.date);
      soldByDay.update(day, (sum) => sum + sale.outputKg,
          ifAbsent: () => sale.outputKg);
    }
    final days = {...producedByDay.keys, ...soldByDay.keys}.toList()..sort();
    var produced = 0.0;
    var sold = 0.0;
    for (final day in days) {
      produced += producedByDay[day] ?? 0;
      sold += soldByDay[day] ?? 0;
      if (_exceeds(sold, produced)) {
        throw const FormatException(
            'O estoque beneficiado é insuficiente na data da venda.');
      }
    }
  }
}

typedef CoffeeOriginYield = ({
  double liters,
  double outputKg,
  int count,
});

Map<(String?, bool, CoffeeCleaningInputBase), CoffeeOriginYield>
    compareCoffeeYields(Iterable<CoffeeLot> lots) {
  final totals =
      <(String?, bool, CoffeeCleaningInputBase), CoffeeOriginYield>{};
  for (final lot in lots) {
    for (final cleaning in lot.cleanings) {
      if (cleaning.litersPerSack60 == null) continue;
      final key =
          (lot.confirmedPlotId, lot.hasMixedOrigins, cleaning.inputBase!);
      final current = totals[key];
      totals[key] = (
        liters: (current?.liters ?? 0) + cleaning.inputLiters!,
        outputKg: (current?.outputKg ?? 0) + cleaning.outputKg,
        count: (current?.count ?? 0) + 1,
      );
    }
  }
  return totals;
}

class CoffeeLotHarvestSource {
  const CoffeeLotHarvestSource({
    required this.date,
    required this.totalLiters,
    required this.allocatedLiters,
    this.receiptId,
  });

  final DateTime date;
  final String? receiptId;
  final double totalLiters, allocatedLiters;
  double get availableLiters => _available(totalLiters, allocatedLiters);
}

class CoffeeProcessingRepository {
  static const module = FarmAccessPolicy.coffeeLotModule;
  static final _store = LocalSyncCollectionStore<CoffeeLot>(
    module: module,
    legacyKey:
        FarmAccessPolicy.coffeeProcessingModules['coffeeProcessingLots']!,
  );

  Future<List<CoffeeLot>> list({
    required String propertyId,
    int? seasonYear,
  }) async {
    FarmAccessPolicy.requireCoffeeHarvest();
    return [
      for (final lot in await _store.getAll(fromJson: CoffeeLot.fromJson))
        if (lot.propertyId == propertyId &&
            (seasonYear == null || lot.seasonYear == seasonYear))
          lot,
    ]..sort((a, b) => b.date.compareTo(a.date));
  }

  Future<CoffeeLot> getLot({
    required String propertyId,
    required String lotId,
  }) async {
    final lots = await list(propertyId: propertyId);
    return _findLot(lots, propertyId, lotId);
  }

  Future<void> saveLot(CoffeeLot lot, {CoffeeLot? expected}) async {
    FarmAccessPolicy.requireCoffeeHarvest();
    final catalog = await CatalogStore.open();
    await LocalWriteBatch.run(() async {
      FarmAccessPolicy.requireCoffeeHarvest();
      final previous = await _store.getAll(fromJson: CoffeeLot.fromJson);
      final existing = previous.where((item) => item.id == lot.id).firstOrNull;
      if (!FarmApiClient.standaloneLocalMode &&
          (existing == null) != (expected == null)) {
        throw const FormatException('O lote mudou. Atualize antes de editar.');
      }
      if (!FarmApiClient.standaloneLocalMode &&
          existing != null &&
          expected != null &&
          _lotHeader(existing) != _lotHeader(expected)) {
        throw const FormatException('O lote mudou. Atualize antes de editar.');
      }
      if (existing != null &&
          (existing.propertyId != lot.propertyId ||
              existing.seasonYear != lot.seasonYear)) {
        throw const FormatException(
            'Este lote pertence a outra fazenda ou safra.');
      }
      final updated = lot._withHistory(
        measurements: existing?.measurements ?? const [],
        cleanings: existing?.cleanings ?? const [],
        sales: existing?.sales ?? const [],
      );
      updated.validate();
      if (existing != null &&
          existing.cleanings.isNotEmpty &&
          jsonEncode(existing.toJson()['inputs']) !=
              jsonEncode(updated.toJson()['inputs'])) {
        throw const FormatException(
            'As origens ficam preservadas após a primeira limpa.');
      }
      final plotIds = {
        for (final input in updated.inputs)
          if (input.plotId != null) input.plotId!,
      };
      await requireCoffeeCatalogLink(
        catalog.scope,
        propertyId: updated.propertyId,
        active: existing == null,
      );
      for (final plotId in plotIds) {
        await requireCoffeeCatalogLink(
          catalog.scope,
          propertyId: updated.propertyId,
          plotId: plotId,
          active: existing == null ||
              !existing.inputs.any((input) => input.plotId == plotId),
        );
      }
      final group = [
        for (final item in previous)
          if (item.id != updated.id &&
              item.propertyId == updated.propertyId &&
              item.seasonYear == updated.seasonYear)
            item,
        updated,
      ];
      validateCoffeeProcessingLots(group);
      if (!FarmApiClient.standaloneLocalMode) {
        await _validateReceipts(updated, group);
        await _persist(previous, updated);
        return;
      }
      final allocations = coffeeLotAllocations(group);
      final totals = <CoffeeHarvestDayKey, double>{};
      for (final plotId in allocations.keys.map((key) => key.$2).toSet()) {
        final production = await CoffeeHarvestRepository().production(
          propertyId: updated.propertyId,
          plotId: plotId,
          seasonYear: updated.seasonYear,
        );
        for (final day in production.days) {
          totals[(updated.propertyId, plotId, updated.seasonYear, day.date)] =
              day.totalLiters;
        }
      }
      validateCoffeeProcessingAllocations(allocations, totals);
      await _persist(previous, updated);
    });
  }

  Future<List<CoffeeLotHarvestSource>> harvestSources({
    required String propertyId,
    required String plotId,
    required int seasonYear,
    String? excludingLotId,
  }) async {
    FarmAccessPolicy.requireCoffeeHarvest();
    late List<CoffeeLotHarvestSource> result;
    await LocalWriteBatch.run(() async {
      final lots = await list(propertyId: propertyId, seasonYear: seasonYear);
      if (!FarmApiClient.standaloneLocalMode) {
        final receipts = await CoffeeReceiptRepository().list(
            propertyId: propertyId,
            plotId: plotId,
            seasonYear: seasonYear,
            confirmedOnly: true);
        final used = _receiptAllocations(
            lots.where((item) => item.id != excludingLotId));
        result = [
          for (final receipt in receipts)
            if (receipt.receivedLiters > 0)
              CoffeeLotHarvestSource(
                date: receipt.harvestDate,
                totalLiters: receipt.receivedLiters,
                allocatedLiters: used[receipt.id] ?? 0,
                receiptId: receipt.id,
              ),
        ]..sort((a, b) => b.date.compareTo(a.date));
        return;
      }
      final allocations = coffeeLotAllocations(
        lots.where((item) => item.id != excludingLotId),
      );
      final production = await CoffeeHarvestRepository().production(
        propertyId: propertyId,
        plotId: plotId,
        seasonYear: seasonYear,
      );
      result = [
        for (final day in production.days)
          if (day.totalLiters > 0)
            CoffeeLotHarvestSource(
              date: day.date,
              totalLiters: day.totalLiters,
              allocatedLiters:
                  allocations[(propertyId, plotId, seasonYear, day.date)] ?? 0,
            ),
      ];
    }, notifySync: false);
    return result;
  }

  /// Called within the harvest update transaction before replacing a total.
  Future<void> checkHarvestDayCapacity(
    CoffeeHarvestDayKey key,
    double totalLiters,
  ) async {
    final lots = await list(propertyId: key.$1, seasonYear: key.$3);
    final allocated = coffeeLotAllocations(lots)[key] ?? 0;
    if (_exceeds(allocated, totalLiters)) {
      throw const FormatException(
        'Já há litros desse dia vinculados a lotes. Confira as origens antes de reduzir o total.',
      );
    }
  }

  Future<void> addMeasurement({
    required String propertyId,
    required String lotId,
    required CoffeeLotMeasurement measurement,
  }) =>
      _updateLot(propertyId, lotId, (lot) {
        measurement.validate();
        final updated = _append(lot.measurements, measurement, measurement.id,
            (item) => item.id, (item) => item.toJson());
        return identical(updated, lot.measurements)
            ? lot
            : lot._withHistory(measurements: updated);
      });

  Future<void> addCleaning({
    required String propertyId,
    required String lotId,
    required CoffeeLotCleaning cleaning,
  }) =>
      _updateLot(propertyId, lotId, (lot) {
        cleaning.validate();
        final updated = _append(lot.cleanings, cleaning, cleaning.id,
            (item) => item.id, (item) => item.toJson());
        return identical(updated, lot.cleanings)
            ? lot
            : lot._withHistory(cleanings: updated);
      });

  Future<void> addSale({
    required String propertyId,
    required String lotId,
    required CoffeeLotSale sale,
  }) =>
      _updateLot(propertyId, lotId, (lot) {
        sale.validate();
        final updated = _append(lot.sales, sale, sale.id, (item) => item.id,
            (item) => item.toJson());
        return identical(updated, lot.sales)
            ? lot
            : lot._withHistory(sales: updated);
      });

  Future<void> _updateLot(
    String propertyId,
    String lotId,
    CoffeeLot Function(CoffeeLot) update,
  ) async {
    FarmAccessPolicy.requireCoffeeHarvest();
    await LocalWriteBatch.run(() async {
      FarmAccessPolicy.requireCoffeeHarvest();
      final previous = await _store.getAll(fromJson: CoffeeLot.fromJson);
      final lot = _findLot(previous, propertyId, lotId);
      final updated = update(lot);
      if (identical(updated, lot)) return;
      updated.validate();
      validateCoffeeProcessingLots([
        for (final other in previous)
          if (other.id != updated.id) other,
        updated,
      ]);
      await _persist(previous, updated);
    });
  }

  static CoffeeLot _findLot(
      List<CoffeeLot> lots, String propertyId, String lotId) {
    final lot = lots
        .where((item) => item.id == lotId && item.propertyId == propertyId)
        .firstOrNull;
    if (lot == null) {
      throw const FormatException('Lote não encontrado nesta fazenda.');
    }
    return lot;
  }

  String _lotHeader(CoffeeLot lot) => jsonEncode({
        ...lot.toJson()
          ..remove('measurements')
          ..remove('cleanings')
          ..remove('sales'),
      });

  Future<void> _validateReceipts(CoffeeLot lot, List<CoffeeLot> group) async {
    final receipts = {
      for (final receipt in await CoffeeReceiptRepository().list(
          propertyId: lot.propertyId,
          seasonYear: lot.seasonYear,
          confirmedOnly: true))
        receipt.id: receipt,
    };
    final allocated = _receiptAllocations(group);
    for (final input in lot.inputs) {
      final receipt = receipts[input.receiptId];
      if (receipt == null ||
          input.origin != CoffeeLotOrigin.confirmed ||
          input.plotId != receipt.plotId ||
          input.harvestDate != receipt.harvestDate ||
          input.volumeLiters != input.linkedLiters ||
          lot.date.isBefore(receipt.receivedDate) ||
          _exceeds(allocated[receipt.id] ?? 0, receipt.receivedLiters)) {
        throw const FormatException(
            'Confira a data e os litros disponíveis do recebimento confirmado.');
      }
    }
  }

  Map<String, double> _receiptAllocations(Iterable<CoffeeLot> lots) {
    final used = <String, double>{};
    for (final lot in lots) {
      for (final input in lot.inputs) {
        final receipt = input.receiptId;
        final liters = input.volumeLiters;
        if (receipt == null || liters == null) continue;
        used.update(receipt, (value) => value + liters, ifAbsent: () => liters);
      }
    }
    return used;
  }

  Future<void> _persist(List<CoffeeLot> previous, CoffeeLot updated) =>
      _store.saveAll(
        records: [...previous.where((lot) => lot.id != updated.id), updated],
        previousRecords: previous,
        idOf: (lot) => lot.id,
        toJson: (lot) => lot.toJson(),
        fromJson: CoffeeLot.fromJson,
      );
}

List<T> _append<T>(
  List<T> history,
  T record,
  String id,
  String Function(T) idOf,
  Map<String, Object?> Function(T) toJson,
) {
  final existing = history.where((item) => idOf(item) == id).firstOrNull;
  if (existing == null) return [...history, record];
  if (jsonEncode(toJson(existing)) != jsonEncode(toJson(record))) {
    throw const FormatException(
        'Este movimento já foi registrado com outros dados.');
  }
  return history;
}

void validateCoffeeProcessingLots(Iterable<CoffeeLot> lots) {
  final codes = <(String, int, String)>{};
  final movements = <String>{};
  for (final lot in lots) {
    if (!codes
        .add((lot.propertyId, lot.seasonYear, lot.code.trim().toLowerCase()))) {
      throw const FormatException(
          'Já existe um lote com este código na fazenda e safra.');
    }
    for (final id in [
      ...lot.measurements.map((item) => item.id),
      ...lot.cleanings.map((item) => item.id),
      ...lot.sales.map((item) => item.id),
    ]) {
      if (!movements.add(id)) {
        throw const FormatException(
            'Um movimento já está registrado em outro lote.');
      }
    }
  }
}

Map<CoffeeHarvestDayKey, double> coffeeLotAllocations(
    Iterable<CoffeeLot> lots) {
  final allocated = <CoffeeHarvestDayKey, double>{};
  for (final lot in lots) {
    for (final input in lot.inputs) {
      final liters = input.linkedLiters;
      if (liters == null) continue;
      final key = (
        lot.propertyId,
        input.plotId!,
        lot.seasonYear,
        coffeeCivilDate(input.harvestDate!)
      );
      allocated.update(key, (total) => total + liters, ifAbsent: () => liters);
    }
  }
  return allocated;
}

void validateCoffeeProcessingAllocations(
  Map<CoffeeHarvestDayKey, double> allocations,
  Map<CoffeeHarvestDayKey, double> confirmedTotals,
) {
  for (final entry in allocations.entries) {
    final available = confirmedTotals[entry.key];
    if (available == null || _exceeds(entry.value, available)) {
      throw const FormatException(
        'Os litros vinculados excedem a colheita disponível no dia do talhão.',
      );
    }
  }
}

DateTime? _optionalDate(Object? value) =>
    value == null ? null : DateTime.parse(value as String);

Iterable<T> _decode<T>(
  Object? value,
  T Function(Map<String, dynamic>) fromJson,
) =>
    (value as List).map((item) => fromJson(item as Map<String, dynamic>));

bool _validId(String value) => value.trim().isNotEmpty && value.length <= 160;
bool _positive(double value) => value.isFinite && value > 0 && value <= 1e12;

double _weight(
  CoffeeProcessedUnit unit,
  double quantity,
  double? kgPerBag,
  double? remainderKg,
) =>
    unit == CoffeeProcessedUnit.kilograms
        ? quantity
        : quantity * kgPerBag! + (remainderKg ?? 0);

void _validateWeight(
  CoffeeProcessedUnit unit,
  double quantity,
  double? kgPerBag,
  double? remainderKg,
) {
  if (!quantity.isFinite ||
      quantity < 0 ||
      quantity > 1e12 ||
      (unit == CoffeeProcessedUnit.kilograms &&
          (kgPerBag != null || remainderKg != null)) ||
      (unit == CoffeeProcessedUnit.bags &&
          (quantity.truncateToDouble() != quantity ||
              kgPerBag == null ||
              !_positive(kgPerBag) ||
              (remainderKg != null &&
                  (!remainderKg.isFinite ||
                      remainderKg < 0 ||
                      remainderKg >= kgPerBag)))) ||
      !_positive(_weight(unit, quantity, kgPerBag, remainderKg))) {
    throw const FormatException(
        'Informe kg ou sacos inteiros com peso por saco e sobra menor que um saco.');
  }
}

bool _exceeds(double amount, double limit) =>
    amount - limit > math.max(amount.abs(), limit.abs()) * 1.8e-15;

double _available(double total, double used) =>
    _exceeds(total, used) ? total - used : 0;
