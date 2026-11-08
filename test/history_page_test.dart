import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/data/conversation.dart';
import 'package:mewhub/data/database.dart';
import 'package:mewhub/state/app_state.dart';
import 'package:mewhub/state/settings_store.dart';
import 'package:mewhub/ui/pages/history_page.dart';
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
  late Conversation first;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mewhub_history_page_');
    AppPaths.support = root;
    AppPaths.cache = root;
    FlutterSecureStorage.setMockInitialValues({});
    store = await SettingsStore.load();
    db = await AppDatabase.open('${root.path}/mewhub.db');
    app = AppState(store: store, db: db);
    first = Conversation(
      assistantId: store.value.currentAssistantId,
      title: 'Biology notes',
      nodes: [
        MessageNode(messages: [ChatMessage.text(Role.user, 'mitochondria clue')]),
      ],
      updatedAt: DateTime(2026, 11, 8, 12),
    );
    await db.saveConversation(first);
    await db.saveConversation(
      Conversation(
        assistantId: store.value.currentAssistantId,
        title: 'Second chat',
        nodes: [
          MessageNode(messages: [ChatMessage.text(Role.user, 'another clue')]),
        ],
        updatedAt: DateTime(2026, 11, 8, 13),
      ),
    );
    await app.refreshList();
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

  Widget host() => MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsStore>.value(value: store),
      ChangeNotifierProvider<AppState>.value(value: app),
    ],
    child: MaterialApp(home: const HistoryPage(), routes: {'/search': (_) => const SearchPage()}),
  );

  testWidgets('history pins and opens scoped message search results', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(find.text('Biology notes'), findsOneWidget);
    expect(find.byKey(ValueKey('history-pin-${first.id}')), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('history-pin-${first.id}')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect((await tester.runAsync(db.listConversations))!.firstWhere((item) => item.id == first.id).pinned, isTrue);

    await tester.tap(find.byKey(const ValueKey('history-search-messages')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('message-search-query')), 'mitochondria');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(find.text('Biology notes'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.textSpan?.toPlainText().contains('mitochondria') == true,
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('history entries use a compact single-row layout', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    final entry = find.byKey(ValueKey('history-item-${first.id}'));
    expect(entry, findsOneWidget);
    expect(tester.getSize(entry).height, lessThan(72));
  });

  testWidgets('swipe deletion can be undone from history', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    final dismissible = tester.widget<Dismissible>(find.byKey(ValueKey('history-dismiss-${first.id}')));
    expect(await tester.runAsync(() => dismissible.confirmDismiss!(DismissDirection.endToStart)), isTrue);
    dismissible.onDismissed!(DismissDirection.endToStart);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect((await tester.runAsync(db.listConversations))!.any((item) => item.id == first.id), isFalse);

    final undoAction = tester.widget<SnackBarAction>(find.byType(SnackBarAction));
    undoAction.onPressed();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    expect((await tester.runAsync(db.listConversations))!.any((item) => item.id == first.id), isTrue);
  });
}
