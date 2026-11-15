import 'dart:async';
import 'dart:io';

import 'package:agrogestao/features/operations_v2/v2_store.dart';
import 'package:agrogestao/features/sync/app_database.dart';
import 'package:agrogestao/features/sync/farm_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('two independent SQLite handles recover cache writes and share lease', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final temp = await Directory.systemTemp.createTemp('agro-sqlite-probe-');
    final path = '${temp.path}${Platform.pathSeparator}pilot.sqlite';
    final first = await AppDatabase.openPath(path);
    final second = await AppDatabase.openPath(path);
    try {
      await Future.wait([V2Store.initialize(first), V2Store.initialize(second)]);
      await second.rawQuery('PRAGMA busy_timeout=0');
      final lease = await SyncRunLease.acquire(first, 'farm:fictional');
      expect(lease, isNotNull);
      try {
        expect(await SyncRunLease.acquire(second, 'farm:fictional'), isNull);
        final nested = await SyncRunLease.acquire(second, 'catalog:fictional');
        expect(nested, isNotNull);
        await nested?.release();
      } finally {
        await lease?.release();
      }
      final next = await SyncRunLease.acquire(second, 'farm:fictional');
      expect(next, isNotNull);
      await next?.release();

      final started = Completer<void>();
      final unlock = Completer<void>();
      final holding = first.transaction((tx) async {
        await tx.insert('sync_metadata', {
          'farm_id': 'fictional', 'key': 'probe', 'value': 'holding',
        });
        started.complete();
        await unlock.future;
      });
      await started.future;
      final store = V2Store(
        db: second,
        client: FarmApiClient.forSession(
          baseUrl: 'http://127.0.0.1:1', token: 'fictional', farmId: 'fictional',
        ),
        scope: 'synthetic', tokenExpiry: DateTime.now().add(const Duration(hours: 1)),
      );
      try {
        await second.insert('sync_metadata', {
          'farm_id': 'fictional', 'key': 'test', 'value': 'private',
        });
        fail('The second writer unexpectedly acquired the busy database');
      } on DatabaseException catch (error) {
        expect(AppDatabase.isBusy(error), isTrue);
        expect(v2Error(error), isNot(contains('sync_metadata')));
        expect(v2Error(error), isNot(contains('private')));
      } finally {
        Timer(const Duration(milliseconds: 200), unlock.complete);
      }
      await store.cache('commercial-features', {'farm_id': 'fictional'});
      await holding;
      expect((await store.cached('commercial-features'))!['farm_id'], 'fictional');
    } finally {
      await second.close();
      await first.close();
      await temp.delete(recursive: true);
    }
  });
}
