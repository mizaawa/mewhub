import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/tools/cartesian_plot.dart';
import 'package:mewhub/ui/theme.dart';
import 'package:mewhub/ui/widgets/cartesian_plot_view.dart';

void main() {
  setUp(() => I18n.apply(AppLang.zh));

  Widget app(Widget child, {bool dark = false}) =>
      MaterialApp(theme: dark ? MewTheme.dark(3) : MewTheme.light(0), home: child);

  group('geometry', () {
    test('a window close to the canvas shape keeps equal units and fills the canvas', () {
      // The old fit left blank bands beside a square window on a tall canvas.
      const window = Rect.fromLTRB(-10, -10, 10, 10);
      final geometry = PlotGeometry(window, const Size(360, 600));
      expect(geometry.equalUnits, isTrue);
      expect(geometry.xScale, geometry.yScale);
      final origin = geometry.toScreen(Offset.zero);
      expect(
        (geometry.toScreen(const Offset(1, 0)) - origin).distance,
        closeTo((geometry.toScreen(const Offset(0, 1)) - origin).distance, 1e-9),
      );
      // The whole window is shown and spans the canvas width; the extra
      // height shows more of the plane instead of an empty margin.
      expect(geometry.visible.left, lessThanOrEqualTo(window.left));
      expect(geometry.visible.right, greaterThanOrEqualTo(window.right));
      expect(geometry.visible.top, lessThan(window.top));
      expect(geometry.visible.bottom, greaterThan(window.bottom));
      expect(geometry.toScreen(window.topLeft).dx, closeTo(14, 1e-9));
      expect(geometry.toScreen(window.bottomRight).dx, closeTo(360 - 14, 1e-9));
      final restored = geometry.toWorld(geometry.toScreen(const Offset(3, -1)));
      expect(restored.dx, closeTo(3, 1e-9));
      expect(restored.dy, closeTo(-1, 1e-9));
    });

    test('a much taller or wider window is stretched to fill instead of shrinking into a strip', () {
      const window = Rect.fromLTRB(-1, -1, 5, 30);
      final geometry = PlotGeometry(window, const Size(340, 300));
      expect(geometry.equalUnits, isFalse);
      expect(geometry.toScreen(const Offset(-1, 0)).dx, closeTo(14, 1e-9));
      expect(geometry.toScreen(const Offset(5, 0)).dx, closeTo(340 - 14, 1e-9));
      expect(geometry.toScreen(const Offset(0, 30)).dy, closeTo(14, 1e-9));
      expect(geometry.toScreen(const Offset(0, -1)).dy, closeTo(300 - 14, 1e-9));
      final restored = geometry.toWorld(geometry.toScreen(const Offset(2, 17)));
      expect(restored.dx, closeTo(2, 1e-9));
      expect(restored.dy, closeTo(17, 1e-9));
    });

    test('graphs of sin, cos and tan get ticks at multiples of π', () {
      expect(CartesianPlotPainter.piTickStep(4 * math.pi, 340), closeTo(math.pi / 2, 1e-12));
      expect(CartesianPlotPainter.piTickStep(2 * math.pi, 340), closeTo(math.pi / 4, 1e-12));
      expect(CartesianPlotPainter.piTickStep(100000, 340), isNull);
    });

    test('similar spans keep equal units on any canvas; lopsided windows fill it', () {
      // A 4:3 window on a tall phone and a square one in landscape stay true.
      for (final (window, size) in [
        (const Rect.fromLTRB(-8, -6, 8, 6), const Size(388, 683)),
        (const Rect.fromLTRB(-5, -5, 5, 5), const Size(880, 210)),
      ]) {
        final geometry = PlotGeometry(window, size);
        expect(geometry.equalUnits, isTrue, reason: '$window on $size');
        expect(geometry.xScale, geometry.yScale);
      }
      // sin x on [−2π, 2π] × [−1.5, 1.5] in the chat card fills its height.
      final trig = PlotGeometry(Rect.fromLTRB(-2 * math.pi, -1.5, 2 * math.pi, 1.5), const Size(345, 172.5));
      expect(trig.equalUnits, isFalse);
      expect(trig.toScreen(const Offset(0, 1.5)).dy, closeTo(14, 1e-9));
      expect(trig.toScreen(const Offset(0, -1.5)).dy, closeTo(172.5 - 14, 1e-9));
    });

    test('segments are clipped to the canvas before dashes are drawn', () {
      const bounds = Rect.fromLTWH(0, 0, 400, 300);
      final clip = CartesianPlotPainter.clipSegment(const Offset(-1e6, 50), const Offset(1e6, 50), bounds)!;
      expect(Offset.lerp(const Offset(-1e6, 50), const Offset(1e6, 50), clip.$1)!.dx, closeTo(0, 1e-6));
      expect(Offset.lerp(const Offset(-1e6, 50), const Offset(1e6, 50), clip.$2)!.dx, closeTo(400, 1e-6));
      expect(CartesianPlotPainter.clipSegment(const Offset(-50, -50), const Offset(-10, -90), bounds), isNull);
      expect(CartesianPlotPainter.clipSegment(const Offset(10, 10), const Offset(20, 20), bounds), (0.0, 1.0));
    });

    test('ticks land roughly 52 px apart on 1-2-5 steps', () {
      expect(CartesianPlotPainter.tickStep(20, 340), 2);
      expect(CartesianPlotPainter.tickStep(13, 340), 2);
      expect(CartesianPlotPainter.tickStep(100, 300), 20);
      expect(CartesianPlotPainter.tickStep(.02, 300), closeTo(.002, 1e-12));
    });
  });

  testWidgets('the chat card takes the window shape and fills the width', (tester) async {
    Future<Size> previewSize(CartesianPlot plot) async {
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(width: 340, child: CartesianPlotCard(plot: plot)),
            ),
          ),
        ),
      );
      return tester.getSize(find.byKey(const ValueKey('cartesian-preview')));
    }

    expect(await previewSize(CartesianPlot.example()), const Size(340, 340));
    expect(
      await previewSize(CartesianPlot(xMin: -10, xMax: 10, yMin: -2, yMax: 2, functions: const ['sin(x)'])),
      const Size(340, 170),
    );
    expect(
      await previewSize(CartesianPlot(xMin: -1, xMax: 5, yMin: -1, yMax: 30, functions: const ['2^x'])),
      Size(340, 340 / .75),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('circles, reference lines and segments paint without errors in every theme', (tester) async {
    final plot = CartesianPlot(
      functions: const ['C: y = ±sqrt(9 - x^2)', 'y = 1', 'x = -1', 'sin(x)'],
      points: const [
        PlotPoint(x: 0, y: 0, label: 'A'),
        PlotPoint(x: 3, y: 0, label: "A'"),
        PlotPoint(x: 0, y: 3, label: 'P_1', showCoordinates: false),
      ],
      segments: const [
        PlotSegment(from: 'A', to: "A'"),
        PlotSegment(from: "A'", to: 'P_1', dashed: true),
      ],
      xMin: -4,
      xMax: 4,
      yMin: -4,
      yMax: 4,
    );
    for (final dark in [false, true]) {
      await tester.pumpWidget(
        app(
          Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(width: 340, child: CartesianPlotCard(plot: plot, showHeader: false)),
            ),
          ),
          dark: dark,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cartesian-legend-0')), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    // A figure of points and segments has no legend; the button floats.
    await tester.pumpWidget(
      app(
        Scaffold(
          body: SizedBox(
            width: 340,
            child: CartesianPlotCard(
              plot: CartesianPlot(
                points: const [
                  PlotPoint(x: 0, y: 0, label: 'A'),
                  PlotPoint(x: 1, y: 1, label: 'B'),
                ],
                segments: const [PlotSegment(from: 'A', to: 'B')],
              ),
              showHeader: false,
            ),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('cartesian-expand')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the graph opens it full screen', (tester) async {
    await tester.pumpWidget(
      app(
        Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(width: 340, child: CartesianPlotCard(plot: CartesianPlot.example(), showHeader: false)),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('cartesian-expand')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cartesian-preview')));
    await tester.pumpAndSettle();
    expect(find.byType(CartesianPlotPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inline graph is visible and expands to interactive full-screen copy', (tester) async {
    final plot = CartesianPlot.example();
    await tester.pumpWidget(
      app(
        Scaffold(
          body: SizedBox(width: 340, child: CartesianPlotCard(plot: plot)),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('cartesian-preview')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('cartesian-expand')));
    await tester.pumpAndSettle();
    expect(find.byType(CartesianPlotPage), findsOneWidget);
    final original =
        tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byKey(const ValueKey('cartesian-canvas')),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter!
            as CartesianPlotPainter;
    await tester.tap(find.byKey(const ValueKey('cartesian-zoom-in')));
    await tester.pump();
    final zoomed =
        tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byKey(const ValueKey('cartesian-canvas')),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter!
            as CartesianPlotPainter;
    expect(zoomed.view.width, lessThan(original.view.width));
    await tester.drag(find.byKey(const ValueKey('cartesian-canvas')), const Offset(25, 20));
    await tester.pump();
    final moved =
        tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byKey(const ValueKey('cartesian-canvas')),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter!
            as CartesianPlotPainter;
    expect(moved.view.center, isNot(zoomed.view.center));
    await tester.tap(find.byKey(const ValueKey('cartesian-reset')));
    await tester.pump();
    final reset =
        tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byKey(const ValueKey('cartesian-canvas')),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter!
            as CartesianPlotPainter;
    expect(reset.view, original.view);
    expect(plot.functions, ['x^2', '2x + 1']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editor validates function syntax, points and bounds before applying', (tester) async {
    await tester.pumpWidget(app(CartesianPlotPage(initialPlot: CartesianPlot.example())));
    await tester.tap(find.byKey(const ValueKey('cartesian-edit')));
    await tester.pumpAndSettle();
    Future<void> apply() async {
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.ensureVisible(find.byKey(const ValueKey('cartesian-apply')));
      await tester.tap(find.byKey(const ValueKey('cartesian-apply')));
      await tester.pumpAndSettle();
    }

    // The sheet scrolls; a field must be on screen to receive the text.
    Future<void> type(String key, String text) async {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(ValueKey(key)), text);
    }

    await type('cartesian-functions-field', 'sin(');
    await apply();
    expect(find.byKey(const ValueKey('cartesian-validation-error')), findsOneWidget);
    await type('cartesian-functions-field', 'sin(x)\n-x^2+4');
    await type('cartesian-points-field', 'bad point');
    await apply();
    expect(find.textContaining('坐标点格式'), findsOneWidget);
    await type('cartesian-points-field', '1, 2, A\n-3, 4, B');
    await type('cartesian-bound-0', '20');
    await apply();
    expect(find.textContaining('最大值必须大于'), findsOneWidget);
    await type('cartesian-bound-0', '-5');
    await type('cartesian-title-field', '我的函数');
    await apply();
    expect(find.text('我的函数'), findsOneWidget);
    expect(find.byKey(const ValueKey('cartesian-validation-error')), findsNothing);
    final painter =
        tester
                .widget<CustomPaint>(
                  find.descendant(
                    of: find.byKey(const ValueKey('cartesian-canvas')),
                    matching: find.byType(CustomPaint),
                  ),
                )
                .painter!
            as CartesianPlotPainter;
    expect(painter.plot.functions, ['sin(x)', '-x^2+4']);
    expect(painter.plot.points.last.label, 'B');
    expect(painter.plot.xMin, -5);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark portrait, landscape and keyboard inset layouts do not overflow', (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final size in [const Size(320, 568), const Size(640, 320)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(
        app(
          CartesianPlotPage(
            key: ValueKey(size),
            initialPlot: CartesianPlot(functions: ['1/x', 'tan(x)', 'sqrt(x)']),
            allowAttach: true,
          ),
          dark: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('cartesian-edit')));
      await tester.pumpAndSettle();
      tester.view.viewInsets = FakeViewPadding(bottom: size.height * .4);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('cartesian-apply')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = FakeViewPadding.zero;
      Navigator.of(tester.element(find.byKey(const ValueKey('cartesian-apply')))).pop();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('PNG export contains real pixels and preserves requested dimensions', (tester) async {
    await tester.runAsync(() async {
      final bytes = await renderCartesianPlotPng(
        CartesianPlot(
          title: 'Cartesian plane',
          functions: ['x^2', 'sin(x)', '1/x'],
          points: const [PlotPoint(x: 2, y: 4, label: 'A')],
        ),
        size: const Size(800, 800),
      );
      expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 800);
      expect(frame.image.height, 800);
      final raw = await frame.image.toByteData();
      expect(raw!.buffer.asUint8List().toSet().length, greaterThan(30));
      final file = File('build/cartesian-preview.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      frame.image.dispose();
      codec.dispose();
    });
  });

  testWidgets('eight functions get distinct curve colours and typeset formulas in every theme', (tester) async {
    final plot = CartesianPlot(functions: List.generate(8, (i) => 'x + $i'));
    for (var accent = 0; accent < MewColors.accents.length; accent++) {
      for (final dark in [false, true]) {
        final theme = dark ? MewTheme.dark(accent) : MewTheme.light(accent);
        final style = CartesianPlotStyle.of(theme);
        expect(style.series.toSet(), hasLength(8), reason: 'accent $accent dark $dark');
        // The paper follows the accent instead of staying plain white.
        expect(style.paper, isNot(theme.colorScheme.surfaceContainerLow));
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: Scaffold(
              body: SingleChildScrollView(child: CartesianPlotCard(plot: plot)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (var i = 0; i < 8; i++) {
          expect(find.byKey(ValueKey('cartesian-legend-$i')), findsOneWidget);
          expect(find.byKey(ValueKey('cartesian-legend-swatch-$i')), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      }
    }
  });

  test('the first curve takes the accent and every theme keeps its own palette', () {
    for (var accent = 0; accent < MewColors.accents.length; accent++) {
      final light = CartesianPlotStyle.of(MewTheme.light(accent)).series;
      final dark = CartesianPlotStyle.of(MewTheme.dark(accent)).series;
      final hue = HSLColor.fromColor(MewColors.accents[accent]).hue;
      for (final first in [light.first, dark.first]) {
        final difference = (HSLColor.fromColor(first).hue - hue).abs() % 360;
        expect(math.min(difference, 360 - difference), lessThan(12), reason: 'accent $accent');
      }
    }
  });

  testWidgets('PNG export is as tall as the window shape needs', (tester) async {
    expect(cartesianPngSize(CartesianPlot.example()).width, 1200);
    final square = cartesianPngSize(CartesianPlot(functions: const ['x']));
    final wide = cartesianPngSize(CartesianPlot(xMin: -10, xMax: 10, yMin: -2, yMax: 2, functions: const ['x']));
    expect(wide.height, lessThan(square.height));
    await tester.runAsync(() async {
      final bytes = await renderCartesianPlotPng(
        CartesianPlot(
          functions: const ['f(x) = x^2 - 2x - 3', 'x = 1'],
          points: const [PlotPoint(x: 1, y: -4, label: 'P_1', showCoordinates: false)],
        ),
      );
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 1200);
      frame.image.dispose();
      codec.dispose();
    });
  });
}
