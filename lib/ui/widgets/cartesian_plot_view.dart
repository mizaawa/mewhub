import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../../ai/message.dart';
import '../../core/attachments.dart';
import '../../core/i18n.dart';
import '../../tools/cartesian_plot.dart';
import '../../tools/plot_expression.dart';
import '../theme.dart';

String _title(CartesianPlot plot) => plot.title.isEmpty ? t('平面直角坐标系', 'Cartesian plane') : prettyPlotTitle(plot.title);

/// Titles are plain text, yet models sometimes write `x^2` or `$y=x^2$` in them.
String prettyPlotTitle(String title) => title
    .replaceAll(r'$', '')
    .replaceAllMapped(RegExp(r'\^\{?(-?\d+)\}?'), (m) => plotSuperscript(m[1]!))
    .replaceAll(RegExp(r'\\cdot\s*'), '·')
    .replaceAll(RegExp(r'\\times\s*'), '×')
    .replaceAll(RegExp(r'\\pi\b|\bpi\b'), 'π')
    .replaceAll(RegExp(r'\\?sqrt\b'), '√');

/// Tick values: plain decimals with as many places as the [step] needs, so
/// neighbouring ticks never print alike, and a real minus sign.
String _tick(double value, double step) {
  final places = math.min(12, math.max(0, -(math.log(step) / math.ln10).floor()));
  var text = value.toStringAsFixed(places);
  if (text.contains('.')) text = text.replaceFirst(RegExp(r'\.?0+$'), '');
  return text == '-0' ? '0' : text.replaceAll('-', '−');
}

Rect _bounds(CartesianPlot p) => Rect.fromLTRB(p.xMin, p.yMin, p.xMax, p.yMax);

String _describe(CartesianPlot plot) => [
  _title(plot),
  ...plot.curves.map((c) => c.equationText),
  ...plot.points.map((p) => p.caption),
  ...plot.segments.map((s) => '${plotPointName(s.from)}${plotPointName(s.to)}'),
].join('; ');

/// Colours and type of one plot, read from the surrounding theme: graph paper
/// tinted with the accent, recessive grid and axes, ink-coloured labels and
/// the theme's validated curve palette.
@immutable
class CartesianPlotStyle {
  const CartesianPlotStyle({
    required this.paper,
    required this.grid,
    required this.majorGrid,
    required this.axis,
    required this.ink,
    required this.mutedInk,
    required this.series,
    this.textStyle = const TextStyle(),
  });

  factory CartesianPlotStyle.of(ThemeData theme) {
    final scheme = theme.colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return CartesianPlotStyle(
      paper: Color.alphaBlend(scheme.primary.withValues(alpha: dark ? .05 : .035), scheme.surfaceContainerLow),
      grid: scheme.primary.withValues(alpha: dark ? .10 : .08),
      majorGrid: scheme.primary.withValues(alpha: dark ? .22 : .18),
      axis: scheme.onSurfaceVariant,
      ink: scheme.onSurface,
      mutedInk: scheme.onSurfaceVariant,
      series: MewThemeColors.resolve(theme).plotSeries,
      textStyle: theme.textTheme.bodyMedium ?? const TextStyle(),
    );
  }

  final Color paper;
  final Color grid;
  final Color majorGrid;
  final Color axis;
  final Color ink;
  final Color mutedInk;
  final List<Color> series;

  /// The app's text style, for words such as 顶点 that are not math.
  final TextStyle textStyle;

  /// Functions are limited to as many curves as there are colours.
  Color seriesAt(int index) => series[index % series.length];

  @override
  bool operator ==(Object other) =>
      other is CartesianPlotStyle &&
      other.paper == paper &&
      other.grid == grid &&
      other.majorGrid == majorGrid &&
      other.axis == axis &&
      other.ink == ink &&
      other.mutedInk == mutedInk &&
      listEquals(other.series, series) &&
      other.textStyle == textStyle;

  @override
  int get hashCode => Object.hash(paper, grid, majorGrid, axis, ink, mutedInk, Object.hashAll(series), textStyle);
}

/// An immediately visible, theme-aware graph in a chat message.
class CartesianPlotCard extends StatelessWidget {
  const CartesianPlotCard({super.key, required this.plot, this.showHeader = true});
  final CartesianPlot plot;

  /// False inside a tool card, whose own header already names the graph.
  final bool showHeader;

  /// Height for each unit of width: the card takes the shape of the window
  /// within sensible limits, so a typical graph fills it edge to edge.
  static double aspectOf(CartesianPlot plot) =>
      ((plot.xMax - plot.xMin) / (plot.yMax - plot.yMin)).clamp(.75, 2.0).toDouble();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = CartesianPlotStyle.of(theme);
    void open() =>
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CartesianPlotPage(initialPlot: plot)));
    final expand = IconButton(
      key: const ValueKey('cartesian-expand'),
      tooltip: t('放大全屏', 'Open full screen'),
      visualDensity: VisualDensity.compact,
      icon: const Icon(Icons.open_in_full_rounded, size: 20),
      onPressed: open,
    );
    return Container(
      decoration: BoxDecoration(color: style.paper, borderRadius: BorderRadius.circular(18)),
      // Over the graph: an opaque canvas would hide a border painted below it.
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
                    expand,
                  ],
                ),
              ),
            Stack(
              children: [
                Semantics(
                  label: _describe(plot),
                  image: true,
                  child: GestureDetector(
                    onTap: open,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth;
                        final height = math.min(width / aspectOf(plot), 480.0);
                        // Streaming text beside the graph repaints every frame; the
                        // boundary keeps that from redrawing the graph too.
                        return RepaintBoundary(
                          child: CustomPaint(
                            key: const ValueKey('cartesian-preview'),
                            size: Size(width, height),
                            painter: CartesianPlotPainter(plot: plot, style: style),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                if (!showHeader && plot.curves.isEmpty)
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: style.paper.withValues(alpha: .85), shape: BoxShape.circle),
                      child: expand,
                    ),
                  ),
              ],
            ),
            if (plot.curves.isNotEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(14, 8, showHeader ? 14 : 4, showHeader ? 12 : 4),
                child: Row(
                  children: [
                    Expanded(
                      child: _Legend(plot: plot, style: style),
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

/// Each curve's colour beside its typeset formula; the formula itself stays
/// in ink so it reads on any accent.
class _Legend extends StatelessWidget {
  const _Legend({required this.plot, required this.style});
  final CartesianPlot plot;
  final CartesianPlotStyle style;

  @override
  Widget build(BuildContext context) {
    final textStyle = (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).copyWith(
      color: style.ink,
      fontSize: 15,
    );
    return Wrap(
      spacing: 18,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < plot.curves.length; i++)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CustomPaint(
                key: ValueKey('cartesian-legend-swatch-$i'),
                size: const Size(18, 12),
                painter: _SwatchPainter(style.seriesAt(i), dashed: plot.curves[i].dashed),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Math.tex(
                    plot.curves[i].equationTex,
                    key: ValueKey('cartesian-legend-$i'),
                    mathStyle: MathStyle.text,
                    textStyle: textStyle,
                    onErrorFallback: (_) => Text(plot.curves[i].equationText, style: textStyle),
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _SwatchPainter extends CustomPainter {
  _SwatchPainter(this.color, {this.dashed = false});
  final Color color;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    if (!dashed) {
      canvas.drawLine(Offset(1, y), Offset(size.width - 1, y), paint);
      return;
    }
    for (var x = 1.0; x < size.width - 1; x += 7) {
      canvas.drawLine(Offset(x, y), Offset(math.min(x + 3.5, size.width - 1), y), paint);
    }
  }

  @override
  bool shouldRepaint(_SwatchPainter oldDelegate) => oldDelegate.color != color || oldDelegate.dashed != dashed;
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
  Size _canvas = Size.zero;
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
      // Export what is on screen, including the plane the frame shows around
      // the requested window.
      var shown = _canvas.isEmpty ? _view : PlotGeometry(_view, _canvas).visible;
      // The PNG is 0.75–2 times as wide as tall; a landscape view would not
      // fit and be stretched, so widen the other side around the same window.
      final aspect = shown.width / shown.height;
      if (aspect > 2) {
        shown = Rect.fromCenter(center: shown.center, width: shown.width, height: shown.width / 2);
      } else if (aspect < .75) {
        shown = Rect.fromCenter(center: shown.center, width: shown.height * .75, height: shown.height);
      }
      double clamp(double v) => v.clamp(-CartesianPlot.maxCoordinate, CartesianPlot.maxCoordinate);
      final plot = _plot.copyWith(
        xMin: clamp(shown.left),
        xMax: clamp(shown.right),
        yMin: clamp(shown.top),
        yMax: clamp(shown.bottom),
      );
      final bytes = await renderCartesianPlotPng(plot, style: CartesianPlotStyle.of(Theme.of(context)));
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
    final style = CartesianPlotStyle.of(theme);
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
                  child: Container(
                    decoration: BoxDecoration(color: style.paper, borderRadius: BorderRadius.circular(22)),
                    foregroundDecoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: theme.colorScheme.outlineVariant),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(22),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final size = constraints.biggest;
                          _canvas = size;
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
                            child: Semantics(
                              label: _describe(_plot),
                              image: true,
                              child: RepaintBoundary(
                                child: CustomPaint(
                                  size: size,
                                  painter: CartesianPlotPainter(plot: _plot, style: style, view: _view),
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
              if (_plot.curves.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 96),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
                    child: _Legend(plot: _plot, style: style),
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
    text: widget.plot.points.map((p) => '${p.x}, ${p.y}${p.name.isEmpty ? '' : ', ${p.name}'}').join('\n'),
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
        final x = double.parse(parts[0]);
        final y = double.parse(parts[1]);
        final label = parts.length == 3 ? parts[2] : '';
        // A point the user left as it was keeps its hidden coordinates.
        final kept = widget.plot.points.where((p) => p.x == x && p.y == y && p.name == plotPointName(label));
        points.add(PlotPoint(x: x, y: y, label: label, showCoordinates: kept.isEmpty || kept.first.showCoordinates));
      }
      // Segments stay while both of their points do.
      final names = {for (final point in points) point.name};
      final plot = CartesianPlot(
        title: _title.text,
        functions: _functions.text.split('\n').map((f) => f.trim()).where((f) => f.isNotEmpty).toList(),
        points: points,
        segments: [
          for (final segment in widget.plot.segments)
            if (names.contains(plotPointName(segment.from)) && names.contains(plotPointName(segment.to))) segment,
        ],
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
              hintText: 'x^2\nf(x) = sin(x)\nx = 2',
              helperText: t(
                '支持 2x、π、sqrt(x)、sin(x)（弧度）；f(x)= 命名，x=2 画竖线',
                'Supports 2x, pi, sqrt(x), sin(x) (radians); f(x)= names, x=2 is vertical',
              ),
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

/// Places a requested coordinate window on a canvas so the graph fills it.
///
/// The window is fitted inside a small padding and the rest of the canvas
/// shows more of the plane rather than an empty margin. A window with similar
/// x and y spans keeps one unit length on both axes whatever the canvas
/// shape, so circles stay round and perpendicular lines square: the model was
/// told to choose such spans when shape matters. A lopsided window (a sine
/// wave, an exponential) is stretched to the canvas once their proportions
/// differ by more than [maxExpansion], so it never shrinks into a strip.
class PlotGeometry {
  PlotGeometry(this.window, Size size, {double padding = 14, this.maxExpansion = 1.3}) {
    final inset = math.min(padding, size.shortestSide / 4);
    final content = Rect.fromLTRB(
      inset,
      inset,
      math.max(inset + 1, size.width - inset),
      math.max(inset + 1, size.height - inset),
    );
    final sx = content.width / window.width;
    final sy = content.height / window.height;
    final aspect = window.width / window.height;
    equalUnits = (aspect >= 2 / 3 && aspect <= 3 / 2) || math.max(sx, sy) / math.min(sx, sy) <= maxExpansion;
    xScale = equalUnits ? math.min(sx, sy) : sx;
    yScale = equalUnits ? math.min(sx, sy) : sy;
    _center = content.center;
    final bottomLeft = toWorld(Offset(0, size.height));
    final topRight = toWorld(Offset(size.width, 0));
    visible = Rect.fromLTRB(bottomLeft.dx, bottomLeft.dy, topRight.dx, topRight.dy);
  }

  /// Requested range: left/right are x, top/bottom are the smaller/larger y.
  final Rect window;
  final double maxExpansion;
  late final bool equalUnits;
  late final double xScale;
  late final double yScale;
  late final Offset _center;

  /// The whole range the canvas shows, in the same orientation as [window].
  late final Rect visible;

  Offset toScreen(Offset value) =>
      Offset(_center.dx + (value.dx - window.center.dx) * xScale, _center.dy - (value.dy - window.center.dy) * yScale);
  Offset toWorld(Offset value) =>
      Offset(window.center.dx + (value.dx - _center.dx) / xScale, window.center.dy - (value.dy - _center.dy) / yScale);
}

// Bundled by flutter_math_fork. Named in full: TextStyle.package would also
// prefix the fallback fonts and lose glyphs such as subscript digits.
const _katex = 'packages/flutter_math_fork/';
const _uprightWords = {'sin', 'cos', 'tan', 'arcsin', 'arccos', 'arctan', 'ln', 'log', 'lg', 'mod'};
// Variables (italic), then digits, operators and symbols (upright), then
// anything else, such as Chinese names, in the app font.
const _mathSymbols = r'\x00-\x40\x5B-\x60\x7B-\x7F−×·√∛±≤≥′⌊⌋⌈⌉';
final _mathRuns = RegExp('([A-Za-zπ]+)|([$_mathSymbols]+)|([^A-Za-zπ$_mathSymbols]+)');

/// Math set the way the chat's formulas are: variables in KaTeX italic,
/// digits, operators and function names upright, other words (顶点) in the
/// app's font.
TextSpan _mathSpan(String text, CartesianPlotStyle style, {required double size, Color? color, Paint? halo}) {
  final fallback = [?style.textStyle.fontFamily, ...?style.textStyle.fontFamilyFallback];
  TextStyle font(String family, {bool italic = false}) => TextStyle(
    fontFamily: '$_katex$family',
    fontFamilyFallback: fallback,
    fontStyle: italic ? FontStyle.italic : FontStyle.normal,
    fontSize: size,
    height: 1.15,
    color: halo == null ? color ?? style.ink : null,
    foreground: halo,
  );
  final upright = font('KaTeX_Main');
  final italic = font('KaTeX_Math', italic: true);
  final words = (halo == null ? style.textStyle.copyWith(color: color ?? style.ink) : style.textStyle).copyWith(
    fontSize: size * .92,
    height: 1.15,
    foreground: halo,
  );
  return TextSpan(
    children: [
      for (final run in _mathRuns.allMatches(text))
        TextSpan(
          text: run[0],
          style: run[1] != null
              ? (_uprightWords.contains(run[1]) ? upright : italic)
              : run[2] != null
              ? upright
              : words,
        ),
    ],
  );
}

const _subscriptDigits = '₀₁₂₃₄₅₆₇₈₉';
const _superscripts = {
  '⁰': '0',
  '¹': '1',
  '²': '2',
  '³': '3',
  '⁴': '4',
  '⁵': '5',
  '⁶': '6',
  '⁷': '7',
  '⁸': '8',
  '⁹': '9',
  '⁻': '−',
  'ˣ': 'x',
  '′': '′',
};
final _scriptRuns = RegExp(
  '([$_subscriptDigits]+)|([${_superscripts.keys.join()}]+)|([^$_subscriptDigits${_superscripts.keys.join()}]+)',
);

/// One line of plot text with real sub- and superscripts. The plain-text
/// forms (y₁, x², eˣ) are set as smaller math characters off the baseline, so
/// they match the legend's formulas on every device, whatever its fonts cover.
class _MathLine {
  _MathLine(String text, CartesianPlotStyle style, {required double size, Color? color, Paint? halo}) {
    for (final run in _scriptRuns.allMatches(text)) {
      final sub = run[1] != null;
      final sup = run[2] != null;
      final content = sub
          ? run[0]!.split('').map((c) => '${_subscriptDigits.indexOf(c)}').join()
          : sup
          ? run[0]!.split('').map((c) => _superscripts[c]).join()
          : run[0]!;
      final painter = TextPainter(
        text: _mathSpan(content, style, size: sub || sup ? size * .7 : size, color: color, halo: halo),
        textDirection: TextDirection.ltr,
      )..layout();
      _parts.add((painter, sub ? size * .22 : (sup ? -size * .36 : 0.0)));
    }
    final baselines = [
      for (final (painter, _) in _parts) painter.computeDistanceToActualBaseline(TextBaseline.alphabetic),
    ];
    final baseline = baselines.fold(0.0, math.max);
    var top = 0.0;
    var bottom = 0.0;
    var x = 0.0;
    for (var i = 0; i < _parts.length; i++) {
      final (painter, shift) = _parts[i];
      final y = baseline - baselines[i] + shift;
      top = math.min(top, y);
      bottom = math.max(bottom, y + painter.height);
      _offsets.add(Offset(x, y));
      x += painter.width;
    }
    this.size = Size(x, bottom - top);
    _top = top;
  }

  final _parts = <(TextPainter, double)>[];
  final _offsets = <Offset>[];
  late final double _top;
  late final Size size;

  void paint(Canvas canvas, Offset topLeft) {
    for (var i = 0; i < _parts.length; i++) {
      _parts[i].$1.paint(canvas, topLeft + _offsets[i] - Offset(0, _top));
    }
  }

  void dispose() {
    for (final (painter, _) in _parts) {
      painter.dispose();
    }
  }
}

/// Text on the graph, placed where it hides no other label and drawn over a
/// halo of paper so grid lines and curves never cut through it.
class _LabelLayer {
  _LabelLayer(this.canvas, Size size, this.style) : bounds = (Offset.zero & size).deflate(2);
  final Canvas canvas;
  final Rect bounds;
  final CartesianPlotStyle style;
  final _taken = <Rect>[];

  void reserve(Rect rect) => _taken.add(rect);

  /// Paints [text] at the first candidate inside the canvas and clear of
  /// earlier labels and [avoid]. With [force] it falls back to the first
  /// candidate rather than dropping the label.
  bool place(
    String text,
    List<Offset Function(Size size)> candidates, {
    required double size,
    Color? color,
    bool force = false,
    List<Rect> avoid = const [],
  }) {
    final fill = _MathLine(text, style, size: size, color: color);
    Rect? chosen;
    for (final candidate in candidates) {
      final rect = candidate(fill.size) & fill.size;
      final inside =
          rect.left >= bounds.left &&
          rect.top >= bounds.top &&
          rect.right <= bounds.right &&
          rect.bottom <= bounds.bottom;
      final grown = rect.inflate(1.5);
      if (inside && !_taken.any(grown.overlaps) && !avoid.any(grown.overlaps)) {
        chosen = rect;
        break;
      }
    }
    if (chosen == null && force && candidates.isNotEmpty) {
      final first = candidates.first(fill.size);
      chosen =
          Offset(
            first.dx.clamp(bounds.left, math.max(bounds.left, bounds.right - fill.size.width)),
            first.dy.clamp(bounds.top, math.max(bounds.top, bounds.bottom - fill.size.height)),
          ) &
          fill.size;
    }
    if (chosen == null) {
      fill.dispose();
      return false;
    }
    final halo = _MathLine(
      text,
      style,
      size: size,
      halo: Paint()
        ..color = style.paper
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeJoin = StrokeJoin.round,
    );
    halo.paint(canvas, chosen.topLeft);
    fill.paint(canvas, chosen.topLeft);
    halo.dispose();
    fill.dispose();
    _taken.add(chosen);
    return true;
  }
}

/// Custom painter shared by the preview, the full-screen view and the PNG.
class CartesianPlotPainter extends CustomPainter {
  CartesianPlotPainter({required this.plot, required this.style, Rect? view}) : view = view ?? _bounds(plot);
  final CartesianPlot plot;
  final CartesianPlotStyle style;
  final Rect view;

  /// A 1-2-5 step that puts labelled lines roughly 52 px apart, rounded to
  /// the nearest nice value so a short range such as ±2 still gets labels.
  static double tickStep(double span, double pixels) {
    final desired = span / math.max(2, pixels / 52);
    final power = math.pow(10, (math.log(desired) / math.ln10).floor()).toDouble();
    final relative = desired / power;
    return (relative < 1.5
            ? 1
            : relative < 3.5
            ? 2
            : relative < 7.5
            ? 5
            : 10) *
        power;
  }

  /// A step of π/12 … 16π near the 52 px spacing, for graphs of sin, cos and
  /// tan, whose key points sit at multiples of π; null when no such step fits.
  static double? piTickStep(double span, double pixels) {
    final desired = span / math.max(2, pixels / 52);
    const fractions = [1 / 12, 1 / 6, 1 / 4, 1 / 2, 1, 2, 4, 8, 16];
    final best = fractions
        .map((f) => f * math.pi)
        .reduce((a, b) => (math.log(a / desired)).abs() <= (math.log(b / desired)).abs() ? a : b);
    final ratio = best / desired;
    return ratio > .5 && ratio < 2 ? best : null;
  }

  // Graph paper: five small squares per labelled step (two for steps of 2).
  static double _minorStep(double step) {
    final power = math.pow(10, (math.log(step) / math.ln10).floor()).toDouble();
    return (step / power).round() == 2 ? step / 2 : step / 5;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 80 || size.height < 70) return;
    final g = PlotGeometry(view, size);
    final shown = g.visible;
    final bounds = Offset.zero & size;
    canvas.save();
    canvas.clipRect(bounds);
    canvas.drawRect(bounds, Paint()..color = style.paper);

    final piStep = plot.curves.any((c) => c.expression.isPeriodic) ? piTickStep(shown.width, size.width) : null;
    final xStep = piStep ?? tickStep(shown.width, size.width);
    final yStep = tickStep(shown.height, size.height);
    // Minor squares first, then the labelled lines over them. Index-based
    // loops avoid accumulated floating-point error at tiny scales.
    for (final (xs, ys, paint) in [
      (
        piStep == null ? _minorStep(xStep) : xStep / 2,
        _minorStep(yStep),
        Paint()
          ..color = style.grid
          ..strokeWidth = .6,
      ),
      (
        xStep,
        yStep,
        Paint()
          ..color = style.majorGrid
          ..strokeWidth = .8,
      ),
    ]) {
      if (xs * g.xScale >= 7) {
        final start = (shown.left / xs).ceil();
        for (var i = start; i <= (shown.right / xs).floor() && i < start + 600; i++) {
          final x = g.toScreen(Offset(i * xs, 0)).dx;
          canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
        }
      }
      if (ys * g.yScale >= 7) {
        final start = (shown.top / ys).ceil();
        for (var i = start; i <= (shown.bottom / ys).floor() && i < start + 600; i++) {
          final y = g.toScreen(Offset(0, i * ys)).dy;
          canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
        }
      }
    }

    final origin = g.toScreen(Offset.zero);
    final xAxis = origin.dy >= 0 && origin.dy <= size.height;
    final yAxis = origin.dx >= 0 && origin.dx <= size.width;
    final axisPaint = Paint()
      ..color = style.axis
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (xAxis) {
      final end = Offset(size.width - 2, origin.dy);
      canvas.drawLine(Offset(0, origin.dy), end, axisPaint);
      canvas.drawPath(
        Path()
          ..moveTo(end.dx - 8, end.dy - 4.5)
          ..lineTo(end.dx, end.dy)
          ..lineTo(end.dx - 8, end.dy + 4.5),
        axisPaint..style = PaintingStyle.stroke,
      );
    }
    if (yAxis) {
      final end = Offset(origin.dx, 2);
      canvas.drawLine(Offset(origin.dx, size.height), end, axisPaint);
      canvas.drawPath(
        Path()
          ..moveTo(end.dx - 4.5, end.dy + 8)
          ..lineTo(end.dx, end.dy)
          ..lineTo(end.dx + 4.5, end.dy + 8),
        axisPaint..style = PaintingStyle.stroke,
      );
    }

    final runs = _drawCurves(canvas, g, size);
    _drawSegments(canvas, g, size);

    final labels = _LabelLayer(canvas, size, style);
    final dots = <(Offset, PlotPoint)>[];
    for (final point in plot.points) {
      final at = g.toScreen(Offset(point.x, point.y));
      if (!bounds.inflate(1).contains(at)) continue;
      canvas.drawCircle(at, 6.2, Paint()..color = style.paper);
      canvas.drawCircle(at, 4.2, Paint()..color = style.ink);
      labels.reserve(Rect.fromCircle(center: at, radius: 6));
      dots.add((at, point));
    }

    // Axis names and the origin, as in a textbook figure.
    if (xAxis) {
      labels.place(
        'x',
        [
          (s) => Offset(size.width - 8 - s.width, origin.dy + 5),
          (s) => Offset(size.width - 8 - s.width, origin.dy - 5 - s.height),
        ],
        size: 15,
        force: true,
      );
    }
    if (yAxis) {
      labels.place(
        'y',
        [(s) => Offset(origin.dx - 8 - s.width, 2), (s) => Offset(origin.dx + 8, 2)],
        size: 15,
        force: true,
      );
    }
    if (xAxis && yAxis) {
      labels.place('O', [
        (s) => Offset(origin.dx - 5 - s.width, origin.dy + 3),
        (s) => Offset(origin.dx + 5, origin.dy + 3),
        (s) => Offset(origin.dx - 5 - s.width, origin.dy - 3 - s.height),
      ], size: 13);
    }

    for (final (at, point) in dots) {
      final caption = point.caption;
      if (caption.isEmpty) continue;
      labels.place(
        caption,
        [
          // Clear of the dot: diagonals first, so a caption does not sit on
          // an axis or grid line running through the point.
          (s) => Offset(at.dx + 8, at.dy - 4 - s.height),
          (s) => Offset(at.dx - 8 - s.width, at.dy - 4 - s.height),
          (s) => Offset(at.dx + 8, at.dy + 4),
          (s) => Offset(at.dx - 8 - s.width, at.dy + 4),
          (s) => Offset(at.dx - s.width / 2, at.dy - 9 - s.height),
          (s) => Offset(at.dx - s.width / 2, at.dy + 9),
          (s) => Offset(at.dx + 10, at.dy - s.height / 2),
          (s) => Offset(at.dx - 10 - s.width, at.dy - s.height / 2),
        ],
        size: 12.5,
        force: true,
      );
    }

    _placeTags(labels, runs, g, size);

    // Tick values give way to everything above.
    final axisY = origin.dy.clamp(0.0, size.height);
    final axisX = origin.dx.clamp(0.0, size.width);
    final firstX = (shown.left / xStep).ceil();
    for (var i = firstX; i <= (shown.right / xStep).floor() && i < firstX + 100; i++) {
      if (i == 0 && yAxis) continue;
      final x = g.toScreen(Offset(i * xStep, 0)).dx;
      labels.place(
        piStep == null ? _tick(i * xStep, xStep) : formatPlotNumber(i * xStep),
        [(s) => Offset(x - s.width / 2, axisY + 4), (s) => Offset(x - s.width / 2, axisY - 4 - s.height)],
        size: 11.5,
        color: style.mutedInk,
      );
    }
    final firstY = (shown.top / yStep).ceil();
    for (var i = firstY; i <= (shown.bottom / yStep).floor() && i < firstY + 100; i++) {
      if (i == 0 && xAxis) continue;
      final y = g.toScreen(Offset(0, i * yStep)).dy;
      labels.place(
        _tick(i * yStep, yStep),
        [(s) => Offset(axisX - 5 - s.width, y - s.height / 2), (s) => Offset(axisX + 5, y - s.height / 2)],
        size: 11.5,
        color: style.mutedInk,
      );
    }
    canvas.restore();
  }

  /// Draws every curve and returns the on-screen runs of each, for labels.
  List<List<Offset>> _drawCurves(Canvas canvas, PlotGeometry g, Size size) {
    final runs = <List<Offset>>[];
    for (var j = 0; j < plot.curves.length; j++) {
      final curve = plot.curves[j];
      final expression = curve.expression;
      final paint = Paint()
        ..color = style.seriesAt(j)
        ..style = PaintingStyle.stroke
        ..strokeWidth = curve.dashed ? 1.8 : 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final visible = <Offset>[];
      runs.add(visible);
      final path = Path();
      if (expression.isVertical) {
        final x = g.toScreen(Offset(expression.verticalX!, 0)).dx;
        if (x < -2 || x > size.width + 2) continue;
        path
          ..moveTo(x, 0)
          ..lineTo(x, size.height);
        visible.addAll([Offset(x, 0), Offset(x, size.height)]);
      } else {
        // y = ±… is one curve in one colour: the upper and the lower branch.
        for (final lower in expression.plusMinus ? const [false, true] : const [false]) {
          _trace(path, visible, (x) => expression.evaluate(x, lower: lower), g, size);
        }
      }
      if (curve.dashed) {
        // Like an axis of symmetry or an asymptote in a textbook.
        for (final metric in path.computeMetrics()) {
          for (var d = 0.0; d < metric.length; d += 12) {
            canvas.drawPath(metric.extractPath(d, math.min(d + 7, metric.length)), paint);
          }
        }
      } else {
        canvas.drawPath(path, paint);
      }
    }
    return runs;
  }

  /// Samples [f] across the canvas into [path]. Where the function stops
  /// being defined (the ends of sqrt(9 − x²)), the exact edge is found by
  /// bisection, so the two halves of a circle meet instead of leaving a gap.
  void _trace(Path path, List<Offset> visible, double Function(double x) f, PlotGeometry g, Size size) {
    final shown = g.visible;
    final samples = (size.width * 1.5).ceil().clamp(200, 2400);
    final dx = shown.width / samples;
    Offset? screen(double x) {
      final y = f(x);
      if (!y.isFinite) return null;
      final point = g.toScreen(Offset(x, y));
      return point.dy.isFinite && (point.dy - size.height / 2).abs() <= size.height * 8 ? point : null;
    }

    double edge(double defined, double undefined) {
      for (var k = 0; k < 24; k++) {
        final middle = (defined + undefined) / 2;
        if (f(middle).isFinite) {
          defined = middle;
        } else {
          undefined = middle;
        }
      }
      return defined;
    }

    Offset? previous;
    var previousX = shown.left;
    double? undefinedX;
    for (var i = 0; i <= samples; i++) {
      final x = shown.left + i * dx;
      final y = f(x);
      if (!y.isFinite) {
        // Defined → undefined: finish exactly at the domain edge.
        if (previous != null && y.isNaN) {
          final end = screen(edge(previousX, x));
          if (end != null && (end.dy - previous.dy).abs() < size.height * .5) path.lineTo(end.dx, end.dy);
        }
        previous = null;
        undefinedX = y.isNaN ? x : null;
        continue;
      }
      final point = screen(x);
      if (point == null) {
        previous = null;
        undefinedX = null;
        continue;
      }
      // Undefined → defined: start exactly at the domain edge.
      if (previous == null && undefinedX != null) {
        final startX = edge(x, undefinedX);
        final start = screen(startX);
        if (start != null && (start.dy - point.dy).abs() < size.height * .5) {
          path.moveTo(start.dx, start.dy);
          previous = start;
          previousX = startX;
        }
      }
      undefinedX = null;
      var connect = previous != null;
      if (previous != null) {
        final mid = f((previousX + x) / 2);
        final middleY = g.toScreen(Offset(x, mid)).dy;
        // A discontinuity or a sharp jump must not become a false vertical line.
        connect =
            mid.isFinite &&
            (point.dy - previous.dy).abs() < size.height * .5 &&
            (middleY - (point.dy + previous.dy) / 2).abs() < 8;
      }
      if (connect) {
        path.lineTo(point.dx, point.dy);
      } else {
        path.moveTo(point.dx, point.dy);
      }
      if (point.dy >= 0 && point.dy <= size.height) visible.add(point);
      previous = point;
      previousX = x;
    }
  }

  /// Sides of figures between named points; dashed ones are auxiliary lines.
  void _drawSegments(Canvas canvas, PlotGeometry g, Size size) {
    for (final segment in plot.segments) {
      final from = plot.pointNamed(segment.from);
      final to = plot.pointNamed(segment.to);
      final a = g.toScreen(Offset(from.x, from.y));
      final b = g.toScreen(Offset(to.x, to.y));
      // Only the part on the canvas is drawn: zoomed in, a segment can be
      // millions of pixels long.
      final visible = clipSegment(a, b, (Offset.zero & size).inflate(8));
      if (visible == null) continue;
      final (t0, t1) = visible;
      final paint = Paint()
        ..color = style.ink.withValues(alpha: .78)
        ..strokeWidth = segment.dashed ? 1.5 : 1.8
        ..strokeCap = StrokeCap.round;
      if (!segment.dashed) {
        canvas.drawLine(Offset.lerp(a, b, t0)!, Offset.lerp(a, b, t1)!, paint);
        continue;
      }
      final length = (b - a).distance;
      if (length == 0) continue;
      final direction = (b - a) / length;
      // Dashes keep their phase from the first point while panning.
      for (var d = (t0 * length / 10).floor() * 10.0; d < t1 * length; d += 10) {
        canvas.drawLine(a + direction * d, a + direction * math.min(d + 6, length), paint);
      }
    }
  }

  /// The part of the segment [a]–[b] inside [bounds] as fractions of its
  /// length (Liang–Barsky); null when it misses [bounds].
  static (double, double)? clipSegment(Offset a, Offset b, Rect bounds) {
    var t0 = 0.0;
    var t1 = 1.0;
    final d = b - a;
    for (final (p, q) in [
      (-d.dx, a.dx - bounds.left),
      (d.dx, bounds.right - a.dx),
      (-d.dy, a.dy - bounds.top),
      (d.dy, bounds.bottom - a.dy),
    ]) {
      if (p == 0) {
        if (q < 0) return null;
        continue;
      }
      final t = q / p;
      if (p < 0) {
        if (t > t1) return null;
        t0 = math.max(t0, t);
      } else {
        if (t < t0) return null;
        t1 = math.min(t1, t);
      }
    }
    return (t0, t1);
  }

  /// Writes each named curve's tag (y₁, f(x), x = 2) beside the curve, near
  /// its right-hand end, so curves are identified without relying on colour.
  void _placeTags(_LabelLayer labels, List<List<Offset>> runs, PlotGeometry g, Size size) {
    final inner = (Offset.zero & size).deflate(12);
    // A tag lying on an axis reads like a tick value; keep it off both.
    final origin = g.toScreen(Offset.zero);
    final axes = [
      Rect.fromLTRB(0, origin.dy - 4, size.width, origin.dy + 4),
      Rect.fromLTRB(origin.dx - 4, 0, origin.dx + 4, size.height),
    ];
    for (var j = 0; j < plot.curves.length; j++) {
      final tag = plot.curves[j].tag;
      if (tag == null) continue;
      if (plot.curves[j].expression.isVertical) {
        // The line spans the full height, so only its x needs to be inside.
        if (runs[j].isEmpty || runs[j].first.dx < inner.left || runs[j].first.dx > inner.right) continue;
        final x = runs[j].first.dx;
        labels.place(
          tag,
          [
            (s) => Offset(x + 6, 8),
            (s) => Offset(x - 6 - s.width, 8),
            (s) => Offset(x + 6, size.height - 8 - s.height),
            (s) => Offset(x - 6 - s.width, size.height - 8 - s.height),
          ],
          size: 13.5,
          avoid: axes,
        );
        continue;
      }
      final points = runs[j].where(inner.contains).toList();
      if (points.isEmpty) continue;
      labels.place(
        tag,
        [
          for (final fraction in const [.94, .82, .7, .58, .46, .34, .22, .1]) ...[
            (s) => points[((points.length - 1) * fraction).round()] + Offset(-s.width - 5, -s.height - 5),
            (s) => points[((points.length - 1) * fraction).round()] + const Offset(5, 5),
            (s) => points[((points.length - 1) * fraction).round()] + Offset(5, -s.height - 5),
            (s) => points[((points.length - 1) * fraction).round()] + Offset(-s.width - 5, 5),
          ],
        ],
        size: 13.5,
        avoid: axes,
      );
    }
  }

  @override
  bool shouldRepaint(CartesianPlotPainter oldDelegate) =>
      oldDelegate.plot != plot || oldDelegate.view != view || oldDelegate.style != style;
}

/// Pixel size for exporting [plot]: 1200 wide and as tall as its window's
/// shape needs, plus room for the title and legend.
Size cartesianPngSize(CartesianPlot plot) {
  final logicalPlot = 600 / CartesianPlotCard.aspectOf(plot);
  final legend = plot.curves.isEmpty ? 12.0 : plot.curves.length * 26.0 + 16;
  return Size(1200, ((logicalPlot + 56 + legend) * 2).clamp(400, 4096).roundToDouble());
}

/// Rasterizes directly, independent of widget mounting or frame timing.
Future<Uint8List> renderCartesianPlotPng(CartesianPlot plot, {Size? size, CartesianPlotStyle? style}) async {
  final out = size ?? cartesianPngSize(plot);
  if (!out.width.isFinite ||
      !out.height.isFinite ||
      out.width < 200 ||
      out.height < 200 ||
      out.width > 4096 ||
      out.height > 4096) {
    throw ArgumentError.value(out, 'size', 'Use dimensions between 200 and 4096 pixels.');
  }
  final paint = style ?? CartesianPlotStyle.of(MewTheme.light(0));
  // Laid out at phone size and scaled, so text keeps its proportions.
  final scale = out.width / 600;
  final logical = out / scale;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder)..scale(scale);
  canvas.drawRect(Offset.zero & logical, Paint()..color = paint.paper);
  final title = TextPainter(
    text: TextSpan(
      text: _title(plot),
      style: paint.textStyle.copyWith(color: paint.ink, fontSize: 18, fontWeight: FontWeight.w600),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    ellipsis: '…',
  )..layout(maxWidth: logical.width - 40);
  title.paint(canvas, const Offset(20, 14));
  final titleHeight = title.height + 26;
  title.dispose();
  final legend = [for (final curve in plot.curves) _MathLine(curve.equationText, paint, size: 15)];
  // A tiny export keeps at least 120 px of graph and lists what fits.
  final rows = math.max(0, math.min(legend.length, ((logical.height - titleHeight - 120) / 26).floor()));
  final legendHeight = legend.isEmpty ? 12.0 : rows * 26.0 + 16;
  final area = Size(logical.width, logical.height - titleHeight - legendHeight);
  canvas.save();
  canvas.translate(0, titleHeight);
  CartesianPlotPainter(plot: plot, style: paint).paint(canvas, area);
  canvas.restore();
  for (var i = 0; i < rows; i++) {
    final middle = logical.height - legendHeight + 8 + i * 26 + 13;
    canvas.save();
    canvas.translate(22, middle - 6);
    _SwatchPainter(paint.seriesAt(i), dashed: plot.curves[i].dashed).paint(canvas, const Size(18, 12));
    canvas.restore();
    // A formula wider than the image is scaled down rather than cut off.
    final line = legend[i];
    final shrink = math.min(1.0, (logical.width - 70) / line.size.width);
    canvas.save();
    canvas.translate(48, middle - line.size.height * shrink / 2);
    canvas.scale(shrink);
    line.paint(canvas, Offset.zero);
    canvas.restore();
  }
  for (final line in legend) {
    line.dispose();
  }
  final picture = recorder.endRecording();
  ui.Image? image;
  try {
    image = await picture.toImage(out.width.round(), out.height.round());
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('PNG encoding failed');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image?.dispose();
    picture.dispose();
  }
}
