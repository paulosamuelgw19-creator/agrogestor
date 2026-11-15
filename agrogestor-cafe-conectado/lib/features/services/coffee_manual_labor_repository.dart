import 'dart:convert';

import '../auth/farm_access_policy.dart';
import '../harvest/coffee_harvest_repository.dart' show coffeeCivilDate;
import '../operators/operator_repository.dart';
import '../properties/catalog_store.dart';
import '../properties/plot_notebook_repository.dart';
import '../sync/local_sync_collection_store.dart';
import '../sync/local_write_batch.dart';
import 'service_repository.dart';

enum CoffeeManualLaborPaymentKind { advance, payment }

class CoffeeManualLaborPayment {
  const CoffeeManualLaborPayment({
    required this.id,
    required this.propertyId,
    required this.workerId,
    required this.date,
    required this.kind,
    required this.amountCents,
    this.notes = '',
    this.workerName = '',
  });

  final String id, propertyId, workerId, workerName, notes;
  final DateTime date;
  final CoffeeManualLaborPaymentKind kind;
  final int amountCents;

  Map<String, Object?> toJson() => {
        'id': id,
        'propertyId': propertyId,
        'workerId': workerId,
        'workerName': workerName.trim(),
        'date': coffeeCivilDate(date).toIso8601String(),
        'kind': kind.name,
        'amountCents': amountCents,
        'notes': notes.trim(),
      };

  factory CoffeeManualLaborPayment.fromJson(Map<String, dynamic> json) =>
      CoffeeManualLaborPayment(
        id: json['id'] as String,
        propertyId: json['propertyId'] as String,
        workerId: json['workerId'] as String,
        workerName: json['workerName'] as String,
        date: DateTime.parse(json['date'] as String),
        kind:
            CoffeeManualLaborPaymentKind.values.byName(json['kind'] as String),
        amountCents: json['amountCents'] as int,
        notes: json['notes'] as String,
      );

  void validate({bool stored = true}) {
    if ([id, propertyId, workerId]
            .any((value) => value.trim().isEmpty || value.length > 160) ||
        date.year < 1900 ||
        date.year > 9999 ||
        amountCents <= 0 ||
        amountCents > 1000000000000 ||
        (stored && workerName.trim().isEmpty) ||
        workerName.length > 300 ||
        notes.length > 4000) {
      throw const FormatException(
          'Confira a pessoa, a data e o valor do acerto.');
    }
  }
}

class CoffeeManualLaborDay {
  const CoffeeManualLaborDay({
    required this.serviceId,
    required this.serviceType,
    required this.propertyId,
    required this.plotId,
    required this.date,
    required this.workerId,
    required this.workerName,
    required this.dailyRateCents,
  });

  final String serviceId, serviceType, propertyId, plotId, workerId, workerName;
  final DateTime date;
  final int? dailyRateCents;
}

class CoffeeManualLaborSummary {
  CoffeeManualLaborSummary(
    List<CoffeeManualLaborDay> days,
    List<CoffeeManualLaborPayment> payments,
  )   : days = List.unmodifiable(days),
        payments = List.unmodifiable(payments) {
    var known = 0;
    var missing = 0;
    for (final day in days) {
      final dailyRate = day.dailyRateCents;
      if (dailyRate == null) {
        missing++;
      } else {
        known += dailyRate;
      }
    }
    var advances = 0;
    var paid = 0;
    for (final item in payments) {
      if (item.kind == CoffeeManualLaborPaymentKind.advance) {
        advances += item.amountCents;
      } else {
        paid += item.amountCents;
      }
    }
    knownDueCents = known;
    unknownRateCount = missing;
    advancesCents = advances;
    paymentsCents = paid;
  }

  final List<CoffeeManualLaborDay> days;
  final List<CoffeeManualLaborPayment> payments;
  late final int knownDueCents, unknownRateCount, advancesCents, paymentsCents;
  int? get dueCents => unknownRateCount == 0 ? knownDueCents : null;
  int? get balanceCents => unknownRateCount == 0
      ? knownDueCents - advancesCents - paymentsCents
      : null;
}

class CoffeeManualLaborRepository {
  static const module = 'coffeeManualLaborPayments';
  static const _store = LocalSyncCollectionStore<CoffeeManualLaborPayment>(
    module: module,
    legacyKey: 'campo_gestor_coffee_manual_labor_payments_v1',
  );

  Future<CoffeeManualLaborSummary> summary({
    required String workerId,
    String? propertyId,
    DateTime? start,
    DateTime? end,
  }) async {
    FarmAccessPolicy.requireCoffeeManager();
    final from = start == null ? null : coffeeCivilDate(start);
    final through = end == null ? null : coffeeCivilDate(end);
    if (from != null && through != null && from.isAfter(through)) {
      throw const FormatException(
          'A data final deve ser igual ou posterior à inicial.');
    }
    bool inPeriod(DateTime date) {
      final civil = coffeeCivilDate(date);
      return (from == null || !civil.isBefore(from)) &&
          (through == null || !civil.isAfter(through));
    }

    late CoffeeManualLaborSummary result;
    await LocalWriteBatch.run(() async {
      final days = await _days(workerId, propertyId);
      final payments =
          await _store.getAll(fromJson: CoffeeManualLaborPayment.fromJson);
      result = CoffeeManualLaborSummary(
        [
          for (final item in days)
            if (inPeriod(item.date)) item
        ],
        [
          for (final item in payments)
            if (item.workerId == workerId &&
                (propertyId == null || item.propertyId == propertyId) &&
                inPeriod(item.date))
              item,
        ]..sort((a, b) => b.date.compareTo(a.date)),
      );
    });
    return result;
  }

  Future<void> savePayment(CoffeeManualLaborPayment payment) async {
    FarmAccessPolicy.requireCoffeeManager();
    payment.validate(stored: false);
    final catalog = await CatalogStore.open();
    await LocalWriteBatch.run(() async {
      FarmAccessPolicy.requireCoffeeManager();
      final previous =
          await _store.getAll(fromJson: CoffeeManualLaborPayment.fromJson);
      final existing =
          previous.where((item) => item.id == payment.id).firstOrNull;
      final incoming = payment.toJson();
      if (existing != null) {
        incoming['workerName'] = existing.workerName;
        if (jsonEncode(existing.toJson()) != jsonEncode(incoming)) {
          throw const FormatException(
              'Esse acerto já foi registrado com outros dados.');
        }
        return;
      }
      await requireCoffeeCatalogLink(catalog.scope,
          propertyId: payment.propertyId);
      final operators = await OperatorRepository().getAll();
      final operator =
          operators.where((item) => item.id == payment.workerId).firstOrNull;
      final history = operator == null
          ? await _days(payment.workerId, payment.propertyId)
          : null;
      final name = operator?.name ?? history?.firstOrNull?.workerName;
      if (name == null || name.trim().isEmpty) {
        throw const FormatException('Selecione uma pessoa cadastrada.');
      }
      incoming['workerName'] = name;
      final saved = CoffeeManualLaborPayment.fromJson(incoming);
      saved.validate();
      await _store.saveAll(
        records: [...previous, saved],
        previousRecords: previous,
        idOf: (item) => item.id,
        toJson: (item) => item.toJson(),
        fromJson: CoffeeManualLaborPayment.fromJson,
      );
    });
  }

  Future<List<CoffeeManualLaborDay>> _days(
      String workerId, String? propertyId) async {
    final days = <(String, DateTime), CoffeeManualLaborDay>{};
    for (final service in await ServiceRepository().getAll()) {
      if (!service.isManual ||
          (propertyId != null && service.propertyId != propertyId)) {
        continue;
      }
      for (final day in service.days) {
        final date = coffeeCivilDate(day.date);
        for (final worker in day.manualWorkers) {
          if (worker.workerId != workerId) continue;
          days.putIfAbsent(
              (service.id, date),
              () => CoffeeManualLaborDay(
                    serviceId: service.id,
                    serviceType: service.jobType,
                    propertyId: service.propertyId,
                    plotId: service.fieldId,
                    date: date,
                    workerId: worker.workerId,
                    workerName: worker.workerName,
                    dailyRateCents: worker.dailyRateCents,
                  ));
        }
      }
    }
    return days.values.toList()..sort((a, b) => b.date.compareTo(a.date));
  }
}
