import 'dart:convert';

import 'plot_expression.dart';
import 'tool.dart';

class PlotPoint {
  const PlotPoint({required this.x, required this.y, this.label = ''});
  final double x;
  final double y;
  final String label;

  factory PlotPoint.fromJson(Map<String, dynamic> json) => PlotPoint(
    x: _coordinate(json['x'], 'point x'),
    y: _coordinate(json['y'], 'point y'),
    label: _text(json['label'], 'point label', 40),
  );

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'label': label};
}

/// Serializable plot data stored in the normal tool result / chat history.
/// All entry points validate limits before the renderer does any sampling.
class CartesianPlot {
  CartesianPlot._({
    required this.title,
    required this.xMin,
    required this.xMax,
    required this.yMin,
    required this.yMax,
    required this.points,
    required this.functions,
  });

  static const maxFunctions = 8;
  static const maxPoints = 64;
  static const maxCoordinate = 1000000.0;
  static const minSpan = 0.000001;

  final String title;
  final double xMin;
  final double xMax;
  final double yMin;
  final double yMax;
  final List<PlotPoint> points;
  final List<String> functions;

  factory CartesianPlot({
    String title = '',
    double xMin = -10,
    double xMax = 10,
    double yMin = -10,
    double yMax = 10,
    List<PlotPoint> points = const [],
    List<String> functions = const [],
  }) {
    _text(title, 'title', 100);
    for (final entry in {'x_min': xMin, 'x_max': xMax, 'y_min': yMin, 'y_max': yMax}.entries) {
      _coordinate(entry.value, entry.key);
    }
    if (xMax - xMin < minSpan || yMax - yMin < minSpan) {
      throw const FormatException('Each maximum must exceed its minimum by at least 0.000001.');
    }
    if (points.length > maxPoints || functions.length > maxFunctions) {
      throw const FormatException('Use at most 64 points and 8 functions per plot.');
    }
    for (final point in points) {
      _coordinate(point.x, 'point x');
      _coordinate(point.y, 'point y');
      _text(point.label, 'point label', 40);
    }
    final validatedFunctions = <String>[];
    for (final function in functions) {
      validatedFunctions.add(PlotExpression.compile(function).source);
    }
    return CartesianPlot._(
      title: title.trim(),
      xMin: xMin,
      xMax: xMax,
      yMin: yMin,
      yMax: yMax,
      points: List.unmodifiable(points),
      functions: List.unmodifiable(validatedFunctions),
    );
  }

  factory CartesianPlot.fromJson(Map<String, dynamic> json) {
    final rawFunctions = json['functions'] ?? const <String>[];
    final rawPoints = json['points'] ?? const <Map<String, dynamic>>[];
    if (rawFunctions is! List || rawFunctions.length > maxFunctions) {
      throw const FormatException('functions must be an array of up to 8 expressions.');
    }
    if (rawPoints is! List || rawPoints.length > maxPoints) {
      throw const FormatException('points must be an array of up to 64 points.');
    }
    return CartesianPlot(
      title: _text(json['title'], 'title', 100),
      xMin: _coordinate(json['x_min'] ?? -10, 'x_min'),
      xMax: _coordinate(json['x_max'] ?? 10, 'x_max'),
      yMin: _coordinate(json['y_min'] ?? -10, 'y_min'),
      yMax: _coordinate(json['y_max'] ?? 10, 'y_max'),
      functions: [
        for (final value in rawFunctions)
          if (value is String) value else throw const FormatException('Every function must be a string.'),
      ],
      points: [
        for (final value in rawPoints)
          if (value is Map<String, dynamic>)
            PlotPoint.fromJson(value)
          else
            throw const FormatException('Every point must be an object with numeric x and y.'),
      ],
    );
  }

  factory CartesianPlot.example() => CartesianPlot(
    functions: const ['x^2', '2x + 1'],
    points: const [PlotPoint(x: 0, y: 0, label: 'O')],
  );

  Map<String, dynamic> toJson() => {
    'title': title,
    'x_min': xMin,
    'x_max': xMax,
    'y_min': yMin,
    'y_max': yMax,
    'functions': functions,
    'points': points.map((point) => point.toJson()).toList(),
  };
}

double _coordinate(Object? value, String name) {
  if (value is! num || !value.isFinite || value.abs() > CartesianPlot.maxCoordinate) {
    throw FormatException('$name must be a finite number between -1000000 and 1000000.');
  }
  return value.toDouble();
}

String _text(Object? value, String name, int limit) {
  if (value == null) return '';
  if (value is! String || value.length > limit) {
    throw FormatException('$name must be text no longer than $limit characters.');
  }
  return value.trim();
}

AppTool buildCartesianPlotTool() => AppTool(
  name: 'plot_cartesian',
  displayName: 'Cartesian coordinate plot',
  description:
      'Display an interactive Cartesian coordinate graph directly in the chat. '
      'Use it to explain math with y=f(x) functions and labeled (x,y) points. '
      'The user can open the graph full screen, pan, zoom and edit the parameters. '
      'The graph is rendered locally, without an external image service. '
      'A successful result automatically displays the graph in the chat; do not invent an image URL or add a Markdown image link. '
      'Angles use radians. Functions may have domain gaps; do not replace them with invented values.',
  parameters: objectSchema({
    'title': {'type': 'string', 'description': 'A short descriptive title.', 'maxLength': 100},
    'functions': {
      'type': 'array',
      'description':
          'Up to 8 expressions in x for y=f(x), such as x^2, -x^2+4, 2x+1, sin(x), sqrt(x), or 1/x. '
          'Supports + - * / % ^, parentheses, pi, e, sin/cos/tan, asin/acos/atan, sqrt, abs, ln, log (base 10), exp, floor, ceil.',
      'maxItems': CartesianPlot.maxFunctions,
      'items': {'type': 'string', 'maxLength': PlotExpression.maxLength},
    },
    'points': {
      'type': 'array',
      'description': 'Up to 64 individual labeled coordinate points.',
      'maxItems': CartesianPlot.maxPoints,
      'items': objectSchema(
        {
          'x': _coordinateSchema('Horizontal coordinate.'),
          'y': _coordinateSchema('Vertical coordinate.'),
          'label': {'type': 'string', 'description': 'Optional point name, for example A.', 'maxLength': 40},
        },
        required: ['x', 'y'],
      ),
    },
    'x_min': _coordinateSchema('Left boundary, defaults to -10; must be smaller than x_max.'),
    'x_max': _coordinateSchema('Right boundary, defaults to 10.'),
    'y_min': _coordinateSchema('Bottom boundary, defaults to -10; must be smaller than y_max.'),
    'y_max': _coordinateSchema('Top boundary, defaults to 10.'),
  }),
  execute: (arguments) async {
    try {
      final plot = CartesianPlot.fromJson(arguments);
      return jsonEncode({'type': 'cartesian_plot', 'plot': plot.toJson()});
    } on FormatException catch (error) {
      return jsonEncode({'error': error.message});
    }
  },
);

Map<String, dynamic> _coordinateSchema(String description) => {
  'type': 'number',
  'description': description,
  'minimum': -CartesianPlot.maxCoordinate,
  'maximum': CartesianPlot.maxCoordinate,
};
