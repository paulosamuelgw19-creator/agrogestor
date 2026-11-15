import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../auth/auth_service.dart';
import '../auth/farm_access_policy.dart';
import '../services/service_repository.dart';
import '../sync/farm_api_client.dart';
import '../sync/local_sync_collection_store.dart';
import '../sync/local_write_batch.dart';
import 'catalog_store.dart';

enum PlotNoteStatus { note, open, resolved }

class PlotNote {
  const PlotNote({
    required this.id,
    required this.propertyId,
    required this.plotId,
    required this.date,
    required this.text,
    this.photoPath,
    this.photoAttachmentId,
    this.status = PlotNoteStatus.note,
    this.followUpOn,
    this.inspection = false,
    this.operationId,
  });

  final String id, propertyId, plotId, text;
  final DateTime date;
  final DateTime? followUpOn;
  final String? photoPath, photoAttachmentId;
  final String? operationId;
  final bool inspection;
  final PlotNoteStatus status;

  Map<String, Object?> toJson() => {
        'id': id,
        'propertyId': propertyId,
        'plotId': plotId,
        'date': date.toIso8601String(),
        'text': text,
        if (photoPath != null) 'photoPath': photoPath,
        if (photoAttachmentId != null) 'photoAttachmentId': photoAttachmentId,
        'status': status.name,
        if (followUpOn != null) 'followUpOn': followUpOn!.toIso8601String(),
        if (inspection) 'inspection': true,
        if (operationId != null) 'operationId': operationId,
      };

  factory PlotNote.fromJson(Map<String, dynamic> json) => PlotNote(
        id: json['id'] as String,
        propertyId: json['propertyId'] as String,
        plotId: json['plotId'] as String,
        date: DateTime.parse(json['date'] as String),
        text: json['text'] as String,
        photoPath: json['photoPath'] as String?,
        photoAttachmentId: json['photoAttachmentId'] as String?,
        status: PlotNoteStatus.values.byName(json['status'] as String),
        followUpOn: json['followUpOn'] == null
            ? null
            : DateTime.parse(json['followUpOn'] as String),
        inspection: json['inspection'] == true,
        operationId: json['operationId'] as String?,
      );

  void validate() {
    if ([id, propertyId, plotId]
            .any((id) => id.trim().isEmpty || id.length > 160) ||
        (text.trim().isEmpty &&
            (photoPath == null || photoPath!.trim().isEmpty) &&
            (FarmApiClient.standaloneLocalMode || photoAttachmentId == null)) ||
        (photoAttachmentId != null &&
            !RegExp(r'^[A-Za-z0-9_-]{16,80}$').hasMatch(photoAttachmentId!)) ||
        text.trim().length > 4000 ||
        (followUpOn != null && status == PlotNoteStatus.note) ||
        (operationId != null &&
            (status != PlotNoteStatus.resolved ||
                operationId!.trim().isEmpty))) {
      throw const FormatException(
          'Informe o talhão e acrescente um texto de até 4 mil caracteres ou uma foto.');
    }
  }
}

class PlotNotebookRepository {
  static final _store = LocalSyncCollectionStore<PlotNote>(
    module: FarmAccessPolicy.plotNotebookModule,
    legacyKey: FarmAccessPolicy
        .coffeeLocalModules[FarmAccessPolicy.plotNotebookModule]!,
  );

  Future<List<PlotNote>> list({
    required String propertyId,
    required String plotId,
  }) async {
    final session = _session();
    final notes = await _store.getAll(fromJson: PlotNote.fromJson);
    _checkSession(session);
    return [
      for (final note in notes)
        if (note.propertyId == propertyId && note.plotId == plotId) note,
    ]..sort((a, b) => b.date.compareTo(a.date));
  }

  Future<void> save(PlotNote note) async {
    final session = _session();
    note.validate();
    final catalog = await CatalogStore.open();
    File? copiedPhoto;
    try {
      await LocalWriteBatch.run(() async {
        _checkSession(session);
        final previous = await _store.getAll(fromJson: PlotNote.fromJson);
        final existing =
            previous.where((item) => item.id == note.id).firstOrNull;
        if (existing != null &&
            (existing.propertyId != note.propertyId ||
                existing.plotId != note.plotId)) {
          throw const FormatException('A anotação pertence a outro talhão.');
        }
        await requireCoffeeCatalogLink(
          catalog.scope,
          propertyId: note.propertyId,
          plotId: note.plotId,
          active: existing == null,
          confirmedUntil:
              FarmApiClient.standaloneLocalMode ? null : catalog.tokenExpiry,
        );
        await _validateOperation(
            note.operationId, note.propertyId, note.plotId);
        String? photoPath;
        final selected = note.photoPath;
        if (selected != null && selected.isNotEmpty) {
          final source = File(selected);
          final root = await getApplicationSupportDirectory();
          final attachments =
              Directory('${root.path}${Platform.pathSeparator}attachments');
          await attachments.create(recursive: true);
          final resolved = await source.resolveSymbolicLinks();
          final allowed = await attachments.resolveSymbolicLinks();
          final size = await source.length();
          if (size <= 0 || size > 8 * 1024 * 1024) {
            throw const FormatException('Escolha uma foto de até 8 MB.');
          }
          if (resolved.startsWith('$allowed${Platform.pathSeparator}')) {
            photoPath = resolved;
          } else {
            final target = File(
              '$allowed${Platform.pathSeparator}plot-note-${const Uuid().v4()}.img',
            );
            copiedPhoto = target;
            await source.copy(target.path);
            photoPath = target.path;
          }
        }
        await _save(
            previous,
            PlotNote(
              id: note.id,
              propertyId: note.propertyId,
              plotId: note.plotId,
              date: note.date,
              text: note.text.trim(),
              photoPath: photoPath,
              photoAttachmentId: existing?.photoPath == photoPath
                  ? existing?.photoAttachmentId
                  : null,
              status: note.status,
              followUpOn: note.followUpOn,
              inspection: note.inspection,
              operationId: note.operationId,
            ));
      });
    } catch (_) {
      final photo = copiedPhoto;
      if (photo != null && await photo.exists()) await photo.delete();
      rethrow;
    }
  }

  Future<void> setStatus({
    required String propertyId,
    required String plotId,
    required String id,
    required PlotNoteStatus status,
    String? operationId,
    PlotNoteStatus? expectedStatus,
  }) async {
    final session = _session();
    final catalog =
        FarmApiClient.standaloneLocalMode ? null : await CatalogStore.open();
    await LocalWriteBatch.run(() async {
      _checkSession(session);
      final previous = await _store.getAll(fromJson: PlotNote.fromJson);
      final note = previous
          .where((item) =>
              item.id == id &&
              item.propertyId == propertyId &&
              item.plotId == plotId)
          .firstOrNull;
      if (note == null) {
        throw const FormatException('Anotação não encontrada neste talhão.');
      }
      if (expectedStatus != null && note.status != expectedStatus) {
        throw const FormatException(
            'A pendência mudou. Abra o caderno novamente.');
      }
      if (note.status == status &&
          (operationId == null || note.operationId == operationId)) {
        return;
      }
      if (status == PlotNoteStatus.note || note.status == PlotNoteStatus.note) {
        throw const FormatException(
            'Somente pendências podem mudar de estado.');
      }
      if (operationId != null && status != PlotNoteStatus.resolved) {
        throw const FormatException(
            'Conclua a pendência para vincular o serviço.');
      }
      if (catalog != null) {
        await requireCoffeeCatalogLink(
          catalog.scope,
          propertyId: propertyId,
          plotId: plotId,
          confirmedUntil: catalog.tokenExpiry,
        );
      }
      await _validateOperation(operationId, propertyId, plotId);
      await _save(
          previous,
          PlotNote(
            id: note.id,
            propertyId: note.propertyId,
            plotId: note.plotId,
            date: note.date,
            text: note.text,
            photoPath: note.photoPath,
            photoAttachmentId: note.photoAttachmentId,
            status: status,
            followUpOn: note.followUpOn,
            inspection: note.inspection,
            operationId: operationId,
          ));
    });
  }

  Future<void> _validateOperation(
    String? operationId,
    String propertyId,
    String plotId,
  ) async {
    if (operationId == null) return;
    if (!FarmApiClient.standaloneLocalMode) {
      throw const FormatException(
        'O vínculo com serviço está disponível no caderno local.',
      );
    }
    final services = await ServiceRepository().getAll();
    if (!services.any((service) =>
        service.id == operationId &&
        service.propertyId == propertyId &&
        service.fieldId == plotId &&
        service.isFinished &&
        !service.isCancelled)) {
      throw const FormatException('Escolha um serviço concluído deste talhão.');
    }
  }

  (String, String?, String?) _session() {
    FarmAccessPolicy.requirePlotNotebook();
    final auth = AuthService();
    final user = auth.currentUser!;
    return (user.id, user.farmId, auth.accessToken);
  }

  void _checkSession((String, String?, String?) expected) {
    if (_session() != expected) {
      throw const FarmAccessDenied('A sessão mudou. Abra o caderno novamente.');
    }
  }

  Future<void> _save(List<PlotNote> previous, PlotNote note) => _store.saveAll(
        records: [...previous.where((item) => item.id != note.id), note],
        previousRecords: previous,
        idOf: (item) => item.id,
        toJson: (item) => item.toJson(),
        fromJson: PlotNote.fromJson,
      );
}

/// Validates the current catalog links inside the same write transaction.
Future<void> requireCoffeeCatalogLink(
  String scope, {
  required String propertyId,
  String? plotId,
  bool active = false,
  DateTime? confirmedUntil,
}) async {
  final transaction = LocalWriteBatch.current!;
  Future<Map<String, dynamic>?> record(String kind, String id) async {
    final rows = await transaction.query(
      'catalog_records',
      columns: ['payload', 'origin', 'state', 'expires_at'],
      where: 'scope=? AND kind=? AND id=?',
      whereArgs: [scope, kind, id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.single;
    if (confirmedUntil != null) {
      final expiry = DateTime.tryParse(row['expires_at'] as String? ?? '');
      final now = DateTime.now();
      if (row['origin'] != 'server' ||
          row['state'] != 'synced' ||
          expiry == null ||
          !now.isBefore(expiry) ||
          !now.isBefore(confirmedUntil)) {
        return null;
      }
    }
    final data = jsonDecode(row['payload'] as String) as Map<String, dynamic>;
    return active && data['archived'] == 1 ? null : data;
  }

  if (await record('properties', propertyId) == null) {
    throw const FormatException('Selecione uma fazenda disponível.');
  }
  if (plotId != null) {
    final plot = await record('plots', plotId);
    if (plot == null || plot['property_id'] != propertyId) {
      throw const FormatException('Selecione um talhão desta fazenda.');
    }
  }
}
