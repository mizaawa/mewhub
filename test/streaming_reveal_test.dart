import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/ui/theme.dart';
import 'package:mewhub/ui/widgets/streaming_reveal.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => I18n.apply(AppLang.zh));

  testWidgets('streamed text appears gradually, then settles on the full text', (tester) async {
    const body = 'The quick brown fox jumps over the lazy dog and keeps running.';
    final state = GlobalKey<StreamingRevealState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: MewTheme.light(0),
        home: Scaffold(
          body: StreamingReveal(key: state, text: body, streaming: true),
        ),
      ),
    );
    await tester.pump();
    final first = tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data;
    expect(first.length, lessThan(body.length), reason: 'the whole text must not appear in one frame');

    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final later = tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data;
    expect(later.length, greaterThan(first.length));

    await tester.pumpWidget(
      MaterialApp(
        theme: MewTheme.light(0),
        home: Scaffold(
          body: StreamingReveal(key: state, text: body, streaming: false),
        ),
      ),
    );
    await tester.pump();
    expect(tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data, body);
    expect(find.byType(MarkdownBody), findsOneWidget);
  });

  testWidgets('reduced motion shows the finished text at once', (tester) async {
    const body = 'Instant text for users who prefer less motion.';
    await tester.pumpWidget(
      MaterialApp(
        theme: MewTheme.light(0),
        builder: (context, child) =>
            MediaQuery(data: MediaQuery.of(context).copyWith(disableAnimations: true), child: child!),
        home: const Scaffold(body: StreamingReveal(text: body, streaming: true)),
      ),
    );
    await tester.pump();
    expect(tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data, body);
  });
}
