import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../auth/farm_access_policy.dart';
import '../properties/catalog_store.dart';
import '../properties/plot_notebook_repository.dart';
import '../services/farm_service.dart';
import '../services/service_repository.dart';
import '../sync/local_sync_collection_store.dart';
import '../sync/local_write_batch.dart';

enum CoffeeAnalysisType { soil, leaf }

class CoffeeAnalysisResult {
  const CoffeeAnalysisResult({
    required this.indicator,
    required this.unit,
    required this.value,
    this.method = '',
    this.referenceMin,
    this.referenceMax,
    this.referenceSource = '',
  });

  final String indicator, unit, method;
  final double value;
  final double? referenceMin, referenceMax;
  final String referenceSource;

  String? get referencePosition {
    final minimum = referenceMin;
    final maximum = referenceMax;
    if (minimum == null || maximum == null) return null;
    if (value < minimum) return 'Abaixo da faixa informada';
    if (value > maximum) return 'Acima da faixa informada';
    return 'Dentro da faixa informada';
  }

  bool get hasValidReference {
    final minimum = referenceMin;
    final maximum = referenceMax;
    if (minimum == null && maximum == null) {
      return referenceSource.trim().isEmpty;
    }
    return minimum != null &&
        maximum != null &&
        minimum.isFinite &&
        maximum.isFinite &&
        minimum < maximum &&
        referenceSource.trim().isNotEmpty &&
        referenceSource.length <= 240;
  }

  Map<String, Object?> toJson() => {
        'indicator': indicator.trim(),
        'unit': unit.trim(),
        'value': value,
        'method': method.trim(),
        if (referenceMin != null) 'referenceMin': referenceMin,
        if (referenceMax != null) 'referenceMax': referenceMax,
        if (referenceSource.trim().isNotEmpty)
          'referenceSource': referenceSource.trim(),
      };

  factory CoffeeAnalysisResult.fromJson(Map<String, dynamic> json) =>
      CoffeeAnalysisResult(
        indicator: json['indicator'] as String,
        unit: json['unit'] as String,
        value: (json['value'] as num).toDouble(),
        method: json['method'] as String? ?? '',
        referenceMin: (json['referenceMin'] as num?)?.toDouble(),
        referenceMax: (json['referenceMax'] as num?)?.toDouble(),
        referenceSource: json['referenceSource'] as String? ?? '',
      );
}

class CoffeeAnalysis {
  const CoffeeAnalysis({
    required this.id,
    required this.propertyId,
    required this.plotId,
    required this.type,
    required this.collectedAt,
    required this.laboratory,
    required this.sampleId,
    this.context = '',
    this.pdfPath,
    this.results = const [],
    this.agronomistGuidance = '',
    this.operationId,
  });

  final String id, propertyId, plotId, laboratory, sampleId, context;
  final String agronomistGuidance;
  final String? pdfPath, operationId;
  final CoffeeAnalysisType type;
  final DateTime collectedAt;
  final List<CoffeeAnalysisResult> results;

  Map<String, Object?> toJson() => {
        'id': id,
        'propertyId': propertyId,
        'plotId': plotId,
        'type': type.name,
        'collectedAt':
            DateTime(collectedAt.year, collectedAt.month, collectedAt.day)
                .toIso8601String(),
        'laboratory': laboratory.trim(),
        'sampleId': sampleId.trim(),
        'context': context.trim(),
        if (pdfPath?.trim().isNotEmpty == true) 'pdfPath': pdfPath,
        'results': [for (final result in results) result.toJson()],
        'agronomistGuidance': agronomistGuidance.trim(),
        if (operationId?.isNotEmpty == true) 'operationId': operationId,
      };

  factory CoffeeAnalysis.fromJson(Map<String, dynamic> json) => CoffeeAnalysis(
        id: json['id'] as String,
        propertyId: json['propertyId'] as String,
        plotId: json['plotId'] as String,
        type: CoffeeAnalysisType.values.byName(json['type'] as String),
        collectedAt: DateTime.parse(json['collectedAt'] as String),
        laboratory: json['laboratory'] as String,
        sampleId: json['sampleId'] as String,
        context: json['context'] as String,
        pdfPath: json['pdfPath'] as String?,
        results: [
          for (final result in json['results'] as List)
            CoffeeAnalysisResult.fromJson(result as Map<String, dynamic>),
        ],
        agronomistGuidance: json['agronomistGuidance'] as String,
        operationId: json['operationId'] as String?,
      );

  void validate() {
    if ([id, propertyId, plotId, laboratory, sampleId]
            .any((field) => field.trim().isEmpty || field.length > 160) ||
        (operationId?.length ?? 0) > 160 ||
        context.length > 1000 ||
        agronomistGuidance.length > 4000 ||
        results.length > 100) {
      throw const FormatException(
        'Confira a data, o laboratório e a identificação da amostra.',
      );
    }
    final indicators = <String>{};
    for (final result in results) {
      if (!result.hasValidReference) {
        throw const FormatException(
          'Confira os limites e a fonte da faixa de referência.',
        );
      }
      if (result.indicator.trim().isEmpty ||
          result.unit.trim().isEmpty ||
          result.indicator.length > 160 ||
          result.unit.length > 80 ||
          result.method.length > 160 ||
          !result.value.isFinite ||
          !indicators.add(_normalize(result.indicator))) {
        throw const FormatException(
          'Use indicadores únicos e informe unidade e valor válido em cada resultado.',
        );
      }
    }
  }

  bool canLinkOperation(FarmService operation) =>
      operation.propertyId == propertyId &&
      operation.fieldId == plotId &&
      operation.isFinished &&
      !operation.isCancelled;
}

class CoffeeAnalysisComparisonRow {
  const CoffeeAnalysisComparisonRow({
    required this.indicator,
    this.first,
    this.second,
    this.difference,
  });

  final String indicator;
  final CoffeeAnalysisResult? first, second;
  final double? difference;
}

class CoffeeAnalysisComparison {
  const CoffeeAnalysisComparison({
    required this.contextsCompatible,
    required this.rows,
  });

  final bool contextsCompatible;
  final List<CoffeeAnalysisComparisonRow> rows;
}

String _normalize(String value) =>
    value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

CoffeeAnalysisComparison compareCoffeeAnalyses(
  CoffeeAnalysis first,
  CoffeeAnalysis second,
) {
  final contextsCompatible = first.propertyId == second.propertyId &&
      first.plotId == second.plotId &&
      first.type == second.type &&
      first.context.trim().isNotEmpty &&
      _normalize(first.context) == _normalize(second.context);
  final older = {
    for (final result in first.results) _normalize(result.indicator): result,
  };
  final newer = {
    for (final result in second.results) _normalize(result.indicator): result,
  };
  final rows = <CoffeeAnalysisComparisonRow>[];
  for (final key in {...older.keys, ...newer.keys}) {
    final a = older[key];
    final b = newer[key];
    // Unit symbols are case-sensitive (for example, m and M are different).
    final difference = contextsCompatible &&
            a != null &&
            b != null &&
            a.unit.trim().isNotEmpty &&
            a.unit.trim() == b.unit.trim() &&
            a.method.trim().isNotEmpty &&
            _normalize(a.method) == _normalize(b.method)
        ? b.value - a.value
        : null;
    rows.add(CoffeeAnalysisComparisonRow(
      indicator: (a ?? b!).indicator,
      first: a,
      second: b,
      difference: difference?.isFinite == true ? difference : null,
    ));
  }
  return CoffeeAnalysisComparison(
    contextsCompatible: contextsCompatible,
    rows: List.unmodifiable(rows),
  );
}

class CoffeeAnalysisRepository {
  static final _store = LocalSyncCollectionStore<CoffeeAnalysis>(
    module: 'coffeeAnalyses',
    legacyKey: FarmAccessPolicy.coffeeProductionModules['coffeeAnalyses']!,
  );

  Future<List<CoffeeAnalysis>> list({
    required String propertyId,
    required String plotId,
    CoffeeAnalysisType? type,
  }) async {
    FarmAccessPolicy.requireCoffeeManager();
    return [
      for (final analysis
          in await _store.getAll(fromJson: CoffeeAnalysis.fromJson))
        if (analysis.propertyId == propertyId &&
            analysis.plotId == plotId &&
            (type == null || analysis.type == type))
          analysis,
    ]..sort((a, b) => b.collectedAt.compareTo(a.collectedAt));
  }

  Future<List<FarmService>> completedOperations({
    required String propertyId,
    required String plotId,
  }) async {
    FarmAccessPolicy.requireCoffeeManager();
    return [
      for (final service in await ServiceRepository().getAll())
        if (service.propertyId == propertyId &&
            service.fieldId == plotId &&
            service.isFinished &&
            !service.isCancelled)
          service,
    ]..sort((a, b) =>
        (b.endedAt ?? b.startedAt).compareTo(a.endedAt ?? a.startedAt));
  }

  Future<void> save(
    CoffeeAnalysis analysis, {
    Uint8List? pickedPdf,
    String? pickedPdfName,
  }) async {
    FarmAccessPolicy.requireCoffeeManager();
    analysis.validate();
    if (pickedPdf != null && pickedPdf.length > coffeeAnalysisPdfMaxBytes) {
      throw const FormatException('O arquivo PDF excede 8 MB.');
    }
    final selectedBytes =
        pickedPdf == null ? null : Uint8List.fromList(pickedPdf);
    if (selectedBytes != null) {
      if (pickedPdfName?.toLowerCase().endsWith('.pdf') != true) {
        throw const FormatException('Selecione um arquivo com extensão PDF.');
      }
      validateCoffeeAnalysisPdf(selectedBytes);
    }
    final catalog = await CatalogStore.open();
    await LocalWriteBatch.run(() async {
      FarmAccessPolicy.requireCoffeeManager();
      final previous = await _store.getAll(fromJson: CoffeeAnalysis.fromJson);
      final existing =
          previous.where((item) => item.id == analysis.id).firstOrNull;
      if (existing != null &&
          (existing.propertyId != analysis.propertyId ||
              existing.plotId != analysis.plotId ||
              existing.type != analysis.type)) {
        throw const FormatException(
            'A análise pertence a outro talhão ou tipo.');
      }
      await requireCoffeeCatalogLink(
        catalog.scope,
        propertyId: analysis.propertyId,
        plotId: analysis.plotId,
        active: existing == null,
      );
      final operationId = analysis.operationId;
      if (operationId != null && operationId.isNotEmpty) {
        final operations = await completedOperations(
          propertyId: analysis.propertyId,
          plotId: analysis.plotId,
        );
        if (!operations.any((operation) => operation.id == operationId)) {
          throw const FormatException(
            'Vincule uma operação concluída neste talhão.',
          );
        }
      }
      final json = analysis.toJson();
      final selectedPath = json['pdfPath'] as String?;
      if (selectedBytes != null || selectedPath != null) {
        final bytes =
            selectedBytes ?? await readCoffeeAnalysisPdf(File(selectedPath!));
        final directory = await getApplicationSupportDirectory();
        final separator = Platform.pathSeparator;
        final folder = await openPrivateCoffeeAttachmentFolder(
          directory,
          'coffee-analyses',
        );
        final path = folder.path;
        final digest = sha256.convert(bytes).toString();
        final target = File('$path$separator$digest.pdf');
        final targetType =
            await FileSystemEntity.type(target.path, followLinks: false);
        if (targetType == FileSystemEntityType.notFound) {
          final temporary = File('$path$separator${const Uuid().v4()}.tmp');
          try {
            await temporary.writeAsBytes(bytes, flush: true);
            await temporary.rename(target.path);
          } finally {
            if (await temporary.exists()) await temporary.delete();
          }
        } else if (targetType != FileSystemEntityType.file ||
            sha256.convert(await readCoffeeAnalysisPdf(target)).toString() !=
                digest) {
          throw const FormatException('O PDF privado está danificado.');
        }
        json['pdfPath'] = target.path;
      }
      final updated = CoffeeAnalysis.fromJson(json);
      await _store.saveAll(
        records: [...previous.where((item) => item.id != analysis.id), updated],
        previousRecords: previous,
        idOf: (item) => item.id,
        toJson: (item) => item.toJson(),
        fromJson: CoffeeAnalysis.fromJson,
      );
    });
  }
}

const coffeeAnalysisPdfMaxBytes = 8 * 1024 * 1024;

Future<Directory> openPrivateCoffeeAttachmentFolder(
  Directory supportDirectory,
  String child,
) async {
  if (!RegExp(r'^[a-z0-9-]+$').hasMatch(child)) {
    throw ArgumentError.value(child, 'child');
  }
  final root = await supportDirectory.resolveSymbolicLinks();
  final separator = Platform.pathSeparator;
  Future<Directory> createFolder(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    final folder = Directory(path);
    if (type == FileSystemEntityType.notFound) {
      await folder.create();
    } else if (type != FileSystemEntityType.directory) {
      throw const FormatException('A pasta privada de anexos é inválida.');
    }
    if (await folder.resolveSymbolicLinks() != path) {
      throw const FormatException('A pasta privada de anexos é inválida.');
    }
    return folder;
  }

  final attachments = await createFolder('$root${separator}attachments');
  return createFolder('${attachments.path}$separator$child');
}

Future<Uint8List> readCoffeeAnalysisPdf(File file) async {
  if (!file.path.toLowerCase().endsWith('.pdf') ||
      !await file.exists() ||
      await file.length() > coffeeAnalysisPdfMaxBytes) {
    throw const FormatException('Selecione um arquivo PDF de até 8 MB.');
  }
  final bytes = await file.openRead().fold<BytesBuilder>(
    BytesBuilder(copy: false),
    (result, chunk) {
      if (result.length + chunk.length > coffeeAnalysisPdfMaxBytes) {
        throw const FormatException('O arquivo PDF excede 8 MB.');
      }
      return result..add(chunk);
    },
  );
  final content = bytes.takeBytes();
  validateCoffeeAnalysisPdf(content);
  return content;
}

void validateCoffeeAnalysisPdf(Uint8List content) {
  if (content.length < 13 || content.length > coffeeAnalysisPdfMaxBytes) {
    throw const FormatException('Selecione um arquivo PDF válido de até 8 MB.');
  }
  final header = latin1.decode(content.sublist(0, 9));
  final end = latin1.decode(content.sublist(
    content.length > 1024 ? content.length - 1024 : 0,
  ));
  if (!RegExp(r'^%PDF-(1\.[0-7]|2\.0)[\r\n]').hasMatch(header) ||
      !RegExp(r'%%EOF[\x00\x09\x0a\x0c\x0d\x20]*$').hasMatch(end)) {
    throw const FormatException(
        'O arquivo não contém um documento PDF válido.');
  }
}
