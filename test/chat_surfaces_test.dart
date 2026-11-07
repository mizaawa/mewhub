import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/data/assistant.dart';
import 'package:mewhub/data/conversation.dart';
import 'package:mewhub/data/settings.dart';
import 'package:mewhub/ui/chat/message_bubble.dart';
import 'package:mewhub/ui/chat/reasoning_card.dart';
import 'package:mewhub/ui/chat/tool_card.dart';
import 'package:mewhub/ui/theme.dart';
import 'package:mewhub/ui/widgets/code_block.dart';
import 'package:mewhub/ui/widgets/markdown_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final capture = Platform.environment['MEWHUB_CAPTURE_DIR'];

  setUpAll(() async {
    I18n.apply(AppLang.zh);
    if (capture != null) {
      final bytes = await File(Platform.environment['MEWHUB_TEST_FONT']!).readAsBytes();
      for (final family in ['Roboto', 'Ahem', 'monospace']) {
        await (FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
      await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  for (final dark in [false, true]) {
    testWidgets('all message surfaces are borderless, dark=$dark', (tester) async {
      tester.view.physicalSize = const Size(420, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final imageKey = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: imageKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: dark ? MewTheme.dark(0) : MewTheme.light(0),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: MessageBubble(
                    node: MessageNode(
                      messages: [
                        ChatMessage(
                          role: Role.assistant,
                          parts: [
                            const TextPart('文档和消息卡片使用统一的无描边外观。\n\n```markdown\n# Sora 兼容接口文档\n\n公开的调用示例。\n```'),
                            ReasoningPart('检查各组件的表面与圆角。', finishedAt: DateTime(2026, 11, 8)),
                            const ToolPart(
                              callId: 'tool',
                              name: 'calculate',
                              input: '{"expression":"1 + 1"}',
                              output: '2',
                            ),
                            const DocumentPart(path: 'fixture.md', fileName: '接口说明.md', mime: 'text/markdown'),
                            const CitationsPart([Citation(title: '参考资料', url: 'https://example.com')]),
                          ],
                        ),
                      ],
                    ),
                    index: 0,
                    assistant: Assistant(name: 'MewBot'),
                    display: const DisplaySettings(bubbleAssistant: true),
                    streaming: false,
                    isLast: true,
                    favorite: false,
                    onAction: (_) {},
                    onApprove: (_, _) {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final type in [CodeBlock, ReasoningCard, ToolCard]) {
        expect(find.byType(type), findsOneWidget);
      }
      final surfaces = find.descendant(of: find.byType(MessageBubble), matching: find.byType(DecoratedBox));
      for (final box in tester.widgetList<DecoratedBox>(surfaces)) {
        final decoration = box.decoration;
        if (decoration is BoxDecoration) {
          expect(decoration.border, isNull, reason: 'Unexpected card outline: $decoration');
        }
      }
      if (capture != null) {
        await tester.runAsync(() async {
          final boundary = imageKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File('$capture/surfaces-${dark ? 'dark' : 'light'}.png').writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('code aliases, nested blocks and math keep their own transparent wrapper', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MewTheme.light(0),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: MarkdownView(
              data: r'''
```md
# Markdown
```

```json
{"key": "value"}
```

> ```python
> print("nested")
> ```

| a | b |
|---|---|
| 1 | 2 |

$$x^2 + y^2 = z^2$$
''',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CodeBlock), findsNWidgets(3));
    expect(find.byType(Table), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
