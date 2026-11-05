import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ui/theme.dart';
import 'package:mewhub/ui/widgets/code_block.dart';
import 'package:mewhub/ui/widgets/markdown_view.dart';

const _sample = r'''
# Title

Some **bold** text with inline math $E=mc^2$ and a price of $5 and $6.

$$
\int_0^1 x^2 dx = \frac{1}{3}
$$

| a | b |
|---|---|
| 1 | 2 |

```dart
void main() => print('hi');
```
''';

void main() {
  testWidgets('renders markdown with code, math and tables', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MewTheme.light(0),
        home: const Scaffold(
          body: SingleChildScrollView(child: MarkdownView(data: _sample)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CodeBlock), findsOneWidget);
    expect(find.byType(Math), findsNWidgets(2));
    expect(find.byType(Table), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('normalizes bracket math delimiters', () {
    final bs = String.fromCharCode(92);
    expect(MarkdownView.normalizeMath('a $bs(x$bs) b'), r'a $x$ b');
    expect(MarkdownView.normalizeMath('$bs[y$bs]'), '\n\$\$y\$\$\n');
  });

  test('prices with dollar signs are not treated as math', () {
    final syntax = InlineMathSyntax();
    expect(RegExp(syntax.pattern.pattern).hasMatch(r'costs $5 and $6 today'), isFalse);
    expect(RegExp(syntax.pattern.pattern).hasMatch(r'inline $x^2$ here'), isTrue);
  });
}
