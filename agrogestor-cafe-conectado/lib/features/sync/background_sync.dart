import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../auth/auth_service.dart';
import 'sync_service.dart';
import 'app_database.dart';

const backgroundSyncUniqueName = 'agrogestor-background-sync';
const backgroundSyncTaskName = 'agrogestor-sync-farm';

@pragma('vm:entry-point')
void agroGestorBackgroundDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    try {
      await AuthService().init(startSync: false);
      await SyncService().syncNow();
      return true;
    } finally {
      await appDatabase.close();
    }
  });
}
