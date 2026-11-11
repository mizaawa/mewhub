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
  Future<void> deleteConversation(String id) async => rows.remove(id);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LoopbackHttpOverrides extends HttpOverrides {}

Future<void> waitFor(bool Function() predicate, {String Function()? diagnostic}) async {
  for (var i = 0; i < 400; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting${diagnostic == null ? '' : ': ${diagnostic()}'}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late SettingsStore store;
  late MemoryDatabase db;
  late AppState app;
  late HttpServer server;
  late List<String> prompts;
  late Completer<void> firstGate;
  late Completer<void> secondGate;
  late Completer<void> firstByte;

  setUp(() async {
    HttpOverrides.global = null;
    Net.reconfigure();
    temp = await Directory.systemTemp.createTemp('mewhub_edit');
    AppPaths.support = temp;
    AppPaths.cache = temp;
    FlutterSecureStorage.setMockInitialValues({});
    store = await SettingsStore.load();
    prompts = [];
    firstGate = Completer<void>();
    secondGate = Completer<void>();
    // The first byte is held until a test releases it, so "stop before any
    // text" is deterministic; other tests release it right after sending.
    firstByte = Completer<void>();
    var call = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      prompts.add(await utf8.decodeStream(request));
      request.response.bufferOutput = false;
      request.response.headers.contentType = ContentType('text', 'event-stream');
      final current = call++;
      final gate = current == 0 ? firstGate : secondGate;
      try {
        // The first request waits for the test's go-ahead, so text can never
        // arrive before a stop that is meant to happen with nothing displayed.
        if (current == 0) await firstByte.future;
        request.response.write('data: {"choices":[{"delta":{"content":"part${current}a"}}]}\n\n');
        await request.response.flush();
        await gate.future;
        request.response.write(
          'data: {"choices":[{"delta":{"content":" part${current}b"},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
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
    if (!firstByte.isCompleted) firstByte.complete();
    if (!firstGate.isCompleted) firstGate.complete();
    if (!secondGate.isCompleted) secondGate.complete();
    app.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await server.close(force: true);
    Net.reconfigure();
    await store.flush();
    store.dispose();
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

  test('saving an edited user message updates the chat and regenerates the reply', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      Net.reconfigure();
      try {
        final chat = app.chat;
        final sending = chat.send([const TextPart('first question')]);
        await waitFor(() => prompts.isNotEmpty);
        firstByte.complete();
        await waitFor(() => chat.conversation.currentMessages.length == 2);
        firstGate.complete();
        await sending;
        expect(chat.conversation.currentMessages.last.text, 'part0a part0b');
        expect(chat.generating, isFalse);

        final resend = chat.editAndResend(chat.conversation.nodes.first.current.id, [
          const TextPart('edited question'),
        ]);
        await waitFor(
          () =>
              chat.conversation.currentMessages.length == 2 &&
              chat.conversation.nodes.first.current.text == 'edited question',
          diagnostic: () => 'nodes=${chat.generating}',
        );
        await waitFor(() => chat.conversation.currentMessages.last.text.contains('part1a'));
        secondGate.complete();
        await resend;

        final msgs = chat.conversation.currentMessages;
        expect(msgs.length, 2);
        expect(msgs[0].text, 'edited question');
        expect(msgs[1].role, Role.assistant);
        expect(msgs[1].text, 'part1a part1b');
        expect(db.rows[chat.conversation.id]!.currentMessages[0].text, 'edited question');
        expect(prompts.length, 2);
        expect(prompts[1], contains('edited question'));
        expect(prompts[1], isNot(contains('first question')));
      } finally {
        Net.reconfigure();
      }
    }, _LoopbackHttpOverrides());
  });

  test('saving an edit while the reply is still streaming applies it and starts over', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      Net.reconfigure();
      try {
        final chat = app.chat;
        unawaited(chat.send([const TextPart('first question')]));
        await waitFor(() => prompts.isNotEmpty);
        firstByte.complete();
        await waitFor(() => chat.conversation.currentMessages.last.text == 'part0a');
        expect(chat.generating, isTrue);

        final resend = chat.editAndResend(chat.conversation.nodes.first.current.id, [
          const TextPart('edited question'),
        ]);
        await waitFor(
          () =>
              chat.conversation.currentMessages.length == 2 &&
              chat.conversation.nodes.first.current.text == 'edited question',
          diagnostic: () =>
              'generating=${chat.generating} nodes=${chat.conversation.currentMessages.map((m) => m.text).toList()}',
        );
        await waitFor(() => chat.generating && chat.conversation.currentMessages.last.text.contains('part1a'));
        secondGate.complete();
        await resend;

        final msgs = chat.conversation.currentMessages;
        expect(msgs.length, 2);
        expect(msgs[0].text, 'edited question');
        expect(msgs[1].text, 'part1a part1b');
        expect(prompts.last, contains('edited question'));
      } finally {
        Net.reconfigure();
      }
    }, _LoopbackHttpOverrides());
  });

  test('stopping a reply keeps the partial text visible and in the next prompt', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      Net.reconfigure();
      try {
        final chat = app.chat;
        final sending = chat.send([const TextPart('tell me a story')]);
        await waitFor(() => prompts.isNotEmpty);
        firstByte.complete();
        await waitFor(() => chat.conversation.currentMessages.last.text == 'part0a');
        chat.stop();
        await sending;

        final msgs = chat.conversation.currentMessages;
        expect(msgs.length, 2);
        expect(msgs[1].text, 'part0a', reason: 'the stopped reply must not disappear');
        expect(msgs[1].interrupted, isTrue);
        expect(msgs[1].error, isNull);
        expect(chat.generating, isFalse);
        expect(db.rows[chat.conversation.id]!.currentMessages[1].text, 'part0a');

        // A follow-up turn still carries the partial reply as context.
        secondGate = Completer<void>()..complete();
        final follow = chat.send([const TextPart('go on')]);
        await waitFor(() => prompts.length >= 2);
        await follow;
        expect(prompts[1], contains('part0a'));
        expect(prompts[1], contains('tell me a story'));
      } finally {
        Net.reconfigure();
      }
    }, _LoopbackHttpOverrides());
  });

  test('stopping before any text arrives leaves no empty bubble behind', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      Net.reconfigure();
      try {
        final chat = app.chat;
        // Hold the first byte back so the stop lands before any text exists.
        firstByte = Completer<void>();
        final sending = chat.send([const TextPart('answer this')]);
        await waitFor(() => chat.conversation.currentMessages.length == 2);
        chat.stop();
        await sending;
        final msgs = chat.conversation.currentMessages;
        expect(
          msgs.length,
          1,
          reason:
              'an empty placeholder must be dropped: ${msgs.map((m) => '${m.role.name}:${m.text}:${m.interrupted}').toList()}',
        );
        expect(msgs.single.text, 'answer this');
      } finally {
        Net.reconfigure();
      }
    }, _LoopbackHttpOverrides());
  });
}
