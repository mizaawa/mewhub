import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/core/accent_colors.dart';
import 'package:mewhub/ui/theme.dart';
import 'package:mewhub/ui/widgets/code_block.dart';
import 'package:mewhub/ui/widgets/common.dart';
import 'package:mewhub/ui/widgets/markdown_view.dart';

double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

double _hueGap(Color a, Color b) {
  final d = (HSLColor.fromColor(a).hue - HSLColor.fromColor(b).hue).abs() % 360;
  return math.min(d, 360 - d);
}

void main() {
  test('Caramel keeps the designed milk palette exactly', () {
    final light = MewTheme.light(0);
    expect(light.colorScheme.surface, MewColors.cream);
    expect(light.colorScheme.surfaceContainerLow, MewColors.milk);
    expect(light.colorScheme.surfaceContainer, MewColors.porcelain);
    expect(light.colorScheme.surfaceContainerHighest, MewColors.oat);
    expect(light.colorScheme.onSurface, MewColors.ink);
    expect(light.colorScheme.onSurfaceVariant, MewColors.mute);
    expect(light.colorScheme.onSecondaryContainer, MewColors.cocoa);
    expect(light.snackBarTheme.backgroundColor, MewColors.cocoa);
    final dark = MewTheme.dark(0);
    expect(dark.colorScheme.surface, MewColors.nightBase);
    expect(dark.colorScheme.surfaceContainerLow, MewColors.nightSurface);
    expect(dark.colorScheme.surfaceContainerHigh, MewColors.nightRaised);
    expect(dark.colorScheme.outlineVariant, MewColors.nightLine);
    final extra = light.extension<MewThemeColors>()!;
    expect(extra.accentGlow, const Color(0xFFE7B98F));
    expect(extra.codeSurface, const Color(0xFFF7F2EB));
    expect(extra.inlineCode, const Color(0xFF8B4F28));
    expect(extra.toastSurface, MewColors.cocoa);
    expect(dark.extension<MewThemeColors>()!.codeSurface, const Color(0xFF1C1915));
  });

  test('other accents re-tint every neutral and extra colour of the theme', () {
    for (var i = 1; i < accentColors.length; i++) {
      final accent = accentColors[i];
      for (final dark in [false, true]) {
        final theme = dark ? MewTheme.dark(i) : MewTheme.light(i);
        final s = theme.colorScheme;
        final reason = 'accent $i dark=$dark';
        expect(s.surface, mewRetint(dark ? MewColors.nightBase : MewColors.cream, accent), reason: reason);
        expect(s.onSurface, mewRetint(dark ? const Color(0xFFF1EAE1) : MewColors.ink, accent), reason: reason);
        expect(s.surfaceContainerLow, mewRetint(dark ? MewColors.nightSurface : MewColors.milk, accent));
        expect(s.outlineVariant, mewRetint(dark ? MewColors.nightLine : const Color(0xFFEAE0D3), accent));
        expect(theme.extension<MewThemeColors>(), MewThemeColors.forAccent(accent, theme.brightness), reason: reason);
        // Text stays as readable as the designed palette.
        expect(_contrast(s.onSurface, s.surface), greaterThan(12), reason: reason);
        expect(_contrast(s.onSurfaceVariant, s.surface), greaterThan(3.2), reason: reason);
        expect(_contrast(Colors.white, theme.snackBarTheme.backgroundColor!), greaterThan(7), reason: reason);
      }
      // Hues far from Caramel visibly move the cream and the gradient glow with them.
      if (_hueGap(accent, MewColors.caramel) > 30) {
        expect(MewTheme.light(i).colorScheme.surface, isNot(MewColors.cream));
        final glow = MewTheme.light(i).extension<MewThemeColors>()!.accentGlow;
        expect(_hueGap(glow, accent), lessThan(_hueGap(glow, MewColors.caramel)));
      }
    }
  });

  test('retinting keeps lightness and turns hue with the accent', () {
    const designed = Color(0xFFE7B98F);
    for (final accent in accentColors) {
      final out = HSLColor.fromColor(mewRetint(designed, accent));
      final source = HSLColor.fromColor(designed);
      expect(out.lightness, closeTo(source.lightness, 0.01));
      final expected = (source.hue + HSLColor.fromColor(accent).hue - HSLColor.fromColor(MewColors.caramel).hue) % 360;
      final gap = (out.hue - expected).abs() % 360;
      expect(math.min(gap, 360 - gap), lessThan(2));
    }
    expect(mewRetint(Colors.white, accentColors[4]), Colors.white);
  });

  test('themes compare equal for the same accent and lerp their extras', () {
    expect(MewTheme.light(3), MewTheme.light(3));
    expect(MewTheme.dark(3), MewTheme.dark(3));
    expect(MewTheme.light(3) == MewTheme.light(4), isFalse);
    final mid = ThemeData.lerp(MewTheme.light(0), MewTheme.light(4), 0.5).extension<MewThemeColors>()!;
    final a = MewTheme.light(0).extension<MewThemeColors>()!;
    final b = MewTheme.light(4).extension<MewThemeColors>()!;
    expect(mid.codeSurface, Color.lerp(a.codeSurface, b.codeSurface, 0.5));
  });

  testWidgets('code blocks, inline code and toasts use the accent palette', (tester) async {
    final theme = MewTheme.light(4);
    final extra = theme.extension<MewThemeColors>()!;
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Builder(
            builder: (c) {
              context = c;
              return const SingleChildScrollView(
                child: Column(
                  children: [
                    CodeBlock(code: 'print(1);', language: 'dart'),
                    MarkdownView(data: 'Run `flutter test` now'),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    bool painted(Color color) => find
        .byWidgetPredicate(
          (w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).color == color,
        )
        .evaluate()
        .isNotEmpty;
    expect(painted(extra.codeSurface), isTrue);
    final spans = <TextSpan>[];
    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      rich.text.visitChildren((span) {
        if (span is TextSpan) spans.add(span);
        return true;
      });
    }
    expect(spans.firstWhere((span) => span.text == 'flutter test').style?.color, extra.inlineCode);

    toast(context, 'Saved');
    await tester.pump(const Duration(milliseconds: 300));
    expect(painted(extra.toastSurface), isTrue);
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });
}
