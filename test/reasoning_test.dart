import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/provider_config.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/data/assistant.dart';
import 'package:mewhub/data/settings.dart';
import 'package:mewhub/state/settings_store.dart';
import 'package:mewhub/ui/chat/composer.dart';
import 'package:mewhub/ui/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('UI offers auto through max, without off', () {
    expect(ReasoningLevel.selectable.map((e) => e.effort), ['auto', 'low', 'medium', 'high', 'xhigh', 'max']);
  });

  test('stored "off" and unknown values load as auto', () {
    expect(ReasoningLevel.fromName('off'), ReasoningLevel.auto);
    expect(ReasoningLevel.fromName('bogus'), ReasoningLevel.auto);
    expect(ReasoningLevel.fromName('xhigh'), ReasoningLevel.xhigh);
    expect(Assistant.fromJson({'reasoning': 'off'}).reasoning, ReasoningLevel.auto);
  });

  test('OpenAI effort steps down for models without xhigh / max', () {
    expect(openAiEffort('gpt-5.6', ReasoningLevel.max), 'max');
    expect(openAiEffort('gpt-5.5', ReasoningLevel.max), 'xhigh');
    expect(openAiEffort('gpt-5.4', ReasoningLevel.xhigh), 'xhigh');
    expect(openAiEffort('gpt-5', ReasoningLevel.xhigh), 'high');
    expect(openAiEffort('o3', ReasoningLevel.max), 'high');
    expect(openAiEffort('gpt-5', ReasoningLevel.medium), 'medium');
  });

  test('Claude effort steps down on older models', () {
    expect(anthropicEffort('claude-opus-5-5', ReasoningLevel.xhigh), 'xhigh');
    expect(anthropicEffort('claude-opus-4-6', ReasoningLevel.xhigh), 'high');
    expect(anthropicEffort('claude-opus-4-6', ReasoningLevel.max), 'max');
    expect(anthropicEffort('claude-opus-4-5-20251101', ReasoningLevel.max), 'high');
  });

  group('last pick persists', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('mewhub_reason');
      AppPaths.support = tmp;
      AppPaths.cache = tmp;
      FlutterSecureStorage.setMockInitialValues({});
    });
    tearDown(() => tmp.delete(recursive: true));

    test('model and reasoning survive a reload', () async {
      final store = await SettingsStore.load();
      store.update((s) => s.copyWith(lastChatModelId: 'm1', lastReasoning: ReasoningLevel.xhigh));
      await store.flush();
      final again = await SettingsStore.load();
      expect(again.value.lastChatModelId, 'm1');
      expect(again.value.lastReasoning, ReasoningLevel.xhigh);
      final cleared = AppSettings.fromJson(again.value.copyWith(lastChatModelId: null).toJson());
      expect(cleared.lastChatModelId, isNull);
      expect(cleared.lastReasoning, ReasoningLevel.xhigh);
    });
  });

  testWidgets('long model names fit a narrow phone without overflow', (tester) async {
    tester.view.physicalSize = const Size(320 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: MewTheme.light(0),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Composer(
              settings: AppSettings.fromJson(const {}),
              generating: false,
              onSend: (_) async {},
              onStop: () {},
              modelLabel: 'claude-opus-5-5-20261101-thinking-extended-preview',
              providerLabel: 'Some very long gateway name',
              onPickModel: () {},
              searchEnabled: false,
              onToggleSearch: () {},
              reasoning: ReasoningLevel.xhigh,
              onReasoning: (_) {},
              supportsReasoning: true,
              supportsVision: true,
              activeModes: const {},
              onToggleMode: (_) {},
              onQuickMessage: (_) {},
              onCompress: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('claude-opus-5-5', findRichText: true), findsOneWidget);
  });

  testWidgets('reasoning sheet slider reports each level', (tester) async {
    final picked = <ReasoningLevel>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: MewTheme.light(0),
        home: Scaffold(
          body: ReasoningSheet(initial: ReasoningLevel.medium, onChanged: picked.add),
        ),
      ),
    );
    await tester.tap(find.text('xhigh'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('auto'));
    await tester.pumpAndSettle();
    expect(picked, [ReasoningLevel.xhigh, ReasoningLevel.auto]);
    expect(tester.takeException(), isNull);
  });
}
