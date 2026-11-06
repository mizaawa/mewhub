import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/core/release_update.dart';
import 'package:mewhub/data/database.dart';
import 'package:mewhub/data/usage_statistics.dart';
import 'package:mewhub/state/app_state.dart';
import 'package:mewhub/state/settings_store.dart';
import 'package:mewhub/ui/chat/chat_drawer.dart';
import 'package:mewhub/ui/pages/usage_stats_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('only a newer published GitHub release produces an update', () async {
    http.Client api(String tag, {int status = 200}) => MockClient(
      (_) async => http.Response(
        '{"tag_name":"$tag","body":"Fixes and improvements",'
        '"html_url":"https://github.com/mizaawa/mewhub/releases/tag/$tag"}',
        status,
      ),
    );

    final next = await checkForReleaseUpdate(client: api('v1.2.1'), currentVersion: '1.2.0');
    expect(next?.version, 'v1.2.1');
    expect(next?.notes, 'Fixes and improvements');
    expect(next?.url.path, '/mizaawa/mewhub/releases/tag/v1.2.1');
    expect(await checkForReleaseUpdate(client: api('v1.2.0'), currentVersion: '1.2.0'), isNull);
    expect(await checkForReleaseUpdate(client: api('v1.1.9'), currentVersion: '1.2.0'), isNull);
    expect(await checkForReleaseUpdate(client: api('v1.3.0', status: 403), currentVersion: '1.2.0'), isNull);
    expect(
      await checkForReleaseUpdate(client: MockClient((_) async => throw Exception('offline')), currentVersion: '1.2.0'),
      isNull,
    );
  });

  testWidgets('compact release notice sits between the profile and Today Token, not in stats', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final root = (await tester.runAsync(() => Directory.systemTemp.createTemp('mewhub_release_notice')))!;
    AppPaths.support = root;
    AppPaths.cache = root;
    FlutterSecureStorage.setMockInitialValues({});
    final store = (await tester.runAsync(SettingsStore.load))!;
    I18n.apply(AppLang.zh);
    final db = (await tester.runAsync(() => AppDatabase.open('${root.path}/mewhub.db')))!;
    final app = AppState(store: store, db: db);
    addTearDown(() async {
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
    final launches = <MethodCall>[];
    const launcher = MethodChannel('plugins.flutter.io/url_launcher');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(launcher, (call) async {
      launches.add(call);
      return true;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(launcher, null);
    });

    final release = ReleaseUpdate(
      version: 'v1.3.0',
      notes: 'First\nSecond\nThird\nFourth\nFifth\nSixth',
      url: Uri.parse('https://github.com/mizaawa/mewhub/releases/tag/v1.3.0'),
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: store),
          ChangeNotifierProvider.value(value: app),
        ],
        child: MaterialApp(
          home: Scaffold(body: ChatDrawer(embedded: true, releaseUpdate: Future.value(release))),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('release-update-notice'));
    final profile = find.byKey(const ValueKey('user-profile-header'));
    final token = find.byKey(const ValueKey('sidebar-today-token'));
    expect(card, findsOneWidget);
    expect(tester.getBottomLeft(profile).dy, lessThan(tester.getTopLeft(card).dy));
    expect(tester.getBottomLeft(card).dy, lessThan(tester.getTopLeft(token).dy));
    expect(tester.getSize(card).height, 52);
    expect(find.text('有新版本 v1.3.0'), findsOneWidget);
    await tester.tap(card);
    await tester.pump();
    expect(launches.where((call) => call.method == 'launch').length, 1);
    expect(launches.single.arguments.toString(), contains('/releases/tag/v1.3.0'));

    await tester.pumpWidget(
      MaterialApp(
        home: StatsPage(statistics: UsageStatistics(now: DateTime(2026, 11, 6))),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('release-update-notice')), findsNothing);
  });
}
