import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/tools/cartesian_plot.dart';
import 'package:mewhub/tools/plot_expression.dart';

void main() {
  group('PlotExpression', () {
    test('evaluates precedence, signed exponents, and right-associative powers', () {
      expect(PlotExpression.compile('-x^2').evaluate(3), -9);
      expect(PlotExpression.compile('x^-2').evaluate(2), 0.25);
      expect(PlotExpression.compile('2^3^2').evaluate(1), 512);
      expect(PlotExpression.compile('2( x + 1 )').evaluate(3), 8);
    });

    test('evaluates supported functions, constants, and common graph syntax', () {
      expect(PlotExpression.compile('y = sin(pi / 2)').evaluate(0), closeTo(1, 1e-10));
      expect(PlotExpression.compile('sqrt(x)+abs(-3)').evaluate(4), 5);
      expect(PlotExpression.compile('log(100)+ln(e)').evaluate(0), closeTo(3, 1e-10));
      expect(PlotExpression.compile('2x + 1').evaluate(4), 9);
    });

    test('leaves domain gaps as nonfinite values', () {
      expect(PlotExpression.compile('1 / x').evaluate(0).isInfinite, isTrue);
      expect(PlotExpression.compile('sqrt(x)').evaluate(-1).isNaN, isTrue);
    });

    test('rejects code, unknown symbols, broken syntax and resource abuse', () {
      for (final expression in [
        '',
        'import dart:io',
        'alert(x)',
        'x; throw 1',
        '(',
        'sin x',
        '1${List.filled(193, '+1').join()}',
        '(${List.filled(50, '(').join()}x${List.filled(50, ')').join()})',
        List.filled(513, 'x').join(),
      ]) {
        expect(() => PlotExpression.compile(expression), throwsFormatException, reason: expression);
      }
    });
  });

  group('CartesianPlot', () {
    test('serializes and restores bounded graph data', () {
      final plot = CartesianPlot(
        title: 'Parabola',
        xMin: -5,
        xMax: 5,
        yMin: -2,
        yMax: 20,
        functions: const ['x^2'],
        points: const [PlotPoint(x: 2, y: 4, label: 'A')],
      );
      final json = jsonDecode(jsonEncode(plot.toJson())) as Map<String, dynamic>;
      final restored = CartesianPlot.fromJson(json);
      expect(restored.title, 'Parabola');
      expect(restored.functions, ['x^2']);
      expect(restored.xMin, -5);
      expect(restored.points.single.x, 2);
      expect(restored.points.single.label, 'A');
    });

    test('provides a valid factory demo and immutable contents', () {
      final plot = CartesianPlot.example();
      expect(plot.functions, ['x^2', '2x + 1']);
      expect(() => plot.functions.add('x'), throwsUnsupportedError);
      expect(() => plot.points.add(const PlotPoint(x: 1, y: 1)), throwsUnsupportedError);
    });

    test('rejects nonfinite bounds, inverted or tiny ranges, oversized inputs, and unsafe points', () {
      for (final json in <Map<String, dynamic>>[
        {'x_min': double.nan},
        {'y_max': double.infinity},
        {'x_min': 11, 'x_max': 10},
        {'y_min': 1, 'y_max': 1},
        {'x_min': -1000001},
        {
          'points': [null],
        },
        {
          'functions': ['x;'],
        },
        {
          'points': List.filled(65, {'x': 1, 'y': 1}),
        },
        {'functions': List.filled(9, 'x')},
        {
          'points': [
            {'x': double.nan, 'y': 0},
          ],
        },
      ]) {
        expect(() => CartesianPlot.fromJson(json), throwsFormatException, reason: '$json');
      }
    });
  });

  group('Cartesian plotting tool', () {
    test('returns renderable structured chat output for a model-created plot', () async {
      final tool = buildCartesianPlotTool();
      expect(tool.name, 'plot_cartesian');
      final result = jsonDecode(
        await tool.execute({
          'title': 'Vertex',
          'functions': ['x^2'],
          'points': [
            {'x': 1, 'y': 1, 'label': 'A'},
          ],
        }),
      ) as Map<String, dynamic>;
      expect(result['type'], 'cartesian_plot');
      expect(CartesianPlot.fromJson(result['plot'] as Map<String, dynamic>).points.single.label, 'A');
    });

    test('returns a safe visible validation error for invalid model arguments', () async {
      final result = jsonDecode(
        await buildCartesianPlotTool().execute({
          'functions': ['evil()'],
        }),
      ) as Map<String, dynamic>;
      expect(result.containsKey('error'), isTrue);
      expect(result.containsKey('type'), isFalse);
    });
  });
}
