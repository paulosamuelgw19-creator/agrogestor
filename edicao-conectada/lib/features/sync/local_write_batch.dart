import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../auth/auth_service.dart';
import '../auth/farm_access_policy.dart';
import 'app_database.dart';
import 'sync_service.dart';

/// Keeps related local records and their outbox events in one SQLite commit.
class LocalWriteBatch {
  static final Object _transactionKey = Object();
  static Transaction? get current =>
      Zone.current[_transactionKey] as Transaction?;

  static Future<void> run(Future<void> Function() action) async {
    if (current != null) return action();
    final user = AuthService().currentUser;
    if (user?.farmId == null || kIsWeb) return action();
    final db = await appDatabase.database;
    await db.transaction((tx) => runZoned(() async {
          await action();
          if (AuthService().currentUser?.id != user!.id ||
              AuthService().currentUser?.farmId != user.farmId) {
            throw const FarmAccessDenied(
                'A sessão mudou. Abra esta tela novamente.');
          }
        }, zoneValues: {_transactionKey: tx}));
    SyncService().notifyLocalChange();
  }
}
