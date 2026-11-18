import 'dart:convert';

import 'cartesian_plot.dart';
import 'plot_expression.dart';
import 'plot_segment_style.dart';
import 'tool.dart';

class SpatialPoint {
  const SpatialPoint({required this.x, required this.y, required this.z, this.label = '', this.showCoordinates = true});
  final double x;
  final double y;
  final double z;
  final String label;
  final bool showCoordinates;

  String get name => plotPointName(label);
  String get coordinates => '(${formatPlotNumber(x)}, ${formatPlotNumber(y)}, ${formatPlotNumber(z)})';
  String get caption => [if (name.isNotEmpty) name, if (showCoordinates) coordinates].join(' ');

  factory SpatialPoint.fromJson(Map<String, dynamic> json) => SpatialPoint(
    x: _coordinate(json['x'], 'point x'),
    y: _coordinate(json['y'], 'point y'),
    z: _coordinate(json['z'], 'point z'),
    label: _text(json['label'], 'point label', 40),
    showCoordinates: json['show_coordinates'] != false,
  );

  Map<String, dynamic> toJson() => {
    'x': x,
    'y': y,
    'z': z,
    'label': label,
    if (!showCoordinates) 'show_coordinates': false,
  };
}

class SpatialSegment {
  const SpatialSegment({
    required this.from,
    required this.to,
    bool dashed = false,
    PlotLineStyle? style,
    this.color = PlotLineColor.theme,
  }) : style = style ?? (dashed ? PlotLineStyle.dashed : PlotLineStyle.solid);
  final String from;
  final String to;
  final PlotLineStyle style;
  final PlotLineColor color;
  bool get dashed => style == PlotLineStyle.dashed;

  factory SpatialSegment.fromJson(Map<String, dynamic> json) => SpatialSegment(
    from: _text(json['from'], 'segment from', 40),
    to: _text(json['to'], 'segment to', 40),
    style: PlotLineStyle.parse(json['style'], legacyDashed: json['dashed'] == true),
    color: PlotLineColor.parse(json['color']),
  );

  Map<String, dynamic> toJson() => {
    'from': from,
    'to': to,
    if (style != PlotLineStyle.solid) 'style': style.jsonName,
    if (color != PlotLineColor.theme) 'color': color.jsonName,
  };
}

typedef SpatialVertex = ({double x, double y, double z});
typedef SpatialMesh = ({int surface, List<SpatialVertex?> vertices});

/// Validated serializable data for an interactive 3D Cartesian graph.
class SpatialPlot {
  SpatialPlot._({
    required this.title,
    required this.xMin,
    required this.xMax,
    required this.yMin,
    required this.yMax,
    required this.zMin,
    required this.zMax,
    required this.expressions,
    required this.points,
    required this.segments,
  }) : surfaces = List.unmodifiable(expressions.map((e) => e.source));

  static const maxSurfaces = 6;
  static const maxPoints = 64;
  static const maxSegments = 32;
  static const maxCoordinate = 1000000.0;
  static const minSpan = 0.000001;

  final String title;
  final double xMin;
  final double xMax;
  final double yMin;
  final double yMax;
  final double zMin;
  final double zMax;
  final List<String> surfaces;
  final List<SpatialPoint> points;
  final List<SpatialSegment> segments;

  final List<SpatialExpression> expressions;

  // Cache just the current resolution on this plot, not every graph in chat.
  // Orbit, pan and zoom only reproject these world-space samples.
  static const maxMeshDivisions = 32;
  int _divisions = 0;
  List<SpatialMesh> _meshes = const [];
  List<SpatialMesh> sampleSurfaces(int divisions) {
    RangeError.checkValueInInterval(divisions, 1, maxMeshDivisions, 'divisions');
    if (_divisions == divisions) return _meshes;
    final stride = divisions + 1;
    List<SpatialVertex?> sample(SpatialExpression expression, bool lower) => List.unmodifiable(
      List<SpatialVertex?>.generate(stride * stride, (i) {
        final x = xMin + (xMax - xMin) * (i % stride) / divisions;
        final y = yMin + (yMax - yMin) * (i ~/ stride) / divisions;
        final z = expression.evaluate(x, y, lower: lower);
        return z.isFinite && z >= zMin && z <= zMax ? (x: x, y: y, z: z) : null;
      }),
    );
    _meshes = List.unmodifiable([
      for (final (i, expression) in expressions.indexed) ...[
        (surface: i, vertices: sample(expression, false)),
        if (expression.plusMinus) (surface: i, vertices: sample(expression, true)),
      ],
    ]);
    _divisions = divisions;
    return _meshes;
  }

  late final String _identity = jsonEncode(toJson());

  @override
  bool operator ==(Object other) => other is SpatialPlot && other._identity == _identity;
  @override
  int get hashCode => _identity.hashCode;

  factory SpatialPlot({
    String title = '',
    double xMin = -5,
    double xMax = 5,
    double yMin = -5,
    double yMax = 5,
    double zMin = -5,
    double zMax = 5,
    List<String> surfaces = const [],
    List<SpatialPoint> points = const [],
    List<SpatialSegment> segments = const [],
  }) {
    _text(title, 'title', 100);
    for (final entry in {
      'x_min': xMin,
      'x_max': xMax,
      'y_min': yMin,
      'y_max': yMax,
      'z_min': zMin,
      'z_max': zMax,
    }.entries) {
      _coordinate(entry.value, entry.key);
    }
    if (xMax - xMin < minSpan || yMax - yMin < minSpan || zMax - zMin < minSpan) {
      throw const FormatException('Each maximum must exceed its minimum by at least 0.000001.');
    }
    if (surfaces.length > maxSurfaces || points.length > maxPoints || segments.length > maxSegments) {
      throw const FormatException('Use at most 6 surfaces, 64 points and 32 segments per spatial plot.');
    }
    final compiled = surfaces.map(SpatialExpression.compile);
    for (final point in points) {
      _coordinate(point.x, 'point x');
      _coordinate(point.y, 'point y');
      _coordinate(point.z, 'point z');
      _text(point.label, 'point label', 40);
    }
    for (final segment in segments) {
      final from = points.where((p) => p.name.isNotEmpty && p.name == plotPointName(segment.from)).length;
      final to = points.where((p) => p.name.isNotEmpty && p.name == plotPointName(segment.to)).length;
      if (from != 1 || to != 1) {
        throw FormatException('Segment ${segment.from}–${segment.to} must join two unique labeled points.');
      }
      if (plotPointName(segment.from) == plotPointName(segment.to)) {
        throw const FormatException('A segment needs two different points.');
      }
    }
    return SpatialPlot._(
      title: title.trim(),
      xMin: xMin,
      xMax: xMax,
      yMin: yMin,
      yMax: yMax,
      zMin: zMin,
      zMax: zMax,
      expressions: List.unmodifiable(compiled),
      points: List.unmodifiable(points),
      segments: List.unmodifiable(segments),
    );
  }

  factory SpatialPlot.fromJson(Map<String, dynamic> json) {
    final rawSurfaces = json['surfaces'] ?? const <String>[];
    final rawPoints = json['points'] ?? const <Map<String, dynamic>>[];
    final rawSegments = json['segments'] ?? const <Map<String, dynamic>>[];
    if (rawSurfaces is! List || rawSurfaces.length > maxSurfaces) {
      throw const FormatException('surfaces must be an array of up to 6 expressions.');
    }
    if (rawPoints is! List || rawPoints.length > maxPoints) {
      throw const FormatException('points must be an array of up to 64 points.');
    }
    if (rawSegments is! List || rawSegments.length > maxSegments) {
      throw const FormatException('segments must be an array of up to 32 segments.');
    }
    return SpatialPlot(
      title: _text(json['title'], 'title', 100),
      xMin: _coordinate(json['x_min'] ?? -5, 'x_min'),
      xMax: _coordinate(json['x_max'] ?? 5, 'x_max'),
      yMin: _coordinate(json['y_min'] ?? -5, 'y_min'),
      yMax: _coordinate(json['y_max'] ?? 5, 'y_max'),
      zMin: _coordinate(json['z_min'] ?? -5, 'z_min'),
      zMax: _coordinate(json['z_max'] ?? 5, 'z_max'),
      surfaces: [
        for (final value in rawSurfaces)
          value is String ? value : throw const FormatException('Every surface must be a string.'),
      ],
      points: [
        for (final value in rawPoints)
          if (value is Map<String, dynamic>)
            SpatialPoint.fromJson(value)
          else
            throw const FormatException('Every point must be an object with numeric x, y and z.'),
      ],
      segments: [
        for (final value in rawSegments)
          if (value is Map<String, dynamic>)
            SpatialSegment.fromJson(value)
          else
            throw const FormatException('Every segment must be an object with from and to labels.'),
      ],
    );
  }

  factory SpatialPlot.example() => SpatialPlot(
    surfaces: const ['z = (x^2 + y^2) / 4 - 2'],
    points: const [SpatialPoint(x: 0, y: 0, z: -2, label: 'P')],
  );

  SpatialPlot copyWith({
    String? title,
    double? xMin,
    double? xMax,
    double? yMin,
    double? yMax,
    double? zMin,
    double? zMax,
    List<String>? surfaces,
    List<SpatialPoint>? points,
    List<SpatialSegment>? segments,
  }) => SpatialPlot(
    title: title ?? this.title,
    xMin: xMin ?? this.xMin,
    xMax: xMax ?? this.xMax,
    yMin: yMin ?? this.yMin,
    yMax: yMax ?? this.yMax,
    zMin: zMin ?? this.zMin,
    zMax: zMax ?? this.zMax,
    surfaces: surfaces ?? this.surfaces,
    points: points ?? this.points,
    segments: segments ?? this.segments,
  );

  SpatialPoint pointNamed(String name) => points.firstWhere((p) => p.name == plotPointName(name));

  Map<String, dynamic> toJson() => {
    'title': title,
    'x_min': xMin,
    'x_max': xMax,
    'y_min': yMin,
    'y_max': yMax,
    'z_min': zMin,
    'z_max': zMax,
    'surfaces': surfaces,
    'points': points.map((point) => point.toJson()).toList(),
    if (segments.isNotEmpty) 'segments': segments.map((segment) => segment.toJson()).toList(),
  };
}

double _coordinate(Object? value, String name) {
  if (value is! num || !value.isFinite || value.abs() > SpatialPlot.maxCoordinate) {
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

String spatialPlotPromptHint() =>
    '<spatial_graphs>\n'
    'For geometry questions where the user asks to connect, join, draw edges between, or form a shape from named points, '
    'call plot_spatial with every vertex in points and every requested straight edge in segments; points alone draw only '
    'dots and never connect automatically. Each segment is one '
    '{"from":"A","to":"B"} pair and both names must exactly match point labels. For a polygon, connect consecutive '
    'vertices and close the outline from the last vertex back to the first; do not add diagonals unless requested. '
    'Example square A(0,0,0), B(2,0,0), C(2,2,0), D(0,2,0): points A–D and segments '
    '[{"from":"A","to":"B"},{"from":"B","to":"C"},{"from":"C","to":"D"},{"from":"D","to":"A"}]. '
    'For a triangle ABC use AB, BC, CA. For a vector from O to A use OA. When the request specifies a particular '
    'construction, preserve its labels and include only those edges. Use solid for visible edges, dashed for '
    'hidden edges or auxiliary heights/medians, dotted for projection guides, and dash_dot for centerlines or '
    'symmetry axes. The optional color accepts default, red, orange, green, teal, blue, purple, pink, gray or '
    'black; use distinct colors to group or emphasize construction lines and leave ordinary object edges at '
    'the theme default. Choose ranges that include all vertices.\n'
    '</spatial_graphs>';

AppTool buildSpatialPlotTool() => AppTool(
  name: 'plot_spatial',
  displayName: '3D Cartesian coordinate plot',
  description:
      'Draw an interactive three-dimensional Cartesian coordinate system in the chat. Use surfaces z=f(x,y), '
      'labeled 3D points and segments between them for spatial functions, paraboloids, saddle surfaces, '
      'polyhedra, vectors and solid analytic geometry. The user can open it full screen, rotate with one finger '
      'and pan with two fingers. Use plot_cartesian instead for a two-dimensional y=f(x) graph. '
      'Use explicit x and y arguments in sin(x), cos(y), sqrt(x^2+y^2), etc.; never use parameters other than x '
      'and y. Choose ranges that contain the useful surface and all important points. Point labels are names only '
      '(A, B, P_1, O), without repeated coordinates. For requested line connections, define each endpoint as a point '
      'and give each edge in segments as {from: label, to: label}; close polygon outlines last-to-first and omit '
      'unrequested diagonals. Do not add an image link or repeat the call arguments.',
  promptHint: spatialPlotPromptHint(),
  parameters: objectSchema({
    'title': {'type': 'string', 'description': 'Short plain-text title in the user\'s language.', 'maxLength': 100},
    'surfaces': {
      'type': 'array',
      'description':
          'Up to 6 z=f(x,y) expressions, such as "x^2+y^2", "z = sin(x)*cos(y)", or '
          '"f(x,y) = sqrt(9-x^2-y^2)". Supports + - * / % ^, parentheses, implicit multiplication, pi, e, '
          'sin, cos, tan, asin, acos, atan, sqrt, cbrt, abs, ln, log, exp, floor and ceil. One ± draws both branches.',
      'maxItems': SpatialPlot.maxSurfaces,
      'items': {'type': 'string', 'maxLength': SpatialExpression.maxLength},
    },
    'points': {
      'type': 'array',
      'description': 'Up to 64 labeled points in three dimensions.',
      'maxItems': SpatialPlot.maxPoints,
      'items': objectSchema(
        {
          'x': _number,
          'y': _number,
          'z': _number,
          'label': {'type': 'string', 'description': 'Name only, without coordinates.', 'maxLength': 40},
          'show_coordinates': {'type': 'boolean', 'description': 'Show (x,y,z) beside the point. Defaults true.'},
        },
        required: ['x', 'y', 'z'],
      ),
    },
    'segments': {
      'type': 'array',
      'description':
          'Up to 32 straight 3D edges. Each item joins two existing point labels exactly, e.g. '
          '{"from":"A","to":"B"}. Use one item per requested edge; close a polygon from the last '
          'vertex to the first, and add diagonals only when requested. Use style solid for visible edges, dashed '
          'for hidden/auxiliary edges, dotted for projection guides, or dash_dot for centerlines/symmetry axes; '
          'color may be default, red, orange, green, teal, blue, purple, pink, gray or black.',
      'maxItems': SpatialPlot.maxSegments,
      'items': objectSchema(
        {
          'from': {'type': 'string', 'maxLength': 40},
          'to': {'type': 'string', 'maxLength': 40},
          'style': {
            'type': 'string',
            'enum': [for (final style in PlotLineStyle.values) style.jsonName],
            'description': 'solid (default), dashed, dotted or dash_dot.',
          },
          'color': {
            'type': 'string',
            'enum': [for (final color in PlotLineColor.values) color.jsonName],
            'description':
                'Line color token. Defaults to theme; choose a palette name only when it clarifies the figure.',
          },
        },
        required: ['from', 'to'],
      ),
    },
    for (final axis in ['x', 'y', 'z']) '${axis}_min': _number,
    for (final axis in ['x', 'y', 'z']) '${axis}_max': _number,
  }),
  execute: (arguments) async {
    try {
      final plot = SpatialPlot.fromJson(arguments);
      final outside = [
        for (final point in plot.points)
          if (point.x < plot.xMin ||
              point.x > plot.xMax ||
              point.y < plot.yMin ||
              point.y > plot.yMax ||
              point.z < plot.zMin ||
              point.z > plot.zMax)
            '${point.name.isEmpty ? 'point' : point.name} ${point.coordinates}',
      ];
      return jsonEncode({
        'type': 'spatial_plot',
        'plot': plot.toJson(),
        'status': 'The interactive 3D graph is now shown to the user in the chat.',
        if (outside.isNotEmpty) 'notes': ['Outside the initial window: ${outside.join(', ')}.'],
      });
    } on FormatException catch (error) {
      return jsonEncode({'error': error.message});
    }
  },
);

const _number = {'type': 'number', 'minimum': -SpatialPlot.maxCoordinate, 'maximum': SpatialPlot.maxCoordinate};
