// Android-only regression probe. Uses disposable files, never the user's DB.
// flutter build apk --debug -t tool/native_database_probe.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:agrogestao/features/sync/app_database.dart';

Future<Database> connection(String path, bool shared) => shared
    ? openDatabase(path, singleInstance: true, version: 1,
        onConfigure: (db) async {
        await db.rawQuery('PRAGMA journal_mode=WAL');
      })
    : AppDatabase.openPath(path);

@pragma('vm:entry-point')
void worker(List<Object> args) async {
  BackgroundIsolateBinaryMessenger.ensureInitialized(
      args[0] as RootIsolateToken);
  final port = args[1] as SendPort;
  Database? db;
  final close = ReceivePort();
  try {
    db = await connection(args[2] as String, args[3] as bool);
    final rows =
        await db.rawQuery('SELECT COUNT(*) AS n FROM regression_probe');
    port.send(
        {'ready': true, 'rows': rows.first['n'], 'close': close.sendPort});
    await close.first;
  } catch (error) {
    port.send({'error': '$error'});
  } finally {
    await db?.close();
    close.close();
    Isolate.exit();
  }
}

Future<Map<String, Object?>> exercise(String path, bool shared) async {
  final db = await connection(path, shared);
  await db.execute(
      'CREATE TABLE regression_probe(id INTEGER PRIMARY KEY,note TEXT)');
  final replies = ReceivePort();
  SendPort? close;
  int? observed;
  String? failure;
  Isolate? isolate;
  Future<dynamic>? response;
  void receive(Map reply) {
    if (reply['error'] != null) throw StateError('${reply['error']}');
    close = reply['close'] as SendPort;
    observed = reply['rows'] as int;
  }

  try {
    await db.transaction((tx) async {
      await tx.insert(
          'regression_probe', {'id': 1, 'note': 'Synthetic transaction'});
      isolate = await Isolate.spawn(
          worker, [RootIsolateToken.instance!, replies.sendPort, path, shared]);
      response = replies.first.timeout(const Duration(seconds: 25));
      if (shared) {
        receive(await response! as Map);
      } else {
        // Different native handles share Android's single worker thread.
        // COMMIT must release that worker before waiting for the new reader.
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    });
    if (!shared) receive(await response! as Map);
  } catch (error) {
    failure = '$error';
  }
  final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM regression_probe'));
  close?.send(true);
  replies.close();
  // The main handle is not shared in the corrected case.
  await db.close();
  isolate?.kill(priority: Isolate.immediate);
  return {
    'shared': shared,
    'error': failure,
    'worker_rows': observed,
    'committed_rows': count,
    'passed': shared
        ? failure != null && failure.contains('no current transaction')
        : failure == null && count == 1 && (observed == 0 || observed == 1)
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final directory = await Directory(
          '${(await getTemporaryDirectory()).path}/db-regression-${DateTime.now().millisecondsSinceEpoch}')
      .create();
  final results = <Map<String, Object?>>[];
  try {
    results.add(await exercise('${directory.path}/baseline.sqlite3', true));
    for (var i = 0; i < 3; i++) {
      results
          .add(await exercise('${directory.path}/corrected-$i.sqlite3', false));
    }
  } catch (error) {
    results.add({'passed': false, 'error': '$error'});
  }
  final output = {
    'passed': results.every((r) => r['passed'] == true),
    'results': results
  };
  await File(
          '${(await getTemporaryDirectory()).path}/native-db-regression.json')
      .writeAsString(jsonEncode(output));
  runApp(MaterialApp(
      home:
          Scaffold(body: SafeArea(child: SelectableText(jsonEncode(output))))));
}
