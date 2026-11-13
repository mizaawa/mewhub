import 'dart:convert';
import 'dart:math' as math;

import 'plot_expression.dart';
import 'tool.dart';

class PlotPoint {
  const PlotPoint({required this.x, required this.y, this.label = '', this.showCoordinates = true});
  final double x;
  final double y;
  final String label;

  /// Whether the graph prints "(x, y)" beside the point. A tutor can hide an
  /// answer the user should find; dense data stays readable.
  final bool showCoordinates;

  factory PlotPoint.fromJson(Map<String, dynamic> json) => PlotPoint(
    x: _coordinate(json['x'], 'point x'),
    y: _coordinate(json['y'], 'point y'),
    label: _text(json['label'], 'point label', 40),
    showCoordinates: json['show_coordinates'] != false,
  );

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'label': label, if (!showCoordinates) 'show_coordinates': false};

  /// The label as a name. Models often copy the coordinates into it, as in
  /// "A(1, 2)", which the graph prints anyway; older chats keep such labels.
  String get name => plotPointName(label);

  /// "(1/3, −√3/2)", formatted the way the solution would write it.
  String get coordinates => '(${formatPlotNumber(x)}, ${formatPlotNumber(y)})';

  /// What the graph writes beside the dot.
  String get caption => [if (name.isNotEmpty) name, if (showCoordinates) coordinates].join(' ');

  PlotPoint copyWith({String? label}) =>
      PlotPoint(x: x, y: y, label: label ?? this.label, showCoordinates: showCoordinates);
}

// A trailing "(1, 2)", "（1，2）", ": (1, 2)" or "=(1,2)" in a point label.
final _coordinateSuffix = RegExp(r'^(.*?)[\s:=：＝]*[(（\[]([^()（）\[\],，;；]+)[,，;；]([^()（）\[\],，;；]+)[)）\]]\s*$');
// What a written coordinate may contain: 3, −1.5, 1/3, π/2, √3/2, 2√3, e,
// ln 2, once sqrt(3) and ln(2) have been flattened to √3 and ln 2.
final _coordinateValue = RegExp(r'^[\s\d.+\-−*/^√πe]+$');
final _logWords = RegExp(r'ln|lg|log');
final _flatCall = RegExp(r'(sqrt|√|ln|lg|log)\s*\(\s*([\d.]+)\s*\)');

/// Removes a coordinate pair the label repeats: "A(1, 2)" → "A",
/// "顶点 (2, -1)" → "顶点", "B(π/2, √3/2)" → "B". Symbolic pairs such as
/// "P(t, t²)" and intervals such as "零点∈(1, 2)" stay: they name the point
/// rather than repeat its position. TeX-style names become plain text:
/// "$P_{1}$" → "P₁".
String plotPointName(String label) {
  final name = label.replaceAll(r'$', '').trim();
  // sqrt(3) → √3, so the call's parentheses do not end the pair early.
  final flat = name.replaceAllMapped(_flatCall, (m) => '${m[1] == 'sqrt' ? '√' : '${m[1]} '}${m[2]}');
  final match = _coordinateSuffix.firstMatch(flat);
  if (match != null) {
    bool numeric(String part) {
      final value = part.replaceAll('sqrt', '√').replaceAll('pi', 'π').replaceAll(_logWords, ' ').trim();
      return value.isNotEmpty && _coordinateValue.hasMatch(value) && RegExp(r'[\dπe]').hasMatch(value);
    }

    final interval = RegExp(r'[∈∉⊂⊆]\s*$').hasMatch(match[1]!);
    if (numeric(match[2]!) && numeric(match[3]!) && !interval) return plotNameText(match[1]!.trim());
  }
  return plotNameText(name);
}

const _squareFree = [2, 3, 5, 6, 7, 10, 11, 13, 14, 15, 17, 19, 21, 22, 23, 26, 29, 30];

/// Formats a coordinate for people. Integers and decimals the model wrote
/// with up to four places print as written; a longer decimal that is a
/// simple fraction, multiple of π or square root to six places (how a model
/// writes 1/3, π/2 or √3/2) prints in that exact form.
String formatPlotNumber(double value) {
  if (!value.isFinite) return value.toString();
  // Rounding noise such as cos(3π/2) = −1.8e-16 is zero, not −0.
  if (value.abs() <= 1e-9) return '0';
  final sign = value < 0 ? '−' : '';
  final a = value.abs();
  bool written(double target) => (a - target).abs() <= 1e-9 * math.max(1, a);
  if (written(a.roundToDouble())) return '$sign${a.round()}';
  if (a < .001 || a >= 100000) {
    final parts = a.toStringAsExponential(2).split('e');
    final exponent = plotSuperscript(int.parse(parts[1]).toString());
    return '$sign${parts[0].replaceFirst(RegExp(r'\.?0+$'), '')}×10$exponent';
  }
  for (var places = 1; places <= 4; places++) {
    final scale = math.pow(10, places);
    if (written((a * scale).roundToDouble() / scale)) return '$sign${a.toStringAsFixed(places)}';
  }
  // An absolute tolerance: six decimals match 1/3 or π/2 at any size, while
  // plain data such as 1157.6253 is not mistaken for a fraction.
  bool exact(double target) => (a - target).abs() <= 5e-7;
  if (a < 1000) {
    for (var q = 2; q <= 12; q++) {
      final p = (a * q).round();
      if (p > 0 && _gcd(p, q) == 1 && exact(p / q)) return '$sign$p/$q';
    }
    for (var q = 1; q <= 12; q++) {
      final p = (a * q / math.pi).round();
      if (p > 0 && p <= 48 && _gcd(p, q) == 1 && exact(p * math.pi / q)) {
        return '$sign${p == 1 ? '' : p}π${q == 1 ? '' : '/$q'}';
      }
    }
    for (final n in _squareFree) {
      for (var q = 1; q <= 12; q++) {
        final p = (a * q / math.sqrt(n)).round();
        if (p > 0 && p <= 12 && _gcd(p, q) == 1 && exact(p * math.sqrt(n) / q)) {
          return '$sign${p == 1 ? '' : p}√$n${q == 1 ? '' : '/$q'}';
        }
      }
    }
  }
  return '$sign${a.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '')}';
}

int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);

/// One plotted curve with the names a textbook figure would print.
class PlotCurve {
  const PlotCurve({
    required this.expression,
    required this.equationTex,
    required this.equationText,
    this.tag,
    this.dashed = false,
  });
  final PlotExpression expression;

  /// Reference lines (x = 2, an unnamed y = 1) are dashed like an axis of
  /// symmetry or an asymptote in a textbook.
  final bool dashed;

  /// Short name written next to the curve (y₁, f(x), l, x = 2); null when the
  /// curve is the only unnamed one and the legend alone identifies it.
  final String? tag;

  /// Legend formula, such as `y_{1}=x^{2}-4 x+3`.
  final String equationTex;

  /// The same formula in plain text, such as `y₁ = x² − 4x + 3`.
  final String equationText;
}

/// A straight segment between two named points, such as a side of a
/// triangle; dashed for a height, a median or a projection line.
class PlotSegment {
  const PlotSegment({required this.from, required this.to, this.dashed = false});
  final String from;
  final String to;
  final bool dashed;

  factory PlotSegment.fromJson(Map<String, dynamic> json) => PlotSegment(
    from: _text(json['from'], 'segment from', 40),
    to: _text(json['to'], 'segment to', 40),
    dashed: json['dashed'] == true,
  );

  Map<String, dynamic> toJson() => {'from': from, 'to': to, if (dashed) 'dashed': true};
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
    required this.segments,
  });

  static const maxFunctions = 8;
  static const maxPoints = 64;
  static const maxSegments = 32;
  static const maxCoordinate = 1000000.0;
  static const minSpan = 0.000001;

  final String title;
  final double xMin;
  final double xMax;
  final double yMin;
  final double yMax;
  final List<PlotPoint> points;
  final List<String> functions;
  final List<PlotSegment> segments;

  /// The point a segment end refers to; ends are checked on construction.
  PlotPoint pointNamed(String name) => points.firstWhere((p) => p.name == plotPointName(name));

  /// [functions] compiled once and named: unnamed curves become y₁, y₂ … when
  /// there are several, so each can be told apart without its colour.
  late final List<PlotCurve> curves = _nameCurves();

  // Plots are parsed again on every rebuild of a chat message; equal content
  // must compare equal so a painter does not redraw an unchanged graph.
  late final String _identity = jsonEncode(toJson());

  @override
  bool operator ==(Object other) => other is CartesianPlot && other._identity == _identity;

  @override
  int get hashCode => _identity.hashCode;

  factory CartesianPlot({
    String title = '',
    double xMin = -10,
    double xMax = 10,
    double yMin = -10,
    double yMax = 10,
    List<PlotPoint> points = const [],
    List<String> functions = const [],
    List<PlotSegment> segments = const [],
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
    if (segments.length > maxSegments) throw const FormatException('Use at most 32 segments per plot.');
    final names = [for (final point in points) point.name];
    for (final segment in segments) {
      for (final end in [segment.from, segment.to]) {
        final matches = names.where((name) => name.isNotEmpty && name == plotPointName(end)).length;
        if (matches != 1) {
          throw FormatException(
            'Segment ${segment.from}–${segment.to}: '
            '${matches == 0 ? 'no point is labeled "$end"; add it to points' : 'several points are labeled "$end"'}.',
          );
        }
      }
      if (plotPointName(segment.from) == plotPointName(segment.to)) {
        throw const FormatException('A segment needs two different points.');
      }
    }
    return CartesianPlot._(
      title: title.trim(),
      xMin: xMin,
      xMax: xMax,
      yMin: yMin,
      yMax: yMax,
      points: List.unmodifiable(points),
      functions: List.unmodifiable(validatedFunctions),
      segments: List.unmodifiable(segments),
    );
  }

  factory CartesianPlot.fromJson(Map<String, dynamic> json) {
    final rawFunctions = json['functions'] ?? const <String>[];
    final rawPoints = json['points'] ?? const <Map<String, dynamic>>[];
    final rawSegments = json['segments'] ?? const <Map<String, dynamic>>[];
    if (rawFunctions is! List || rawFunctions.length > maxFunctions) {
      throw const FormatException('functions must be an array of up to 8 expressions.');
    }
    if (rawPoints is! List || rawPoints.length > maxPoints) {
      throw const FormatException('points must be an array of up to 64 points.');
    }
    if (rawSegments is! List || rawSegments.length > maxSegments) {
      throw const FormatException('segments must be an array of up to 32 segments.');
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
      segments: [
        for (final value in rawSegments)
          if (value is Map<String, dynamic>)
            PlotSegment.fromJson(value)
          else
            throw const FormatException('Every segment must be an object with from and to point labels.'),
      ],
    );
  }

  factory CartesianPlot.example() => CartesianPlot(
    functions: const ['x^2', '2x + 1'],
    points: const [PlotPoint(x: 0, y: 0, label: 'O')],
  );

  CartesianPlot copyWith({List<PlotPoint>? points, double? xMin, double? xMax, double? yMin, double? yMax}) =>
      CartesianPlot(
        title: title,
        functions: functions,
        points: points ?? this.points,
        segments: segments,
        xMin: xMin ?? this.xMin,
        xMax: xMax ?? this.xMax,
        yMin: yMin ?? this.yMin,
        yMax: yMax ?? this.yMax,
      );

  Map<String, dynamic> toJson() => {
    'title': title,
    'x_min': xMin,
    'x_max': xMax,
    'y_min': yMin,
    'y_max': yMax,
    'functions': functions,
    'points': points.map((point) => point.toJson()).toList(),
    if (segments.isNotEmpty) 'segments': segments.map((segment) => segment.toJson()).toList(),
  };

  List<PlotCurve> _nameCurves() {
    final expressions = functions.map(PlotExpression.compile).toList();
    // A bare expression and a plain "y = …" are both just "y"; an unnamed
    // constant is a horizontal reference line rather than a numbered curve.
    bool plain(PlotExpression e) => !e.isVertical && e.label == null && (e.name == null || e.name == 'y');
    bool horizontal(PlotExpression e) => plain(e) && e.isConstant;
    bool unnamed(PlotExpression e) => plain(e) && !e.isConstant;
    final numbered = expressions.where(unnamed).length > 1;
    final taken = {for (final e in expressions) ?e.name};
    var next = 1;
    String freshName() {
      while (taken.contains('y_$next')) {
        next++;
      }
      return 'y_${next++}';
    }

    final curves = <PlotCurve>[];
    for (final e in expressions) {
      final label = e.label;
      // "l: y = 2x + 1" prints as l: y = 2x + 1 and tags the line "l".
      final labelTex = label == null ? '' : '${plotNameTex(label)}{:}\\;';
      final labelText = label == null ? '' : '${plotNameText(label)}: ';
      if (e.isVertical || horizontal(e)) {
        final axis = e.isVertical ? 'x' : 'y';
        final equation = '$axis = ${e.text}';
        curves.add(
          PlotCurve(
            expression: e,
            tag: label == null ? equation : plotNameText(label),
            equationTex: '$labelTex$axis=${e.tex}',
            equationText: '$labelText$equation',
            dashed: true,
          ),
        );
        continue;
      }
      final name = unnamed(e) && numbered ? freshName() : e.name ?? 'y';
      curves.add(
        PlotCurve(
          expression: e,
          tag: label != null
              ? plotNameText(label)
              : unnamed(e) && !numbered
              ? null
              : plotNameText(name),
          equationTex: '$labelTex${plotNameTex(name)}=${e.tex}',
          equationText: '$labelText${plotNameText(name)} = ${e.text}',
        ),
      );
    }
    return curves;
  }

  /// Advice for the model when part of the figure falls outside the window it
  /// chose; the graph is still shown.
  List<String> visibilityNotes() {
    final notes = <String>[];
    for (final curve in curves) {
      final e = curve.expression;
      if (e.isVertical) {
        if (e.verticalX! < xMin || e.verticalX! > xMax) {
          notes.add('${curve.equationText} lies outside x_min..x_max, so it is not visible.');
        }
        continue;
      }
      var defined = false;
      var visible = false;
      for (final lower in e.plusMinus ? const [false, true] : const [false]) {
        for (var i = 0; i <= 600 && !visible; i++) {
          final y = e.evaluate(xMin + (xMax - xMin) * i / 600, lower: lower);
          if (!y.isFinite) continue;
          defined = true;
          visible = y >= yMin && y <= yMax;
        }
      }
      if (!defined) {
        notes.add('${curve.equationText} is undefined for every x in the window, so nothing is drawn.');
      } else if (!visible) {
        notes.add('${curve.equationText} has no value between y_min and y_max in this window, so it is not visible.');
      }
    }
    final outside = [
      for (final p in points)
        if (p.x < xMin || p.x > xMax || p.y < yMin || p.y > yMax)
          '${p.name.isEmpty ? 'point' : p.name} ${p.coordinates}',
    ];
    if (outside.isNotEmpty) notes.add('Outside the window and not visible: ${outside.join(', ')}.');
    return notes;
  }
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

/// Added to the system prompt while the tool is offered: how to present math
/// around a graph. The tool description covers how to call it. [latex]
/// follows the user's setting for rendering formulas in messages.
String cartesianPlotPromptHint({bool latex = true}) =>
    '<math_graphs>\n'
    'You can draw graphs in this chat with plot_cartesian. Use it when a figure makes a math explanation clearer '
    '(function graphs, intersections, solving equations or inequalities graphically, analytic geometry), then '
    'explain with reference to the graph.\n'
    '${latex ? _latexMath : _plainMath}\n'
    '</math_graphs>';

const _latexMath =
    'Write mathematical expressions in LaTeX: \$...\$ inline and \$\$...\$\$ for a displayed equation, for '
    'example "顶点为 \$(2,-1)\$". The chat typesets LaTeX; raw syntax such as x^2, sqrt(x) or 1/(x-1) in prose '
    'looks broken.';
const _plainMath =
    'This chat shows formulas as plain text, so write math with Unicode symbols rather than LaTeX: x², √x, '
    '(x − 1)/(x + 2), π, ≤, ±.';

// Written the model's way, "e^2x" parses as e²·x: ^ takes only the number
// after it. Such an exponent must be in parentheses or followed by a space.
final _shortExponent = RegExp(r'\^\s*-?\d+(?:\.\d+)?[a-zA-Z(]');

AppTool buildCartesianPlotTool({bool latex = true}) => AppTool(
  name: 'plot_cartesian',
  displayName: 'Cartesian coordinate plot',
  description:
      'Draw a Cartesian coordinate graph in the chat: y = f(x) curves, horizontal and vertical lines, '
      'labeled points and segments between them. It is rendered on the device and shown to the user as soon '
      'as the call succeeds; they can open it full screen, pan, zoom and edit it. Use it when a picture helps '
      'with math: graphs and key features of functions, intersections, solving equations or inequalities '
      'graphically, analytic geometry (lines, circles, conics, triangles), transformations of graphs.\n'
      'For a good figure:\n'
      '1. Work out the exact key values first (intercepts, vertex, extrema, intersections, asymptotes) and pass '
      'the important ones as named points, so the figure matches your solution.\n'
      '2. Choose x_min/x_max/y_min/y_max so every key feature is inside with roughly 10-20% margin. Keep the x '
      'and y spans similar when shapes, distances or angles matter; the frame may show a little more than the '
      'requested window.\n'
      '3. A point label is a name only, such as A, B, P_1, O or 顶点. The graph prints every point\'s exact '
      'coordinates next to its name, so never write coordinates into a label.\n'
      '4. Each function appears as a typeset formula in the legend, and when several are unnamed the graph tags '
      'them y₁, y₂ … in order. Refer to curves by these names or by their equations, never by colour, which '
      'depends on the user\'s theme. In your reply write math '
      '${latex ? 'in LaTeX (\$...\$ inline, \$\$...\$\$ displayed)' : 'as plain text with Unicode symbols (x², √x, π)'}, '
      'never raw syntax such as x^2 or sqrt(x).\n'
      '5. Do not add an image link or Markdown image for the graph and do not repeat the call arguments.\n'
      'Angles are in radians. A curve that is not a function of x takes one ±: the circle x^2 + y^2 = 9 is '
      '"y = ±sqrt(9 - x^2)" and the ellipse x^2/4 + y^2 = 1 is "y = ±sqrt(1 - x^2/4)". Points where a function '
      'is undefined stay empty; never invent values for them.',
  promptHint: cartesianPlotPromptHint(latex: latex),
  parameters: objectSchema({
    'title': {
      'type': 'string',
      'description':
          'Short plain-text title in the user\'s language, for example "y = x² − 4x + 3 的图像". '
          'No LaTeX and no \$ signs.',
      'maxLength': 100,
    },
    'functions': {
      'type': 'array',
      'description':
          'Up to 8 curves, one expression each, using only the variable x (substitute numbers for any '
          'parameters). For y = f(x) give the expression: "x^2 - 4x + 3", "2x + 1", "sin(x)", "sqrt(x)", '
          '"1/(x - 1)", "e^x", "ln(x)", "abs(x - 2)". To name a curve on the graph, prefix it: "f(x) = x^2", '
          '"g(x) = 2x + 1", "y_1 = -x + 3", or a line label "l: y = 2x + 1" or "AB: y = -x + 4". '
          '"x = 2" is a vertical line and an unnamed "y = 1" a horizontal one; both are drawn dashed, as for an '
          'axis of symmetry or an asymptote. One ± per curve draws both branches, as in the circle '
          '"y = 1 ± sqrt(4 - (x - 2)^2)". '
          'Syntax: + - * / ^ and parentheses, implicit multiplication (2x, 3(x + 1)), pi, e, sin, cos, tan, '
          'asin, acos, atan, sqrt, cbrt (real cube root, also for negative x), abs, ln (natural log), log2, '
          'lg or log (base 10), exp, floor, ceil. Always put function arguments in parentheses: sin(x), not '
          'sin x. ^ takes only the one number or symbol after it, so put longer exponents in parentheses: '
          'e^(-0.5x), e^(-x^2/2), x^(1/3); likewise 1/(2x). Write the ± sign itself (or \\pm), not "+-".',
      'maxItems': CartesianPlot.maxFunctions,
      'items': {'type': 'string', 'maxLength': PlotExpression.maxLength},
    },
    'points': {
      'type': 'array',
      'description':
          'Up to 64 points to mark, such as intercepts, the vertex, intersection points or the vertices of a figure.',
      'maxItems': CartesianPlot.maxPoints,
      'items': objectSchema(
        {
          'x': _coordinateSchema(
            'x coordinate. Give exact values in full precision (0.3333333333 for 1/3, 1.5707963268 for π/2, '
            '0.8660254038 for √3/2): the graph prints simple fractions, multiples of π and square roots in that '
            'exact form and other values as decimals.',
          ),
          'y': _coordinateSchema('y coordinate, in full precision like x.'),
          'label': {
            'type': 'string',
            'description':
                'Name only, as plain text without \$ signs, such as A, B, P_1 (printed P₁), A\' (printed A′), O, '
                '顶点 or 交点. Never include the coordinates: the graph prints them next to the name.',
            'maxLength': 40,
          },
          'show_coordinates': {
            'type': 'boolean',
            'description':
                'Print "(x, y)" next to the point. Defaults to true; set false to hide a value the user is meant '
                'to work out, or for many data points.',
          },
        },
        required: ['x', 'y'],
      ),
    },
    'segments': {
      'type': 'array',
      'description':
          'Up to 32 straight segments between labeled points, such as the sides of a triangle or polygon '
          '(A to B, B to C, C to A). Set dashed for a height, a median or a projection line. Both ends must be '
          'labels of points in this call.',
      'maxItems': CartesianPlot.maxSegments,
      'items': objectSchema(
        {
          'from': {'type': 'string', 'description': 'Label of the first point, such as A.', 'maxLength': 40},
          'to': {'type': 'string', 'description': 'Label of the second point, such as B.', 'maxLength': 40},
          'dashed': {'type': 'boolean', 'description': 'Draw a dashed auxiliary segment. Defaults to false.'},
        },
        required: ['from', 'to'],
      ),
    },
    'x_min': _coordinateSchema('Left edge of the window, default -10. Must be less than x_max.'),
    'x_max': _coordinateSchema('Right edge of the window, default 10.'),
    'y_min': _coordinateSchema('Bottom edge of the window, default -10. Must be less than y_max.'),
    'y_max': _coordinateSchema('Top edge of the window, default 10.'),
  }),
  execute: (arguments) async {
    try {
      final functions = arguments['functions'];
      for (final function in functions is List ? functions.whereType<String>() : const <String>[]) {
        if (function.contains('+-') || function.contains('+/-')) {
          throw FormatException('"$function": write ± (or \\pm) for two branches; "+-" would only subtract.');
        }
        final exponent = _shortExponent.firstMatch(function);
        if (exponent != null) {
          throw FormatException(
            '"$function": ^ takes only the number right after it, so "${exponent[0]}" multiplies afterwards. '
            'Put the whole exponent in parentheses, such as e^(2x), or add * if a product is meant.',
          );
        }
      }
      final parsed = CartesianPlot.fromJson(arguments);
      final notes = <String>[];
      final repeated = [
        for (final p in parsed.points)
          if (p.name != plotNameText(p.label.trim())) p.label,
      ];
      if (repeated.isNotEmpty) {
        notes.add(
          'Point labels must be names only; the coordinates were removed from ${repeated.map(jsonEncode).join(', ')} '
          'because the graph prints them itself.',
        );
      }
      final plot = parsed.copyWith(points: [for (final p in parsed.points) p.copyWith(label: p.name)]);
      notes.addAll(plot.visibilityNotes());
      return jsonEncode({
        'type': 'cartesian_plot',
        'plot': plot.toJson(),
        'status': 'The graph is now shown to the user in the chat.',
        if (notes.isNotEmpty) 'notes': notes,
      });
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
