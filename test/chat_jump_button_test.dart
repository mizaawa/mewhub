import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/ai/provider_config.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/data/conversation.dart';
import 'package:mewhub/data/database.dart';
import 'package:mewhub/state/app_state.dart';
import 'package:mewhub/state/settings_store.dart';
import 'package:mewhub/state/tts.dart';
import 'package:mewhub/ui/chat/chat_page.dart';
import 'package:mewhub/ui/chat/composer.dart';
import 'package:mewhub/ui/chat/message_bubble.dart';
import 'package:mewhub/ui/theme.dart';
import 'package:provider/provider.dart';

class _FakeDatabase implements AppDatabase {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #saveConversation) return Future<void>.value();
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late SettingsStore store;
  late AppState app;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mewhub_chat_jump');
    AppPaths.support = temp;
    AppPaths.cache = temp;
    FlutterSecureStorage.setMockInitialValues({});
    store = await SettingsStore.load();
    final reasoningModel = store.value.providers
        .expand((provider) => provider.models)
        .firstWhere((model) => model.modelId == 'gpt-5.1');
    store.update(
      (s) => s.copyWith(language: AppLang.zh, lastChatModelId: reasoningModel.id, lastReasoning: ReasoningLevel.max),
    );
    I18n.apply(AppLang.zh);
    app = AppState(store: store, db: _FakeDatabase());
    app.chat.applyExternal(
      (c) => c.copyWith(
        nodes: [
          for (var i = 0; i < 30; i++)
            MessageNode(
              messages: [ChatMessage.text(i.isEven ? Role.user : Role.assistant, 'message $i ${'content ' * 18}')],
            ),
        ],
      ),
    );
  });

  tearDown(() async {
    app.dispose();
    store.dispose();
    await store.flush();
    await temp.delete(recursive: true);
  });

  testWidgets('messages run behind the composer and the last one rests above it', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(bottom: 24);
    addTearDown(tester.view.reset);
    app.chat.applyExternal((c) => c.copyWith(suggestions: const ['再详细一点', '换个说法']));

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: store),
          ChangeNotifierProvider.value(value: app),
          ChangeNotifierProvider(create: (_) => TtsService()),
        ],
        child: MaterialApp(theme: MewTheme.light(0), home: const ChatPage()),
      ),
    );
    for (var frame = 0; frame < 50; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final list = tester.getRect(find.byType(Scrollable).first);
    final composer = tester.getRect(find.byType(Composer));
    final suggestion = tester.getRect(find.text('再详细一点'));
    // The list is no longer cut off above the dock: it reaches the screen edge.
    expect(list.bottom, 844);
    expect(list.bottom, greaterThan(composer.bottom - 1));
    // At the bottom, the last reply still sits clear of suggestions and input.
    final last = tester.getRect(find.textContaining('message 29', findRichText: true).first);
    expect(last.bottom, lessThan(suggestion.top));
    final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(position.extentAfter, lessThan(1));

    // Scrolling up puts conversation text behind the floating dock.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 240));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final under = find.byType(MessageBubble).evaluate().where((e) {
      final box = e.renderObject! as RenderBox;
      return (box.localToGlobal(Offset.zero) & box.size).overlaps(composer);
    });
    expect(under, isNotEmpty, reason: 'messages continue under the translucent composer area');
    expect(tester.takeException(), isNull);
  });

  testWidgets('jump-to-bottom stays above the composer as its height changes', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(bottom: 24);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: store),
          ChangeNotifierProvider.value(value: app),
          ChangeNotifierProvider(create: (_) => TtsService()),
        ],
        child: MaterialApp(theme: MewTheme.light(0), home: const ChatPage()),
      ),
    );
    await tester.pump();
    for (var frame = 0; frame < 50; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    final position = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final jump = find.byKey(const ValueKey('chat-navigation'));
    final reasoning = find.byWidgetPredicate((widget) => widget is Tooltip && widget.message == '思考强度');
    expect(jump, findsOneWidget);
    expect(reasoning, findsOneWidget);
    void expectClear(String state) {
      final jumpRect = tester.getRect(jump);
      final reasoningRect = tester.getRect(reasoning);
      final composerRect = tester.getRect(find.byType(Composer));
      debugPrint(
        '$state: overlap=${jumpRect.overlaps(reasoningRect)}, '
        'reasoning gap=${reasoningRect.top - jumpRect.bottom}, composer gap=${composerRect.top - jumpRect.bottom}',
      );
      expect(jumpRect.overlaps(reasoningRect), isFalse, reason: '$state: jump=$jumpRect, reasoning=$reasoningRect');
      expect(jumpRect.bottom, lessThanOrEqualTo(composerRect.top - 12), reason: state);
    }

    expectClear('single line with bottom safe area');
    await tester.enterText(find.byType(TextField), 'line 1\nline 2\nline 3\nline 4\nline 5');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expectClear('multiline draft');

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    tester.view.padding = FakeViewPadding.zero;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expectClear('keyboard open');

    final buttons = find.byWidgetPredicate((w) => w.key.toString().contains('jump-tile-'));
    expect(buttons, findsNWidgets(4));
    for (final button in buttons.evaluate()) {
      expect(tester.getSize(find.byWidget(button.widget)), const Size(24, 24));
    }
    await tester.tap(find.byTooltip('到最底部'));
    await tester.pump();
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(position.extentAfter, lessThan(1));
    expect(jump, findsNothing);
    debugPrint('after jump: remaining=${position.extentAfter}, navigation hidden');
    expect(tester.takeException(), isNull);
  });
}
