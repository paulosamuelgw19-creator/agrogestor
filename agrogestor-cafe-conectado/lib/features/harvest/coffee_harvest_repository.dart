import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../auth/auth_service.dart';
import '../auth/farm_access_policy.dart';
import '../operators/operator_repository.dart';
import '../processing/coffee_processing_repository.dart';
import '../properties/catalog_store.dart';
import '../properties/plot_notebook_repository.dart';
import '../sync/farm_api_client.dart';
import '../sync/local_sync_collection_store.dart';
import '../sync/local_write_batch.dart';

enum CoffeeHarvestUnit { measures, liters, carts }

enum CoffeeHarvestPaymentKind { advance, payment }

typedef CoffeeHarvestDayKey = (String, String, int, DateTime);

class CoffeeHarvestEntry {
  const CoffeeHarvestEntry({
    required this.id,
    required this.propertyId,
    required this.plotId,
    required this.workerId,
    required this.date,
    required this.seasonYear,
    required this.unit,
    required this.quantity,
    this.litersPerMeasure = 60,
    this.cartCapacityLiters,
    this.ratePerMeasureCents,
    this.workerName = '',
  });

  final String id, propertyId, plotId, workerId, workerName;
  final DateTime date;
  final int seasonYear;
  final CoffeeHarvestUnit unit;
  final double quantity, litersPerMeasure;
  final double? cartCapacityLiters;
  final int? ratePerMeasureCents;

  double get volumeLiters => switch (unit) {
        CoffeeHarvestUnit.measures => quantity * litersPerMeasure,
        CoffeeHarvestUnit.liters => quantity,
        CoffeeHarvestUnit.carts => quantity * cartCapacityLiters!,
      };

  double get measureEquivalent => volumeLiters / litersPerMeasure;

  int? get earnedCents => ratePerMeasureCents == null
      ? null
      : (measureEquivalent * ratePerMeasureCents!).round();

  Map<String, Object?> toJson() => {
        'id': id,
        'propertyId': propertyId,
        'plotId': plotId,
        'workerId': workerId,
        'workerName': workerName,
        'date': date.toIso8601String(),
        'seasonYear': seasonYear,
        'unit': unit.name,
        'quantity': quantity,
        'litersPerMeasure': litersPerMeasure,
        if (cartCapacityLiters != null)
          'cartCapacityLiters': cartCapacityLiters,
        if (ratePerMeasureCents != null)
          'ratePerMeasureCents': ratePerMeasureCents,
      };

  factory CoffeeHarvestEntry.fromJson(Map<String, dynamic> json) =>
      CoffeeHarvestEntry(
        id: json['id'] as String,
        propertyId: json['propertyId'] as String,
        plotId: json['plotId'] as String,
        workerId: json['workerId'] as String,
        workerName: json['workerName'] as String,
        date: DateTime.parse(json['date'] as String),
        seasonYear: json['seasonYear'] as int,
        unit: CoffeeHarvestUnit.values.byName(json['unit'] as String),
        quantity: (json['quantity'] as num).toDouble(),
        litersPerMeasure: (json['litersPerMeasure'] as num).toDouble(),
        cartCapacityLiters: (json['cartCapacityLiters'] as num?)?.toDouble(),
        ratePerMeasureCents: json['ratePerMeasureCents'] as int?,
      );

  void validate({bool stored = true}) {
    _validateScope([id, propertyId, plotId, workerId], seasonYear);
    final capacity = cartCapacityLiters;
    if ((stored && workerName.trim().isEmpty) ||
        !_positive(quantity) ||
        !_positive(litersPerMeasure) ||
        (unit == CoffeeHarvestUnit.carts && capacity == null) ||
        (capacity != null && !_positive(capacity)) ||
        !_positive(volumeLiters) ||
        !_positive(measureEquivalent)) {
      throw const FormatException(
          'Confira a quantidade e as unidades da colheita.');
    }
    final rate = ratePerMeasureCents;
    if (rate != null &&
        (rate < 0 ||
            rate > _maxMoneyCents ||
            measureEquivalent * rate > _maxMoneyCents)) {
      throw const FormatException('Confira o valor por medida.');
    }
  }
}

class CoffeeHarvestPayment {
  const CoffeeHarvestPayment({
    required this.id,
    required this.propertyId,
    required this.workerId,
    required this.date,
    required this.seasonYear,
    required this.kind,
    required this.amountCents,
    this.notes = '',
    this.workerName = '',
  });

  final String id, propertyId, workerId, workerName, notes;
  final DateTime date;
  final int seasonYear, amountCents;
  final CoffeeHarvestPaymentKind kind;

  Map<String, Object?> toJson() => {
        'id': id,
        'propertyId': propertyId,
        'workerId': workerId,
        'workerName': workerName,
        'date': date.toIso8601String(),
        'seasonYear': seasonYear,
        'kind': kind.name,
        'amountCents': amountCents,
        'notes': notes,
      };

  factory CoffeeHarvestPayment.fromJson(Map<String, dynamic> json) =>
      CoffeeHarvestPayment(
        id: json['id'] as String,
        propertyId: json['propertyId'] as String,
        workerId: json['workerId'] as String,
        workerName: json['workerName'] as String,
        date: DateTime.parse(json['date'] as String),
        seasonYear: json['seasonYear'] as int,
        kind: CoffeeHarvestPaymentKind.values.byName(json['kind'] as String),
        amountCents: json['amountCents'] as int,
        notes: json['notes'] as String,
      );

  void validate({bool stored = true}) {
    _validateScope([id, propertyId, workerId], seasonYear);
    if ((stored && workerName.trim().isEmpty) ||
        amountCents <= 0 ||
        amountCents > _maxMoneyCents) {
      throw const FormatException('Informe um valor válido para o lançamento.');
    }
  }
}

class CoffeeHarvestSummary {
  CoffeeHarvestSummary(
      List<CoffeeHarvestEntry> entries, List<CoffeeHarvestPayment> payments)
      : entries = List.unmodifiable(entries),
        payments = List.unmodifiable(payments) {
    final byDay = <DateTime, double>{};
    final byWorker = <String, double>{};
    var liters = 0.0;
    var known = 0;
    var hasUnknown = false;
    var advances = 0;
    var paid = 0;
    for (final entry in entries) {
      final date = entry.date;
      final day = DateTime(date.year, date.month, date.day);
      final volume = entry.volumeLiters;
      byDay.update(day, (previous) => previous + volume,
          ifAbsent: () => volume);
      byWorker.update(entry.workerId, (previous) => previous + volume,
          ifAbsent: () => volume);
      liters += volume;
      final value = entry.earnedCents;
      if (value == null) {
        hasUnknown = true;
      } else {
        known += value;
      }
    }
    for (final payment in payments) {
      if (payment.kind == CoffeeHarvestPaymentKind.advance) {
        advances += payment.amountCents;
      } else {
        paid += payment.amountCents;
      }
    }
    litersByDay = Map.unmodifiable(byDay);
    litersByWorker = Map.unmodifiable(byWorker);
    totalLiters = liters;
    knownEarnedCents = known;
    earnedCents = hasUnknown ? null : known;
    advancesCents = advances;
    paymentsCents = paid;
    balanceCents = hasUnknown ? null : known - advances - paid;
  }

  final List<CoffeeHarvestEntry> entries;
  final List<CoffeeHarvestPayment> payments;
  late final Map<DateTime, double> litersByDay;
  late final Map<String, double> litersByWorker;
  late final double totalLiters;
  late final int knownEarnedCents, advancesCents, paymentsCents;
  late final int? earnedCents, balanceCents;
}

class CoffeePlotProduction {
  const CoffeePlotProduction({
    required this.id,
    required this.propertyId,
    required this.plotId,
    required this.date,
    required this.seasonYear,
    required this.unit,
    required this.quantity,
    this.litersPerMeasure = 60,
    this.remainderLiters,
    this.cartCapacityLiters,
    this.checkedWorkerLiters,
  });

  final String id, propertyId, plotId;
  final DateTime date;
  final int seasonYear;
  final CoffeeHarvestUnit unit;
  final double quantity, litersPerMeasure;
  final double? remainderLiters, cartCapacityLiters, checkedWorkerLiters;

  DateTime get civilDate => coffeeCivilDate(date);
  CoffeeHarvestDayKey get dayKey => (propertyId, plotId, seasonYear, civilDate);

  double get volumeLiters => switch (unit) {
        CoffeeHarvestUnit.measures =>
          quantity * litersPerMeasure + (remainderLiters ?? 0),
        CoffeeHarvestUnit.liters => quantity,
        CoffeeHarvestUnit.carts => quantity * cartCapacityLiters!,
      };

  Map<String, Object?> toJson() => {
        'id': id,
        'propertyId': propertyId,
        'plotId': plotId,
        'date': civilDate.toIso8601String(),
        'seasonYear': seasonYear,
        'unit': unit.name,
        'quantity': quantity,
        if (checkedWorkerLiters != null)
          'checkedWorkerLiters': checkedWorkerLiters,
        'litersPerMeasure': litersPerMeasure,
        if (remainderLiters != null) 'remainderLiters': remainderLiters,
        if (cartCapacityLiters != null)
          'cartCapacityLiters': cartCapacityLiters,
      };

  factory CoffeePlotProduction.fromJson(Map<String, dynamic> json) =>
      CoffeePlotProduction(
        id: json['id'] as String,
        propertyId: json['propertyId'] as String,
        plotId: json['plotId'] as String,
        date: DateTime.parse(json['date'] as String),
        seasonYear: json['seasonYear'] as int,
        unit: CoffeeHarvestUnit.values.byName(json['unit'] as String),
        quantity: (json['quantity'] as num).toDouble(),
        litersPerMeasure: (json['litersPerMeasure'] as num).toDouble(),
        checkedWorkerLiters: (json['checkedWorkerLiters'] as num?)?.toDouble(),
        remainderLiters: (json['remainderLiters'] as num?)?.toDouble(),
        cartCapacityLiters: (json['cartCapacityLiters'] as num?)?.toDouble(),
      );

  void validate() {
    _validateScope([id, propertyId, plotId], seasonYear);
    final remainder = remainderLiters;
    final capacity = cartCapacityLiters;
    if (!_positive(litersPerMeasure) ||
        (checkedWorkerLiters != null &&
            (!checkedWorkerLiters!.isFinite || checkedWorkerLiters! < 0)) ||
        !quantity.isFinite ||
        quantity < 0 ||
        quantity > 1e12 ||
        (unit == CoffeeHarvestUnit.measures &&
            quantity.truncateToDouble() != quantity) ||
        (remainder != null &&
            (unit != CoffeeHarvestUnit.measures ||
                !remainder.isFinite ||
                remainder < 0 ||
                remainder >= litersPerMeasure)) ||
        (unit == CoffeeHarvestUnit.carts
            ? capacity == null || !_positive(capacity)
            : capacity != null) ||
        !volumeLiters.isFinite ||
        volumeLiters > 1e12) {
      throw const FormatException(
        'Confira a quantidade, a capacidade da carreta e a sobra menor que uma medida.',
      );
    }
  }
}

class CoffeePlotProductionDay {
  const CoffeePlotProductionDay({
    required this.date,
    this.declared,
    this.workerLiters,
  });

  final DateTime date;
  final CoffeePlotProduction? declared;
  final double? workerLiters;

  double get totalLiters => declared?.volumeLiters ?? workerLiters!;

  bool get needsReview {
    final difference = differenceLiters;
    final checked = declared?.checkedWorkerLiters;
    return difference != null &&
        difference.abs() > 0.000001 &&
        (checked == null || (checked - workerLiters!).abs() > 0.000001);
  }

  double? get differenceLiters {
    final totalDeclared = declared?.volumeLiters;
    final perWorker = workerLiters;
    return totalDeclared == null || perWorker == null
        ? null
        : totalDeclared - perWorker;
  }
}

class CoffeePlotProductionSummary {
  CoffeePlotProductionSummary(List<CoffeePlotProductionDay> days)
      : days = List.unmodifiable(days),
        totalLiters = days.fold(0.0, (total, day) => total + day.totalLiters);

  final List<CoffeePlotProductionDay> days;
  final double totalLiters;
}

class CoffeeHarvestRepository {
  static final _entries = LocalSyncCollectionStore<CoffeeHarvestEntry>(
    module: 'coffeeHarvestEntries',
    legacyKey: FarmAccessPolicy.coffeeLocalModules['coffeeHarvestEntries']!,
  );
  static final _payments = LocalSyncCollectionStore<CoffeeHarvestPayment>(
    module: 'coffeeHarvestPayments',
    legacyKey: FarmAccessPolicy.coffeeLocalModules['coffeeHarvestPayments']!,
  );
  static final _production = LocalSyncCollectionStore<CoffeePlotProduction>(
    module: 'coffeePlotProduction',
    legacyKey:
        FarmAccessPolicy.coffeeProductionModules['coffeePlotProduction']!,
  );

  Future<void> saveProduction(CoffeePlotProduction production) async {
    final session = _session();
    production.validate();
    final catalog = await CatalogStore.open();
    await _saveProduction(production, catalog, session);
  }

  Future<void> _saveProduction(CoffeePlotProduction production,
          CatalogStore catalog, (String, String?, String?) session) =>
      LocalWriteBatch.run(() async {
        _checkSession(session);
        final previous =
            await _production.getAll(fromJson: CoffeePlotProduction.fromJson);
        if (previous.any((item) =>
            item.id == production.id && item.dayKey != production.dayKey)) {
          throw const FormatException(
            'Este lançamento pertence a outro dia, talhão ou safra.',
          );
        }
        final existing = previous
            .where((item) => item.dayKey == production.dayKey)
            .firstOrNull;
        await requireCoffeeCatalogLink(
          catalog.scope,
          propertyId: production.propertyId,
          plotId: production.plotId,
          active: existing == null,
          confirmedUntil:
              FarmApiClient.standaloneLocalMode ? null : catalog.tokenExpiry,
        );
        final id = existing?.id ??
            (FarmApiClient.standaloneLocalMode
                ? production.id
                : _connectedDayId(production));
        final updated =
            CoffeePlotProduction.fromJson({...production.toJson(), 'id': id});
        if (FarmApiClient.standaloneLocalMode) {
          await CoffeeProcessingRepository().checkHarvestDayCapacity(
            updated.dayKey,
            updated.volumeLiters,
          );
        }
        _checkSession(session);
        await _production.saveAll(
          records: [
            ...previous.where((item) => item.id != updated.id),
            updated
          ],
          previousRecords: previous,
          idOf: (item) => item.id,
          toJson: (item) => item.toJson(),
          fromJson: CoffeePlotProduction.fromJson,
        );
      });

  Future<void> reviewProduction(CoffeePlotProductionDay day,
      {required bool keepDeclared}) async {
    final session = _session();
    final declared = day.declared;
    final workerLiters = day.workerLiters;
    if (declared == null || workerLiters == null || !day.needsReview) {
      throw const FormatException(
          'Este lançamento não precisa de conferência.');
    }
    final catalog = await CatalogStore.open();
    await LocalWriteBatch.run(() async {
      final current = await production(
        propertyId: declared.propertyId,
        plotId: declared.plotId,
        seasonYear: declared.seasonYear,
      );
      final latest =
          current.days.where((item) => item.date == day.date).firstOrNull;
      if (latest == null ||
          !latest.needsReview ||
          latest.declared?.id != declared.id ||
          latest.declared?.volumeLiters != declared.volumeLiters ||
          latest.workerLiters != workerLiters) {
        throw const FormatException(
            'O total do dia mudou. Atualize a colheita e confira novamente.');
      }
      final updated = CoffeePlotProduction.fromJson({
        ...declared.toJson(),
        if (keepDeclared) 'checkedWorkerLiters': workerLiters,
        if (!keepDeclared) ...{
          'unit': CoffeeHarvestUnit.liters.name,
          'quantity': workerLiters,
          'checkedWorkerLiters': null,
          'remainderLiters': null,
          'cartCapacityLiters': null,
        },
      });
      updated.validate();
      await _saveProduction(updated, catalog, session);
    });
  }

  Future<CoffeePlotProductionSummary> production({
    required String propertyId,
    required String plotId,
    required int seasonYear,
  }) async {
    final session = _session();
    late CoffeePlotProductionSummary summary;
    await LocalWriteBatch.run(() async {
      final declarations = {
        for (final item in await _production.getAll(
            fromJson: CoffeePlotProduction.fromJson))
          if (item.propertyId == propertyId &&
              item.plotId == plotId &&
              item.seasonYear == seasonYear)
            item.civilDate: item,
      };
      final byWorkers = <DateTime, double>{};
      for (final entry in await entries(
          propertyId: propertyId, seasonYear: seasonYear, plotId: plotId)) {
        final volume = entry.volumeLiters;
        byWorkers.update(coffeeCivilDate(entry.date), (total) => total + volume,
            ifAbsent: () => volume);
      }
      final dates = {...declarations.keys, ...byWorkers.keys}.toList()
        ..sort((a, b) => b.compareTo(a));
      summary = CoffeePlotProductionSummary([
        for (final date in dates)
          CoffeePlotProductionDay(
            date: date,
            declared: declarations[date],
            workerLiters: byWorkers[date],
          ),
      ]);
    }, notifySync: false);
    _checkSession(session);
    return summary;
  }

  Future<void> saveEntry(CoffeeHarvestEntry entry) async {
    final session = _session();
    entry.validate(stored: false);
    if (!FarmApiClient.standaloneLocalMode &&
        entry.ratePerMeasureCents != null) {
      throw const FormatException(
          'O valor por medida está disponível na edição local.');
    }
    final catalog = await CatalogStore.open();
    await _append(
      _entries,
      record: entry.toJson(),
      fromJson: CoffeeHarvestEntry.fromJson,
      toJson: (item) => item.toJson(),
      session: session,
      validateCatalog: () => requireCoffeeCatalogLink(
        catalog.scope,
        propertyId: entry.propertyId,
        plotId: entry.plotId,
        active: true,
        confirmedUntil:
            FarmApiClient.standaloneLocalMode ? null : catalog.tokenExpiry,
      ),
    );
  }

  Future<void> setEntryRate({
    required String propertyId,
    required String plotId,
    required String id,
    required int? ratePerMeasureCents,
  }) async {
    FarmAccessPolicy.requireCoffeeManager();
    await LocalWriteBatch.run(() async {
      FarmAccessPolicy.requireCoffeeManager();
      final previous =
          await _entries.getAll(fromJson: CoffeeHarvestEntry.fromJson);
      final entry = previous
          .where((item) =>
              item.id == id &&
              item.propertyId == propertyId &&
              item.plotId == plotId)
          .firstOrNull;
      if (entry == null) {
        throw const FormatException('Lançamento não encontrado neste talhão.');
      }
      if (entry.ratePerMeasureCents == ratePerMeasureCents) return;
      final updated = CoffeeHarvestEntry.fromJson({
        ...entry.toJson(),
        'ratePerMeasureCents': ratePerMeasureCents,
      });
      updated.validate();
      await _entries.saveAll(
        records: [
          for (final item in previous)
            if (item.id == id) updated else item
        ],
        previousRecords: previous,
        idOf: (item) => item.id,
        toJson: (item) => item.toJson(),
        fromJson: CoffeeHarvestEntry.fromJson,
      );
    });
  }

  Future<void> savePayment(CoffeeHarvestPayment payment) async {
    FarmAccessPolicy.requireCoffeeManager();
    final session = _session();
    payment.validate(stored: false);
    final catalog = await CatalogStore.open();
    await _append(
      _payments,
      record: payment.toJson(),
      fromJson: CoffeeHarvestPayment.fromJson,
      toJson: (item) => item.toJson(),
      session: session,
      validateCatalog: () => requireCoffeeCatalogLink(catalog.scope,
          propertyId: payment.propertyId),
    );
  }

  Future<void> _append<T>(
    LocalSyncCollectionStore<T> store, {
    required Map<String, Object?> record,
    required T Function(Map<String, dynamic>) fromJson,
    required Map<String, Object?> Function(T) toJson,
    required (String, String?, String?) session,
    required Future<void> Function() validateCatalog,
  }) =>
      LocalWriteBatch.run(() async {
        _checkSession(session);
        final previous = await store.getAll(fromJson: fromJson);
        String idOf(T item) => toJson(item)['id'] as String;
        final existing =
            previous.where((item) => idOf(item) == record['id']).firstOrNull;
        if (existing != null) {
          final stored = toJson(existing);
          record['workerName'] = stored['workerName'];
          if (jsonEncode(record) != jsonEncode(stored)) {
            throw const FormatException(
              'Este lançamento já foi registrado com outros dados.',
            );
          }
          return;
        }
        await validateCatalog();
        final workers = await OperatorRepository().getAll();
        final worker =
            workers.where((item) => item.id == record['workerId']).firstOrNull;
        if (worker == null || worker.name.trim().isEmpty) {
          throw const FormatException('Selecione uma pessoa cadastrada.');
        }
        record['workerName'] = worker.name;
        _checkSession(session);
        await store.saveAll(
          records: [...previous, fromJson(record)],
          previousRecords: previous,
          idOf: idOf,
          toJson: toJson,
          fromJson: fromJson,
        );
      });

  Future<List<CoffeeHarvestEntry>> entries({
    required String propertyId,
    required int seasonYear,
    String? plotId,
    String? workerId,
  }) async {
    final session = _session();
    final records =
        await _entries.getAll(fromJson: CoffeeHarvestEntry.fromJson);
    _checkSession(session);
    return [
      for (final entry in records)
        if (entry.propertyId == propertyId &&
            entry.seasonYear == seasonYear &&
            (plotId == null || entry.plotId == plotId) &&
            (workerId == null || entry.workerId == workerId))
          entry,
    ]..sort((a, b) => b.date.compareTo(a.date));
  }

  Future<List<CoffeeHarvestPayment>> payments({
    required String propertyId,
    required int seasonYear,
    String? workerId,
  }) async {
    FarmAccessPolicy.requireCoffeeManager();
    return [
      for (final payment
          in await _payments.getAll(fromJson: CoffeeHarvestPayment.fromJson))
        if (payment.propertyId == propertyId &&
            payment.seasonYear == seasonYear &&
            (workerId == null || payment.workerId == workerId))
          payment,
    ]..sort((a, b) => b.date.compareTo(a.date));
  }

  Future<CoffeeHarvestSummary> summary({
    required String propertyId,
    required int seasonYear,
    String? workerId,
  }) async {
    FarmAccessPolicy.requireCoffeeManager();
    late CoffeeHarvestSummary result;
    await LocalWriteBatch.run(() async {
      result = CoffeeHarvestSummary(
        await entries(
            propertyId: propertyId, seasonYear: seasonYear, workerId: workerId),
        await payments(
            propertyId: propertyId, seasonYear: seasonYear, workerId: workerId),
      );
    });
    return result;
  }

  (String, String?, String?) _session() {
    FarmAccessPolicy.requireCoffeeHarvest();
    final auth = AuthService();
    final user = auth.currentUser!;
    return (user.id, user.farmId, auth.accessToken);
  }

  void _checkSession((String, String?, String?) expected) {
    if (_session() != expected) {
      throw const FarmAccessDenied(
          'A sessão mudou. Abra a colheita novamente.');
    }
  }

  String _connectedDayId(CoffeePlotProduction day) => const Uuid().v5(
        Namespace.url.value,
        'agrogestor:coffeePlotProduction:${jsonEncode([
              day.propertyId,
              day.plotId,
              day.seasonYear,
              day.civilDate.toIso8601String().split('T').first,
            ])}',
      );
}

const _maxMoneyCents = 1000000000000;

bool _positive(double value) => value.isFinite && value > 0 && value <= 1e12;

DateTime coffeeCivilDate(DateTime date) =>
    DateTime(date.year, date.month, date.day);

Map<CoffeeHarvestDayKey, double> coffeeHarvestSourceTotals(
  Iterable<CoffeeHarvestEntry> entries,
  Iterable<CoffeePlotProduction> declarations,
) {
  final totals = <CoffeeHarvestDayKey, double>{};
  for (final entry in entries) {
    final key = (
      entry.propertyId,
      entry.plotId,
      entry.seasonYear,
      coffeeCivilDate(entry.date)
    );
    final volume = entry.volumeLiters;
    totals.update(key, (sum) => sum + volume, ifAbsent: () => volume);
  }
  for (final entry in declarations) {
    totals[entry.dayKey] = entry.volumeLiters;
  }
  return totals;
}

void _validateScope(List<String> ids, int seasonYear) {
  if (ids.any((id) => id.trim().isEmpty || id.length > 160) ||
      seasonYear < 1900 ||
      seasonYear > 9999) {
    throw const FormatException(
        'Confira a fazenda, a pessoa e o ano da safra.');
  }
}
