import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/data/assistant.dart';
import 'package:mewhub/tools/local_tools.dart';
import 'package:mewhub/tools/plot_expression.dart';
import 'package:mewhub/tools/plot_segment_style.dart';
import 'package:mewhub/tools/spatial_plot.dart';
import 'package:mewhub/ui/chat/tool_card.dart';
import 'package:mewhub/ui/theme.dart';
import 'package:mewhub/ui/widgets/cartesian_plot_view.dart';
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

    test('normalizes the equation name before parsing and displays y as y', () {
      const source = 'Ｆ_２（Ｘ，Ｙ）＝２ＸＹ²＋√（Ｙ）';
      final surface = SpatialExpression.compile(source);
      expect(surface.source, source);
      expect(surface.evaluate(3, 4), 98);
      expect(surface.equationText, startsWith('F₂(x,y) = '));
      expect(surface.equationText, contains('y²'));
      expect(surface.equationTex, contains('y^{2}'));
      expect(SpatialExpression.compile('Z = SIN(Y)').evaluate(2, math.pi / 2), closeTo(1, 1e-10));
      expect(() => SpatialExpression.compile('xyz'), throwsFormatException);
      expect(() => SpatialExpression.compile('x±y±1'), throwsFormatException);
    });

    test('caches the sampled resolution and preserves holes and both branches', () {
      final plot = SpatialPlot(
        xMin: -1,
        xMax: 1,
        yMin: -1,
        yMax: 1,
        zMin: -1,
        zMax: 1,
        surfaces: ['z = ±sqrt(1 - x² - y²)', 'z = 5'],
      );
      final meshes = plot.sampleSurfaces(4);
      expect(plot.sampleSurfaces(4), same(meshes));
      expect(meshes.map((mesh) => mesh.surface), [0, 0, 1]);
      expect(meshes[0].vertices[12], (x: 0.0, y: 0.0, z: 1.0));
      expect(meshes[1].vertices[12], (x: 0.0, y: 0.0, z: -1.0));
      expect(meshes[0].vertices.first, isNull);
      expect(meshes[2].vertices.every((v) => v == null), isTrue);
      expect(plot.sampleSurfaces(8).first.vertices, hasLength(81));
      expect(() => plot.sampleSurfaces(1000), throwsRangeError);
      expect(SpatialPlot.fromJson(plot.toJson()), plot);
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

  group('spatial camera projection', () {
    final plot = SpatialPlot.example();

    test('skips repaint for equal plots and camera values, but not new views or styles', () {
      const size = Size(390, 844);
      final style = CartesianPlotStyle.of(MewTheme.dark(0));
      final old = SpatialPlotPainter(plot: plot, style: style, size: size);
      expect(
        SpatialPlotPainter(plot: SpatialPlot.fromJson(plot.toJson()), style: style, size: size).shouldRepaint(old),
        isFalse,
      );
      expect(SpatialPlotPainter(plot: plot, style: style, size: size, yaw: .7).shouldRepaint(old), isTrue);
      expect(SpatialPlotPainter(plot: plot, style: style, size: size.flipped).shouldRepaint(old), isTrue);
      expect(
        SpatialPlotPainter(plot: plot, style: CartesianPlotStyle.of(MewTheme.light(0)), size: size).shouldRepaint(old),
        isTrue,
      );
    });

    test('extends every XYZ axis across the viewport', () {
      const size = Size(390, 844);
      final projection = SpatialProjection(size: size, plot: plot);
      for (final axis in SpatialAxis.values) {
        final line = projection.axisAcrossCanvas(axis, 0, 0, 0);
        expect(line, isNotNull, reason: '$axis should cross the visible canvas');
        final (a, b) = line!;
        bool onEdge(Offset p) =>
            p.dx.abs() < 1e-6 ||
            (p.dx - size.width).abs() < 1e-6 ||
            p.dy.abs() < 1e-6 ||
            (p.dy - size.height).abs() < 1e-6;
        expect(onEdge(a), isTrue);
        expect(onEdge(b), isTrue);
        expect((b - a).distance, greaterThan(100));
      }
    });

    test('keeps the XY grid spacing steady as the camera zooms', () {
      const size = Size(390, 844);
      final normal = SpatialProjection(size: size, plot: plot);
      final zoomed = SpatialProjection(size: size, plot: plot, zoom: 3);
      expect(zoomed.gridStep, lessThan(normal.gridStep));

      double screenSpacing(SpatialProjection projection) =>
          (projection.project(0, 0, 0)!.at - projection.project(projection.gridStep, 0, 0)!.at).distance;
      expect(screenSpacing(normal), inInclusiveRange(18, 75));
      expect(screenSpacing(zoomed), inInclusiveRange(18, 75));
      expect(screenSpacing(zoomed), closeTo(screenSpacing(normal), 12));
    });

    test('uses orthographic geometry and extends the XY grid across the viewport', () {
      const size = Size(390, 844);
      final projection = SpatialProjection(size: size, plot: plot);
      final bounds = projection.xyPlaneWorldBounds(0);
      expect(bounds, isNotNull);
      expect(bounds!.width, greaterThan(plot.xMax - plot.xMin));
      expect(bounds.height, greaterThan(plot.yMax - plot.yMin));
      for (final fixedX in [true, false]) {
        final line = projection.xyGridLine(
          fixedX: fixedX,
          value: fixedX ? (bounds.left + bounds.right) / 2 : (bounds.top + bounds.bottom) / 2,
          z: 0,
        );
        expect(line, isNotNull);
        expect(
          line!.$1.dx.abs() < 1e-5 ||
              line.$1.dy.abs() < 1e-5 ||
              (line.$1.dx - size.width).abs() < 1e-5 ||
              (line.$1.dy - size.height).abs() < 1e-5,
          isTrue,
        );
        expect(
          line.$2.dx.abs() < 1e-5 ||
              line.$2.dy.abs() < 1e-5 ||
              (line.$2.dx - size.width).abs() < 1e-5 ||
              (line.$2.dy - size.height).abs() < 1e-5,
          isTrue,
        );
      }

      final cube = SpatialPlot(xMin: -1, xMax: 1, yMin: -1, yMax: 1, zMin: -1, zMax: 1);
      final cubeProjection = SpatialProjection(size: size, plot: cube);
      double edgeLength(double y, double z) =>
          (cubeProjection.project(1, y, z)!.at - cubeProjection.project(-1, y, z)!.at).distance;
      expect(edgeLength(-1, -1), closeTo(edgeLength(1, 1), 1e-8));
    });

    test('safely skips the XY grid when the plane is viewed edge-on', () {
      const size = Size(390, 844);
      final projection = SpatialProjection(size: size, plot: plot, pitch: 0);
      expect(projection.xyPlaneWorldBounds(0), isNull);
      final picture = ui.PictureRecorder();
      SpatialPlotPainter(
        plot: plot,
        style: CartesianPlotStyle.of(MewTheme.light(0)),
        size: size,
        pitch: 0,
      ).paint(Canvas(picture), size);
      picture.endRecording().dispose();
    });
  });

  group('spatial tool and persistence', () {
    test('the single switch registers both coordinate tools', () {
      final tools = buildLocalTools({LocalTool.cartesianPlot});
      expect(tools.map((tool) => tool.name), ['plot_cartesian', 'plot_spatial']);
      expect(buildLocalTools(const {}).where((tool) => tool.name.startsWith('plot_')), isEmpty);

      final spatial = tools.last;
      expect(spatial.promptHint, contains('close the outline from the last vertex back to the first'));
      expect(spatial.promptHint, contains('dotted for projection guides'));
      expect(spatial.description, contains('omit unrequested diagonals'));
      final segments = (spatial.parameters['properties'] as Map)['segments'] as Map;
      expect(segments['description'], contains('Each item joins two existing point labels exactly'));
      final properties = (segments['items'] as Map)['properties'] as Map;
      expect(properties['style']['enum'], ['solid', 'dashed', 'dotted', 'dash_dot']);
      expect(properties['color']['enum'], containsAll(['default', 'red', 'teal', 'blue', 'purple']));
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
            {'from': 'A', 'to': 'B', 'style': 'dash_dot', 'color': 'purple'},
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
      expect(plot.segments.map((segment) => segment.style), [PlotLineStyle.dashed, PlotLineStyle.dashDot]);
      expect(plot.segments.last.color, PlotLineColor.purple);
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
    final legend = tester.widget<PlotFormula>(find.byKey(const ValueKey('spatial-legend-0')));
    expect(legend.tex, 'z=x^{2}+y^{2}');
    expect(legend.text, 'z = x² + y²');
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
    expect(rotated.yaw, closeTo(initial.yaw + 70 / 140, .02));
    expect(rotated.pitch, closeTo(initial.pitch + 20 / 140, .02));
    expect(rotated.pan, initial.pan);
    expect(rotated.zoom, initial.zoom);

    final canvas = tester.getRect(find.byKey(const ValueKey('spatial-canvas')));
    final center = canvas.center;
    final first = await tester.startGesture(center + const Offset(-30, 0));
    final second = await tester.startGesture(center + const Offset(30, 0));
    await tester.pump();
    await first.moveBy(const Offset(30, 20));
    await tester.pump();
    await second.moveBy(const Offset(30, 20));
    await tester.pumpAndSettle();
    final panned = projection();
    expect(panned.pan, rotated.pan + const Offset(30, 20));
    expect(panned.yaw, rotated.yaw);
    expect(panned.pitch, rotated.pitch);
    final beforePinch = panned.zoom;
    await first.moveBy(const Offset(-15, 0));
    await second.moveBy(const Offset(15, 0));
    await tester.pumpAndSettle();
    expect(projection().zoom, greaterThan(beforePinch));
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

  testWidgets('asymmetric negative coordinate ranges render inside the canvas', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final plot = SpatialPlot(
      title: '偏心范围',
      xMin: -9,
      xMax: -2,
      yMin: 1,
      yMax: 5,
      zMin: -7,
      zMax: -3,
      points: const [SpatialPoint(x: -4, y: 2, z: -5, label: 'P')],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: MewTheme.light(0),
        home: SpatialPlotPage(initialPlot: plot),
      ),
    );
    await tester.pumpAndSettle();

    final paint = tester.widget<CustomPaint>(
      find.descendant(of: find.byKey(const ValueKey('spatial-canvas')), matching: find.byType(CustomPaint)),
    );
    final projection = (paint.painter as SpatialPlotPainter).projection;
    final bounds = Offset.zero & projection.size;
    for (final x in [plot.xMin, plot.xMax]) {
      for (final y in [plot.yMin, plot.yMax]) {
        for (final z in [plot.zMin, plot.zMax]) {
          expect(bounds.contains(projection.project(x, y, z)!.at), isTrue);
        }
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('spatial segment patterns and colors render without errors', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final plot = SpatialPlot(
      points: const [
        SpatialPoint(x: -2, y: -1, z: 0, label: 'A'),
        SpatialPoint(x: 2, y: -1, z: 0, label: 'B'),
        SpatialPoint(x: 2, y: 1, z: 2, label: 'C'),
        SpatialPoint(x: -2, y: 1, z: 2, label: 'D'),
      ],
      segments: const [
        SpatialSegment(from: 'A', to: 'B', style: PlotLineStyle.solid, color: PlotLineColor.blue),
        SpatialSegment(from: 'B', to: 'C', style: PlotLineStyle.dashed, color: PlotLineColor.orange),
        SpatialSegment(from: 'C', to: 'D', style: PlotLineStyle.dotted, color: PlotLineColor.green),
        SpatialSegment(from: 'D', to: 'A', style: PlotLineStyle.dashDot, color: PlotLineColor.purple),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: MewTheme.light(0),
        home: SpatialPlotPage(initialPlot: plot),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('inline plot orbits without scrolling its chat container', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: MewTheme.light(0),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                const SizedBox(height: 24),
                SpatialPlotCard(plot: SpatialPlot.example()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final beforeScroll = scrollable.position.pixels;
    final paint = tester.widget<CustomPaint>(find.byKey(const ValueKey('spatial-preview')));
    final initial = (paint.painter as SpatialPlotPainter).projection;
    await tester.drag(find.byKey(const ValueKey('spatial-preview')), const Offset(0, 80));
    await tester.pumpAndSettle();
    final after = tester.widget<CustomPaint>(find.byKey(const ValueKey('spatial-preview')));
    final rotated = (after.painter as SpatialPlotPainter).projection;
    expect(rotated.pitch, greaterThan(initial.pitch));
    expect(scrollable.position.pixels, beforeScroll);
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

  testWidgets('a malformed update cannot revive the previous spatial graph on rebuild', (tester) async {
    Future<void> show(String output) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ToolCard(
              part: ToolPart(callId: 'same', name: 'plot_spatial', input: '{}', output: output),
            ),
          ),
        ),
      ),
    );
    await show('{"type":"spatial_plot","plot":{"surfaces":["z = x+y"]}}');
    expect(find.byType(SpatialPlotCard), findsOneWidget);
    expect(
      spatialPlotDescription(tester.widget<SpatialPlotCard>(find.byType(SpatialPlotCard)).plot),
      endsWith('z = x + y'),
    );
    await show('{broken');
    await show('{broken');
    expect(find.byType(SpatialPlotCard), findsNothing);
    await show('{"error":"invalid surface"}');
    expect(find.text('invalid surface'), findsOneWidget);
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
