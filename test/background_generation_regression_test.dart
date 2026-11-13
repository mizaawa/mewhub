import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/ai/provider_config.dart';
import 'package:mewhub/core/net.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/data/conversation.dart';
import 'package:mewhub/data/database.dart';
import 'package:mewhub/state/app_state.dart';
import 'package:mewhub/state/settings_store.dart';

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
  Future<void> deleteConversation(String id) async {
    rows.remove(id);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LoopbackHttpOverrides extends HttpOverrides {}

Future<void> waitFor(bool Function() predicate, {String Function()? diagnostic}) async {
  for (var i = 0; i < 300; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for streaming fixture${diagnostic == null ? '' : ': ${diagnostic()}'}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late SettingsStore store;
  late MemoryDatabase db;
  late AppState app;
  late HttpServer server;
  late Completer<void> finish;

  setUp(() async {
    HttpOverrides.global = null;
    Net.reconfigure();
    temp = await Directory.systemTemp.createTemp('mewhub_generation');
    AppPaths.support = temp;
    AppPaths.cache = temp;
    FlutterSecureStorage.setMockInitialValues({});
    store = await SettingsStore.load();
    finish = Completer<void>();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await utf8.decodeStream(request);
      request.response.bufferOutput = false;
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: {"choices":[{"delta":{"content":"Hello"}}]}\n\n');
      await request.response.flush();
      await finish.future;
      try {
        request.response.write(
          'data: {"choices":[{"delta":{"content":" world"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
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
        display: s.display.copyWith(notifyOnFinish: false),
        assistants: [s.currentAssistant.copyWith(enableMemory: false, enableRecentChats: false)],
      ),
    );
    db = MemoryDatabase();
    app = AppState(store: store, db: db);
    await app.init();
  });

  tearDown(() async {
    if (!finish.isCompleted) finish.complete();
    app.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await server.close(force: true);
    Net.reconfigure();
    await store.flush();
    store.dispose();
    // Work after the reply (list refresh, settings writes) can still land a
    // file while the sandbox is removed; retry instead of failing on Linux's
    // "Directory not empty".
    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        await temp.delete(recursive: true);
        break;
      } on FileSystemException {
        if (attempt == 9) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  test('first send appears in sidebar before the response finishes', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      Net.reconfigure();
      try {
        final chat = app.chat;
        final sending = chat.send([const TextPart('First question')]);
        await waitFor(
          () => chat.conversation.currentMessages.last.text == 'Hello',
          diagnostic: () => 'error=${chat.lastError}, nodes=${chat.conversation.currentMessages.map((m) => m.text)}',
        );
        expect(chat.generating, isTrue);
        expect(app.conversations.map((c) => c.id), contains(chat.conversation.id));
        expect(app.isGenerating(chat.conversation.id), isTrue);
        finish.complete();
        await sending;
      } finally {
        Net.reconfigure();
      }
    }, _LoopbackHttpOverrides());
  });

  test('reopening an in-flight conversation preserves its stream and controller', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      Net.reconfigure();
      try {
        final original = app.chat;
        final sending = original.send([const TextPart('Keep streaming')]);
        await waitFor(
          () => original.conversation.currentMessages.last.text == 'Hello',
          diagnostic: () =>
              'error=${original.lastError}, nodes=${original.conversation.currentMessages.map((m) => m.text)}',
        );
        app.newChat();
        expect(app.chat.conversation.id, isNot(original.conversation.id));
        await app.openConversation(original.conversation.id);
        final reopened = app.chat;
        expect(identical(reopened, original), isTrue);
        expect(reopened.generating, isTrue);
        finish.complete();
        await sending;
        expect(app.chat.conversation.currentMessages.last.text, 'Hello world');
        expect(db.rows[original.conversation.id]!.currentMessages.last.text, 'Hello world');
      } finally {
        Net.reconfigure();
      }
    }, _LoopbackHttpOverrides());
  });

  test('deleting a generating conversation cancels its stream and removes its saved row', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      Net.reconfigure();
      try {
        final original = app.chat;
        final id = original.conversation.id;
        final sending = original.send([const TextPart('Delete this reply')]);
        await waitFor(() => original.conversation.currentMessages.last.text == 'Hello');
        expect(app.isGenerating(id), isTrue);

        await app.deleteConversation(id).timeout(const Duration(seconds: 5));
        if (!finish.isCompleted) finish.complete();
        await sending;

        expect(db.rows, isEmpty);
        expect(app.conversations, isEmpty);
        expect(app.chat.conversation.id, isNot(id));
      } finally {
        Net.reconfigure();
      }
    }, _LoopbackHttpOverrides());
  });
}
