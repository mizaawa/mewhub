import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/data/database.dart';
import 'package:mewhub/state/app_state.dart';
import 'package:mewhub/state/settings_store.dart';
import 'package:mewhub/ui/pages/tools_pages.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory root;
  late SettingsStore store;
  late AppDatabase db;
  late AppState app;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mewhub_search_page_');
    AppPaths.support = root;
    AppPaths.cache = root;
    FlutterSecureStorage.setMockInitialValues({});
    store = await SettingsStore.load();
    db = await AppDatabase.open('${root.path}/mewhub.db');
    app = AppState(store: store, db: db);
  });

  tearDown(() async {
    app.dispose();
    await store.flush();
    store.dispose();
    await db.close();
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        await root.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt == 9) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  testWidgets('message search exposes assistant scope, ranking, and refresh controls', (tester) async {
    I18n.apply(AppLang.zh);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsStore>.value(value: store),
          ChangeNotifierProvider<AppState>.value(value: app),
        ],
        child: const MaterialApp(home: SearchPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('message-search-query')), findsOneWidget);
    expect(find.byKey(const ValueKey('message-search-scope')), findsOneWidget);
    expect(find.byKey(const ValueKey('message-search-sort')), findsOneWidget);
    expect(find.byKey(const ValueKey('message-search-refresh')), findsOneWidget);
    expect(find.text('当前助手'), findsOneWidget);
    expect(find.text('所有助手'), findsOneWidget);
  });
}
