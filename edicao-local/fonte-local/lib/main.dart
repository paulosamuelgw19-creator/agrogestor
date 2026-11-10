import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';
import 'app/agro_app.dart';
import 'features/auth/auth_service.dart';
import 'features/sync/farm_api_client.dart';
import 'features/sync/background_sync.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (defaultTargetPlatform == TargetPlatform.android &&
      !FarmApiClient.standaloneLocalMode) {
    await Workmanager().initialize(agroGestorBackgroundDispatcher);
  }
  await AuthService().init();
  runApp(const AgroApp());
}
