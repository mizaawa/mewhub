import 'dart:io';
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

  test('geometry preserves equal unit lengths for non-square coordinate ranges', () {
    final geometry = PlotGeometry(const Rect.fromLTRB(-10, -2, 10, 2), const Size(320, 480));
    final origin = geometry.toScreen(Offset.zero);
    expect(
      (geometry.toScreen(const Offset(1, 0)) - origin).distance,
      closeTo((geometry.toScreen(const Offset(0, 1)) - origin).distance, .000001),
    );
    final restored = geometry.toWorld(geometry.toScreen(const Offset(3, -1)));
    expect(restored.dx, closeTo(3, .000001));
    expect(restored.dy, closeTo(-1, .000001));
    expect(CartesianPlotPainter.tickStep(20, 300), greaterThan(0));
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

    await tester.enterText(find.byKey(const ValueKey('cartesian-functions-field')), 'sin(');
    await apply();
    expect(find.byKey(const ValueKey('cartesian-validation-error')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('cartesian-functions-field')), 'sin(x)\n-x^2+4');
    await tester.enterText(find.byKey(const ValueKey('cartesian-points-field')), 'bad point');
    await apply();
    expect(find.textContaining('坐标点格式'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('cartesian-points-field')), '1, 2, A\n-3, 4, B');
    await tester.enterText(find.byKey(const ValueKey('cartesian-bound-0')), '20');
    await apply();
    expect(find.textContaining('最大值必须大于'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('cartesian-bound-0')), '-5');
    await tester.enterText(find.byKey(const ValueKey('cartesian-title-field')), '我的函数');
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

  testWidgets('eight functions have distinct legend colors in every theme', (tester) async {
    final plot = CartesianPlot(functions: List.generate(8, (i) => 'x + $i'));
    for (var accent = 0; accent < MewColors.accents.length; accent++) {
      for (final dark in [false, true]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: dark ? MewTheme.dark(accent) : MewTheme.light(accent),
            home: Scaffold(
              body: SingleChildScrollView(child: CartesianPlotCard(plot: plot)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final colors = <Color?>{for (var i = 0; i < 8; i++) tester.widget<Text>(find.text('●  x + $i')).style!.color};
        expect(colors, hasLength(8));
        expect(tester.takeException(), isNull);
      }
    }
  });
}
