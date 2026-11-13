import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/attachments.dart';
import 'core/paths.dart';
import 'data/database.dart';
import 'state/app_state.dart';
import 'state/settings_store.dart';
import 'state/tts.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  configureAndroidImagePicker();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    mewSystemUiOverlayStyle(WidgetsBinding.instance.platformDispatcher.platformBrightness),
  );

  await AppPaths.init();
  await Attachments.recoverLostChatPhotos();
  final store = await SettingsStore.load();
  final db = await AppDatabase.open();
  await db.recordAppLaunch();
  final app = AppState(store: store, db: db);
  await app.init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: store),
        ChangeNotifierProvider.value(value: app),
        ChangeNotifierProvider(create: (_) => TtsService()),
      ],
      child: const MewHubApp(),
    ),
  );
}
