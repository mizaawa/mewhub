import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../tools/plot_segment_style.dart';

Color resolvePlotLineColor(PlotLineColor color, Color fallback) {
  final darkTheme = fallback.computeLuminance() > .5;
  return switch (color) {
    PlotLineColor.theme => fallback,
    PlotLineColor.red => Color(darkTheme ? 0xFFFF6B6B : 0xFFE53935),
    PlotLineColor.orange => Color(darkTheme ? 0xFFFFB74D : 0xFFEF6C00),
    PlotLineColor.green => Color(darkTheme ? 0xFF81C784 : 0xFF2E7D32),
    PlotLineColor.teal => Color(darkTheme ? 0xFF4DB6AC : 0xFF00897B),
    PlotLineColor.blue => Color(darkTheme ? 0xFF64B5F6 : 0xFF1565C0),
    PlotLineColor.purple => Color(darkTheme ? 0xFFCE93D8 : 0xFF7B1FA2),
    PlotLineColor.pink => Color(darkTheme ? 0xFFF48FB1 : 0xFFC2185B),
    PlotLineColor.gray => Color(darkTheme ? 0xFFBDBDBD : 0xFF757575),
    // A white/ink counterpart keeps the explicit black token visible on a
    // dark canvas while still reading as the darkest available line on light.
    PlotLineColor.black => darkTheme ? fallback : const Color(0xFF212121),
  };
}

/// Draws a styled segment while preserving pattern phase when it is clipped.
void drawPlotSegment(Canvas canvas, Offset a, Offset b, Paint paint, PlotLineStyle style, Rect bounds) {
  if (!a.isFinite || !b.isFinite) return;
  final length = (b - a).distance;
  if (!length.isFinite || length < 1e-6) return;
  final direction = (b - a) / length;
  final clipped = _clip(a, b, bounds);
  if (clipped == null) return;
  final (t0, t1) = clipped;
  if (style == PlotLineStyle.solid) {
    canvas.drawLine(a + direction * (length * t0), a + direction * (length * t1), paint);
    return;
  }

  final pattern = switch (style) {
    PlotLineStyle.solid => const <double>[],
    PlotLineStyle.dashed => const [7.0, 4.0],
    PlotLineStyle.dotted => const [0.1, 5.0],
    PlotLineStyle.dashDot => const [7.0, 3.0, 0.1, 3.0],
  };
  final period = pattern.fold<double>(0, (sum, value) => sum + value);
  final visibleStart = length * t0;
  final visibleEnd = length * t1;
  var offset = (visibleStart / period).floorToDouble() * period;
  while (offset < visibleEnd) {
    var cursor = offset;
    for (var i = 0; i < pattern.length; i++) {
      final run = pattern[i];
      final runEnd = cursor + run;
      if (i.isEven && runEnd >= visibleStart && cursor <= visibleEnd) {
        final start = math.max(cursor, visibleStart);
        final end = math.min(runEnd, visibleEnd);
        final from = a + direction * start;
        final to = a + direction * end;
        if (style == PlotLineStyle.dotted || (style == PlotLineStyle.dashDot && i == 2)) {
          if (bounds.inflate(paint.strokeWidth).contains(from)) {
            canvas.drawCircle(from, paint.strokeWidth / 2, paint..style = PaintingStyle.fill);
          }
        } else if (end > start) {
          canvas.drawLine(from, to, paint..style = PaintingStyle.stroke);
        }
      }
      cursor = runEnd;
    }
    offset += period;
  }
}

(double, double)? _clip(Offset a, Offset b, Rect bounds) {
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
