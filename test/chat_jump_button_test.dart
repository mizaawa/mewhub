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
    await store.flush();
    store.dispose();
    await temp.delete(recursive: true);
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
    await tester.pump(const Duration(milliseconds: 400));

    final list = tester.widget<ListView>(find.byType(ListView).first);
    list.controller!.jumpTo(300);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final jump = find.ancestor(
      of: find.byIcon(Icons.keyboard_double_arrow_down_rounded),
      matching: find.byType(FloatingActionButton),
    );
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

    await tester.tap(jump);
    await tester.pump();
    for (var frame = 0; frame < 40; frame++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(list.controller!.offset, 0);
    final scale = tester.widget<AnimatedScale>(find.ancestor(of: jump, matching: find.byType(AnimatedScale)));
    expect(scale.scale, 0);
    debugPrint('after jump: scroll=${list.controller!.offset}, button scale=${scale.scale}');
    expect(tester.takeException(), isNull);
  });
}
