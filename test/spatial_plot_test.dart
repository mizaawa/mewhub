import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/data/assistant.dart';
import 'package:mewhub/tools/local_tools.dart';
import 'package:mewhub/tools/plot_expression.dart';
import 'package:mewhub/tools/spatial_plot.dart';
import 'package:mewhub/ui/chat/tool_card.dart';
import 'package:mewhub/ui/theme.dart';
import 'package:mewhub/ui/widgets/spatial_plot_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('surface expressions', () {
    test('evaluates x and y, names, constants and implicit multiplication', () {
      expect(SpatialExpression.compile('x^2 + 2y + sin(y)').evaluate(3, 2), closeTo(13 + math.sin(2), 1e-12));
      expect(SpatialExpression.compile('f(x,y) = sqrt(x^2+y^2)').evaluate(3, 4), 5);
      expect(SpatialExpression.compile('z = pi * x * y').evaluate(2, 3), closeTo(6 * math.pi, 1e-12));
      expect(SpatialExpression.compile('z = −x² + cos(y)').evaluate(2, 0), -3);
    });

    test('keeps domain errors out of the mesh and rejects other variables', () {
      expect(SpatialExpression.compile('sqrt(9-x^2-y^2)').evaluate(4, 0), isNaN);
      expect(SpatialExpression.compile('1/(x-y)').evaluate(2, 2).isInfinite, isTrue);
      for (final expression in ['', 'z = ', 'z = t + 1', 'z = x; delete()', 'z = y = 2']) {
        expect(() => SpatialExpression.compile(expression), throwsFormatException, reason: expression);
      }
      expect(() => PlotExpression.compile('y'), throwsFormatException, reason: '2D expressions stay one-dimensional');
    });
  });

  group('spatial tool and persistence', () {
    test('the single switch registers both coordinate tools', () {
      final tools = buildLocalTools({LocalTool.cartesianPlot});
      expect(tools.map((tool) => tool.name), ['plot_cartesian', 'plot_spatial']);
      expect(buildLocalTools(const {}).where((tool) => tool.name.startsWith('plot_')), isEmpty);
    });

    test('serializes a surface, 3D points and segments', () async {
      final result = jsonDecode(
        await buildSpatialPlotTool().execute({
          'title': '马鞍面',
          'surfaces': ['z = x^2 - y^2'],
          'points': [
            {'x': 1, 'y': 0, 'z': 1, 'label': 'A'},
            {'x': 0, 'y': 1, 'z': -1, 'label': 'B', 'show_coordinates': false},
          ],
          'segments': [
            {'from': 'A', 'to': 'B', 'dashed': true},
          ],
          'x_min': -2,
          'x_max': 2,
          'y_min': -2,
          'y_max': 2,
          'z_min': -2,
          'z_max': 2,
        }),
      ) as Map<String, dynamic>;
      expect(result['type'], 'spatial_plot');
      expect(result.containsKey('error'), isFalse);
      final plot = SpatialPlot.fromJson(result['plot'] as Map<String, dynamic>);
      expect(plot.expressions.single.evaluate(2, 1), 3);
      expect(plot.points.map((p) => p.caption), ['A (1, 0, 1)', 'B']);
      expect(plot.segments.single.dashed, isTrue);
      expect(SpatialPlot.fromJson(jsonDecode(jsonEncode(plot.toJson()))), plot);
      expect(plot.copyWith(zMax: 10), isNot(plot));
    });

    test('validates all three ranges, point coordinates and segment labels', () async {
      for (final arguments in [
        {'x_min': 1, 'x_max': 1},
        {'y_min': double.nan},
        {'z_min': 3, 'z_max': 2},
        {
          'points': [
            {'x': 1, 'y': 2},
          ],
        },
        {
          'points': [
            {'x': 1, 'y': 2, 'z': 3, 'label': 'A'},
          ],
          'segments': [
            {'from': 'A', 'to': 'missing'},
          ],
        },
        {
          'surfaces': ['x + y + z'],
        },
        {'surfaces': List.filled(7, 'x')},
      ]) {
        expect(jsonDecode(await buildSpatialPlotTool().execute(arguments)), contains('error'));
      }
    });
  });

  testWidgets('saved spatial tool results render in chat and open full screen', (tester) async {
    I18n.apply(AppLang.zh);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final output = await buildSpatialPlotTool().execute({
      'title': '抛物面',
      'surfaces': ['x^2+y^2'],
      'z_min': 0,
      'z_max': 60,
    });
    final original = ToolPart(callId: 'spatial', name: 'plot_spatial', input: '{}', output: output);
    final restored = Part.fromJson(jsonDecode(jsonEncode(original.toJson()))) as ToolPart;
    await tester.pumpWidget(
      MaterialApp(
        theme: MewTheme.light(0),
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: MewTheme.light(0),
        home: Scaffold(
          body: SingleChildScrollView(child: ToolCard(part: restored)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SpatialPlotCard), findsOneWidget);
    expect(find.text('空间直角坐标系'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('spatial-expand')));
    await tester.pumpAndSettle();
    expect(find.byType(SpatialPlotPage), findsOneWidget);
    expect(find.text('单指旋转 · 双指平移/缩放'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one finger rotates and two fingers pan and zoom', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: MewTheme.light(0),
        home: SpatialPlotPage(initialPlot: SpatialPlot.example()),
      ),
    );
    await tester.pumpAndSettle();
    SpatialProjection projection() =>
        tester
                .widget<CustomPaint>(
                  find.descendant(of: find.byKey(const ValueKey('spatial-canvas')), matching: find.byType(CustomPaint)),
                )
                .painter
            is SpatialPlotPainter
        ? (tester
                      .widget<CustomPaint>(
                        find.descendant(
                          of: find.byKey(const ValueKey('spatial-canvas')),
                          matching: find.byType(CustomPaint),
                        ),
                      )
                      .painter
                  as SpatialPlotPainter)
              .projection
        : fail('missing spatial painter');
    final initial = projection();
    await tester.drag(find.byKey(const ValueKey('spatial-canvas')), const Offset(70, 20));
    await tester.pumpAndSettle();
    final rotated = projection();
    expect(rotated.yaw, isNot(initial.yaw));
    expect(rotated.pitch, greaterThan(initial.pitch));
    expect(rotated.pan, initial.pan);
    expect(rotated.zoom, initial.zoom);

    final canvas = tester.getRect(find.byKey(const ValueKey('spatial-canvas')));
    final center = canvas.center;
    final first = await tester.startGesture(center + const Offset(-30, 0));
    final second = await tester.startGesture(center + const Offset(30, 0));
    await tester.pump();
    await first.moveBy(const Offset(30, 20));
    await second.moveBy(const Offset(30, 20));
    await tester.pumpAndSettle();
    final panned = projection();
    expect(panned.pan, rotated.pan + const Offset(30, 20));
    expect(panned.yaw, rotated.yaw);
    expect(panned.pitch, rotated.pitch);
    await first.up();
    await second.up();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('spatial-zoom-in')));
    await tester.pumpAndSettle();
    expect(projection().zoom, greaterThan(1));
    await tester.tap(find.byKey(const ValueKey('spatial-reset')));
    await tester.pumpAndSettle();
    expect(projection().zoom, 1);
    expect(projection().pan, Offset.zero);
    expect(projection().yaw, -.65);
    expect(tester.takeException(), isNull);
  });

  testWidgets('full screen editor validates and applies 3D parameters', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: MewTheme.light(0),
        home: SpatialPlotPage(initialPlot: SpatialPlot.example()),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('spatial-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('spatial-surfaces-field')), 'x + y + z');
    await tester.ensureVisible(find.byKey(const ValueKey('spatial-apply')));
    await tester.tap(find.byKey(const ValueKey('spatial-apply')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('spatial-validation-error')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('spatial-surfaces-field')), 'z = x*y');
    await tester.enterText(find.byKey(const ValueKey('spatial-points-field')), '1, 2, 2, A');
    await tester.ensureVisible(find.byKey(const ValueKey('spatial-apply')));
    await tester.tap(find.byKey(const ValueKey('spatial-apply')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('spatial-validation-error')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending, denied and malformed spatial results never draw', (tester) async {
    for (final part in [
      const ToolPart(callId: 's', name: 'plot_spatial', input: '{}', approval: ToolApproval.pending),
      const ToolPart(callId: 's', name: 'plot_spatial', input: '{}', output: '{broken'),
      const ToolPart(callId: 's', name: 'plot_spatial', input: '{}', output: '{"error":"bad range"}'),
      const ToolPart(
        callId: 's',
        name: 'plot_spatial',
        input: '{}',
        output: '{"type":"spatial_plot","plot":{}}',
        approval: ToolApproval.denied,
      ),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ToolCard(part: part)),
        ),
      );
      await tester.pump();
      expect(find.byType(SpatialPlotCard), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}
