import 'dart:convert';

import 'sync_errors.dart';

class CollectionChanges {
  const CollectionChanges(this.upserts, this.deletes);

  final Map<String, Map<String, Object?>> upserts;
  final Set<String> deletes;

  /// Only records deliberately changed relative to the screen's original list
  /// may be written. Remote arrivals and untouched remote edits are preserved.
  static CollectionChanges plan({
    required Map<String, Map<String, Object?>> previous,
    required Map<String, Map<String, Object?>> incoming,
    required Map<String, Map<String, Object?>> current,
    Set<String> conflicts = const {},
    Set<String> tombstones = const {},
  }) {
    final upserts = <String, Map<String, Object?>>{};
    final deletes = <String>{};
    for (final entry in incoming.entries) {
      final original = previous[entry.key];
      if (original != null && _same(original, entry.value)) continue;
      if (conflicts.contains(entry.key) ||
          tombstones.contains(entry.key) ||
          (original == null && current.containsKey(entry.key)) ||
          (original != null && !_same(original, current[entry.key]))) {
        throw _stale;
      }
      upserts[entry.key] = entry.value;
    }
    for (final entry in previous.entries) {
      if (incoming.containsKey(entry.key)) continue;
      if (conflicts.contains(entry.key)) throw _stale;
      if (!current.containsKey(entry.key)) continue;
      if (!_same(entry.value, current[entry.key])) throw _stale;
      deletes.add(entry.key);
    }
    return CollectionChanges(upserts, deletes);
  }

  static const _stale = SyncConflictWriteBlocked(
    'Os dados deste registro mudaram. Feche e abra esta tela para atualizar os dados antes de salvar. Se houver um conflito, resolva-o em Sincronização.',
  );

  static bool _same(Object? a, Object? b) =>
      jsonEncode(_canonical(a)) == jsonEncode(_canonical(b));

  static Object? _canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    if (value is List) return value.map(_canonical).toList();
    return value;
  }
}
