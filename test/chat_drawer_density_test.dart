import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/core/release_update.dart';
import 'package:mewhub/data/database.dart';
import 'package:mewhub/state/app_state.dart';
import 'package:mewhub/state/settings_store.dart';
import 'package:mewhub/ui/chat/chat_drawer.dart';
import 'package:provider/provider.dart';

class _DrawerDatabase implements AppDatabase {
  @override
  Future<List<Map<String, Object?>>> usageByDay({int? days = 30}) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory sandbox;
  late SettingsStore store;
  late AppState app;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('mewhub_drawer_density_');
    AppPaths.support = sandbox;
    AppPaths.cache = sandbox;
    FlutterSecureStorage.setMockInitialValues({});
    store = await SettingsStore.load();
    app = AppState(store: store, db: _DrawerDatabase());
    app.conversations = [
      for (var i = 0; i < 20; i++)
        ConversationSummary(
          id: 'chat-$i',
          assistantId: store.value.currentAssistantId,
          title: 'History item $i',
          pinned: false,
          updatedAt: DateTime(2026, 11, 8, 12, 0, i),
          createdAt: DateTime(2026, 11, 8, 12, 0, i),
          preview: 'History item $i',
        ),
    ];
  });

  tearDown(() async {
    app.dispose();
    await store.flush();
    store.dispose();
    await sandbox.delete(recursive: true);
  });

  testWidgets('conversation history rows stay compact while keeping their loading indicator', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsStore>.value(value: store),
          ChangeNotifierProvider<AppState>.value(value: app),
        ],
        child: MaterialApp(
          home: Scaffold(body: ChatDrawer(embedded: true, releaseUpdate: _noUpdate)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final first = find.descendant(of: find.byKey(const ValueKey('dismiss-chat-19')), matching: find.byType(ListTile));
    expect(tester.getSize(first).height, lessThanOrEqualTo(48));
    expect(tester.widget<ListTile>(first).dense, isTrue);
    expect(find.byKey(const ValueKey('conv-chat-19')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

final Future<ReleaseUpdate?> _noUpdate = Future.value(null);
