import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ai/message.dart';
import '../../core/attachments.dart';
import '../../core/i18n.dart';
import '../../tools/cartesian_plot.dart';
import '../../tools/plot_expression.dart';
import '../theme.dart';

String _title(CartesianPlot plot) => plot.title.isEmpty ? t('平面直角坐标系', 'Cartesian plane') : plot.title;
String _number(double n) => n == 0
    ? '0'
    : (n.abs() < .001 || n.abs() >= 100000)
    ? n.toStringAsExponential(2)
    : n.toStringAsFixed(6).replaceFirst(RegExp(r'\.?0+$'), '');
Rect _bounds(CartesianPlot p) => Rect.fromLTRB(p.xMin, p.yMin, p.xMax, p.yMax);
List<Color> _colors(ColorScheme s) => <Color>{
  s.primary,
  s.tertiary,
  s.secondary,
  ...MewColors.accents.map((c) => s.brightness == Brightness.dark ? Color.lerp(c, Colors.white, .18)! : c),
}.toList();

/// An immediately visible, theme-aware graph in a chat message.
class CartesianPlotCard extends StatelessWidget {
  const CartesianPlotCard({super.key, required this.plot});
  final CartesianPlot plot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 0),
            child: Row(
              children: [
                Icon(Icons.grid_4x4_rounded, color: theme.colorScheme.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _title(plot),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  key: const ValueKey('cartesian-expand'),
                  tooltip: t('放大全屏', 'Open full screen'),
                  icon: const Icon(Icons.open_in_full_rounded),
                  onPressed: () =>
                      Navigator.of(context)
                          .push(MaterialPageRoute<void>(builder: (_) => CartesianPlotPage(initialPlot: plot))),
                ),
              ],
            ),
          ),
          Semantics(
            label:
                '${_title(plot)}; ${plot.functions.join('; ')}; ${plot.points.map((p) => '${p.label} (${p.x}, ${p.y})').join('; ')}',
            image: true,
            child: AspectRatio(
              aspectRatio: 1.2,
              child: CustomPaint(
                key: const ValueKey('cartesian-preview'),
                painter: CartesianPlotPainter(
                  plot: plot,
                  scheme: theme.colorScheme,
                  fontFamily: theme.textTheme.bodyMedium?.fontFamily,
                ),
              ),
            ),
          ),
          if (plot.functions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: _Legend(plot: plot),
            ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.plot});
  final CartesianPlot plot;
  @override
  Widget build(BuildContext context) {
    final colors = _colors(Theme.of(context).colorScheme);
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      children: [
        for (var i = 0; i < plot.functions.length; i++)
          Text('●  ${plot.functions[i]}', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: colors[i])),
      ],
    );
  }
}

/// Explore a copy; original chat messages remain unchanged.
class CartesianPlotPage extends StatefulWidget {
  const CartesianPlotPage({super.key, required this.initialPlot, this.allowAttach = false});
  final CartesianPlot initialPlot;
  final bool allowAttach;
  @override
  State<CartesianPlotPage> createState() => _CartesianPlotPageState();
}

class _CartesianPlotPageState extends State<CartesianPlotPage> {
  late CartesianPlot _plot = widget.initialPlot;
  late Rect _view = _bounds(_plot);
  Rect? _gestureView;
  Offset? _gestureFocal;
  bool _sending = false;
  String? _error;

  void _setView(Rect view) {
    if (view.width < CartesianPlot.minSpan ||
        view.height < CartesianPlot.minSpan ||
        view.left.abs() > CartesianPlot.maxCoordinate ||
        view.right.abs() > CartesianPlot.maxCoordinate ||
        view.top.abs() > CartesianPlot.maxCoordinate ||
        view.bottom.abs() > CartesianPlot.maxCoordinate) {
      return;
    }
    setState(() => _view = view);
  }

  void _zoom(double factor) =>
      _setView(Rect.fromCenter(center: _view.center, width: _view.width * factor, height: _view.height * factor));

  Future<void> _edit() async {
    final result = await showModalBottomSheet<CartesianPlot>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => _PlotEditor(plot: _plot),
    );
    if (result == null || !mounted) return;
    setState(() {
      _plot = result;
      _view = _bounds(result);
      _error = null;
    });
  }

  Future<void> _attach() async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final plot = CartesianPlot(
        title: _plot.title,
        functions: _plot.functions,
        points: _plot.points,
        xMin: _view.left,
        xMax: _view.right,
        yMin: _view.top,
        yMax: _view.bottom,
      );
      final theme = Theme.of(context);
      final bytes = await renderCartesianPlotPng(
        plot,
        scheme: theme.colorScheme,
        fontFamily: theme.textTheme.bodyMedium?.fontFamily,
      );
      final path = await Attachments.storeBytes(bytes, 'png');
      if (!mounted) {
        await Attachments.deleteStored(path);
        return;
      }
      Navigator.of(context).pop(ImagePart(path, meta: {'cartesian_plot': plot.toJson()}));
    } catch (e) {
      if (mounted) setState(() => _error = t('生成图片失败，请重试。', 'Could not create the image. Please try again.'));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: mewSystemUiOverlayStyle(theme.brightness),
      child: Scaffold(
        appBar: AppBar(
          title: Text(_title(_plot), maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              key: const ValueKey('cartesian-edit'),
              tooltip: t('编辑参数', 'Edit parameters'),
              onPressed: _edit,
              icon: const Icon(Icons.tune_rounded),
            ),
            if (widget.allowAttach)
              IconButton(
                key: const ValueKey('cartesian-attach'),
                tooltip: t('添加到聊天', 'Attach to chat'),
                onPressed: _sending ? null : _attach,
                icon: _sending
                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send_rounded),
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
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(22),
                    child: ColoredBox(
                      color: theme.colorScheme.surfaceContainerLow,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final size = constraints.biggest;
                          return GestureDetector(
                            key: const ValueKey('cartesian-canvas'),
                            behavior: HitTestBehavior.opaque,
                            onScaleStart: (d) {
                              _gestureView = _view;
                              _gestureFocal = d.localFocalPoint;
                            },
                            onScaleUpdate: (d) {
                              final original = _gestureView;
                              if (original == null || d.scale <= 0) return;
                              final geometry = PlotGeometry(original, size);
                              final start = geometry.toWorld(_gestureFocal!);
                              final current = geometry.toWorld(d.localFocalPoint);
                              final center = start + (original.center - current) / d.scale;
                              _setView(
                                Rect.fromCenter(
                                  center: center,
                                  width: original.width / d.scale,
                                  height: original.height / d.scale,
                                ),
                              );
                            },
                            child: CustomPaint(
                              size: size,
                              painter: CartesianPlotPainter(
                                plot: _plot,
                                scheme: theme.colorScheme,
                                view: _view,
                                fontFamily: theme.textTheme.bodyMedium?.fontFamily,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
              if (_plot.functions.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 70),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
                    child: _Legend(plot: _plot),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(t('拖动平移 · 双指缩放', 'Drag to pan · Pinch to zoom'), style: theme.textTheme.labelSmall),
                    ),
                    IconButton(
                      key: const ValueKey('cartesian-zoom-out'),
                      tooltip: t('缩小', 'Zoom out'),
                      onPressed: () => _zoom(1.4),
                      icon: const Icon(Icons.remove_rounded),
                    ),
                    IconButton(
                      key: const ValueKey('cartesian-reset'),
                      tooltip: t('重置视图', 'Reset view'),
                      onPressed: () => setState(() => _view = _bounds(_plot)),
                      icon: const Icon(Icons.center_focus_strong_rounded),
                    ),
                    IconButton(
                      key: const ValueKey('cartesian-zoom-in'),
                      tooltip: t('放大', 'Zoom in'),
                      onPressed: () => _zoom(1 / 1.4),
                      icon: const Icon(Icons.add_rounded),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlotEditor extends StatefulWidget {
  const _PlotEditor({required this.plot});
  final CartesianPlot plot;
  @override
  State<_PlotEditor> createState() => _PlotEditorState();
}

class _PlotEditorState extends State<_PlotEditor> {
  late final _title = TextEditingController(text: widget.plot.title);
  late final _functions = TextEditingController(text: widget.plot.functions.join('\n'));
  late final _points = TextEditingController(
    text: widget.plot.points.map((p) => '${p.x}, ${p.y}${p.label.isEmpty ? '' : ', ${p.label}'}').join('\n'),
  );
  late final _range = [
    widget.plot.xMin,
    widget.plot.xMax,
    widget.plot.yMin,
    widget.plot.yMax,
  ].map((v) => TextEditingController(text: '$v')).toList();
  String? _error;

  @override
  void dispose() {
    for (final c in [_title, _functions, _points, ..._range]) {
      c.dispose();
    }
    super.dispose();
  }

  void _apply() {
    try {
      final values = _range.map((c) => double.tryParse(c.text.trim())).toList();
      if (values.any((v) => v == null || !v.isFinite)) {
        throw FormatException(t('坐标范围需要填写有限数值。', 'Enter finite numbers for every boundary.'));
      }
      if (values[0]! >= values[1]! || values[2]! >= values[3]!) {
        throw FormatException(t('最大值必须大于最小值。', 'Each maximum must exceed its minimum.'));
      }
      final points = <PlotPoint>[];
      for (final line in _points.text.split('\n').where((line) => line.trim().isNotEmpty)) {
        final parts = line.replaceAll('，', ',').split(',').map((e) => e.trim()).toList();
        if (parts.length < 2 ||
            parts.length > 3 ||
            double.tryParse(parts[0]) == null ||
            double.tryParse(parts[1]) == null) {
          throw FormatException(t('坐标点格式：x, y, 名称（名称可省略）。', 'Point format: x, y, label (label is optional).'));
        }
        points.add(
          PlotPoint(x: double.parse(parts[0]), y: double.parse(parts[1]), label: parts.length == 3 ? parts[2] : ''),
        );
      }
      final plot = CartesianPlot(
        title: _title.text,
        functions: _functions.text.split('\n').map((f) => f.trim()).where((f) => f.isNotEmpty).toList(),
        points: points,
        xMin: values[0]!,
        xMax: values[1]!,
        yMin: values[2]!,
        yMax: values[3]!,
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
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t('绘图参数', 'Plot parameters'), style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('cartesian-title-field'),
            controller: _title,
            maxLength: 100,
            decoration: InputDecoration(labelText: t('标题', 'Title')),
          ),
          TextField(
            key: const ValueKey('cartesian-functions-field'),
            controller: _functions,
            minLines: 2,
            maxLines: 5,
            maxLength: 4104,
            decoration: InputDecoration(
              labelText: t('函数 · 每行一个，最多 8 个', 'Functions · one per line, up to 8'),
              hintText: 'x^2\nsin(x)',
              helperText: t('支持 2x、π、sqrt(x)、sin(x)；角度用弧度', 'Supports 2x, pi, sqrt(x), sin(x); angles in radians'),
              helperMaxLines: 3,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey('cartesian-points-field'),
            controller: _points,
            minLines: 2,
            maxLines: 5,
            maxLength: 6000,
            decoration: InputDecoration(
              labelText: t('坐标点 · 每行一个，最多 64 个', 'Points · one per line, up to 64'),
              hintText: '1, 2, A\n-3, 4, B',
            ),
          ),
          const SizedBox(height: 16),
          for (var row = 0; row < 2; row++)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                children: [
                  for (var col = 0; col < 2; col++) ...[
                    if (col > 0) const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        key: ValueKey('cartesian-bound-${row * 2 + col}'),
                        controller: _range[row * 2 + col],
                        keyboardType: const TextInputType.numberWithOptions(signed: true, decimal: true),
                        decoration: InputDecoration(
                          labelText: '${row == 0 ? 'x' : 'y'} ${col == 0 ? t('最小值', 'min') : t('最大值', 'max')}',
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
                key: const ValueKey('cartesian-validation-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          FilledButton.icon(
            key: const ValueKey('cartesian-apply'),
            onPressed: _apply,
            icon: const Icon(Icons.check_rounded),
            label: Text(t('应用并绘图', 'Apply and plot')),
          ),
        ],
      ),
    ),
  );
}

/// Uses one pixels-per-unit scale for both axes, preserving mathematical shapes.
class PlotGeometry {
  PlotGeometry(this.world, Size size) {
    final available = Rect.fromLTWH(42, 24, math.max(1, size.width - 62), math.max(1, size.height - 58));
    scale = math.min(available.width / world.width, available.height / world.height);
    area = Rect.fromCenter(center: available.center, width: world.width * scale, height: world.height * scale);
  }
  final Rect world;
  late final double scale;
  late final Rect area;
  Offset toScreen(Offset value) =>
      Offset(area.left + (value.dx - world.left) * scale, area.bottom - (value.dy - world.top) * scale);
  Offset toWorld(Offset value) =>
      Offset(world.left + (value.dx - area.left) / scale, world.top + (area.bottom - value.dy) / scale);
}

/// Custom painter shared by the preview, live editor and exported PNG.
class CartesianPlotPainter extends CustomPainter {
  CartesianPlotPainter({required this.plot, required this.scheme, Rect? view, this.fontFamily})
    : view = view ?? _bounds(plot),
      expressions = plot.functions.map(PlotExpression.compile).toList();
  final CartesianPlot plot;
  final ColorScheme scheme;
  final String? fontFamily;
  final Rect view;
  final List<PlotExpression> expressions;

  static double tickStep(double span, double pixels) {
    final desired = span / math.max(2, pixels / 65);
    final power = math.pow(10, (math.log(desired) / math.ln10).floor()).toDouble();
    final relative = desired / power;
    return (relative <= 1
            ? 1
            : relative <= 2
            ? 2
            : relative <= 5
            ? 5
            : 10) *
        power;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 80 || size.height < 70) return;
    final g = PlotGeometry(view, size);
    final area = g.area;
    canvas.drawRect(Offset.zero & size, Paint()..color = scheme.surfaceContainerLow);
    final grid = Paint()
      ..color = scheme.outlineVariant.withValues(alpha: .7)
      ..strokeWidth = .7;
    final axes = Paint()
      ..color = scheme.onSurfaceVariant
      ..strokeWidth = 1.2;
    final xStep = tickStep(view.width, area.width);
    final yStep = tickStep(view.height, area.height);
    final zero = g.toScreen(Offset.zero);
    final axisX = zero.dx.clamp(area.left, area.right);
    final axisY = zero.dy.clamp(area.top, area.bottom);
    void label(String text, Offset at, {Color? color, double fontSize = 10}) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: color ?? scheme.onSurfaceVariant, fontSize: fontSize, fontFamily: fontFamily),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      )..layout(maxWidth: math.max(1, size.width - 8));
      painter.paint(
        canvas,
        Offset(
          at.dx.clamp(2, math.max(2, size.width - painter.width - 2)),
          at.dy.clamp(2, math.max(2, size.height - painter.height - 2)),
        ),
      );
      painter.dispose();
    }

    // Index-based loops avoid accumulated floating-point error at tiny scales.
    for (
      var i = (view.left / xStep).ceil(), end = (view.right / xStep).floor();
      i <= end && i < (view.left / xStep).ceil() + 100;
      i++
    ) {
      final x = i * xStep;
      final px = g.toScreen(Offset(x, 0)).dx;
      canvas.drawLine(Offset(px, area.top), Offset(px, area.bottom), grid);
      if (i != 0) label(_number(x), Offset(px + 3, axisY + 5));
    }
    for (
      var i = (view.top / yStep).ceil(), end = (view.bottom / yStep).floor();
      i <= end && i < (view.top / yStep).ceil() + 100;
      i++
    ) {
      final y = i * yStep;
      final py = g.toScreen(Offset(0, y)).dy;
      canvas.drawLine(Offset(area.left, py), Offset(area.right, py), grid);
      if (i != 0) label(_number(y), Offset(axisX + 5, py + 2));
    }
    canvas.drawRect(
      area,
      Paint()
        ..color = scheme.outlineVariant
        ..style = PaintingStyle.stroke
        ..strokeWidth = .8,
    );
    if (zero.dx >= area.left && zero.dx <= area.right) {
      canvas.drawLine(Offset(zero.dx, area.top), Offset(zero.dx, area.bottom), axes);
      canvas.drawLine(Offset(zero.dx, area.top), Offset(zero.dx - 4, area.top + 7), axes);
      canvas.drawLine(Offset(zero.dx, area.top), Offset(zero.dx + 4, area.top + 7), axes);
    }
    if (zero.dy >= area.top && zero.dy <= area.bottom) {
      canvas.drawLine(Offset(area.left, zero.dy), Offset(area.right, zero.dy), axes);
      canvas.drawLine(Offset(area.right, zero.dy), Offset(area.right - 7, zero.dy - 4), axes);
      canvas.drawLine(Offset(area.right, zero.dy), Offset(area.right - 7, zero.dy + 4), axes);
    }
    label('x', Offset(area.right - 10, axisY - 20), fontSize: 13);
    label('y', Offset(axisX - 15, area.top), fontSize: 13);
    if (area.contains(zero)) label('0', zero + const Offset(4, 4));

    canvas.save();
    canvas.clipRect(area);
    final colors = _colors(scheme);
    final samples = (area.width * 1.5).ceil().clamp(200, 1800);
    final dx = view.width / samples;
    for (var j = 0; j < expressions.length; j++) {
      final expression = expressions[j];
      final path = Path();
      Offset? previous;
      var previousX = view.left;
      for (var i = 0; i <= samples; i++) {
        final x = view.left + i * dx;
        final y = expression.evaluate(x);
        if (!y.isFinite) {
          previous = null;
          continue;
        }
        final point = g.toScreen(Offset(x, y));
        if (!point.dy.isFinite || (point.dy - area.center.dy).abs() > area.height * 8) {
          previous = null;
          continue;
        }
        var connect = previous != null;
        if (previous != null) {
          final mid = expression.evaluate((previousX + x) / 2);
          final middleY = g.toScreen(Offset(x, mid)).dy;
          // A discontinuity or a sharp jump must not become a false vertical line.
          connect =
              mid.isFinite &&
              (point.dy - previous.dy).abs() < area.height * .5 &&
              (middleY - (point.dy + previous.dy) / 2).abs() < 8;
        }
        if (connect) {
          path.lineTo(point.dx, point.dy);
        } else {
          path.moveTo(point.dx, point.dy);
        }
        previous = point;
        previousX = x;
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = colors[j]
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
    canvas.restore();
    // Labels near a boundary may use the surrounding margin; only curves need
    // clipping to the mathematical viewport.
    for (final point in plot.points) {
      final screen = g.toScreen(Offset(point.x, point.y));
      if (!area.inflate(1).contains(screen)) continue;
      canvas.drawCircle(screen, 5, Paint()..color = scheme.surfaceContainerLow);
      canvas.drawCircle(screen, 3.6, Paint()..color = scheme.primary);
      label(
        '${point.label.isEmpty ? '' : '${point.label} '}(${_number(point.x)}, ${_number(point.y)})',
        screen + const Offset(7, -18),
        color: scheme.onSurface,
        fontSize: 11,
      );
    }
  }

  @override
  bool shouldRepaint(CartesianPlotPainter oldDelegate) =>
      oldDelegate.plot != plot ||
      oldDelegate.view != view ||
      oldDelegate.scheme != scheme ||
      oldDelegate.fontFamily != fontFamily;
}

/// Rasterizes directly, independent of widget mounting or frame timing.
Future<Uint8List> renderCartesianPlotPng(
  CartesianPlot plot, {
  Size size = const Size(1200, 1200),
  ColorScheme? scheme,
  String? fontFamily,
}) async {
  if (!size.width.isFinite ||
      !size.height.isFinite ||
      size.width < 200 ||
      size.height < 200 ||
      size.width > 4096 ||
      size.height > 4096) {
    throw ArgumentError.value(size, 'size', 'Use dimensions between 200 and 4096 pixels.');
  }
  final colors = scheme ?? MewTheme.light(0).colorScheme;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Offset.zero & size, Paint()..color = colors.surfaceContainerLow);
  void text(String value, Offset at, Color color, double fontSize) {
    final painter = TextPainter(
      text: TextSpan(
        text: value,
        style: TextStyle(color: color, fontSize: fontSize, fontFamily: fontFamily),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: size.width - 48);
    painter.paint(canvas, at);
    painter.dispose();
  }

  final titleHeight = size.height >= 500 ? 58.0 : 38.0;
  final legendHeight = plot.functions.isEmpty ? 12.0 : math.min(size.height * .3, plot.functions.length * 24.0 + 12);
  text(_title(plot), const Offset(24, 12), colors.onSurface, size.height >= 500 ? 24 : 16);
  canvas.save();
  canvas.translate(0, titleHeight);
  CartesianPlotPainter(
    plot: plot,
    scheme: colors,
    fontFamily: fontFamily,
  ).paint(canvas, Size(size.width, size.height - titleHeight - legendHeight));
  canvas.restore();
  final palette = _colors(colors);
  for (var i = 0; i < plot.functions.length; i++) {
    final y = size.height - legendHeight + 4 + i * (legendHeight - 8) / plot.functions.length;
    text(
      '●  ${plot.functions[i]}',
      Offset(24, y),
      palette[i],
      math.min(17, (legendHeight - 8) / plot.functions.length - 2),
    );
  }
  final picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(size.width.round(), size.height.round());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('PNG encoding failed');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image?.dispose();
    picture.dispose();
  }
}
