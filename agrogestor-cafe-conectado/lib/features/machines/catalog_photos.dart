import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../operations_v2/v2_store.dart';
import '../work/work_store.dart';
import '../sync/sync_service.dart';

class CatalogPhotoStore {
  CatalogPhotoStore(this.core, {this.sessionValid});
  final V2Store core;
  final bool Function()? sessionValid;
  void checkSession() {
    if (sessionValid?.call() == false) {
      throw StateError('Sua sessão mudou. Abra as fotos novamente.');
    }
  }

  static final Map<String, Future<void>> _syncs = {};
  static Future<CatalogPhotoStore> open() async {
    final work = await WorkStore.open();
    final core = work.core;
    await initialize(core);
    return CatalogPhotoStore(core, sessionValid: work.sessionValid);
  }

  static Future<void> initialize(V2Store core) async {
    await core.db.execute('''CREATE TABLE IF NOT EXISTS catalog_photo_outbox (
      scope TEXT NOT NULL,id TEXT NOT NULL,kind TEXT NOT NULL,target_id TEXT NOT NULL,
      path TEXT NOT NULL,state TEXT NOT NULL,error TEXT,created_at TEXT NOT NULL,
      PRIMARY KEY(scope,id))''');
  }

  Future<List<Json>> pending() async =>
      (await core.db.query('catalog_photo_outbox',
              where: 'scope=? AND state!=?',
              whereArgs: [core.scope, 'archived'],
              orderBy: 'created_at,id'))
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
  Future<void> retry(Json row) async {
    checkSession();
    final permission =
        await refresh(row['kind'] as String, row['target_id'] as String);
    if (permission['can_edit'] != true) {
      throw StateError('Esta conta não pode enviar fotos para o cadastro.');
    }
    await core.db.update(
        'catalog_photo_outbox', {'state': 'pending', 'error': null},
        where: 'scope=? AND id=? AND state=?',
        whereArgs: [core.scope, row['id'], 'conflict']);
    await sync();
  }

  Future<void> archiveConflict(Json row) async {
    checkSession();
    // Explicit acknowledgement only. Retain the image and rejected evidence.
    await core.db.update('catalog_photo_outbox', {'state': 'archived'},
        where: 'scope=? AND id=? AND state=?',
        whereArgs: [core.scope, row['id'], 'conflict']);
  }

  Future<Json> refresh(String kind, String target) async {
    checkSession();
    try {
      final value = await core.client.v2('GET', '/work/$kind/$target/photos');
      checkSession();
      await core.cache('photos:$kind:$target', value);
      return value;
    } on DioException catch (error) {
      if ([401, 403, 404].contains(error.response?.statusCode)) {
        await core.db.delete('v2_mobile_cache',
            where: 'scope=? AND cache_key=?',
            whereArgs: [core.scope, 'photos:$kind:$target']);
      }
      rethrow;
    }
  }

  Future<void> add(String kind, String target, XFile photo) async {
    checkSession();
    if ((await core.cached('photos:$kind:$target'))?['can_edit'] != true) {
      throw StateError(
          'Conecte ao PC gestor para confirmar acesso ao cadastro antes de anexar.');
    }
    if (await photo.length() > 8 * 1024 * 1024) {
      throw StateError('Selecione uma imagem JPEG/PNG de até 8 MB.');
    }
    final id = const Uuid().v4();
    final folder =
        Directory('${File(core.db.path).parent.path}/catalog_photos');
    await folder.create(recursive: true);
    final file = File('${folder.path}/$id');
    await photo.saveTo(file.path);
    checkSession();
    await core.db.insert('catalog_photo_outbox', {
      'scope': core.scope,
      'id': id,
      'kind': kind,
      'target_id': target,
      'path': file.path,
      'state': 'pending',
      'created_at': core.now().toUtc().toIso8601String()
    });
  }

  Future<void> sync() => _syncs[core.scope] ??= _drain().whenComplete(() {
        _syncs.remove(core.scope);
      });
  Future<void> _drain() async {
    for (final row in await pending()) {
      checkSession();
      if (row['state'] != 'pending') continue;
      try {
        await refresh(row['kind'] as String, row['target_id'] as String);
        await core.client.uploadWorkPhoto(
            row['kind'] as String,
            row['target_id'] as String,
            row['id'] as String,
            row['path'] as String);
        await core.db.delete('catalog_photo_outbox',
            where: 'scope=? AND id=?', whereArgs: [core.scope, row['id']]);
        // Keep the private local file for offline viewing. It is never shared by raw path.
      } on DioException catch (error) {
        if ([401, 403, 404, 409, 413, 422]
            .contains(error.response?.statusCode)) {
          await core.db.update('catalog_photo_outbox',
              {'state': 'conflict', 'error': v2Error(error)},
              where: 'scope=? AND id=?', whereArgs: [core.scope, row['id']]);
          continue;
        }
        rethrow;
      }
    }
  }
}

class CatalogPhotosScreen extends StatefulWidget {
  const CatalogPhotosScreen(
      {super.key,
      required this.kind,
      required this.targetId,
      required this.name});
  final String kind, targetId, name;
  @override
  State<CatalogPhotosScreen> createState() => _CatalogPhotosScreenState();
}

class _CatalogPhotosScreenState extends State<CatalogPhotosScreen> {
  CatalogPhotoStore? _store;
  final Map<String, Uint8List> _bytes = {};
  List<Json> _photos = [], _pending = [];
  bool _busy = false, _authorized = false, _canEdit = false;
  String? _message;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final store = _store ??= await CatalogPhotoStore.open();
      Json? value;
      try {
        value = await store.refresh(widget.kind, widget.targetId);
      } catch (error) {
        if (store.sessionValid?.call() == false) rethrow;
        value =
            await store.core.cached('photos:${widget.kind}:${widget.targetId}');
        _message = v2Error(error);
      }
      if (value == null) {
        if (mounted) {
          setState(() {
            _authorized = false;
            _bytes.clear();
            _photos = [];
            _pending = [];
          });
        }
        return;
      }
      final photos = items(value, 'items');
      final pending = (await store.pending())
          .where((p) =>
              p['kind'] == widget.kind && p['target_id'] == widget.targetId)
          .toList();
      if (!mounted) return;
      setState(() {
        _authorized = true;
        _canEdit = value!['can_edit'] == true;
        _photos = photos;
        _pending = pending;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = v2Error(error);
          if (_store?.sessionValid?.call() == false) {
            _authorized = false;
            _canEdit = false;
            _photos = [];
            _pending = [];
            _bytes.clear();
          }
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _add(ImageSource source) async {
    try {
      final image = await ImagePicker().pickImage(
          source: source, maxWidth: 2200, maxHeight: 2200, imageQuality: 85);
      if (image == null || !mounted) return;
      await _store!.add(widget.kind, widget.targetId, image);
      SyncService().notifyLocalChange();
      try {
        await _store!.sync();
      } catch (_) {/* Kept in durable outbox. */}
      await _load();
    } catch (error) {
      if (mounted) setState(() => _message = v2Error(error));
    }
  }

  Future<void> _viewPhoto(String id) async {
    try {
      _store!.checkSession();
      final bytes =
          await _store!.core.client.workPhoto(widget.kind, widget.targetId, id);
      _store!.checkSession();
      if (!mounted) return;
      setState(() {
        // Bound memory even when a machine has years of photo history.
        if (_bytes.length >= 3) _bytes.remove(_bytes.keys.first);
        _bytes[id] = Uint8List.fromList(bytes);
      });
    } catch (error) {
      if (mounted) setState(() => _message = v2Error(error));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: Text('Fotos: ${widget.name}')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (_busy) const LinearProgressIndicator(),
        if (_message != null) Text(_message!),
        if (_authorized && _canEdit)
          Wrap(spacing: 8, children: [
            OutlinedButton.icon(
                onPressed: _busy ? null : () => _add(ImageSource.gallery),
                icon: const Icon(Icons.photo_library),
                label: const Text('Galeria')),
            OutlinedButton.icon(
                onPressed: _busy ? null : () => _add(ImageSource.camera),
                icon: const Icon(Icons.camera_alt),
                label: const Text('Câmera')),
          ]),
        for (final photo in _photos)
          Card(
              child: Column(children: [
            if (_bytes[photo['id']] != null)
              Image.memory(_bytes[photo['id']]!,
                  height: 240,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Text('Imagem inválida.'))
            else
              const Padding(
                  padding: EdgeInsets.all(24),
                  child: Icon(Icons.photo_outlined, size: 48)),
            Text('Registrada em ${photo['created_at']}'),
            TextButton.icon(
                onPressed: () => _viewPhoto(photo['id'] as String),
                icon: const Icon(Icons.visibility),
                label: const Text('Ver foto')),
          ])),
        for (final photo in _pending)
          Card(
              child: Column(children: [
            if (_authorized)
              Image.file(File(photo['path'] as String),
                  height: 200,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Text(
                      'Arquivo local indisponível; registro preservado.')),
            Text(
                '${photo['state'] == 'conflict' ? 'Precisa de revisão' : 'Aguardando envio'}: ${photo['error'] ?? 'Foto salva neste aparelho.'}'),
            if (photo['state'] == 'conflict')
              Wrap(spacing: 8, children: [
                if (_canEdit)
                  TextButton(
                      onPressed: () async {
                        try {
                          await _store!.retry(photo);
                        } catch (error) {
                          if (mounted) {
                            setState(() => _message = v2Error(error));
                          }
                        }
                        await _load();
                      },
                      child: const Text('Tentar enviar novamente')),
                TextButton(
                    onPressed: () async {
                      final accepted = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                                  title: const Text('Arquivar esta pendência?'),
                                  content: const Text(
                                      'A foto e o registro de erro serão preservados neste aparelho. Nenhuma foto confirmada no PC será removida.'),
                                  actions: [
                                    TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, false),
                                        child: const Text('Cancelar')),
                                    FilledButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: const Text('Arquivar'))
                                  ]));
                      if (accepted == true && mounted) {
                        try {
                          await _store!.archiveConflict(photo);
                          await _load();
                        } catch (error) {
                          if (mounted) {
                            setState(() => _message = v2Error(error));
                          }
                        }
                      }
                    },
                    child: const Text('Arquivar pendência')),
              ]),
          ])),
        if (_authorized && _photos.isEmpty && _pending.isEmpty)
          const Text('Nenhuma fotografia cadastrada.'),
        OutlinedButton.icon(
            onPressed: _busy
                ? null
                : () async {
                    try {
                      await _store?.sync();
                    } catch (error) {
                      if (mounted) setState(() => _message = v2Error(error));
                    }
                    await _load();
                  },
            icon: const Icon(Icons.sync),
            label: const Text('Atualizar fotografias')),
      ]));
}
