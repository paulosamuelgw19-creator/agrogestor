import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../analyses/coffee_analysis_repository.dart';
import '../auth/auth_service.dart';
import '../auth/farm_access_policy.dart';
import '../fuel/fuel_repository.dart';
import '../harvest/coffee_harvest_repository.dart';
import '../maintenance/maintenance_repository.dart';
import '../processing/coffee_processing_repository.dart';
import '../properties/catalog_store.dart';
import '../properties/plot_notebook_repository.dart';
import '../sync/local_sync_collection_store.dart';
import '../sync/app_database.dart';
import '../sync/farm_api_client.dart';
import '../sync/local_write_batch.dart';
import '../sync/sync_service.dart';
import '../tools/coffee_tools_repository.dart';

enum CoffeeFinanceKind { purchase, contractedService, expense, income }

enum CoffeeFinanceStage { establishment, management, harvest, processing }

enum CoffeeFinancePriceMode { unit, total }

enum CoffeeFinanceFreightMode { included, separate }

enum CoffeeFinanceOriginKind { fuel, maintenance }

class CoffeeFinanceEntry {
  const CoffeeFinanceEntry({
    required this.id,
    required this.propertyId,
    required this.seasonYear,
    required this.date,
    required this.kind,
    required this.stage,
    required this.category,
    required this.description,
    this.plotId,
    this.settledAt,
    this.supplier = '',
    this.quantity,
    this.unit = '',
    this.priceMode = CoffeeFinancePriceMode.total,
    this.priceCents,
    this.freightMode = CoffeeFinanceFreightMode.included,
    this.freightCents,
    this.pdfPath,
    this.notes = '',
    this.originKind,
    this.originId,
    this.productId,
    this.analysisId,
  });

  final String id, propertyId, category, description, supplier, unit, notes;
  final String? plotId, pdfPath, originId, productId, analysisId;
  final DateTime date;
  final DateTime? settledAt;
  final int seasonYear;
  final int? priceCents, freightCents;
  final double? quantity;
  final CoffeeFinanceKind kind;
  final CoffeeFinanceStage stage;
  final CoffeeFinancePriceMode priceMode;
  final CoffeeFinanceFreightMode freightMode;
  final CoffeeFinanceOriginKind? originKind;

  bool get isIncome => kind == CoffeeFinanceKind.income;

  int? get totalCents {
    final price = priceCents;
    final amount = quantity;
    final freight =
        freightMode == CoffeeFinanceFreightMode.included ? 0 : freightCents;
    if (price == null || freight == null) return null;
    if (priceMode == CoffeeFinancePriceMode.total) return price + freight;
    if (amount == null || !amount.isFinite || amount < 0 || price < 0) {
      return null;
    }
    final subtotal = price * amount;
    if (!subtotal.isFinite || subtotal > _maxCents) return null;
    return _multiplyCents(price, amount) + freight;
  }

  (CoffeeFinanceOriginKind, String)? get originKey {
    final kind = originKind;
    final id = originId;
    return kind != null && id != null ? (kind, id) : null;
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'propertyId': propertyId,
        'seasonYear': seasonYear,
        'date': coffeeCivilDate(date).toIso8601String(),
        'kind': kind.name,
        'stage': stage.name,
        'category': category.trim(),
        'description': description.trim(),
        if (plotId != null) 'plotId': plotId,
        if (settledAt != null)
          'settledAt': coffeeCivilDate(settledAt!).toIso8601String(),
        'supplier': supplier.trim(),
        if (quantity != null) 'quantity': quantity,
        'unit': unit.trim(),
        'priceMode': priceMode.name,
        if (priceCents != null) 'priceCents': priceCents,
        'freightMode': freightMode.name,
        if (freightCents != null) 'freightCents': freightCents,
        if (pdfPath?.trim().isNotEmpty == true) 'pdfPath': pdfPath,
        'notes': notes.trim(),
        if (originKind != null) 'originKind': originKind!.name,
        if (originId != null) 'originId': originId,
        if (productId != null) 'productId': productId,
        if (analysisId != null) 'analysisId': analysisId,
      };

  factory CoffeeFinanceEntry.fromJson(Map<String, dynamic> json) =>
      CoffeeFinanceEntry(
        id: json['id'] as String,
        propertyId: json['propertyId'] as String,
        seasonYear: json['seasonYear'] as int,
        date: DateTime.parse(json['date'] as String),
        kind: CoffeeFinanceKind.values.byName(json['kind'] as String),
        stage: CoffeeFinanceStage.values.byName(json['stage'] as String),
        category: json['category'] as String,
        description: json['description'] as String,
        plotId: json['plotId'] as String?,
        settledAt: json['settledAt'] == null
            ? null
            : DateTime.parse(json['settledAt'] as String),
        supplier: json['supplier'] as String,
        quantity: (json['quantity'] as num?)?.toDouble(),
        unit: json['unit'] as String,
        priceMode:
            CoffeeFinancePriceMode.values.byName(json['priceMode'] as String),
        priceCents: json['priceCents'] as int?,
        freightMode: CoffeeFinanceFreightMode.values
            .byName(json['freightMode'] as String),
        freightCents: json['freightCents'] as int?,
        pdfPath: json['pdfPath'] as String?,
        notes: json['notes'] as String,
        originKind: json['originKind'] == null
            ? null
            : CoffeeFinanceOriginKind.values
                .byName(json['originKind'] as String),
        originId: json['originId'] as String?,
        productId: json['productId'] as String?,
        analysisId: json['analysisId'] as String?,
      );

  void validate() {
    final amount = quantity;
    final price = priceCents;
    final total = totalCents;
    if (!_validId(id) ||
        !_validId(propertyId) ||
        (plotId != null && !_validId(plotId!)) ||
        (productId != null && (!_validId(productId!) || isIncome)) ||
        (analysisId != null &&
            (!_validId(analysisId!) || isIncome || plotId == null)) ||
        seasonYear < 1900 ||
        seasonYear > 9999 ||
        !_validDate(date) ||
        (settledAt != null && !_validDate(settledAt!)) ||
        category.trim().isEmpty ||
        category.length > 160 ||
        description.trim().isEmpty ||
        description.length > 300 ||
        supplier.length > 300 ||
        notes.length > 4000) {
      throw const FormatException(
          'Confira o lançamento, a fazenda, a safra e as datas.');
    }
    if ((amount != null &&
            (!amount.isFinite || amount <= 0 || amount > 1e12)) ||
        (amount == null) != unit.trim().isEmpty ||
        unit.length > 80 ||
        (price != null && (price < 0 || price > _maxCents)) ||
        (freightCents != null &&
            (freightCents! < 0 || freightCents! > _maxCents)) ||
        (freightMode == CoffeeFinanceFreightMode.included &&
            freightCents != null) ||
        (priceMode == CoffeeFinancePriceMode.unit &&
            (amount == null ||
                (price != null && price * amount > _maxCents))) ||
        (total != null && total > _maxCents) ||
        (settledAt != null && total == null)) {
      throw const FormatException(
          'Confira a quantidade, os valores e o frete antes de informar a data de baixa.');
    }
    if ((originKind == null) != (originId == null) ||
        (originId != null && !_validId(originId!)) ||
        (originKind != null &&
            (kind != CoffeeFinanceKind.expense ||
                priceMode != CoffeeFinancePriceMode.total ||
                freightMode != CoffeeFinanceFreightMode.included ||
                price == null))) {
      throw const FormatException(
          'O vínculo da despesa deve preservar o valor do lançamento original.');
    }
  }
}

class CoffeeSaleReceipt {
  const CoffeeSaleReceipt({
    required this.id,
    required this.propertyId,
    required this.lotId,
    required this.saleId,
    required this.date,
    required this.amountCents,
    this.notes = '',
  });

  final String id, propertyId, lotId, saleId, notes;
  final DateTime date;
  final int amountCents;

  Map<String, Object?> toJson() => {
        'id': id,
        'propertyId': propertyId,
        'lotId': lotId,
        'saleId': saleId,
        'date': coffeeCivilDate(date).toIso8601String(),
        'amountCents': amountCents,
        'notes': notes.trim(),
      };

  factory CoffeeSaleReceipt.fromJson(Map<String, dynamic> json) =>
      CoffeeSaleReceipt(
        id: json['id'] as String,
        propertyId: json['propertyId'] as String,
        lotId: json['lotId'] as String,
        saleId: json['saleId'] as String,
        date: DateTime.parse(json['date'] as String),
        amountCents: json['amountCents'] as int,
        notes: json['notes'] as String,
      );

  void validate() {
    if (![id, propertyId, lotId, saleId].every(_validId) ||
        !_validDate(date) ||
        amountCents <= 0 ||
        amountCents > _maxCents ||
        notes.length > 4000) {
      throw const FormatException(
          'Confira o valor, a data e a venda deste recebimento.');
    }
  }
}

class CoffeeFinanceSale {
  CoffeeFinanceSale({
    required this.lot,
    required this.sale,
    required List<CoffeeSaleReceipt> receipts,
  }) : receipts = List.unmodifiable(receipts);

  final CoffeeLot lot;
  final CoffeeLotSale sale;
  final List<CoffeeSaleReceipt> receipts;

  int get receivedCents =>
      receipts.fold(0, (sum, item) => sum + item.amountCents);
  int get outstandingCents => sale.totalPriceCents - receivedCents;

  /// An ambiguous or mixed origin stays at farm level.
  String? get plotId {
    if (lot.inputs.any((input) => input.origin != CoffeeLotOrigin.confirmed)) {
      return null;
    }
    final plots = lot.inputs.map((input) => input.plotId).toSet();
    return plots.length == 1 ? plots.single : null;
  }
}

class CoffeeFinanceLegacySource {
  const CoffeeFinanceLegacySource({
    required this.kind,
    required this.id,
    required this.date,
    required this.description,
    required this.amountCents,
  });

  final CoffeeFinanceOriginKind kind;
  final String id, description;
  final DateTime date;
  final int amountCents;
}

class CoffeeFinanceSummary {
  const CoffeeFinanceSummary({
    required this.entries,
    required this.sales,
    required this.knownExpenseCents,
    required this.knownRevenueCents,
    required this.cashInCents,
    required this.cashOutCents,
    required this.outstandingSalesCents,
    required this.unknownExpenseCount,
    required this.unknownRevenueCount,
    required this.knownHarvestCostCents,
    required this.harvestCashPaidCents,
    this.harvestPayments = const [],
    this.hasUnallocatedHarvestPayments = false,
  });

  final List<CoffeeFinanceEntry> entries;
  final List<CoffeeFinanceSale> sales;
  final int knownExpenseCents, knownRevenueCents, cashInCents, cashOutCents;
  final int outstandingSalesCents, unknownExpenseCount, unknownRevenueCount;
  final int knownHarvestCostCents, harvestCashPaidCents;
  final List<CoffeeHarvestPayment> harvestPayments;
  final bool hasUnallocatedHarvestPayments;

  int get recognizedBalanceCents => knownRevenueCents - knownExpenseCents;
  int get cashBalanceCents => cashInCents - cashOutCents;
  int get harvestAdvanceCents =>
      _harvestPaidAs(CoffeeHarvestPaymentKind.advance);
  int get harvestPaymentCents =>
      _harvestPaidAs(CoffeeHarvestPaymentKind.payment);

  int _harvestPaidAs(CoffeeHarvestPaymentKind kind) => harvestPayments
      .where((item) => item.kind == kind)
      .fold(0, (sum, item) => sum + item.amountCents);
}

class CoffeeFinanceRepository {
  static const entriesModule = 'coffeeFinanceEntries';
  static const receiptsModule = 'coffeeSaleReceipts';

  static const _entries = LocalSyncCollectionStore<CoffeeFinanceEntry>(
    module: entriesModule,
    legacyKey: 'campo_gestor_coffee_finance_entries_v1',
  );
  static const _receipts = LocalSyncCollectionStore<CoffeeSaleReceipt>(
    module: receiptsModule,
    legacyKey: 'campo_gestor_coffee_sale_receipts_v1',
  );

  Future<List<CoffeeFinanceEntry>> productPurchases(String productId) async {
    FarmAccessPolicy.requireCoffeeManager();
    final entries =
        await _entries.getAll(fromJson: CoffeeFinanceEntry.fromJson);
    return entries.where((item) => item.productId == productId).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
  }

  Future<List<CoffeeFinanceEntry>> unlinkedProductExpenses() async {
    final linked = {
      for (final tool in await CoffeeToolsRepository().getAll()) tool.expenseId
    };
    return (await toolExpenseCandidates())
        .where((entry) => !linked.contains(entry.id))
        .toList();
  }

  Future<List<CoffeeFinanceEntry>> toolExpenseCandidates() async {
    FarmAccessPolicy.requireCoffeeManager();
    final entries =
        await _entries.getAll(fromJson: CoffeeFinanceEntry.fromJson);
    return entries
        .where((item) =>
            !item.isIncome && item.productId == null && item.originKey == null)
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
  }

  Future<void> linkProductPurchase({
    required String entryId,
    required String productId,
    Uint8List? pickedPdf,
    String? pickedPdfName,
    CatalogStore? catalogContext,
  }) async {
    FarmAccessPolicy.requireCoffeeManager();
    final catalog = catalogContext ?? await CatalogStore.open();
    await LocalWriteBatch.run(() async {
      final entries =
          await _entries.getAll(fromJson: CoffeeFinanceEntry.fromJson);
      final entry = entries.where((item) => item.id == entryId).firstOrNull;
      if (entry == null ||
          entry.isIncome ||
          entry.originKey != null ||
          (entry.productId != null && entry.productId != productId)) {
        throw const FormatException(
            'Escolha uma despesa disponível deste produto.');
      }
      await saveEntry(
        CoffeeFinanceEntry.fromJson(
            {...entry.toJson(), 'productId': productId}),
        pickedPdf: pickedPdf,
        pickedPdfName: pickedPdfName,
        catalogContext: catalog,
      );
    });
  }

  Future<List<CoffeeFinanceEntry>> entries({
    required String propertyId,
    required int seasonYear,
    String? plotId,
  }) async {
    FarmAccessPolicy.requireCoffeeManager();
    return [
      for (final item
          in await _entries.getAll(fromJson: CoffeeFinanceEntry.fromJson))
        if (item.propertyId == propertyId &&
            item.seasonYear == seasonYear &&
            (plotId == null || item.plotId == plotId))
          item,
    ]..sort((a, b) => b.date.compareTo(a.date));
  }

  Future<List<CoffeeFinanceEntry>> expensesForAnalysis(
      CoffeeAnalysis analysis) async {
    FarmAccessPolicy.requireCoffeeManager();
    final entries =
        await _entries.getAll(fromJson: CoffeeFinanceEntry.fromJson);
    return [
      for (final entry in entries)
        if (!entry.isIncome &&
            entry.analysisId == analysis.id &&
            entry.propertyId == analysis.propertyId &&
            entry.plotId == analysis.plotId)
          entry,
    ]..sort((first, second) => second.date.compareTo(first.date));
  }

  Future<void> saveEntry(
    CoffeeFinanceEntry entry, {
    Uint8List? pickedPdf,
    String? pickedPdfName,
    CatalogStore? catalogContext,
  }) async {
    FarmAccessPolicy.requireCoffeeManager();
    entry.validate();
    Uint8List? selected;
    if (pickedPdf != null) {
      if (pickedPdf.length > coffeeAnalysisPdfMaxBytes ||
          pickedPdfName?.toLowerCase().endsWith('.pdf') != true) {
        throw const FormatException('Selecione um arquivo PDF de até 8 MB.');
      }
      selected = Uint8List.fromList(pickedPdf);
      validateCoffeeAnalysisPdf(selected);
    }
    final catalog = catalogContext ?? await CatalogStore.open();
    await LocalWriteBatch.run(() async {
      FarmAccessPolicy.requireCoffeeManager();
      final previous =
          await _entries.getAll(fromJson: CoffeeFinanceEntry.fromJson);
      final existing =
          previous.where((item) => item.id == entry.id).firstOrNull;
      if ((entry.productId != null ||
              entry.isIncome ||
              entry.originKey != null) &&
          (await CoffeeToolsRepository().getAll())
              .any((tool) => tool.expenseId == entry.id)) {
        throw const FormatException(
            'O lançamento está vinculado a uma ferramenta.');
      }
      if (existing != null &&
          (existing.propertyId != entry.propertyId ||
              existing.seasonYear != entry.seasonYear ||
              existing.originKey != entry.originKey ||
              (existing.productId != null &&
                  entry.productId != null &&
                  existing.productId != entry.productId))) {
        throw const FormatException(
            'O lançamento já pertence a outra fazenda, safra ou origem.');
      }
      await requireCoffeeCatalogLink(
        catalog.scope,
        propertyId: entry.propertyId,
        plotId: entry.plotId,
        active: existing == null || existing.plotId != entry.plotId,
      );
      if (entry.analysisId != null) {
        final analyses = await CoffeeAnalysisRepository().list(
          propertyId: entry.propertyId,
          plotId: entry.plotId!,
        );
        if (!analyses.any((analysis) => analysis.id == entry.analysisId)) {
          throw const FormatException(
              'Escolha um laudo da mesma fazenda e do mesmo talhão.');
        }
      }
      final origin = entry.originKey;
      if (origin != null) {
        if (previous
            .any((item) => item.id != entry.id && item.originKey == origin)) {
          throw const FormatException(
              'Esse abastecimento ou manutenção já foi lançado no financeiro.');
        }
        final (DateTime date, int? amount) original;
        if (existing == null) {
          final sources = await _loadLegacySources(origin.$1);
          final source =
              sources.where((item) => item.id == origin.$2).firstOrNull;
          if (source == null) {
            throw const FormatException(
                'Escolha um registro original com valor informado.');
          }
          original = (source.date, source.amountCents);
        } else {
          original = (existing.date, existing.priceCents);
        }
        if (coffeeCivilDate(original.$1) != coffeeCivilDate(entry.date) ||
            original.$2 != entry.priceCents) {
          throw const FormatException(
              'Use a data e o valor do registro original.');
        }
      }
      final json = entry.toJson();
      if (existing?.productId != null && entry.productId == null) {
        json['productId'] = existing!.productId;
      }
      final sourcePath = json['pdfPath'] as String?;
      if (selected != null || sourcePath != null) {
        final bytes =
            selected ?? await readCoffeeAnalysisPdf(File(sourcePath!));
        json['pdfPath'] = await _storePdf(bytes);
      }
      final updated = CoffeeFinanceEntry.fromJson(json);
      if (existing != null &&
          jsonEncode(existing.toJson()) == jsonEncode(updated.toJson())) {
        return;
      }
      await _entries.saveAll(
        records: [...previous.where((item) => item.id != entry.id), updated],
        previousRecords: previous,
        idOf: (item) => item.id,
        toJson: (item) => item.toJson(),
        fromJson: CoffeeFinanceEntry.fromJson,
      );
    });
  }

  Future<void> saveReceipt(CoffeeSaleReceipt receipt) async {
    FarmAccessPolicy.requireCoffeeHarvest();
    receipt.validate();
    await LocalWriteBatch.run(() async {
      FarmAccessPolicy.requireCoffeeHarvest();
      final previous =
          await _receipts.getAll(fromJson: CoffeeSaleReceipt.fromJson);
      final existing =
          previous.where((item) => item.id == receipt.id).firstOrNull;
      if (existing != null) {
        if (jsonEncode(existing.toJson()) != jsonEncode(receipt.toJson())) {
          throw const FormatException(
              'Esse recebimento já foi registrado com outros dados.');
        }
        return;
      }
      final lot = await CoffeeProcessingRepository().getLot(
        propertyId: receipt.propertyId,
        lotId: receipt.lotId,
      );
      if (!FarmApiClient.standaloneLocalMode) {
        final db = LocalWriteBatch.current!;
        final farmId = AuthService().currentUser!.farmId!;
        final rows = await db.query('local_records',
            columns: ['sync_state'],
            where: 'farm_id=? AND module=? AND record_id=?',
            whereArgs: [farmId, FarmAccessPolicy.coffeeLotModule, lot.id]);
        if (rows.singleOrNull?['sync_state'] != 'synced') {
          throw const FormatException(
              'Sincronize a venda antes de registrar o pagamento.');
        }
        final pending = await pendingConnectedSaleIds(
            propertyId: receipt.propertyId, lotId: receipt.lotId);
        if (pending.contains(receipt.saleId)) {
          throw const FormatException(
              'Já há um recebimento desta venda na fila de sincronização.');
        }
      }
      _validateSaleReceipts(
        [
          for (final item in previous)
            if (item.lotId == receipt.lotId && item.saleId == receipt.saleId)
              item,
          receipt,
        ],
        [lot],
      );
      await _receipts.saveAll(
        records: [...previous, receipt],
        previousRecords: previous,
        idOf: (item) => item.id,
        toJson: (item) => item.toJson(),
        fromJson: CoffeeSaleReceipt.fromJson,
      );
    });
  }

  Future<List<CoffeeFinanceSale>> connectedSalesForLot({
    required String propertyId,
    required String lotId,
  }) async {
    final lot = await CoffeeProcessingRepository()
        .getLot(propertyId: propertyId, lotId: lotId);
    final records = await _connectedPaymentRows(propertyId, lotId);
    return [
      for (final sale in lot.sales)
        CoffeeFinanceSale(
          lot: lot,
          sale: sale,
          receipts: [
            for (final row in records)
              if (row.receipt.saleId == sale.id && row.state == 'synced')
                row.receipt,
          ]..sort((a, b) => b.date.compareTo(a.date)),
        ),
    ];
  }

  Future<Set<String>> pendingConnectedSaleIds({
    required String propertyId,
    required String lotId,
  }) async =>
      {
        for (final row in await _connectedPaymentRows(propertyId, lotId))
          if (row.state != 'synced') row.receipt.saleId,
      };

  Future<Map<String, CoffeeSaleReceipt>> rejectedConnectedSalePayments({
    required String propertyId,
    required String lotId,
  }) async =>
      {
        for (final row in await _connectedPaymentRows(propertyId, lotId))
          if (row.state == 'error' &&
              row.error == SyncService.rejectedSaleBalanceMessage)
            row.receipt.saleId: row.receipt,
      };

  Future<List<({CoffeeSaleReceipt receipt, String state, String? error})>>
      _connectedPaymentRows(String propertyId, String lotId) async {
    FarmAccessPolicy.requireCoffeeHarvest();
    final auth = AuthService();
    final farmId = auth.currentUser!.farmId;
    final token = auth.accessToken;
    if (farmId == null) {
      throw const FarmAccessDenied(
          'O recebimento conectado exige sessão no PC gestor.');
    }
    final db = LocalWriteBatch.current ?? await appDatabase.database;
    final rows = await db.query('local_records',
        columns: ['payload', 'sync_state', 'sync_error'],
        where: "farm_id=? AND module=? AND is_deleted=0 AND "
            r"json_extract(payload,'$.propertyId')=? AND json_extract(payload,'$.lotId')=?",
        whereArgs: [farmId, receiptsModule, propertyId, lotId]);
    FarmAccessPolicy.requireCoffeeHarvest();
    if (auth.accessToken != token || auth.currentUser?.farmId != farmId) {
      throw const FarmAccessDenied('A sessão mudou. Abra as vendas novamente.');
    }
    return [
      for (final row in rows)
        (
          receipt: CoffeeSaleReceipt.fromJson(
              jsonDecode(row['payload']! as String) as Map<String, dynamic>),
          state: row['sync_state']! as String,
          error: row['sync_error'] as String?,
        ),
    ];
  }

  Future<List<CoffeeFinanceSale>> sales({
    required String propertyId,
    required int seasonYear,
  }) async {
    FarmAccessPolicy.requireCoffeeManager();
    late List<CoffeeFinanceSale> result;
    await LocalWriteBatch.run(() async {
      final lots = await CoffeeProcessingRepository().list(
        propertyId: propertyId,
        seasonYear: seasonYear,
      );
      final bySale = <(String, String), List<CoffeeSaleReceipt>>{};
      for (final receipt
          in await _receipts.getAll(fromJson: CoffeeSaleReceipt.fromJson)) {
        if (receipt.propertyId != propertyId) continue;
        (bySale[(receipt.lotId, receipt.saleId)] ??= []).add(receipt);
      }
      result = [
        for (final lot in lots)
          for (final sale in lot.sales)
            CoffeeFinanceSale(
              lot: lot,
              sale: sale,
              receipts: (bySale[(lot.id, sale.id)] ?? [])
                ..sort((a, b) => b.date.compareTo(a.date)),
            ),
      ]..sort((a, b) => b.sale.date.compareTo(a.sale.date));
    });
    return result;
  }

  Future<CoffeeFinanceSummary> summary({
    required String propertyId,
    required int seasonYear,
    String? plotId,
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
      final day = coffeeCivilDate(date);
      return (from == null || !day.isBefore(from)) &&
          (through == null || !day.isAfter(through));
    }

    bool throughEnd(DateTime date) =>
        through == null || !coffeeCivilDate(date).isAfter(through);

    late CoffeeFinanceSummary result;
    await LocalWriteBatch.run(() async {
      final manual = await entries(
        propertyId: propertyId,
        seasonYear: seasonYear,
        plotId: plotId,
      );
      final lotSales = [
        for (final item
            in await sales(propertyId: propertyId, seasonYear: seasonYear))
          if (plotId == null || item.plotId == plotId) item,
      ];
      final harvest = CoffeeHarvestRepository();
      final harvestEntries = await harvest.entries(
        propertyId: propertyId,
        seasonYear: seasonYear,
        plotId: plotId,
      );
      final farmHarvestPayments = (await harvest.payments(
        propertyId: propertyId,
        seasonYear: seasonYear,
      ))
          .where((item) => inPeriod(item.date))
          .toList();
      final harvestPayments =
          plotId == null ? farmHarvestPayments : const <CoffeeHarvestPayment>[];

      final recognized = <CoffeeFinanceEntry>[];
      var expenses = 0;
      var revenue = 0;
      var cashIn = 0;
      var cashOut = 0;
      var unknownExpense = 0;
      var unknownRevenue = 0;
      for (final entry in manual) {
        final amount = entry.totalCents;
        if (inPeriod(entry.date)) {
          recognized.add(entry);
          if (entry.isIncome) {
            if (amount == null) {
              unknownRevenue++;
            } else {
              revenue += amount;
            }
          } else if (amount == null) {
            unknownExpense++;
          } else {
            expenses += amount;
          }
        }
        final settlement = entry.settledAt;
        if (settlement != null && amount != null && inPeriod(settlement)) {
          if (entry.isIncome) {
            cashIn += amount;
          } else {
            cashOut += amount;
          }
        }
      }
      final recognizedSales = <CoffeeFinanceSale>[];
      var outstanding = 0;
      for (final sale in lotSales) {
        final datedReceipts =
            sale.receipts.where((item) => throughEnd(item.date)).toList();
        if (throughEnd(sale.sale.date)) {
          final asOf = CoffeeFinanceSale(
            lot: sale.lot,
            sale: sale.sale,
            receipts: datedReceipts,
          );
          outstanding += asOf.outstandingCents;
          if (inPeriod(sale.sale.date)) {
            revenue += sale.sale.totalPriceCents;
            recognizedSales.add(asOf);
          }
        }
        for (final receipt in datedReceipts) {
          if (inPeriod(receipt.date)) cashIn += receipt.amountCents;
        }
      }
      var harvestCosts = 0;
      for (final entry in harvestEntries) {
        if (!inPeriod(entry.date)) continue;
        final earned = entry.earnedCents;
        if (earned == null) {
          unknownExpense++;
        } else {
          harvestCosts += earned;
        }
      }
      final harvestPaid =
          harvestPayments.fold(0, (sum, item) => sum + item.amountCents);
      result = CoffeeFinanceSummary(
        entries: List.unmodifiable(recognized),
        sales: List.unmodifiable(recognizedSales),
        knownExpenseCents: expenses + harvestCosts,
        knownRevenueCents: revenue,
        cashInCents: cashIn,
        cashOutCents: cashOut + harvestPaid,
        outstandingSalesCents: outstanding,
        unknownExpenseCount: unknownExpense,
        unknownRevenueCount: unknownRevenue,
        knownHarvestCostCents: harvestCosts,
        harvestCashPaidCents: harvestPaid,
        harvestPayments: List.unmodifiable(harvestPayments),
        hasUnallocatedHarvestPayments:
            plotId != null && farmHarvestPayments.isNotEmpty,
      );
    });
    return result;
  }

  Future<List<CoffeeFinanceLegacySource>> legacySources({
    required CoffeeFinanceOriginKind kind,
  }) async {
    FarmAccessPolicy.requireCoffeeManager();
    late List<CoffeeFinanceLegacySource> result;
    await LocalWriteBatch.run(() async {
      final current =
          await _entries.getAll(fromJson: CoffeeFinanceEntry.fromJson);
      final assigned = {
        for (final entry in current)
          if (entry.originKind == kind) entry.originId,
      };
      result = [
        for (final source in await _loadLegacySources(kind))
          if (!assigned.contains(source.id)) source,
      ]..sort((a, b) => b.date.compareTo(a.date));
    });
    return result;
  }

  Future<List<CoffeeFinanceLegacySource>> _loadLegacySources(
    CoffeeFinanceOriginKind kind,
  ) async {
    CoffeeFinanceLegacySource? build(
        String id, DateTime date, String description, double? amount) {
      final cents = amount == null ? null : amount * 100;
      if (cents == null || !cents.isFinite || cents < 0 || cents > _maxCents) {
        return null;
      }
      return CoffeeFinanceLegacySource(
        kind: kind,
        id: id,
        date: date,
        description: description,
        amountCents: cents.round(),
      );
    }

    final sources = switch (kind) {
      CoffeeFinanceOriginKind.fuel => [
          for (final row in await FuelRepository().getAll())
            build(row.id, row.date, 'Abastecimento · ${row.machineName}',
                row.totalCost),
        ],
      CoffeeFinanceOriginKind.maintenance => [
          for (final row in await MaintenanceRepository().getAll())
            build(
                row.id, row.date, '${row.type} · ${row.machineName}', row.cost),
        ],
    };
    return sources.whereType<CoffeeFinanceLegacySource>().toList();
  }
}

void validateCoffeeFinanceLinks({
  required Iterable<CoffeeFinanceEntry> entries,
  required Iterable<CoffeeSaleReceipt> receipts,
  required Iterable<CoffeeLot> lots,
  required Set<String> properties,
  required Map<String, String> plots,
}) {
  final linkedOrigins = <(CoffeeFinanceOriginKind, String)>{};
  for (final entry in entries) {
    if (!properties.contains(entry.propertyId) ||
        (entry.plotId != null && plots[entry.plotId] != entry.propertyId)) {
      throw const FormatException(
          'Um lançamento financeiro perdeu a fazenda ou o talhão.');
    }
    final key = entry.originKey;
    if (key != null && !linkedOrigins.add(key)) {
      throw const FormatException(
          'Uma despesa de origem foi lançada mais de uma vez.');
    }
  }
  _validateSaleReceipts(receipts, lots);
}

void _validateSaleReceipts(
  Iterable<CoffeeSaleReceipt> receipts,
  Iterable<CoffeeLot> lots,
) {
  final sales = <(String, String), (CoffeeLot, CoffeeLotSale)>{
    for (final lot in lots)
      for (final sale in lot.sales) (lot.id, sale.id): (lot, sale),
  };
  final received = <(String, String), int>{};
  final receiptIds = <String>{};
  for (final receipt in receipts) {
    final key = (receipt.lotId, receipt.saleId);
    final source = sales[key];
    if (!receiptIds.add(receipt.id) ||
        source == null ||
        source.$1.propertyId != receipt.propertyId ||
        coffeeCivilDate(receipt.date)
            .isBefore(coffeeCivilDate(source.$2.date))) {
      throw const FormatException(
          'Um recebimento possui vínculo inválido ou data anterior à venda.');
    }
    final sum = received.update(key, (amount) => amount + receipt.amountCents,
        ifAbsent: () => receipt.amountCents);
    if (sum > source.$2.totalPriceCents) {
      throw const FormatException('O recebimento ultrapassa o saldo da venda.');
    }
  }
}

Future<String> _storePdf(Uint8List bytes) async {
  final root = await getApplicationSupportDirectory();
  final directory =
      await openPrivateCoffeeAttachmentFolder(root, 'coffee-finance');
  final separator = Platform.pathSeparator;
  final hash = sha256.convert(bytes).toString();
  final target = File('${directory.path}$separator$hash.pdf');
  final type = await FileSystemEntity.type(target.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    final temporary =
        File('${directory.path}$separator${const Uuid().v4()}.tmp');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  } else if (type != FileSystemEntityType.file ||
      sha256.convert(await readCoffeeAnalysisPdf(target)).toString() != hash) {
    throw const FormatException('O PDF privado está danificado.');
  }
  return target.path;
}

const _maxCents = 1000000000000;

// Retain the decimal quantity through rounding to the nearest cent.
int _multiplyCents(int price, double quantity) {
  final exponentParts = quantity.toString().split('e');
  final decimalParts = exponentParts.first.split('.');
  final fraction = decimalParts.length == 2 ? decimalParts.last : '';
  final exponent =
      exponentParts.length == 2 ? int.parse(exponentParts.last) : 0;
  final decimalPlaces = fraction.length - exponent;
  final numerator = BigInt.parse(decimalParts.join()) * BigInt.from(price);
  final ten = BigInt.from(10);
  if (decimalPlaces <= 0) {
    return (numerator * ten.pow(-decimalPlaces)).toInt();
  }
  final divisor = ten.pow(decimalPlaces);
  return ((numerator + divisor ~/ BigInt.two) ~/ divisor).toInt();
}

bool _validId(String value) => value.trim().isNotEmpty && value.length <= 160;
bool _validDate(DateTime value) => value.year >= 1900 && value.year <= 9999;
