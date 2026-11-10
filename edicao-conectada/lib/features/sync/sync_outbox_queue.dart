import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

class SyncOutboxQueue {
  const SyncOutboxQueue._();

  static Future<bool> acknowledge(
    Transaction tx, {
    required String eventId,
    required String farmId,
    required int version,
  }) async {
    final rows = await tx.query('sync_outbox',
      where: 'event_id=?', whereArgs: [eventId], limit: 1);
    if (rows.isEmpty) return false;
    final event = rows.first;
    final module = event['module']! as String;
    final recordId = event['record_id']! as String;
    await tx.delete('sync_outbox', where: 'event_id=?', whereArgs: [eventId]);

    final conflict = await tx.query(
      'sync_outbox',
      where: "farm_id=? AND module=? AND record_id=? AND state='conflict'",
      whereArgs: [farmId, module, recordId],
      limit: 1,
    );
    if (conflict.isNotEmpty) return true;

    final next = await tx.query(
      'sync_outbox',
      where: "farm_id=? AND module=? AND record_id=? AND state IN ('pending','error','sending')",
      whereArgs: [farmId, module, recordId],
      orderBy: 'created_at ASC,rowid ASC',
      limit: 1,
    );
    if (next.isNotEmpty) {
      await tx.update('sync_outbox', {'base_version': version},
        where: 'event_id=?', whereArgs: [next.first['event_id']]);
    }
    final nextState = next.isEmpty ? null : next.first['state'] as String?;

    await tx.update('local_records', {
      'server_version': version,
      'sync_state': nextState == 'error' ? 'error' : next.isEmpty ? 'synced' : 'pending',
      'sync_error': nextState == 'error' ? next.first['last_error'] as String? : null,
    }, where: 'farm_id=? AND module=? AND record_id=?', whereArgs: [farmId, module, recordId]);
    return true;
  }

  static List<Map<String, Object?>> oldestPerRecord(
    List<Map<String, Object?>> rows, {
    int limit = 100,
  }) {
    final seen = <String>{};
    final selected = <Map<String, Object?>>[];
    for (final row in rows) {
      final key = '${row['module']}\u0000${row['record_id']}';
      if (seen.add(key)) selected.add(row);
      if (selected.length == limit) break;
    }
    return selected;
  }

  static Future<void> enqueue(
    Transaction tx, {
    required String farmId,
    required String module,
    required String recordId,
    required String operation,
    required String? payload,
    required int baseVersion,
    required String createdAt,
  }) async {
    final pending = await tx.query(
      'sync_outbox',
      where: "farm_id=? AND module=? AND record_id=? AND state='pending'",
      whereArgs: [farmId, module, recordId],
      orderBy: 'created_at ASC',
      limit: 1,
    );
    if (pending.isNotEmpty) {
      await tx.update(
        'sync_outbox',
        {
          'operation': operation,
          'payload': payload,
          'state': 'pending',
          'last_error': null,
        },
        where: 'event_id=?',
        whereArgs: [pending.first['event_id']],
      );
      return;
    }
    await tx.delete(
      'sync_outbox',
      where: "farm_id=? AND module=? AND record_id=? AND state='error'",
      whereArgs: [farmId, module, recordId],
    );
    await tx.insert('sync_outbox', {
      'event_id': const Uuid().v4(),
      'farm_id': farmId,
      'module': module,
      'record_id': recordId,
      'operation': operation,
      'payload': payload,
      'base_version': baseVersion,
      'created_at': createdAt,
      'attempts': 0,
      'state': 'pending',
      'last_error': null,
    });
  }
}
