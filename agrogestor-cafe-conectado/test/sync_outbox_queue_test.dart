import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:agrogestao/features/sync/sync_outbox_queue.dart';

void main() {
  late Directory directory;
  late String databasePath;
  late Database database;

  setUpAll(sqfliteFfiInit);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('agrogestor-outbox-test-');
    databasePath = '${directory.path}${Platform.pathSeparator}outbox.sqlite3';
    database = await databaseFactoryFfi.openDatabase(databasePath);
    await database.execute('''CREATE TABLE sync_outbox (
      event_id TEXT PRIMARY KEY,
      farm_id TEXT NOT NULL,
      module TEXT NOT NULL,
      record_id TEXT NOT NULL,
      operation TEXT NOT NULL,
      payload TEXT,
      base_version INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      attempts INTEGER NOT NULL DEFAULT 0,
      state TEXT NOT NULL DEFAULT 'pending',
      last_error TEXT
    )''');
    await database.execute('''CREATE TABLE local_records (
      farm_id TEXT NOT NULL,
      module TEXT NOT NULL,
      record_id TEXT NOT NULL,
      payload TEXT NOT NULL,
      server_version INTEGER NOT NULL,
      sync_state TEXT NOT NULL,
      sync_error TEXT,
      PRIMARY KEY (farm_id,module,record_id)
    )''');
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  Future<void> enqueue({required String payload, String operation = 'upsert'}) =>
      database.transaction((tx) => SyncOutboxQueue.enqueue(
            tx,
            farmId: 'farm-001',
            module: 'machines',
            recordId: 'machine-001',
            operation: operation,
            payload: operation == 'delete' ? null : payload,
            baseVersion: 4,
            createdAt: '2026-10-09T12:00:00Z',
          ));

  test('mescla pendências antes do envio e persiste a fila após reabertura', () async {
    await enqueue(payload: '{"name":"Trator"}');
    final first = (await database.query('sync_outbox')).single;
    final eventId = first['event_id'];
    await enqueue(payload: '{"name":"Trator atualizado"}');
    final mergedPending = (await database.query('sync_outbox')).single;
    expect(mergedPending['event_id'], eventId);
    expect(mergedPending['payload'], '{"name":"Trator atualizado"}');

    await database.update(
      'sync_outbox',
      {'state': 'error', 'attempts': 2, 'last_error': 'Sem conexão'},
      where: 'event_id=?',
      whereArgs: [eventId],
    );
    await enqueue(payload: '{"name":"Trator editado após erro"}');

    final replacement = (await database.query('sync_outbox')).single;
    expect(replacement['event_id'], isNot(eventId));
    expect(replacement['payload'], '{"name":"Trator editado após erro"}');
    expect(replacement['state'], 'pending');
    expect(replacement['attempts'], 0);
    expect(replacement['last_error'], isNull);

    await database.close();
    database = await databaseFactoryFfi.openDatabase(databasePath);
    final restored = (await database.query('sync_outbox')).single;
    expect(restored['event_id'], replacement['event_id']);
    expect(restored['payload'], '{"name":"Trator editado após erro"}');
    expect(restored['base_version'], 4);
  });

  test('uma alteração durante o envio ganha evento próprio para evitar sobrescrever o evento em voo', () async {
    await enqueue(payload: '{"name":"Trator"}');
    final first = (await database.query('sync_outbox')).single;
    await database.update(
      'sync_outbox',
      {'state': 'sending'},
      where: 'event_id=?',
      whereArgs: [first['event_id']],
    );

    await enqueue(payload: '{"name":"Trator em edição"}');

    final rows = await database.query('sync_outbox', orderBy: 'rowid ASC');
    expect(rows, hasLength(2));
    expect(rows.map((row) => row['event_id']).toSet(), hasLength(2));
    expect(rows.any((row) => row['state'] == 'sending'), isTrue);
    expect(rows.any((row) => row['payload'] == '{"name":"Trator em edição"}'), isTrue);
    final sendable = SyncOutboxQueue.oldestPerRecord(rows);
    expect(sendable, hasLength(1));
    expect(sendable.single['event_id'], first['event_id']);
  });

  test('a confirmação atualiza a versão base da alteração seguinte', () async {
    await database.insert('local_records', {
      'farm_id': 'farm-001',
      'module': 'machines',
      'record_id': 'machine-001',
      'payload': '{"name":"Trator em edição"}',
      'server_version': 4,
      'sync_state': 'pending',
    });
    await enqueue(payload: '{"name":"Trator enviado"}');
    final first = (await database.query('sync_outbox')).single;
    await database.update('sync_outbox', {'state': 'sending'},
        where: 'event_id=?', whereArgs: [first['event_id']]);
    await enqueue(payload: '{"name":"Trator em edição"}');

    final followUp = (await database.query('sync_outbox',
      where: "state='pending'", limit: 1)).single;
    expect(followUp['base_version'], 4);

    final acknowledged = await database.transaction((tx) => SyncOutboxQueue.acknowledge(
      tx,
      eventId: first['event_id']! as String,
      farmId: 'farm-001',
      version: 5,
    ));
    expect(acknowledged, isTrue);
    final updatedFollowUp = (await database.query('sync_outbox')).single;
    final local = (await database.query('local_records')).single;
    expect(updatedFollowUp['base_version'], 5);
    expect(updatedFollowUp['payload'], '{"name":"Trator em edição"}');
    expect(local['server_version'], 5);
    expect(local['sync_state'], 'pending');

    final duplicateAck = await database.transaction((tx) => SyncOutboxQueue.acknowledge(
      tx,
      eventId: first['event_id']! as String,
      farmId: 'farm-001',
      version: 5,
    ));
    expect(duplicateAck, isFalse);
    expect((await database.query('sync_outbox')), hasLength(1));
  });

  test('a confirmação não oculta um erro da alteração seguinte', () async {
    await database.insert('local_records', {
      'farm_id': 'farm-001',
      'module': 'machines',
      'record_id': 'machine-001',
      'payload': '{"name":"Trator em edição"}',
      'server_version': 4,
      'sync_state': 'pending',
    });
    await enqueue(payload: '{"name":"Trator enviado"}');
    final first = (await database.query('sync_outbox')).single;
    await database.update('sync_outbox', {'state': 'sending'},
        where: 'event_id=?', whereArgs: [first['event_id']]);
    await enqueue(payload: '{"name":"Trator em edição"}');
    final followUp = (await database.query('sync_outbox',
      where: "state='pending'", limit: 1)).single;
    await database.update('sync_outbox', {
      'state': 'error',
      'last_error': 'Foto não encontrada',
    }, where: 'event_id=?', whereArgs: [followUp['event_id']]);

    await database.transaction((tx) => SyncOutboxQueue.acknowledge(
      tx,
      eventId: first['event_id']! as String,
      farmId: 'farm-001',
      version: 5,
    ));

    final event = (await database.query('sync_outbox')).single;
    final record = (await database.query('local_records')).single;
    expect(event['base_version'], 5);
    expect(event['state'], 'error');
    expect(record['sync_state'], 'error');
    expect(record['sync_error'], 'Foto não encontrada');
  });
}
