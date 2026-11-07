import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/chat/chat_controller.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/data/conversation.dart';
import 'package:mewhub/data/database.dart';
import 'package:mewhub/state/app_state.dart';
import 'package:mewhub/state/settings_store.dart';
import 'package:mewhub/state/tts.dart';
import 'package:mewhub/ui/chat/chat_page.dart';
import 'package:mewhub/ui/chat/message_bubble.dart';
import 'package:mewhub/ui/chat/composer.dart';
import 'package:mewhub/ui/theme.dart';
import 'package:mewhub/ui/widgets/markdown_view.dart';
import 'package:provider/provider.dart';

final _capture = Platform.environment['MEWHUB_CAPTURE_DIR'];
final _captureKey = GlobalKey();

class _Database implements AppDatabase {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #saveConversation) return Future<void>.value();
    return super.noSuchMethod(invocation);
  }
}

class _Chat extends ChatController {
  _Chat({required super.store, required super.db, required super.mcp, required super.conversation});
  bool streaming = true;
  @override
  bool get generating => streaming;
}

class _App extends AppState {
  _App({required super.store, required super.db});
  late final controller = _Chat(
    store: store,
    db: db,
    mcp: mcp,
    conversation: Conversation(
      assistantId: store.value.currentAssistantId,
      nodes: [
        for (var i = 0; i < 40; i++)
          MessageNode(
            id: 'node-$i',
            messages: [
              ChatMessage.text(i.isEven ? Role.user : Role.assistant, 'message $i\n${'content $i ' * (i % 3 + 1)}'),
            ],
          ),
      ],
    ),
  );
  @override
  _Chat get chat => controller;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }
}

Future<void> _frames(WidgetTester tester, [int count = 40]) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late SettingsStore store;
  late _App app;

  setUpAll(() async {
    if (_capture != null) {
      final bytes = await File(Platform.environment['MEWHUB_TEST_FONT']!).readAsBytes();
      for (final family in ['Roboto', 'Ahem', 'monospace']) {
        await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
      await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mewhub_reading');
    AppPaths.support = temp;
    AppPaths.cache = temp;
    FlutterSecureStorage.setMockInitialValues({});
    store = await SettingsStore.load();
    I18n.apply(AppLang.zh);
    app = _App(store: store, db: _Database());
  });

  tearDown(() async {
    app.dispose();
    store.dispose();
    // dispose queues one final save; drain it before deleting the sandbox.
    await store.flush();
    await temp.delete(recursive: true);
  });

  Future<ScrollPosition> open(WidgetTester tester, {bool dark = false, bool reduceMotion = false}) async {
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
          key: _captureKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: dark ? MewTheme.dark(0) : MewTheme.light(0),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
              child: child!,
            ),
            home: const ChatPage(),
          ),
        ),
      ),
    );
    await _frames(tester);
    return tester.state<ScrollableState>(find.byType(Scrollable).first).position;
  }

  void grow({bool append = false}) {
    app.chat.applyExternal((c) {
      final nodes = [...c.nodes];
      if (append) {
        nodes.add(MessageNode(id: 'appended', messages: [ChatMessage.text(Role.assistant, 'new tool reply')]));
      } else {
        final last = nodes.last;
        nodes[nodes.length - 1] = last.upsert(
          last.current.copyWith(
            parts: [TextPart('${last.current.text}\n${List.generate(12, (i) => 'stream line $i').join('\n')}')],
          ),
        );
      }
      return c.copyWith(nodes: nodes);
    });
  }

  Future<void> capture(WidgetTester tester, String name) async {
    if (_capture == null) return;
    await tester.runAsync(() async {
      final boundary = _captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$_capture/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  }

  for (final dark in [false, true]) {
    testWidgets('code wrapper has no background or padding, dark=$dark', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: dark ? MewTheme.dark(0) : MewTheme.light(0),
          home: const Scaffold(body: MarkdownView(data: '```markdown\n# Title\n```')),
        ),
      );
      await _frames(tester);
      final sheet = tester.widget<MarkdownBody>(find.byType(MarkdownBody)).styleSheet!;
      final decoration = sheet.codeblockDecoration! as BoxDecoration;
      debugPrint('code wrapper: color=${decoration.color}, padding=${sheet.codeblockPadding}');
      expect(decoration.color?.a ?? 0, 0);
      expect(sheet.codeblockPadding, EdgeInsets.zero);
    });
  }

  for (final append in [false, true]) {
    testWidgets('history stays still during ${append ? 'new message' : 'stream growth'}', (tester) async {
      final position = await open(tester);
      final reversed = position.axisDirection == AxisDirection.up;
      position.jumpTo(reversed ? 180 : position.maxScrollExtent - 180);
      await _frames(tester);
      final visible = find.byType(MessageBubble).evaluate().where((e) {
        final r = tester.getRect(find.byWidget(e.widget));
        return r.top >= 130 && r.bottom < 600;
      }).toList();
      expect(visible, isNotEmpty);
      final anchor = (visible.first.widget as MessageBubble).node.id;
      final finder = find.byWidgetPredicate((w) => w is MessageBubble && w.node.id == anchor);
      final before = tester.getTopLeft(finder).dy;
      grow(append: append);
      await _frames(tester);
      expect(finder, findsOneWidget);
      final after = tester.getTopLeft(finder).dy;
      debugPrint('history anchor=$anchor before=$before after=$after drift=${after - before}');
      expect(after, closeTo(before, 0.5));
      expect(find.byKey(const ValueKey('streaming-below')), findsOneWidget);
    });
  }

  testWidgets('bottom follows growth over multiple frames', (tester) async {
    final position = await open(tester);
    final before = position.pixels;
    grow();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    final first = position.pixels;
    await tester.pump(const Duration(milliseconds: 80));
    final middle = position.pixels;
    await _frames(tester, 90);
    debugPrint('follow offsets: before=$before first=$first middle=$middle final=${position.pixels}');
    expect(first, greaterThanOrEqualTo(before));
    expect(middle, greaterThan(first));
    expect(position.pixels, greaterThan(middle));
    expect(position.extentAfter, lessThan(1));
    expect(find.byKey(const ValueKey('chat-navigation')), findsNothing);
  });

  testWidgets('navigation expands on scroll, collapses at rest and hides at bottom', (tester) async {
    final position = await open(tester);
    expect(find.byKey(const ValueKey('chat-navigation')), findsNothing);
    final scrollable = find.byType(Scrollable).first;
    await tester.drag(scrollable, const Offset(0, 280));
    await _frames(tester, 12);
    for (final tip in ['到最顶部', '上一条我的消息', '下一条我的消息', '到最底部']) {
      expect(find.byTooltip(tip), findsOneWidget);
    }
    await _frames(tester, 180);
    expect(find.byTooltip('展开消息导航'), findsOneWidget);
    await tester.tap(find.byTooltip('展开消息导航'));
    await _frames(tester, 15);
    expect(find.byTooltip('到最顶部'), findsOneWidget);
    await tester.tap(find.byTooltip('到最顶部'));
    await _frames(tester, 60);
    expect(position.pixels, closeTo(position.minScrollExtent, 1));
    await tester.tap(find.byTooltip('下一条我的消息'));
    await _frames(tester, 40);
    expect(position.pixels, greaterThan(0));
    await tester.tap(find.byTooltip('上一条我的消息'));
    await _frames(tester, 40);
    expect(position.pixels, closeTo(position.minScrollExtent, 1));
    await tester.tap(find.byTooltip('到最底部'));
    await _frames(tester, 90);
    expect(position.extentAfter, lessThan(1));
    expect(find.byKey(const ValueKey('chat-navigation')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('messages fade under the transparent header', (tester) async {
    await open(tester);
    expect(tester.widget<Scaffold>(find.byType(Scaffold).first).extendBodyBehindAppBar, isTrue);
    final mask = tester.widget<ShaderMask>(find.byKey(const ValueKey('chat-top-fade')));
    expect(mask.blendMode, BlendMode.dstIn);
    expect(tester.takeException(), isNull);
  });

  testWidgets('drag interrupts follow immediately and reaching bottom resumes it', (tester) async {
    final position = await open(tester);
    grow();
    await _frames(tester, 4);
    final gesture = await tester.startGesture(const Offset(140, 300));
    await gesture.moveBy(const Offset(0, 130));
    await _frames(tester, 3);
    final reading = position.pixels;
    for (var chunk = 0; chunk < 5; chunk++) {
      grow();
      await _frames(tester, 4);
      expect(position.pixels, closeTo(reading, 0.5));
    }
    await gesture.up();
    await _frames(tester, 50);
    final stopped = position.pixels;
    grow(append: true);
    await _frames(tester, 40);
    expect(position.pixels, closeTo(stopped, 0.5));
    await tester.tap(find.byKey(const ValueKey('streaming-below')));
    await _frames(tester, 80);
    expect(position.extentAfter, lessThan(1));
    grow();
    await _frames(tester, 80);
    expect(position.extentAfter, lessThan(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual scroll to bottom resumes following, wheel scroll pauses it', (tester) async {
    final position = await open(tester);
    await tester.sendEventToBinding(
      const PointerScrollEvent(position: Offset(150, 350), scrollDelta: Offset(0, -200), kind: PointerDeviceKind.mouse),
    );
    await _frames(tester, 30);
    final before = position.pixels;
    grow();
    await _frames(tester, 30);
    expect(position.pixels, closeTo(before, 0.5));
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -800));
    await _frames(tester, 90);
    expect(position.extentAfter, lessThan(1));
    grow();
    await _frames(tester, 80);
    expect(position.extentAfter, lessThan(1));
    expect(find.byKey(const ValueKey('chat-navigation')), findsNothing);
  });

  testWidgets('generation finishing hides dots and keeps the reading position', (tester) async {
    final position = await open(tester);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 250));
    await _frames(tester, 50);
    expect(find.byKey(const ValueKey('streaming-below')), findsOneWidget);
    final before = position.pixels;
    app.chat.streaming = false;
    app.chat.applyExternal((c) => c);
    await _frames(tester);
    expect(position.pixels, closeTo(before, 0.5));
    expect(find.byKey(const ValueKey('streaming-below')), findsNothing);
    expect(find.byKey(const ValueKey('chat-navigation')), findsOneWidget);
  });

  testWidgets('large variable-height history jumps only between user messages', (tester) async {
    app.chat.applyExternal(
      (c) => c.copyWith(
        nodes: [
          for (var i = 0; i < 240; i++)
            MessageNode(
              id: 'long-$i',
              messages: [
                ChatMessage.text(
                  i % 3 == 0 ? Role.user : Role.assistant,
                  'message $i\n${List.generate(i % 9 + 1, (line) => 'variable line $line').join('\n')}',
                ),
              ],
            ),
        ],
      ),
    );
    final position = await open(tester);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 250));
    await _frames(tester, 40);
    await tester.tap(find.byTooltip('到最顶部'));
    await _frames(tester, 100);
    expect(position.pixels, closeTo(0, 1));
    final previous = find.widgetWithIcon(IconButton, Icons.keyboard_arrow_up_rounded);
    expect(tester.widget<IconButton>(previous).onPressed, isNull);
    for (final index in [3, 6, 9]) {
      await tester.tap(find.byTooltip('下一条我的消息'));
      await _frames(tester, 55);
      final item = find.byWidgetPredicate((w) => w is MessageBubble && w.node.id == 'long-$index');
      expect(tester.getTopLeft(item).dy, closeTo(80, 1));
    }
    await tester.tap(find.byTooltip('上一条我的消息'));
    await _frames(tester, 55);
    final item = find.byWidgetPredicate((w) => w is MessageBubble && w.node.id == 'long-6');
    expect(tester.getTopLeft(item).dy, closeTo(80, 1));
    await tester.tap(find.byTooltip('到最底部'));
    await _frames(tester, 120);
    expect(position.extentAfter, lessThan(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard and composer resize preserve bottom following', (tester) async {
    final position = await open(tester);
    await tester.enterText(find.byType(TextField), 'draft\nline 2\nline 3\nline 4');
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await _frames(tester, 70);
    expect(position.extentAfter, lessThan(1));
    expect(find.byKey(const ValueKey('chat-navigation')), findsNothing);
    tester.view.viewInsets = FakeViewPadding.zero;
    await _frames(tester, 60);
    expect(position.extentAfter, lessThan(1));
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets('navigation respects safe areas and reduced motion, dark=$dark', (tester) async {
      tester.view.padding = const FakeViewPadding(top: 28, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 28, bottom: 24);
      final position = await open(tester, dark: dark, reduceMotion: true);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 220));
      await _frames(tester, 20);
      expect(
        tester.getRect(find.byKey(const ValueKey('chat-navigation'))).bottom,
        lessThan(tester.getRect(find.byType(Composer)).top),
      );
      expect(find.byKey(const ValueKey('streaming-below')), findsOneWidget);
      await capture(tester, dark ? 'chat-dark' : 'chat-light');
      await tester.tap(find.byTooltip('到最底部'));
      await _frames(tester, 20);
      expect(position.extentAfter, lessThan(1));
      expect(find.byKey(const ValueKey('chat-navigation')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
