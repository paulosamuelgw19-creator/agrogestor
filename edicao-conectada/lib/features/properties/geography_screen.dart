import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';
import 'package:sqflite/sqflite.dart';
import '../operations_v2/v2_store.dart';
import '../operations_v2/v2_export.dart';
import '../operations_v2/management_reports_screen.dart';
import '../sync/sync_service.dart';
import 'geography_store.dart';

class GeographyScreen extends StatefulWidget {
  const GeographyScreen(
      {super.key,
      required this.propertyId,
      this.store,
      this.initialBackground = 'streets'});
  final String propertyId;
  final GeographyStore? store;
  final String initialBackground;
  @override
  State<GeographyScreen> createState() => _GeographyScreenState();
}

class _GeographyScreenState extends State<GeographyScreen> {
  static const _mapKey =
      String.fromEnvironment('AGROGESTOR_MAPTILER_PUBLIC_KEY');
  final _controller = MapController();
  final _search = TextEditingController();
  final _hit = ValueNotifier<LayerHitResult<String>?>(null);
  GeographyStore? _store;
  Json? _data;
  Json? _reviewRow;
  List<Json> _pending = [];
  List<LatLng> _points = [];
  String? _target, _editing, _message;
  String _color = '#26734D', _background = 'streets';
  int? _vertex;
  int _editingVersion = 0;
  bool _busy = false, _tilesFailed = false;
  @override
  void initState() {
    super.initState();
    _store = widget.store;
    _background = widget.initialBackground;
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    _search.dispose();
    _hit.dispose();
    super.dispose();
  }

  List<Json> get _boundaries =>
      _data == null ? [] : items(_data!, 'boundaries');
  List<Json> get _plots => _data == null ? [] : items(_data!, 'plots');
  Json? _boundary(String target) => _boundaries
      .where((b) => '${b['target_kind']}:${b['target_id']}' == target)
      .firstOrNull;
  String _name(String target) => target.startsWith('property:')
      ? '${(_data!['property'] as Map)['name']}'
      : '${_plots.where((p) => p['id'] == target.split(':').last).firstOrNull?['name'] ?? 'Talhão'}';
  List<LatLng> _coordinates(Json boundary) => (boundary['points'] as List)
      .map((p) => LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble()))
      .toList();

  Future<void> _load() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final store = _store ??= await GeographyStore.open();
      Json? data;
      try {
        data = await store.refresh(widget.propertyId);
      } catch (error) {
        if (store.sessionValid?.call() == false) rethrow;
        data = await store.core.cached('map:${widget.propertyId}');
        _message = data == null
            ? v2Error(error)
            : 'Sem conexão: demarcações confirmadas salvas no aparelho. Imagens de fundo podem estar indisponíveis.';
      }
      final pending = await store.pending(widget.propertyId);
      final draft = await store.core.db.query('geography_editor',
          where: 'scope=? AND property_id=?',
          whereArgs: [store.core.scope, widget.propertyId]);
      if (!mounted) return;
      setState(() {
        _data = data;
        _pending = pending.where((p) => p['state'] != 'reviewed').toList();
        _target ??= 'property:${widget.propertyId}';
        if (_editing == null && data != null && draft.isNotEmpty) {
          final value = Map<String, dynamic>.from(
              jsonDecode(draft.first['payload'] as String) as Map);
          _editing = value['target'] as String;
          _target = _editing;
          _points = _coordinates(value);
          _color = value['color'] as String;
          _editingVersion = value['expected_version'] as int? ?? 0;
          _reviewRow = pending
              .where((p) =>
                  p['id'] == value['review_id'] && p['state'] == 'conflict')
              .firstOrNull;
          _message =
              'Desenho não enviado recuperado deste aparelho. Revise antes de salvar.';
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = v2Error(error);
          if (_store?.sessionValid?.call() == false) {
            _data = null;
            _pending = [];
            _editing = null;
            _points = [];
          }
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _draft() async {
    if (_store == null || _editing == null) return;
    await _store!.core.db.insert(
        'geography_editor',
        {
          'scope': _store!.core.scope,
          'property_id': widget.propertyId,
          'payload': jsonEncode({
            'target': _editing,
            'expected_version': _editingVersion,
            'review_id': _reviewRow?['id'],
            'color': _color,
            'points': _points.map((p) => [p.longitude, p.latitude]).toList()
          })
        },
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _start() async {
    final target = _target!;
    final boundary = _boundary(target);
    setState(() {
      _editing = target;
      _reviewRow = null;
      _editingVersion = boundary?['version'] as int? ?? 0;
      _vertex = null;
      _points = boundary == null || boundary['deleted'] == 1
          ? []
          : _coordinates(boundary);
      _color = boundary?['color'] as String? ?? '#26734D';
    });
    await _draft();
  }

  Future<String?> _reason(String title) async {
    final input = TextEditingController();
    final form = GlobalKey<FormState>();
    final result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
                title: Text(title),
                content: SingleChildScrollView(
                    child: Form(
                        key: form,
                        child: TextFormField(
                            controller: input,
                            maxLength: 160,
                            decoration: const InputDecoration(
                                labelText: 'Descrição da alteração'),
                            validator: (v) => v == null || v.trim().isEmpty
                                ? 'Informe o motivo.'
                                : null))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancelar')),
                  FilledButton(
                      onPressed: () {
                        if (form.currentState!.validate()) {
                          Navigator.pop(ctx, input.text.trim());
                        }
                      },
                      child: const Text('Confirmar'))
                ]));
    // The dialog may still be animating; let its route dispose the field first.
    Future<void>.delayed(const Duration(seconds: 1), input.dispose);
    return result;
  }

  Future<void> _save({bool remove = false}) async {
    final target = remove ? _target : _editing;
    if (target == null || (!remove && _points.length < 3)) {
      setState(() => _message = 'Marque ao menos três vértices.');
      return;
    }
    final reason = await _reason(remove
        ? 'Remover apenas a demarcação? O histórico será preservado.'
        : 'Salvar demarcação sem alterar hectares do cadastro?');
    if (reason == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final parts = target.split(':');
      final body = <String, dynamic>{
        'id': const Uuid().v4(),
        'expected_version':
            remove ? (_boundary(target)?['version'] ?? 0) : _editingVersion,
        'points': remove
            ? []
            : _points.map((p) => [p.longitude, p.latitude]).toList(),
        'color': _color,
        'deleted': remove,
        'reason': reason
      };
      if (_reviewRow == null) {
        await _store!.save(widget.propertyId, parts[0], parts[1], body);
      } else {
        await _store!
            .retryReviewed(_reviewRow!, _editingVersion, revised: body);
      }
      if (!remove) {
        await _store!.core.db.delete('geography_editor',
            where: 'scope=? AND property_id=?',
            whereArgs: [_store!.core.scope, widget.propertyId]);
      }
      if (mounted) {
        setState(() {
          _editing = null;
          _reviewRow = null;
          _points = [];
          _vertex = null;
          _message =
              'Desenho salvo no aparelho; aguardando confirmação do PC gestor.';
        });
      }
      SyncService().notifyLocalChange();
      try {
        await _store!.sync();
      } catch (_) {/* Durable pending state shown below. */}
    } catch (error) {
      if (mounted) setState(() => _message = v2Error(error));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _load();
      }
    }
  }

  Future<void> _locate() async {
    final text = _search.text.trim();
    final values = text
        .split(RegExp(r'[,;]'))
        .map((v) => double.tryParse(v.trim()))
        .toList();
    if (values.length == 2 &&
        values.every((v) => v != null && v.isFinite) &&
        values[0]!.abs() <= 85 &&
        values[1]!.abs() <= 180) {
      _controller.move(LatLng(values[0]!, values[1]!), 16);
      return;
    }
    if (_mapKey.isEmpty) {
      setState(() => _message =
          'Informe latitude, longitude (ex.: -21.5, -46.5). Busca por endereço e satélite exigem provedor configurado.');
      return;
    }
    setState(() => _busy = true);
    try {
      final response = await Dio().get<Json>(
          'https://api.maptiler.com/geocoding/${Uri.encodeComponent(text)}.json',
          queryParameters: {'key': _mapKey, 'limit': 5, 'language': 'pt'},
          options: Options(
              receiveTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(seconds: 15)));
      if (!mounted) return;
      final results = items(response.data ?? {}, 'features');
      if (results.isEmpty) {
        setState(
            () => _message = 'Nenhum endereço encontrado. Tente coordenadas.');
        return;
      }
      final chosen = await showDialog<Json>(
          context: context,
          builder: (ctx) => SimpleDialog(
                  title: const Text('Selecione a localização'),
                  children: [
                    for (final r in results)
                      SimpleDialogOption(
                          onPressed: () => Navigator.pop(ctx, r),
                          child: Text('${r['place_name'] ?? r['text']}'))
                  ]));
      if (chosen != null && mounted) {
        final center = chosen['center'] as List;
        _controller.move(
            LatLng(
                (center[1] as num).toDouble(), (center[0] as num).toDouble()),
            15);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message =
            'Pesquisa indisponível. Confira a internet e a configuração do provedor.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _history() async {
    if (_target == null || !_target!.startsWith('plot:')) return;
    final plotId = _target!.split(':').last;
    if (_data!['administrator'] == true) {
      await Navigator.push(
          context,
          MaterialPageRoute<void>(
              builder: (_) => ManagementReportsScreen(
                  type: 'plots',
                  propertyId: widget.propertyId,
                  plotId: plotId)));
      return;
    }
    try {
      final result =
          await _store!.core.client.v2('GET', '/plots/$plotId/operations');
      if (!mounted) return;
      await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (ctx) => SafeArea(
              child: SizedBox(
                  height: MediaQuery.sizeOf(ctx).height * .8,
                  child: ListView(padding: const EdgeInsets.all(16), children: [
                    const Text('Minhas operações neste talhão',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold)),
                    if (items(result, 'items').isEmpty)
                      const Text('Nenhuma operação registrada por esta conta.'),
                    for (final operation in items(result, 'items'))
                      Card(
                          child: Padding(
                              padding: const EdgeInsets.all(12),
                              child:
                                  SelectableText(managementDetails(operation))))
                  ]))));
    } catch (error) {
      if (mounted) setState(() => _message = v2Error(error));
    }
  }

  Future<void> _review(Json row) async {
    final target = (row['path'] as String).split('/').skip(2).join(':');
    try {
      final current = await _store!.refresh(widget.propertyId);
      final body = Map<String, dynamic>.from(
          jsonDecode(row['payload'] as String) as Map);
      final version = items(current, 'boundaries')
              .where((b) => '${b['target_kind']}:${b['target_id']}' == target)
              .firstOrNull?['version'] as int? ??
          0;
      if (!mounted) return;
      if (body['deleted'] == true) {
        final reason = await _reason(
            'Confirmar remoção da demarcação atual? O cadastro e o histórico permanecem.');
        if (reason == null) return;
        body['reason'] = reason;
        await _store!.retryReviewed(row, version, revised: body);
        await _store!.sync();
      } else {
        setState(() {
          _data = current;
          _target = target;
          _editing = target;
          _reviewRow = row;
          _editingVersion = version;
          _points = _coordinates(body);
          _color = body['color'] as String? ?? '#26734D';
          _message =
              'Revise o rascunho laranja sobre a demarcação confirmada. Ajuste vértices e salve para enviar uma nova revisão.';
        });
        await _draft();
        if (_points.isNotEmpty) _controller.move(_points.first, 16);
      }
    } catch (error) {
      if (mounted) setState(() => _message = v2Error(error));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final boundaries = _boundaries.where((b) => b['deleted'] != 1).toList();
    final allPoints = boundaries.expand(_coordinates).toList();
    final initial =
        allPoints.isEmpty ? const LatLng(-15.8, -47.9) : allPoints.first;
    return Scaffold(
        appBar: AppBar(title: const Text('Mapa da fazenda')),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          if (_busy) const LinearProgressIndicator(),
          if (_message != null)
            Padding(padding: const EdgeInsets.all(8), child: Text(_message!)),
          if (_data == null)
            OutlinedButton(
                onPressed: _busy ? null : _load,
                child: const Text('Conectar ao PC gestor')),
          if (_data != null) ...[
            Text('${(_data!['property'] as Map)['name']}',
                style:
                    const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const Text(
                'Sem rastreamento. Toque no mapa para selecionar um talhão. Durante a edição, cada toque adiciona um vértice.'),
            TextField(
                controller: _search,
                decoration: InputDecoration(
                    labelText: 'Endereço ou latitude, longitude',
                    suffixIcon: IconButton(
                        onPressed: _busy ? null : _locate,
                        icon: const Icon(Icons.search))),
                onSubmitted: (_) => _locate()),
            Wrap(spacing: 8, children: [
              for (final entry in {
                'streets': 'Mapa',
                'satellite': 'Satélite',
                'none': 'Sem imagem (offline)'
              }.entries)
                ChoiceChip(
                    label: Text(entry.value),
                    selected: _background == entry.key,
                    onSelected: (_) {
                      if (entry.key == 'satellite' && _mapKey.isEmpty) {
                        setState(() => _message =
                            'Satélite depende de chave pública e plano do provedor de imagens. Ainda não configurado neste piloto.');
                        return;
                      }
                      setState(() {
                        _background = entry.key;
                        _tilesFailed = false;
                      });
                    }),
            ]),
            if (_tilesFailed)
              const Text(
                  'Imagem indisponível. Seus desenhos continuam visíveis; use “Sem imagem” e coordenadas.'),
            DropdownButtonFormField<String>(
                key: ValueKey(_target),
                initialValue: _target,
                isExpanded: true,
                decoration:
                    const InputDecoration(labelText: 'Cadastro selecionado'),
                items: [
                  DropdownMenuItem(
                      value: 'property:${widget.propertyId}',
                      child: Text(
                          'Fazenda: ${(_data!['property'] as Map)['name']}',
                          overflow: TextOverflow.ellipsis)),
                  for (final p in _plots)
                    DropdownMenuItem(
                        value: 'plot:${p['id']}',
                        child: Text('Talhão: ${p['name']}',
                            overflow: TextOverflow.ellipsis)),
                ],
                onChanged: _editing != null
                    ? null
                    : (v) => setState(() => _target = v)),
            Text(
                'Área do desenho: ${_boundary(_target!)?['deleted'] == 1 ? 'demarcação removida' : _boundary(_target!)?['area_ha'] ?? 'não demarcada'}${_boundary(_target!)?['area_ha'] == null ? '' : ' ha (estimativa WGS84)'}'),
            if (_editing != null) ...[
              Text(
                  '${_points.length} vértices. ${_vertex == null ? 'Toque em um vértice para movê-lo com o próximo toque no mapa.' : 'Toque na nova posição do vértice ${_vertex! + 1}.'}'),
              Wrap(spacing: 8, children: [
                for (final color in {
                  '#26734D': 'Verde',
                  '#1565C0': 'Azul',
                  '#AD1457': 'Rosa',
                  '#F57C00': 'Laranja'
                }.entries)
                  ChoiceChip(
                      label: Text(color.value),
                      selected: _color == color.key,
                      onSelected: (_) {
                        setState(() => _color = color.key);
                        unawaited(_draft());
                      })
              ]),
              Wrap(spacing: 8, children: [
                OutlinedButton(
                    onPressed: _points.isEmpty
                        ? null
                        : () {
                            setState(() {
                              _points.removeLast();
                              _vertex = null;
                            });
                            unawaited(_draft());
                          },
                    child: const Text('Desfazer vértice')),
                FilledButton(
                    onPressed: _busy ? null : _save,
                    child: const Text('Salvar desenho')),
                TextButton(
                    onPressed: () async {
                      if (await _reason('Descartar o desenho não enviado?') ==
                          null) {
                        return;
                      }
                      await _store!.core.db.delete('geography_editor',
                          where: 'scope=? AND property_id=?',
                          whereArgs: [_store!.core.scope, widget.propertyId]);
                      if (mounted) {
                        setState(() {
                          _editing = null;
                          _points = [];
                          _vertex = null;
                        });
                      }
                    },
                    child: const Text('Descartar rascunho')),
              ]),
            ] else
              Wrap(spacing: 8, children: [
                if (_data!['can_edit'] == true)
                  FilledButton.icon(
                      onPressed: _busy ? null : _start,
                      icon: const Icon(Icons.edit_location_alt),
                      label: const Text('Demarcar / editar')),
                if (_data!['can_edit'] == true &&
                    _boundary(_target!) != null &&
                    _boundary(_target!)!['deleted'] != 1)
                  TextButton(
                      onPressed: _busy ? null : () => _save(remove: true),
                      child: const Text('Remover demarcação')),
                if (_target!.startsWith('plot:'))
                  OutlinedButton(
                      onPressed: _busy ? null : _history,
                      child: const Text('Histórico do talhão')),
              ]),
            SizedBox(
                height: (MediaQuery.sizeOf(context).height * .55)
                    .clamp(260, 580)
                    .toDouble(),
                child: Stack(children: [
                  FlutterMap(
                      mapController: _controller,
                      options: MapOptions(
                          initialCenter: initial,
                          initialZoom: allPoints.isEmpty ? 4 : 15,
                          minZoom: 2,
                          maxZoom: 20,
                          onTap: (_, point) {
                            if (_editing != null) {
                              setState(() {
                                if (_vertex != null) {
                                  _points[_vertex!] = point;
                                  _vertex = null;
                                } else {
                                  _points.add(point);
                                }
                              });
                              unawaited(_draft());
                            } else {
                              final hits = _hit.value?.hitValues ?? <String>[];
                              final hit = hits
                                      .where((v) => v.startsWith('plot:'))
                                      .firstOrNull ??
                                  hits.firstOrNull;
                              if (hit != null) setState(() => _target = hit);
                            }
                          }),
                      children: [
                        if (_background != 'none')
                          TileLayer(
                              urlTemplate: _background == 'satellite'
                                  ? 'https://api.maptiler.com/tiles/satellite-v4/{z}/{x}/{y}?key=$_mapKey'
                                  : 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                              userAgentPackageName: 'com.campo.agrogestao',
                              maxNativeZoom:
                                  _background == 'satellite' ? 18 : 19,
                              errorTileCallback: (_, __, ___) {
                                if (mounted && !_tilesFailed) {
                                  WidgetsBinding.instance
                                      .addPostFrameCallback((_) {
                                    if (mounted) {
                                      setState(() => _tilesFailed = true);
                                    }
                                  });
                                }
                              }),
                        PolygonLayer<String>(hitNotifier: _hit, polygons: [
                          for (final b in boundaries)
                            Polygon<String>(
                                points: _coordinates(b),
                                color: Color(int.parse(
                                        'FF${(b['color'] as String).substring(1)}',
                                        radix: 16))
                                    .withValues(alpha: .22),
                                borderColor: Color(int.parse(
                                    'FF${(b['color'] as String).substring(1)}',
                                    radix: 16)),
                                borderStrokeWidth: 2,
                                label: _name(
                                    '${b['target_kind']}:${b['target_id']}'),
                                hitValue:
                                    '${b['target_kind']}:${b['target_id']}')
                        ]),
                        if (_points.length >= 2)
                          PolylineLayer(polylines: [
                            Polyline(points: [
                              ..._points,
                              if (_points.length > 2) _points.first
                            ], color: Colors.orange, strokeWidth: 3)
                          ]),
                        MarkerLayer(markers: [
                          for (var i = 0; i < _points.length; i++)
                            Marker(
                                point: _points[i],
                                width: 34,
                                height: 34,
                                child: GestureDetector(
                                    onTap: () => setState(() => _vertex = i),
                                    child: CircleAvatar(
                                        backgroundColor: _vertex == i
                                            ? Colors.red
                                            : Colors.orange,
                                        radius: 14,
                                        child: Text('${i + 1}',
                                            style: const TextStyle(
                                                fontSize: 12)))))
                        ]),
                      ]),
                  Positioned(
                    left: 4,
                    right: 4,
                    bottom: 4,
                    child: ColoredBox(
                        color: Colors.white.withValues(alpha: .9),
                        child: Padding(
                            padding: const EdgeInsets.all(3),
                            child: Text(
                                _background == 'satellite'
                                    ? '© MapTiler · © OpenStreetMap contributors'
                                    : _background == 'none'
                                        ? 'Demarcações salvas · sem imagem de fundo'
                                        : '© OpenStreetMap contributors',
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.black)))),
                  ),
                  Positioned(
                      right: 6,
                      top: 6,
                      child: Column(children: [
                        IconButton.filledTonal(
                            onPressed: () => _controller.move(
                                _controller.camera.center,
                                (_controller.camera.zoom + 1).clamp(2, 20)),
                            icon: const Icon(Icons.add)),
                        IconButton.filledTonal(
                            onPressed: () => _controller.move(
                                _controller.camera.center,
                                (_controller.camera.zoom - 1).clamp(2, 20)),
                            icon: const Icon(Icons.remove)),
                      ])),
                ])),
            if (_background != 'none')
              SelectableText(_background == 'satellite'
                  ? '© MapTiler https://www.maptiler.com/copyright/ · © OpenStreetMap contributors'
                  : '© OpenStreetMap contributors — https://www.openstreetmap.org/copyright'),
            const Text(
                'O PC valida a geometria e calcula hectares ao sincronizar. O valor do cadastro não é substituído. Imagens não são baixadas para uso offline.'),
            for (final row in _pending)
              Card(
                  child: ListTile(
                      isThreeLine: true,
                      title: Text(row['state'] == 'conflict'
                          ? 'Demarcação precisa de revisão'
                          : 'Demarcação aguardando envio'),
                      subtitle: Text(
                          '${row['error'] ?? 'Rascunho preservado no aparelho.'}'),
                      onTap: row['state'] == 'conflict'
                          ? () => _review(row)
                          : null)),
            OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        try {
                          await _store!.sync();
                        } catch (error) {
                          if (mounted) {
                            setState(() => _message = v2Error(error));
                          }
                        }
                        await _load();
                      },
                icon: const Icon(Icons.sync),
                label: const Text('Sincronizar demarcações')),
          ]
        ]));
  }
}
