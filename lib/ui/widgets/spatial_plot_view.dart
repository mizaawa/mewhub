import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/i18n.dart';
import '../../tools/cartesian_plot.dart';
import '../../tools/spatial_plot.dart';
import 'cartesian_plot_view.dart';

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

  SpatialProjectedPoint? project(double x, double y, double z) {
    if (!x.isFinite || !y.isFinite || !z.isFinite) return null;
    final nx = (x - (plot.xMin + plot.xMax) / 2) / ((plot.xMax - plot.xMin) / 2);
    final ny = (y - (plot.yMin + plot.yMax) / 2) / ((plot.yMax - plot.yMin) / 2);
    final nz = (z - (plot.zMin + plot.zMax) / 2) / ((plot.zMax - plot.zMin) / 2);
    final rx = nx * math.cos(yaw) - ny * math.sin(yaw);
    final ry = nx * math.sin(yaw) + ny * math.cos(yaw);
    final screenY = ry * math.sin(pitch) + nz * math.cos(pitch);
    final depth = ry * math.cos(pitch) - nz * math.sin(pitch);
    // Perspective stays bounded while rotating and gives nearer objects a clear size cue.
    final perspective = 5.5 / (5.5 - depth * .65);
    final scale = math.min(size.width, size.height) * .31 * zoom * perspective;
    final center = size.center(Offset.zero) + pan;
    return SpatialProjectedPoint(Offset(center.dx + rx * scale, center.dy - screenY * scale), depth);
  }
}

class SpatialProjectedPoint {
  const SpatialProjectedPoint(this.at, this.depth);
  final Offset at;
  final double depth;
}

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
  double _yaw = -.65;
  double _pitch = .58;
  double _zoom = 1;
  Offset _pan = Offset.zero;
  Offset _gestureFocal = Offset.zero;
  late double _gestureYaw;
  late double _gesturePitch;
  late double _gestureZoom;
  late Offset _gesturePan;

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
              onScaleStart: (details) {
                _gestureFocal = details.localFocalPoint;
                _gestureYaw = _yaw;
                _gesturePitch = _pitch;
                _gestureZoom = _zoom;
                _gesturePan = _pan;
              },
              onScaleUpdate: (details) {
                setState(() {
                  if (details.pointerCount >= 2) {
                    _pan = _gesturePan + (details.localFocalPoint - _gestureFocal) * details.pointerCount.toDouble();
                    _zoom = (_gestureZoom * details.scale).clamp(.25, 12);
                  } else {
                    _yaw = _gestureYaw + details.focalPointDelta.dx / 140;
                    _pitch = (_gesturePitch + details.focalPointDelta.dy / 140).clamp(-1.35, 1.35);
                  }
                });
              },
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  final height = math.min(width * 1.04, 480.0);
                  return Semantics(
                    label: spatialPlotDescription(plot),
                    image: true,
                    child: RepaintBoundary(
                      child: CustomPaint(
                        key: const ValueKey('spatial-preview'),
                        size: Size(width, height),
                        painter: SpatialPlotPainter(
                          plot: plot,
                          style: style,
                          size: Size(width, height),
                          yaw: _yaw,
                          pitch: _pitch,
                          zoom: _zoom,
                          pan: _pan,
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
  double _yaw = -.65;
  double _pitch = .58;
  double _zoom = 1;
  Offset _pan = Offset.zero;
  late double _gestureYaw;
  late double _gesturePitch;
  late double _gestureZoom;
  late Offset _gesturePan;
  Offset _gestureFocal = Offset.zero;

  void _reset() => setState(() {
    _yaw = -.65;
    _pitch = .58;
    _zoom = 1;
    _pan = Offset.zero;
  });

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
                        return GestureDetector(
                          key: const ValueKey('spatial-canvas'),
                          behavior: HitTestBehavior.opaque,
                          onScaleStart: (details) {
                            _gestureFocal = details.localFocalPoint;
                            _gestureYaw = _yaw;
                            _gesturePitch = _pitch;
                            _gestureZoom = _zoom;
                            _gesturePan = _pan;
                          },
                          onScaleUpdate: (details) {
                            if (details.pointerCount >= 2) {
                              setState(() {
                                _pan =
                                    _gesturePan +
                                    (details.localFocalPoint - _gestureFocal) * details.pointerCount.toDouble();
                                _zoom = (_gestureZoom * details.scale).clamp(.25, 12);
                              });
                            } else {
                              setState(() {
                                _yaw = _gestureYaw + details.focalPointDelta.dx / 140;
                                _pitch = (_gesturePitch + details.focalPointDelta.dy / 140).clamp(-1.35, 1.35);
                              });
                            }
                          },
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
                                  yaw: _yaw,
                                  pitch: _pitch,
                                  zoom: _zoom,
                                  pan: _pan,
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
                    onPressed: () => setState(() => _zoom = (_zoom / 1.3).clamp(.25, 12)),
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
                    onPressed: () => setState(() => _zoom = (_zoom * 1.3).clamp(.25, 12)),
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

  void _line(Canvas canvas, Offset? a, Offset? b, Paint paint) {
    if (a != null && b != null && a.isFinite && b.isFinite) canvas.drawLine(a, b, paint);
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint) {
    final length = (b - a).distance;
    if (length == 0 || !length.isFinite) return;
    final d = (b - a) / length;
    for (var i = 0.0; i < length; i += 10) {
      canvas.drawLine(a + d * i, a + d * math.min(i + 6, length), paint);
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 80 || size.height < 70) return;
    canvas.drawRect(Offset.zero & size, Paint()..color = style.paper);
    final g = projection;
    Offset? at(double x, double y, double z) => g.project(x, y, z)?.at;
    final baseZ = 0 >= plot.zMin && 0 <= plot.zMax ? 0.0 : plot.zMin;
    final grid = Paint()
      ..color = style.grid
      ..strokeWidth = .75;
    for (var i = 0; i <= 10; i++) {
      final x = plot.xMin + (plot.xMax - plot.xMin) * i / 10;
      final y = plot.yMin + (plot.yMax - plot.yMin) * i / 10;
      _line(canvas, at(x, plot.yMin, baseZ), at(x, plot.yMax, baseZ), grid);
      _line(canvas, at(plot.xMin, y, baseZ), at(plot.yMax, y, baseZ), grid);
    }
    final edge = Paint()
      ..color = style.majorGrid
      ..strokeWidth = 1;
    final corners = [
      for (final x in [plot.xMin, plot.xMax])
        for (final y in [plot.yMin, plot.yMax]) (x, y),
    ];
    for (final (x, y) in corners) {
      _line(canvas, at(x, y, plot.zMin), at(x, y, plot.zMax), edge);
    }
    for (final z in [plot.zMin, plot.zMax]) {
      for (var i = 0; i < 4; i++) {
        _line(
          canvas,
          at(corners[i].$1, corners[i].$2, z),
          at(corners[(i + 1) % 4].$1, corners[(i + 1) % 4].$2, z),
          edge,
        );
      }
    }
    _paintSurfaces(canvas, g, size);

    final axes = Paint()
      ..color = style.axis
      ..strokeWidth = 1.5;
    final ox = plot.xMin.clamp(0.0, plot.xMax);
    final oy = plot.yMin.clamp(0.0, plot.yMax);
    final oz = plot.zMin.clamp(0.0, plot.zMax);
    _line(canvas, at(plot.xMin, oy, oz), at(plot.xMax, oy, oz), axes);
    _line(canvas, at(ox, plot.yMin, oz), at(ox, plot.yMax, oz), axes);
    _line(canvas, at(ox, oy, plot.zMin), at(ox, oy, plot.zMax), axes);

    for (final segment in plot.segments) {
      final from = plot.pointNamed(segment.from);
      final to = plot.pointNamed(segment.to);
      final a = at(from.x, from.y, from.z);
      final b = at(to.x, to.y, to.z);
      if (a == null || b == null) continue;
      final paint = Paint()
        ..color = style.ink.withValues(alpha: .8)
        ..strokeWidth = 1.6;
      if (segment.dashed) {
        _dashed(canvas, a, b, paint);
      } else {
        canvas.drawLine(a, b, paint);
      }
    }

    for (final p in plot.points) {
      final point = at(p.x, p.y, p.z);
      if (point == null || !(Offset.zero & size).contains(point)) continue;
      canvas.drawCircle(point, 5, Paint()..color = style.paper);
      canvas.drawCircle(point, 3.5, Paint()..color = style.ink);
      if (p.caption.isNotEmpty) _label(canvas, p.caption, point + const Offset(8, -18), style.ink, size);
    }
    _label(canvas, 'x', at(plot.xMax, oy, oz), style.ink, size);
    _label(canvas, 'y', at(ox, plot.yMax, oz), style.ink, size);
    _label(canvas, 'z', at(ox, oy, plot.zMax), style.ink, size);
    _label(canvas, 'O', at(ox, oy, oz), style.mutedInk, size, offset: const Offset(6, 4));
    void axisTick(String axis, double x, double y, double z) {
      final value = axis == 'x'
          ? x
          : axis == 'y'
          ? y
          : z;
      _label(
        canvas,
        formatPlotNumber(value),
        at(x, y, z),
        style.mutedInk,
        size,
        fontSize: 10,
        offset: const Offset(4, 6),
      );
    }

    axisTick('x', plot.xMin, oy, oz);
    axisTick('x', plot.xMax, oy, oz);
    axisTick('y', ox, plot.yMin, oz);
    axisTick('y', ox, plot.yMax, oz);
    axisTick('z', ox, oy, plot.zMin);
    axisTick('z', ox, oy, plot.zMax);
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
        final light = (.5 + face.depth.clamp(-1.5, 1.5) / 6).clamp(.25, .75);
        canvas.drawPath(face.path, Paint()..color = style.seriesAt(index).withValues(alpha: light));
        canvas.drawPath(
          face.path,
          Paint()
            ..color = style.seriesAt(index).withValues(alpha: .30)
            ..style = PaintingStyle.stroke
            ..strokeWidth = .45,
        );
      }
    }
  }

  @override
  bool shouldRepaint(SpatialPlotPainter old) => old.plot != plot || old.style != style || old.projection != projection;
}
