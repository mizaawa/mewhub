import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/ai/provider_config.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/core/net.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/data/conversation.dart';
import 'package:mewhub/data/database.dart';
import 'package:mewhub/state/app_state.dart';
import 'package:mewhub/state/settings_store.dart';
import 'package:mewhub/state/tts.dart';
import 'package:mewhub/ui/chat/chat_page.dart';
import 'package:mewhub/ui/theme.dart';
import 'package:provider/provider.dart';

class MemoryDatabase implements AppDatabase {
  final rows = <String, Conversation>{};
  @override
  Future<void> saveConversation(Conversation c) async => rows[c.id] = c;
  @override
  Future<Conversation?> getConversation(String id) async => rows[id];
  @override
  Future<List<ConversationSummary>> listConversations({String? assistantId, int limit = 500, int offset = 0}) async => [
    for (final c in rows.values)
      ConversationSummary(
        id: c.id,
        assistantId: c.assistantId,
        title: c.title,
        pinned: c.pinned,
        updatedAt: c.updatedAt,
        createdAt: c.createdAt,
        preview: c.currentMessages.lastOrNull?.text ?? '',
        folder: c.folder,
      ),
  ];
  @override
  Future<Set<String>> favoriteMessageIds() async => {};
  @override
  Future<void> deleteConversation(String id) async => rows.remove(id);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LoopbackHttpOverrides extends HttpOverrides {}

Future<void> frames(WidgetTester tester, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// Pumps while letting real I/O progress, so sockets keep moving under the
/// widget tester's fake clock.
Future<bool> settle(WidgetTester tester, bool Function() done, {int tries = 300, int stepMs = 10}) async {
  for (var i = 0; i < tries; i++) {
    if (done()) return true;
    await tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: stepMs)));
    await tester.pump(const Duration(milliseconds: 16));
  }
  return done();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late SettingsStore store;
  late MemoryDatabase db;
  late AppState app;
  late HttpServer server;
  late List<String> prompts;
  late Completer<void> gate;

  setUp(() async {
    HttpOverrides.global = null;
    Net.reconfigure();
    temp = await Directory.systemTemp.createTemp('mewhub_edit_ui');
    AppPaths.support = temp;
    AppPaths.cache = temp;
    FlutterSecureStorage.setMockInitialValues({});
    store = await SettingsStore.load();
    I18n.apply(AppLang.zh);
    prompts = [];
    gate = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      prompts.add(await utf8.decodeStream(request));
      request.response.bufferOutput = false;
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: {"choices":[{"delta":{"content":"reply ${prompts.length}"}}]}\n\n');
      await request.response.flush();
      await gate.future;
      try {
        request.response.write(
          'data: {"choices":[{"delta":{"content":" done"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
        );
        await request.response.close();
      } catch (_) {}
    });
    final model = ModelConfig(id: 'fixture-model', modelId: 'fixture');
    final provider = ProviderConfig(
      id: 'fixture-provider',
      kind: ProviderKind.openai,
      name: 'Fixture',
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      models: [model],
    );
    store.update(
      (s) => s.copyWith(
        providers: [provider],
        chatModelId: model.id,
        autoTitle: false,
        suggestions: false,
        autoRetry: false,
        autoCompress: false,
        display: s.display.copyWith(notifyOnFinish: false),
        assistants: [
          s.currentAssistant.copyWith(enableMemory: false, enableRecentChats: false, enableWebSearch: false),
        ],
      ),
    );
    db = MemoryDatabase();
    app = AppState(store: store, db: db);
    await app.init();
  });

  tearDown(() async {
    if (!gate.isCompleted) gate.complete();
    app.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await server.close(force: true);
    Net.reconfigure();
    await store.flush();
    store.dispose();
    await temp.delete(recursive: true);
  });

  Widget host() => MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsStore>.value(value: store),
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider(create: (_) => TtsService()),
    ],
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: MewTheme.light(0), home: const ChatPage()),
  );

  testWidgets('pencil edit on a sent message saves and resends', (tester) async {
    await HttpOverrides.runWithHttpOverrides(() async {
      Net.reconfigure();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      try {
        await tester.pumpWidget(host());
        await frames(tester);

        final chat = app.chat;
        unawaited(chat.send([const TextPart('first question')]));
        // Release the first response immediately: a stalled socket would make
        // the pooled connection unavailable to the resend.
        gate.complete();
        gate = Completer<void>()..complete();
        expect(
          await settle(tester, () => chat.conversation.currentMessages.length == 2),
          isTrue,
          reason: 'reply placeholder never appeared',
        );

        final pencil = find.byIcon(Icons.edit_outlined);
        expect(pencil, findsWidgets);
        await tester.tap(pencil.first);
        await frames(tester, 30);

        // The composer keeps its own field, so target the sheet's one.
        final field = find.descendant(of: find.byType(BottomSheet), matching: find.byType(TextField));
        expect(field, findsOneWidget);
        await tester.enterText(field, 'edited question');
        await frames(tester, 5);
        final save = find.text(I18n.isZh ? '保存并重新发送' : 'Save & resend');
        expect(save, findsOneWidget);
        await tester.tap(save);
        // Real-time steps: the sheet's continuation waits for the interrupted
        // stream, which the fake clock cannot drive on its own.
        final applied = await settle(
          tester,
          () => chat.conversation.nodes.first.current.text == 'edited question',
          tries: 400,
          stepMs: 5,
        );
        expect(
          applied,
          isTrue,
          reason:
              'save was ignored; nodes=${chat.conversation.nodes.length} '
              'first=${chat.conversation.nodes.first.messages.map((m) => m.text).toList()} '
              'sel=${chat.conversation.nodes.first.selected} gen=${chat.generating} '
              'msgs=${chat.conversation.nodes.first.messages.map((m) => m.text).toList()}',
        );
        // The UI handed the edit to the controller, which started a fresh
        // reply. The resend request itself is covered end to end by
        // chat_edit_resend_test.dart, where sockets are not on a fake clock.
        expect(chat.generating || prompts.length >= 2, isTrue);
        expect(find.textContaining('edited question'), findsWidgets);
      } finally {
        Net.reconfigure();
      }
    }, _LoopbackHttpOverrides());
  });
}
