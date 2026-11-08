import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/data/assistant.dart';
import 'package:mewhub/data/config_transfer.dart';
import 'package:mewhub/data/conversation.dart';
import 'package:mewhub/data/database.dart';
import 'package:mewhub/data/models_misc.dart';
import 'package:mewhub/data/settings.dart';
import 'package:mewhub/state/app_state.dart';
import 'package:mewhub/state/settings_store.dart';
import 'package:mewhub/state/tts.dart';
import 'package:mewhub/ui/chat/chat_page.dart';
import 'package:mewhub/ui/chat/chat_usage_sheet.dart';
import 'package:mewhub/ui/chat/message_bubble.dart';
import 'package:mewhub/ui/settings/config_transfer_pages.dart';
import 'package:mewhub/ui/theme.dart';
import 'package:provider/provider.dart';

final _capture = Platform.environment['MEWHUB_CAPTURE_DIR'];
final _key = GlobalKey();

/// In-memory store: no debounced timers or file writes inside fake async.
class _MemoryStore extends ChangeNotifier implements SettingsStore {
  _MemoryStore(this._value);
  AppSettings _value;

  @override
  AppSettings get value => _value;

  @override
  void update(AppSettings Function(AppSettings s) fn) {
    _value = fn(_value);
    notifyListeners();
  }

  @override
  void replace(AppSettings settings) => update((_) => settings);

  @override
  void upsertAssistant(Assistant a) =>
      update((s) => s.copyWith(assistants: [for (final x in s.assistants) x.id == a.id ? a : x]));

  @override
  Future<void> flush() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Db implements AppDatabase {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #saveConversation) return Future<void>.value();
    if (invocation.memberName == #memories) return Future.value(<MemoryItem>[]);
    return super.noSuchMethod(invocation);
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  if (_capture == null) return;
  await tester.runAsync(() async {
    final boundary = _key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$_capture/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _frames(WidgetTester tester, [int n = 30]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    I18n.apply(AppLang.zh);
    if (_capture != null) {
      final bytes = await File(Platform.environment['MEWHUB_TEST_FONT']!).readAsBytes();
      for (final family in ['Roboto', 'Ahem', 'monospace']) {
        await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
      await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  testWidgets('assistant header shows the assistant name with the model underneath', (tester) async {
    Widget bubble({required bool showModel, String? modelName = 'gpt-6-astra'}) => MaterialApp(
      theme: MewTheme.light(0),
      home: Scaffold(
        body: MessageBubble(
          node: MessageNode(
            messages: [
              ChatMessage(role: Role.assistant, parts: const [TextPart('hello')], modelName: modelName),
            ],
          ),
          index: 0,
          assistant: Assistant(name: 'Zako'),
          display: DisplaySettings(showModelName: showModel),
          streaming: false,
          isLast: true,
          favorite: false,
          onAction: (_) {},
          onApprove: (_, _) {},
        ),
      ),
    );
    await tester.pumpWidget(bubble(showModel: true));
    await tester.pumpAndSettle();
    final name = tester.getRect(find.text('Zako'));
    final model = tester.getRect(find.byKey(const ValueKey('assistant-header-model')));
    expect(find.text('gpt-6-astra'), findsOneWidget);
    expect(model.top, greaterThanOrEqualTo(name.bottom - 1), reason: 'model name sits under the assistant name');
    final nameStyle = tester.widget<Text>(find.text('Zako')).style!;
    final modelStyle = tester.widget<Text>(find.text('gpt-6-astra')).style!;
    expect(modelStyle.fontSize!, lessThan(nameStyle.fontSize!));

    await tester.pumpWidget(bubble(showModel: false));
    await tester.pumpAndSettle();
    expect(find.text('Zako'), findsOneWidget);
    expect(find.text('gpt-6-astra'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('usage sheet summarises the visible branch per model', (tester) async {
    final conv = Conversation(
      assistantId: 'a',
      nodes: [
        MessageNode(messages: [ChatMessage.text(Role.user, 'q')]),
        MessageNode(
          messages: [
            ChatMessage(
              role: Role.assistant,
              parts: const [TextPart('a')],
              modelId: 'm1',
              modelName: 'Model One',
              usage: const TokenUsage(input: 12000, output: 3000, cached: 6000, reasoning: 1000),
            ),
          ],
        ),
        MessageNode(messages: [ChatMessage.text(Role.user, 'q2')]),
        MessageNode(
          messages: [
            ChatMessage(
              role: Role.assistant,
              parts: const [TextPart('b')],
              modelId: 'm2',
              modelName: 'Model Two',
              usage: const TokenUsage(input: 20000, output: 1000),
            ),
          ],
        ),
      ],
    );
    final summary = ChatUsageSummary.of(conv);
    expect(summary.total.total, 36000);
    expect(summary.replies, 2);
    expect(summary.models.map((m) => m.name), ['Model Two', 'Model One']);
    expect(summary.cacheRate, closeTo(6000 / 32000, 1e-9));

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: _key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: MewTheme.light(0),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: Material(
                color: MewTheme.light(0).colorScheme.surfaceContainerLow,
                child: ChatUsageSheet(summary: summary, contextLength: 128000),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('36,000'), findsOneWidget);
    expect(find.text('Model One'), findsOneWidget);
    expect(find.text('最近一次请求的上下文'), findsOneWidget);
    await _shot(tester, 'usage-sheet');
    expect(tester.takeException(), isNull);
  });

  group('chat page quick drawers', () {
    late _MemoryStore store;
    late AppState app;

    setUp(() {
      store = _MemoryStore(
        AppSettings.initial().copyWith(
          language: AppLang.zh,
          onboarded: true,
          mcpServers: [McpServerConfig(id: 'mt', name: 'mt', url: 'http://127.0.0.1:1/mcp')],
          quickMessages: [QuickMessage(id: 'q1', title: '总结一下', content: '请总结上面的内容')],
          lorebooks: [
            Lorebook(
              id: 'book',
              name: '设定集',
              entries: [
                LoreEntry(keywords: const ['猫'], content: '设定'),
              ],
            ),
          ],
        ),
      );
      I18n.apply(AppLang.zh);
      app = AppState(store: store, db: _Db());
    });

    tearDown(() {
      app.dispose();
      store.dispose();
    });

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<SettingsStore>.value(value: store),
            ChangeNotifierProvider<AppState>.value(value: app),
            ChangeNotifierProvider(create: (_) => TtsService()),
          ],
          child: RepaintBoundary(
            key: _key,
            child: MaterialApp(debugShowCheckedModeBanner: false, theme: MewTheme.light(0), home: const ChatPage()),
          ),
        ),
      );
      await _frames(tester);
    }

    testWidgets('the + panel keeps one compact action row plus MCP and extension entries', (tester) async {
      await open(tester);
      await tester.tap(find.byIcon(Icons.add_rounded));
      await _frames(tester);
      final panel = tester.getRect(find.byKey(const ValueKey('composer-tools-panel')));
      expect(panel.height, lessThan(140), reason: 'two short rows, not a grid');
      for (final key in ['photos', 'camera', 'files', 'compress']) {
        expect(find.byKey(ValueKey('composer-action-$key')), findsOneWidget);
      }
      expect(find.text('MCP'), findsOneWidget);
      expect(find.text('扩展'), findsOneWidget);
      await _shot(tester, 'composer-panel');
      expect(tester.takeException(), isNull);
    });

    testWidgets('MCP drawer toggles a server for the current assistant', (tester) async {
      await open(tester);
      await tester.tap(find.byIcon(Icons.add_rounded));
      await _frames(tester);
      await tester.tap(find.byKey(const ValueKey('composer-mcp-entry')));
      await _frames(tester, 40);
      expect(find.text('MCP 服务器'), findsOneWidget);
      final card = find.byKey(const ValueKey('mcp-quick-mt'));
      expect(card, findsOneWidget);
      final assistantId = store.value.currentAssistantId;
      // Pre-1.5 settings without a link get the server attached once.
      final linked = store.value.assistantById(assistantId)!.mcpServerIds.contains('mt');
      await tester.tap(find.descendant(of: card, matching: find.byType(Switch)));
      await _frames(tester, 20);
      expect(store.value.assistantById(assistantId)!.mcpServerIds.contains('mt'), !linked);
      await _shot(tester, 'mcp-drawer');
      expect(tester.takeException(), isNull);
    });

    testWidgets('extension drawer inserts quick messages and links lorebooks', (tester) async {
      await open(tester);
      await tester.tap(find.byIcon(Icons.add_rounded));
      await _frames(tester);
      await tester.tap(find.byKey(const ValueKey('composer-extensions-entry')));
      await _frames(tester, 40);
      expect(find.text('总结一下'), findsOneWidget);
      await _shot(tester, 'extensions-drawer');
      await tester.tap(find.byKey(const ValueKey('ext-tab-lorebooks')));
      await _frames(tester, 20);
      final lore = find.byKey(const ValueKey('lore-book'));
      expect(lore, findsOneWidget);
      await tester.tap(find.descendant(of: lore, matching: find.byType(Switch)));
      await _frames(tester, 10);
      expect(store.value.currentAssistant.lorebookIds, contains('book'));
      await tester.tap(find.byKey(const ValueKey('ext-tab-modes')));
      await _frames(tester, 20);
      final modeId = store.value.modes.first.id;
      await tester.tap(find.descendant(of: find.byKey(ValueKey('mode-$modeId')), matching: find.byType(Switch)));
      await _frames(tester, 10);
      expect(app.chat.modeIds, contains(modeId));
      await tester.tap(find.byKey(const ValueKey('ext-tab-quick')));
      await _frames(tester, 20);
      await tester.tap(find.text('总结一下'));
      await _frames(tester);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, '请总结上面的内容');
      expect(tester.takeException(), isNull);
    });

    testWidgets('backup page offers QR transfer and the sender loops through every code', (tester) async {
      tester.view.physicalSize = const Size(390, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Widget wrap(Widget page) => MultiProvider(
        providers: [
          ChangeNotifierProvider<SettingsStore>.value(value: store),
          ChangeNotifierProvider<AppState>.value(value: app),
        ],
        child: RepaintBoundary(
          key: _key,
          child: MaterialApp(debugShowCheckedModeBanner: false, theme: MewTheme.light(0), home: page),
        ),
      );
      await tester.pumpWidget(wrap(const ConfigQrSendPage(includeSecrets: false)));
      await _frames(tester, 10);
      final frames = ConfigTransfer.encode(store.value, includeSecrets: false);
      expect(find.byKey(const ValueKey('config-qr')), findsOneWidget);
      final seen = <String>{};
      for (var i = 0; i < frames.length + 1; i++) {
        seen.add(tester.widget<Text>(find.byKey(const ValueKey('config-qr-index'))).data!);
        await tester.pump(const Duration(milliseconds: 660));
      }
      expect(seen.length, frames.length, reason: 'every code is shown in turn');
      await _shot(tester, 'qr-send');
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    });
  });
}
