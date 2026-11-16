import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/i18n.dart';
import '../../tools/cartesian_plot.dart';
import '../../tools/plot_segment_style.dart';
import '../../tools/spatial_plot.dart';
import 'cartesian_plot_view.dart';
import 'plot_segment_painter.dart';

String spatialPlotTitle(SpatialPlot plot) =>
    plot.title.isEmpty ? t('空间直角坐标系', '3D Cartesian coordinates') : prettyPlotTitle(plot.title);

/// Shared orthonormal world-to-screen transform, including orbit and pan state.
@immutable
class SpatialProjection {
  const SpatialProjection({
    required this.size,
    required this.plot,
    this.yaw = -.65,
    this.pitch = .58,
    this.zoom = 1,
    this.pan = Offset.zero,
  });

  final Size size;
  final SpatialPlot plot;
  final double yaw;
  final double pitch;
  final double zoom;
  final Offset pan;

  // Keep the world-space scale equal on all axes. Normalizing each range
  // independently makes a 1×1×10 box look like a cube and distorts geometry.
  double get _halfSpan => math.max(plot.xMax - plot.xMin, math.max(plot.yMax - plot.yMin, plot.zMax - plot.zMin)) / 2;

  Offset _projectUnit(double nx, double ny, double nz) {
    final rx = nx * math.cos(yaw) - ny * math.sin(yaw);
    final ry = nx * math.sin(yaw) + ny * math.cos(yaw);
    final screenY = ry * math.sin(pitch) + nz * math.cos(pitch);
    // Orthographic projection keeps parallel edges parallel and preserves
    // equal lengths for equal world-space edges, so boxes do not look warped.
    return Offset(rx, -screenY);
  }

  /// World-coordinate bounds of the XY plane needed to cover the viewport.
  /// Returns null when the camera looks almost exactly along the plane.
  Rect? xyPlaneWorldBounds(double z) {
    final xMid = (plot.xMin + plot.xMax) / 2;
    final yMid = (plot.yMin + plot.yMax) / 2;
    final origin = project(xMid, yMid, z)?.at;
    final xPoint = project(xMid + 1, yMid, z)?.at;
    final yPoint = project(xMid, yMid + 1, z)?.at;
    if (origin == null || xPoint == null || yPoint == null) return null;
    final xAxis = xPoint - origin;
    final yAxis = yPoint - origin;
    final determinant = xAxis.dx * yAxis.dy - yAxis.dx * xAxis.dy;
    if (!determinant.isFinite || determinant.abs() < 1e-5) return null;
    final coords = <Offset>[];
    for (final corner in [
      Offset.zero,
      Offset(size.width, 0),
      Offset(size.width, size.height),
      Offset(0, size.height),
    ]) {
      final delta = corner - origin;
      final x = (delta.dx * yAxis.dy - delta.dy * yAxis.dx) / determinant + xMid;
      final y = (xAxis.dx * delta.dy - xAxis.dy * delta.dx) / determinant + yMid;
      if (!x.isFinite || !y.isFinite) return null;
      coords.add(Offset(x, y));
    }
    return Rect.fromLTRB(
      coords.map((p) => p.dx).reduce(math.min),
      coords.map((p) => p.dy).reduce(math.min),
      coords.map((p) => p.dx).reduce(math.max),
      coords.map((p) => p.dy).reduce(math.max),
    );
  }

  /// A screen-clipped infinite XY grid line at [value] world units.
  (Offset, Offset)? xyGridLine({required bool fixedX, required double value, required double z}) {
    final xMid = (plot.xMin + plot.xMax) / 2;
    final yMid = (plot.yMin + plot.yMax) / 2;
    final anchor = fixedX ? project(value, yMid, z)?.at : project(xMid, value, z)?.at;
    final next = fixedX ? project(value, yMid + 1, z)?.at : project(xMid + 1, value, z)?.at;
    if (anchor == null || next == null) return null;
    return clipInfiniteLineToRect(anchor, next - anchor, Offset.zero & size);
  }

  /// Fit the projected coordinate box to both dimensions, including portrait
  /// full-screen canvases where the available height greatly exceeds width.
  double get _fitScale {
    final unit = _halfSpan;
    final xMid = (plot.xMin + plot.xMax) / 2;
    final yMid = (plot.yMin + plot.yMax) / 2;
    final zMid = (plot.zMin + plot.zMax) / 2;
    final corners = [
      for (final x in [(plot.xMin - xMid) / unit, (plot.xMax - xMid) / unit])
        for (final y in [(plot.yMin - yMid) / unit, (plot.yMax - yMid) / unit])
          for (final z in [(plot.zMin - zMid) / unit, (plot.zMax - zMid) / unit]) _projectUnit(x, y, z),
    ];
    final minX = corners.map((p) => p.dx).reduce(math.min);
    final maxX = corners.map((p) => p.dx).reduce(math.max);
    final minY = corners.map((p) => p.dy).reduce(math.min);
    final maxY = corners.map((p) => p.dy).reduce(math.max);
    final width = math.max(maxX - minX, .01);
    final height = math.max(maxY - minY, .01);
    return math.min(size.width * .84 / width, size.height * .84 / height);
  }

  /// World-space interval that keeps adjacent XY grid lines near 34 logical px.
  double get gridStep {
    final worldScale = _fitScale * zoom / _halfSpan;
    final xAxis = _projectUnit(1, 0, 0) * worldScale;
    final yAxis = _projectUnit(0, 1, 0) * worldScale;
    final area = (xAxis.dx * yAxis.dy - xAxis.dy * yAxis.dx).abs();
    final pitchX = area / math.max(yAxis.distance, 1e-6);
    final pitchY = area / math.max(xAxis.distance, 1e-6);
    final smallestPitch = math.max(math.min(pitchX, pitchY), 1e-4);
    // Do not quantize the world step to 1-2-5 values: that can make a small
    // zoom change suddenly double the screen spacing of the whole grid.
    return 34 / smallestPitch;
  }

  /// The axis line through [x], [y], [z], clipped to the canvas edges.
  (Offset, Offset)? axisAcrossCanvas(SpatialAxis axis, double x, double y, double z) {
    final anchor = project(x, y, z)?.at;
    if (anchor == null) return null;
    final delta = _halfSpan * .1;
    final next = switch (axis) {
      SpatialAxis.x => project(x + delta, y, z),
      SpatialAxis.y => project(x, y + delta, z),
      SpatialAxis.z => project(x, y, z + delta),
    };
    if (next == null) return null;
    return clipInfiniteLineToRect(anchor, next.at - anchor, Offset.zero & size);
  }

  static (Offset, Offset)? clipInfiniteLineToRect(Offset anchor, Offset direction, Rect bounds) {
    if (!anchor.isFinite || !direction.isFinite || direction.distanceSquared < 1e-12) return null;
    final intersections = <Offset>[];
    void add(double x, double y) {
      final point = Offset(x, y);
      if (!point.isFinite ||
          x < bounds.left - 1e-6 ||
          x > bounds.right + 1e-6 ||
          y < bounds.top - 1e-6 ||
          y > bounds.bottom + 1e-6 ||
          intersections.any((old) => (old - point).distance < 1e-5)) {
        return;
      }
      intersections.add(point);
    }

    if (direction.dx.abs() > 1e-9) {
      for (final x in [bounds.left, bounds.right]) {
        final t = (x - anchor.dx) / direction.dx;
        add(x, anchor.dy + t * direction.dy);
      }
    }
    if (direction.dy.abs() > 1e-9) {
      for (final y in [bounds.top, bounds.bottom]) {
        final t = (y - anchor.dy) / direction.dy;
        add(anchor.dx + t * direction.dx, y);
      }
    }
    if (intersections.length < 2) return null;
    var first = intersections.first;
    var second = intersections[1];
    var farthest = (first - second).distanceSquared;
    for (var i = 0; i < intersections.length; i++) {
      for (var j = i + 1; j < intersections.length; j++) {
        final distance = (intersections[i] - intersections[j]).distanceSquared;
        if (distance > farthest) {
          farthest = distance;
          first = intersections[i];
          second = intersections[j];
        }
      }
    }
    final dot = (second - first).dx * direction.dx + (second - first).dy * direction.dy;
    return dot >= 0 ? (first, second) : (second, first);
  }

  SpatialProjectedPoint? project(double x, double y, double z) {
    if (!x.isFinite || !y.isFinite || !z.isFinite) return null;
    final unit = _halfSpan;
    final nx = (x - (plot.xMin + plot.xMax) / 2) / unit;
    final ny = (y - (plot.yMin + plot.yMax) / 2) / unit;
    final nz = (z - (plot.zMin + plot.zMax) / 2) / unit;
    final projected = _projectUnit(nx, ny, nz);
    final scale = _fitScale * zoom;
    final center = size.center(Offset.zero) + pan;
    final depth = (nx * math.sin(yaw) + ny * math.cos(yaw)) * math.cos(pitch) - nz * math.sin(pitch);
    return SpatialProjectedPoint(center + projected * scale, depth);
  }
}

class SpatialProjectedPoint {
  const SpatialProjectedPoint(this.at, this.depth);
  final Offset at;
  final double depth;
}

enum SpatialAxis { x, y, z }

typedef _SpatialGestureUpdate = void Function(Offset panDelta, double scaleRatio, int pointerCount);

/// Uses actual pointer positions for the camera gesture. ScaleGestureRecognizer
/// reports a re-based centroid and scale when fingers join or lift, which can
/// drop half of a pan in a scrollable chat card.
class _SpatialGestureRecognizer extends OneSequenceGestureRecognizer {
  _SpatialGestureRecognizer({super.debugOwner});

  _SpatialGestureUpdate? onUpdate;

  final Map<int, Offset> _positions = {};
  final Map<int, Offset> _initialPositions = {};
  bool _accepted = false;

  @override
  String get debugDescription => 'spatial camera';

  @override
  void addAllowedPointer(PointerDownEvent event) {
    _positions[event.pointer] = event.localPosition;
    _initialPositions[event.pointer] = event.localPosition;
    super.addAllowedPointer(event);
    if (_accepted) resolvePointer(event.pointer, GestureDisposition.accepted);
  }

  Offset _focalPoint(Map<int, Offset> positions) {
    if (positions.isEmpty) return Offset.zero;
    return positions.values.reduce((a, b) => a + b) / positions.length.toDouble();
  }

  double _spread(Map<int, Offset> positions, Offset focal) {
    if (positions.length < 2) return 0;
    return positions.values.map((point) => (point - focal).distance).reduce((a, b) => a + b) / positions.length;
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerDownEvent) {
      _positions[event.pointer] = event.localPosition;
      _initialPositions[event.pointer] = event.localPosition;
      return;
    }
    if (event is PointerMoveEvent && _positions.containsKey(event.pointer)) {
      final previousFocal = _focalPoint(_positions);
      final previousSpread = _spread(_positions, previousFocal);
      _positions[event.pointer] = event.localPosition;
      final focal = _focalPoint(_positions);
      final delta = focal - previousFocal;
      final spread = _spread(_positions, focal);
      final scaleRatio = previousSpread > .1 ? spread / previousSpread : 1.0;
      final travelled = (event.localPosition - _initialPositions[event.pointer]!).distance;

      // Accept after a small, intentional drag so a one-finger orbit wins
      // against the enclosing chat Scrollable. A tap still belongs to onTap.
      if (!_accepted && (travelled > 8 || scaleRatio > 1.04 || scaleRatio < .96)) {
        resolve(GestureDisposition.accepted);
      }
      if (_accepted && (delta.distanceSquared > 0 || scaleRatio != 1)) {
        onUpdate?.call(delta, scaleRatio, _positions.length);
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _positions.remove(event.pointer);
      _initialPositions.remove(event.pointer);
    }
    stopTrackingIfPointerNoLongerDown(event);
  }

  @override
  void acceptGesture(int pointer) => _accepted = true;

  @override
  void rejectGesture(int pointer) {}

  @override
  void didStopTrackingLastPointer(int pointer) {
    _positions.clear();
    _initialPositions.clear();
    _accepted = false;
  }
}

/// Maintains a camera independently of the widget hosting it.
class _SpatialCamera {
  double yaw = -.65;
  double pitch = .58;
  double zoom = 1;
  Offset pan = Offset.zero;

  void update(Offset delta, double scaleRatio, int pointerCount) {
    if (pointerCount >= 2) {
      pan += delta;
      if (scaleRatio.isFinite && scaleRatio > 0) zoom = (zoom * scaleRatio).clamp(.25, 12);
    } else {
      yaw += delta.dx / 140;
      pitch = (pitch + delta.dy / 140).clamp(-1.35, 1.35);
    }
  }

  void reset() {
    yaw = -.65;
    pitch = .58;
    zoom = 1;
    pan = Offset.zero;
  }
}

Map<Type, GestureRecognizerFactory> _spatialGestureFactories(_SpatialCamera camera, VoidCallback changed) => {
  _SpatialGestureRecognizer: GestureRecognizerFactoryWithHandlers<_SpatialGestureRecognizer>(
    _SpatialGestureRecognizer.new,
    (recognizer) => recognizer
      ..onUpdate = (delta, scaleRatio, pointerCount) {
        camera.update(delta, scaleRatio, pointerCount);
        changed();
      },
  ),
};

class SpatialPlotCard extends StatefulWidget {
  const SpatialPlotCard({super.key, required this.plot, this.showHeader = true});
  final SpatialPlot plot;
  final bool showHeader;

  @override
  State<SpatialPlotCard> createState() => _SpatialPlotCardState();
}

class _SpatialPlotCardState extends State<SpatialPlotCard> {
  SpatialPlot get plot => widget.plot;
  bool get showHeader => widget.showHeader;
  final _camera = _SpatialCamera();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = CartesianPlotStyle.of(theme);
    void open() =>
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SpatialPlotPage(initialPlot: plot)));
    final expand = IconButton(
      key: const ValueKey('spatial-expand'),
      tooltip: t('放大全屏', 'Open full screen'),
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.open_in_full_rounded, size: 20),
      onPressed: open,
    );
    return Container(
      decoration: BoxDecoration(color: style.paper, borderRadius: BorderRadius.circular(18)),
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showHeader)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 6, 2),
                child: Row(
                  children: [
                    Icon(Icons.view_in_ar_rounded, color: theme.colorScheme.primary, size: 21),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        spatialPlotTitle(plot),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    expand,
                  ],
                ),
              ),
            GestureDetector(
              onTap: open,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final height = math.min(width * 1.04, 480.0);
                  return Semantics(
                    label: spatialPlotDescription(plot),
                    image: true,
                    child: RawGestureDetector(
                      gestures: _spatialGestureFactories(_camera, () => setState(() {})),
                      behavior: HitTestBehavior.opaque,
                      child: RepaintBoundary(
                        child: CustomPaint(
                          key: const ValueKey('spatial-preview'),
                          size: Size(width, height),
                          painter: SpatialPlotPainter(
                            plot: plot,
                            style: style,
                            size: Size(width, height),
                            yaw: _camera.yaw,
                            pitch: _camera.pitch,
                            zoom: _camera.zoom,
                            pan: _camera.pan,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 4, 4),
              child: Row(
                children: [
                  Expanded(
                    child: _SpatialLegend(plot: plot, style: style),
                  ),
                  if (!showHeader) expand,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String spatialPlotDescription(SpatialPlot plot) =>
    [spatialPlotTitle(plot), ...plot.surfaces.map((s) => 'z = $s'), ...plot.points.map((p) => p.caption)].join('; ');

class _SpatialLegend extends StatelessWidget {
  const _SpatialLegend({required this.plot, required this.style});
  final SpatialPlot plot;
  final CartesianPlotStyle style;
  @override
  Widget build(BuildContext context) {
    if (plot.surfaces.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        for (var i = 0; i < plot.surfaces.length; i++)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 13,
                height: 3,
                decoration: BoxDecoration(color: style.seriesAt(i), borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  plot.surfaces[i].contains('=') ? plot.surfaces[i] : 'z = ${plot.surfaces[i]}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: themeText(style),
                ),
              ),
            ],
          ),
      ],
    );
  }

  TextStyle themeText(CartesianPlotStyle style) => style.textStyle.copyWith(color: style.ink, fontSize: 12);
}

class SpatialPlotPage extends StatefulWidget {
  const SpatialPlotPage({super.key, required this.initialPlot});
  final SpatialPlot initialPlot;
  @override
  State<SpatialPlotPage> createState() => _SpatialPlotPageState();
}

class _SpatialPlotPageState extends State<SpatialPlotPage> {
  late SpatialPlot _plot = widget.initialPlot;
  final _camera = _SpatialCamera();

  void _reset() => setState(_camera.reset);

  Future<void> _edit() async {
    final result = await showModalBottomSheet<SpatialPlot>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _SpatialEditor(plot: _plot),
    );
    if (result != null && mounted) setState(() => _plot = result);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = CartesianPlotStyle.of(theme);
    return Scaffold(
      appBar: AppBar(
        title: Text(spatialPlotTitle(_plot), maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            key: const ValueKey('spatial-edit'),
            tooltip: t('编辑参数', 'Edit parameters'),
            onPressed: _edit,
            icon: const Icon(Icons.tune_rounded),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
                child: Container(
                  decoration: BoxDecoration(color: style.paper, borderRadius: BorderRadius.circular(22)),
                  foregroundDecoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: theme.colorScheme.outlineVariant),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: LayoutBuilder(
                      builder: (context, c) {
                        return RawGestureDetector(
                          key: const ValueKey('spatial-canvas'),
                          gestures: _spatialGestureFactories(_camera, () => setState(() {})),
                          behavior: HitTestBehavior.opaque,
                          child: Semantics(
                            label: spatialPlotDescription(_plot),
                            image: true,
                            child: RepaintBoundary(
                              child: CustomPaint(
                                size: c.biggest,
                                painter: SpatialPlotPainter(
                                  plot: _plot,
                                  style: style,
                                  size: c.biggest,
                                  yaw: _camera.yaw,
                                  pitch: _camera.pitch,
                                  zoom: _camera.zoom,
                                  pan: _camera.pan,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
            if (_plot.surfaces.isNotEmpty)
              SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
                child: _SpatialLegend(plot: _plot, style: style),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      t('单指旋转 · 双指平移/缩放', 'One finger to orbit · Two fingers to pan/zoom'),
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('spatial-zoom-out'),
                    tooltip: t('缩小', 'Zoom out'),
                    onPressed: () => setState(() => _camera.zoom = (_camera.zoom / 1.3).clamp(.25, 12)),
                    icon: const Icon(Icons.remove_rounded),
                  ),
                  IconButton(
                    key: const ValueKey('spatial-reset'),
                    tooltip: t('重置视图', 'Reset view'),
                    onPressed: _reset,
                    icon: const Icon(Icons.center_focus_strong_rounded),
                  ),
                  IconButton(
                    key: const ValueKey('spatial-zoom-in'),
                    tooltip: t('放大', 'Zoom in'),
                    onPressed: () => setState(() => _camera.zoom = (_camera.zoom * 1.3).clamp(.25, 12)),
                    icon: const Icon(Icons.add_rounded),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpatialEditor extends StatefulWidget {
  const _SpatialEditor({required this.plot});
  final SpatialPlot plot;
  @override
  State<_SpatialEditor> createState() => _SpatialEditorState();
}

class _SpatialEditorState extends State<_SpatialEditor> {
  late final _title = TextEditingController(text: widget.plot.title);
  late final _surfaces = TextEditingController(text: widget.plot.surfaces.join('\n'));
  late final _points = TextEditingController(
    text: widget.plot.points.map((p) => '${p.x}, ${p.y}, ${p.z}${p.name.isEmpty ? '' : ', ${p.name}'}').join('\n'),
  );
  late final _ranges = [
    widget.plot.xMin,
    widget.plot.xMax,
    widget.plot.yMin,
    widget.plot.yMax,
    widget.plot.zMin,
    widget.plot.zMax,
  ].map((v) => TextEditingController(text: '$v')).toList();
  String? _error;

  @override
  void dispose() {
    for (final c in [_title, _surfaces, _points, ..._ranges]) {
      c.dispose();
    }
    super.dispose();
  }

  void _apply() {
    try {
      final values = _ranges.map((c) => double.tryParse(c.text.trim())).toList();
      if (values.any((v) => v == null || !v.isFinite)) {
        throw FormatException(t('坐标范围需要填写有限数值。', 'Enter finite numbers for every boundary.'));
      }
      for (var i = 0; i < 6; i += 2) {
        if (values[i]! >= values[i + 1]!) {
          throw FormatException(t('最大值必须大于最小值。', 'Each maximum must exceed its minimum.'));
        }
      }
      final points = <SpatialPoint>[];
      for (final line in _points.text.split('\n').where((line) => line.trim().isNotEmpty)) {
        final parts = line.replaceAll('，', ',').split(',').map((e) => e.trim()).toList();
        if (parts.length < 3 || parts.length > 4 || parts.take(3).any((v) => double.tryParse(v) == null)) {
          throw FormatException(t('坐标点格式：x, y, z, 名称（名称可省略）。', 'Point format: x, y, z, label (label is optional).'));
        }
        final x = double.parse(parts[0]);
        final y = double.parse(parts[1]);
        final z = double.parse(parts[2]);
        final label = parts.length == 4 ? parts[3] : '';
        final kept = widget.plot.points.where(
          (p) => p.x == x && p.y == y && p.z == z && p.name == plotPointName(label),
        );
        points.add(
          SpatialPoint(x: x, y: y, z: z, label: label, showCoordinates: kept.isEmpty || kept.first.showCoordinates),
        );
      }
      final names = {for (final p in points) p.name};
      final plot = widget.plot.copyWith(
        title: _title.text,
        surfaces: _surfaces.text.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
        points: points,
        segments: [
          for (final s in widget.plot.segments)
            if (names.contains(plotPointName(s.from)) && names.contains(plotPointName(s.to))) s,
        ],
        xMin: values[0],
        xMax: values[1],
        yMin: values[2],
        yMax: values[3],
        zMin: values[4],
        zMax: values[5],
      );
      Navigator.pop(context, plot);
    } on FormatException catch (e) {
      setState(() => _error = '${t('请检查参数：', 'Check parameters: ')}${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t('空间绘图参数', '3D plot parameters'), style: Theme.of(context).textTheme.titleLarge),
          TextField(
            key: const ValueKey('spatial-title-field'),
            controller: _title,
            maxLength: 100,
            decoration: InputDecoration(labelText: t('标题', 'Title')),
          ),
          TextField(
            key: const ValueKey('spatial-surfaces-field'),
            controller: _surfaces,
            minLines: 2,
            maxLines: 5,
            maxLength: 3078,
            decoration: InputDecoration(
              labelText: t('曲面 z=f(x,y) · 每行一个', 'Surfaces z=f(x,y) · one per line'),
              hintText: 'z = x^2 + y^2\nsin(x) * cos(y)',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('spatial-points-field'),
            controller: _points,
            minLines: 2,
            maxLines: 5,
            maxLength: 8000,
            decoration: InputDecoration(
              labelText: t('三维坐标点 · 每行一个', '3D points · one per line'),
              hintText: '0, 0, 0, O\n1, 2, 3, A',
            ),
          ),
          const SizedBox(height: 12),
          for (var row = 0; row < 3; row++)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  for (var col = 0; col < 2; col++) ...[
                    if (col > 0) const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        key: ValueKey('spatial-bound-${row * 2 + col}'),
                        controller: _ranges[row * 2 + col],
                        keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                        decoration: InputDecoration(
                          labelText: '${'xyz'[row]} ${col == 0 ? t('最小值', 'min') : t('最大值', 'max')}',
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _error!,
                key: const ValueKey('spatial-validation-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          FilledButton.icon(
            key: const ValueKey('spatial-apply'),
            onPressed: _apply,
            icon: const Icon(Icons.check_rounded),
            label: Text(t('应用并绘图', 'Apply and plot')),
          ),
        ],
      ),
    ),
  );
}

/// Software-rendered surface mesh with depth sorting; no GPU or external service required.
class SpatialPlotPainter extends CustomPainter {
  SpatialPlotPainter({
    required this.plot,
    required this.style,
    required Size size,
    double yaw = -.65,
    double pitch = .58,
    double zoom = 1,
    Offset pan = Offset.zero,
  }) : projection = SpatialProjection(size: size, plot: plot, yaw: yaw, pitch: pitch, zoom: zoom, pan: pan);
  final SpatialPlot plot;
  final CartesianPlotStyle style;
  final SpatialProjection projection;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 80 || size.height < 70) return;
    canvas.drawRect(Offset.zero & size, Paint()..color = style.paper);
    final g = projection;
    Offset? at(double x, double y, double z) => g.project(x, y, z)?.at;
    final ox = plot.xMin <= 0 && plot.xMax >= 0
        ? 0.0
        : plot.xMin > 0
        ? plot.xMin
        : plot.xMax;
    final oy = plot.yMin <= 0 && plot.yMax >= 0
        ? 0.0
        : plot.yMin > 0
        ? plot.yMin
        : plot.yMax;
    final oz = plot.zMin <= 0 && plot.zMax >= 0
        ? 0.0
        : plot.zMin > 0
        ? plot.zMin
        : plot.zMax;
    final baseZ = oz;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    var step = g.gridStep;
    double niceStep(double raw) {
      final magnitude = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
      final normalized = raw / magnitude;
      final factor = normalized < 1.5
          ? 1
          : normalized < 3.5
          ? 2
          : normalized < 7.5
          ? 5
          : 10;
      return factor * magnitude;
    }

    final planeBounds = g.xyPlaneWorldBounds(baseZ);
    if (planeBounds != null) {
      final plane = Path();
      final planeCorners = [
        at(planeBounds.left, planeBounds.top, baseZ),
        at(planeBounds.right, planeBounds.top, baseZ),
        at(planeBounds.right, planeBounds.bottom, baseZ),
        at(planeBounds.left, planeBounds.bottom, baseZ),
      ];
      if (planeCorners.every((point) => point != null)) {
        plane.moveTo(planeCorners.first!.dx, planeCorners.first!.dy);
        for (final point in planeCorners.skip(1)) {
          plane.lineTo(point!.dx, point.dy);
        }
        plane.close();
        canvas.drawPath(plane, Paint()..color = style.seriesAt(0).withValues(alpha: .045));
      }

      if (planeBounds.width / step > 400 || planeBounds.height / step > 400) {
        step = niceStep(math.max(planeBounds.width, planeBounds.height) / 400);
      }
      void drawGridAxis({required bool fixedX, required double min, required double max}) {
        final first = (min / step).ceil() * step;
        for (var i = 0; i < 400; i++) {
          final value = first + i * step;
          if (value > max + step * 1e-9) break;
          final line = g.xyGridLine(fixedX: fixedX, value: value, z: baseZ);
          if (line == null) continue;
          final major = (value / step).round() % 5 == 0;
          final paint = Paint()
            ..color = major ? style.majorGrid.withValues(alpha: .48) : style.grid
            ..strokeWidth = major ? .9 : .65;
          canvas.drawLine(line.$1, line.$2, paint);
        }
      }

      drawGridAxis(fixedX: true, min: planeBounds.left, max: planeBounds.right);
      drawGridAxis(fixedX: false, min: planeBounds.top, max: planeBounds.bottom);
    }
    _paintSurfaces(canvas, g, size);

    final axes = Paint()
      ..color = style.axis
      ..strokeWidth = 1.7;
    final xLine = g.axisAcrossCanvas(SpatialAxis.x, ox, oy, oz);
    final yLine = g.axisAcrossCanvas(SpatialAxis.y, ox, oy, oz);
    final zLine = g.axisAcrossCanvas(SpatialAxis.z, ox, oy, oz);
    if (xLine != null) canvas.drawLine(xLine.$1, xLine.$2, axes);
    if (yLine != null) canvas.drawLine(yLine.$1, yLine.$2, axes);
    if (zLine != null) canvas.drawLine(zLine.$1, zLine.$2, axes);
    canvas.restore();

    for (final segment in plot.segments) {
      final from = plot.pointNamed(segment.from);
      final to = plot.pointNamed(segment.to);
      final a = at(from.x, from.y, from.z);
      final b = at(to.x, to.y, to.z);
      if (a == null || b == null) continue;
      final paint = Paint()
        ..color = resolvePlotLineColor(segment.color, style.ink).withValues(alpha: .9)
        ..strokeWidth = segment.style == PlotLineStyle.dotted ? 2.0 : 1.7
        ..strokeCap = StrokeCap.round;
      drawPlotSegment(canvas, a, b, paint, segment.style, (Offset.zero & size).inflate(8));
    }

    for (final p in plot.points) {
      final point = at(p.x, p.y, p.z);
      if (point == null || !(Offset.zero & size).contains(point)) continue;
      canvas.drawCircle(point, 5, Paint()..color = style.paper);
      canvas.drawCircle(point, 3.5, Paint()..color = style.ink);
      if (p.caption.isNotEmpty) _label(canvas, p.caption, point + const Offset(8, -18), style.ink, size);
    }
    _label(canvas, 'x', xLine?.$2, style.ink, size);
    _label(canvas, 'y', yLine?.$2, style.ink, size);
    _label(canvas, 'z', zLine?.$2, style.ink, size);
    _label(canvas, 'O', at(ox, oy, oz), style.mutedInk, size, offset: const Offset(6, 4));
    double tickStep(double min, double max) {
      final raw = (max - min) / 4;
      final magnitude = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
      final normalized = raw / magnitude;
      final factor = normalized < 1.5
          ? 1
          : normalized < 3.5
          ? 2
          : normalized < 7.5
          ? 5
          : 10;
      return factor * magnitude;
    }

    void axisTicks(double min, double max, Offset? Function(double) pointAt, Offset labelOffset) {
      final step = tickStep(min, max);
      final first = (min / step).ceil() * step;
      final paint = Paint()
        ..color = style.axis
        ..strokeWidth = 1.2;
      for (var index = 0; index < 8; index++) {
        final value = first + index * step;
        if (value > max || (value - min).abs() < step * .03 || value.abs() < step * .03) continue;
        final point = pointAt(value);
        if (point == null) continue;
        canvas.drawCircle(point, 1.6, paint);
        _label(canvas, formatPlotNumber(value), point, style.mutedInk, size, fontSize: 9, offset: labelOffset);
      }
    }

    axisTicks(plot.xMin, plot.xMax, (x) => at(x, oy, oz), const Offset(3, 4));
    axisTicks(plot.yMin, plot.yMax, (y) => at(ox, y, oz), const Offset(-18, 4));
    axisTicks(plot.zMin, plot.zMax, (z) => at(ox, oy, z), const Offset(4, -12));
  }

  void _label(
    Canvas canvas,
    String text,
    Offset? at,
    Color color,
    Size size, {
    double fontSize = 13,
    Offset offset = const Offset(6, -18),
  }) {
    if (at == null || !at.isFinite) return;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          shadows: [
            Shadow(color: style.paper, blurRadius: 3),
            Shadow(color: style.paper, blurRadius: 3),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final position = Offset(
      (at.dx + offset.dx).clamp(2.0, math.max(2.0, size.width - painter.width - 2)),
      (at.dy + offset.dy).clamp(2.0, math.max(2.0, size.height - painter.height - 2)),
    );
    painter.paint(canvas, position);
    painter.dispose();
  }

  void _paintSurfaces(Canvas canvas, SpatialProjection g, Size size) {
    final density = (math.min(size.shortestSide, 650) / 20).clamp(16, 32).toInt();
    for (var index = 0; index < plot.expressions.length; index++) {
      final expression = plot.expressions[index];
      final values = List.generate(
        density + 1,
        (row) => List.generate(density + 1, (col) {
          final x = plot.xMin + (plot.xMax - plot.xMin) * col / density;
          final y = plot.yMin + (plot.yMax - plot.yMin) * row / density;
          final z = expression.evaluate(x, y);
          return z.isFinite && z >= plot.zMin && z <= plot.zMax ? g.project(x, y, z) : null;
        }),
      );
      final faces =
          <
            ({
              double depth,
              Path path,
              SpatialProjectedPoint a,
              SpatialProjectedPoint b,
              SpatialProjectedPoint c,
              SpatialProjectedPoint d,
            })
          >[];
      for (var row = 0; row < density; row++) {
        for (var col = 0; col < density; col++) {
          final a = values[row][col];
          final b = values[row][col + 1];
          final c = values[row + 1][col + 1];
          final d = values[row + 1][col];
          if (a == null || b == null || c == null || d == null) continue;
          final path = Path()
            ..moveTo(a.at.dx, a.at.dy)
            ..lineTo(b.at.dx, b.at.dy)
            ..lineTo(c.at.dx, c.at.dy)
            ..lineTo(d.at.dx, d.at.dy)
            ..close();
          faces.add((depth: (a.depth + b.depth + c.depth + d.depth) / 4, path: path, a: a, b: b, c: c, d: d));
        }
      }
      faces.sort((a, b) => a.depth.compareTo(b.depth));
      for (final face in faces) {
        final light = (.55 + face.depth.clamp(-1.5, 1.5) / 10).clamp(.4, .7);
        canvas.drawPath(face.path, Paint()..color = style.seriesAt(index).withValues(alpha: light));
        canvas.drawPath(
          face.path,
          Paint()
            ..color = style.seriesAt(index).withValues(alpha: .42)
            ..style = PaintingStyle.stroke
            ..strokeWidth = .45,
        );
      }
    }
  }

  @override
  bool shouldRepaint(SpatialPlotPainter old) => old.plot != plot || old.style != style || old.projection != projection;
}
