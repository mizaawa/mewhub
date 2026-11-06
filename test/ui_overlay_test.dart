import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/provider_config.dart';
import 'package:mewhub/data/settings.dart';
import 'package:mewhub/ui/chat/composer.dart';
import 'package:mewhub/ui/theme.dart';
import 'package:mewhub/ui/widgets/common.dart';

Widget _composer({required Future<void> Function(String) onSend}) => Composer(
  settings: AppSettings.fromJson(const {}),
  generating: false,
  onSend: (parts) => onSend(parts.map((p) => (p as dynamic).text as String).join()),
  onStop: () {},
  modelLabel: 'gpt-5.6',
  onPickModel: () {},
  searchEnabled: false,
  onToggleSearch: () {},
  reasoning: ReasoningLevel.auto,
  onReasoning: (_) {},
  supportsReasoning: true,
  supportsVision: true,
  activeModes: const {},
  onToggleMode: (_) {},
  onQuickMessage: (_) {},
  onCompress: () {},
);

void main() {
  testWidgets('toast sits above the composer and closes from its button', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        theme: MewTheme.light(0),
        home: Scaffold(
          body: Builder(
            builder: (c) {
              ctx = c;
              return Align(
                alignment: Alignment.bottomCenter,
                child: _composer(onSend: (_) async {}),
              );
            },
          ),
        ),
      ),
    );
    toast(ctx, 'Web search on');
    await tester.pumpAndSettle();
    expect(find.text('Web search on'), findsOneWidget);

    final toastBox = tester.getRect(find.text('Web search on'));
    final inputBox = tester.getRect(find.byType(TextField));
    expect(toastBox.bottom, lessThan(inputBox.top), reason: 'toast must not cover the input');

    // A second toast replaces the first instead of stacking.
    toast(ctx, 'Web search off');
    await tester.pumpAndSettle();
    expect(find.text('Web search on'), findsNothing);
    expect(find.text('Web search off'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close_rounded).last);
    await tester.pumpAndSettle();
    expect(find.text('Web search off'), findsNothing);

    // Auto-dismiss also cleans up its timer.
    toast(ctx, 'bye');
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(find.text('bye'), findsNothing);
  });

  testWidgets('full-screen editor shares the draft and can send it', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: MewTheme.light(0),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: _composer(onSend: (v) async => sent.add(v)),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'draft');
    await tester.tap(find.byIcon(Icons.open_in_full_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(FullScreenEditor), findsOneWidget);

    final editor = find.descendant(of: find.byType(FullScreenEditor), matching: find.byType(TextField));
    expect(tester.widget<TextField>(editor).controller!.text, 'draft');
    await tester.enterText(editor, 'draft\nline two');
    await tester.pump();
    expect(find.textContaining('2'), findsWidgets);

    // Collapse keeps the text in the composer.
    await tester.tap(find.byIcon(Icons.close_fullscreen_rounded));
    await tester.pumpAndSettle();
    expect(find.byType(FullScreenEditor), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'draft\nline two');

    await tester.tap(find.byIcon(Icons.open_in_full_rounded));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(FullScreenEditor), matching: find.byIcon(Icons.arrow_upward_rounded)),
    );
    await tester.pumpAndSettle();
    expect(sent, ['draft\nline two']);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
  });

  testWidgets('full-screen editor button aligns with the send button', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: _composer(onSend: (_) async {}),
          ),
        ),
      ),
    );
    final expandX = tester.getCenter(find.byIcon(Icons.open_in_full_rounded)).dx;
    final sendX = tester.getCenter(find.byIcon(Icons.arrow_upward_rounded)).dx;
    expect((expandX - sendX).abs(), lessThanOrEqualTo(1));
  });
}
