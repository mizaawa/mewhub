import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/tools/cartesian_plot.dart';
import 'package:mewhub/tools/spatial_plot.dart';
import 'package:mewhub/ui/widgets/cartesian_plot_view.dart';
import 'package:mewhub/ui/widgets/spatial_plot_view.dart';

const _size = Size(240, 240);
const _style = CartesianPlotStyle(
  paper: Colors.white,
  grid: Colors.grey,
  majorGrid: Colors.grey,
  axis: Colors.black,
  ink: Colors.black,
  mutedInk: Colors.black,
  series: [Color(0xffff0000), Color(0xff0000ff)],
);

Future<ByteData> _pixels(CustomPainter painter) async {
  final recorder = ui.PictureRecorder();
  painter.paint(Canvas(recorder), _size);
  final picture = recorder.endRecording();
  final image = await picture.toImage(_size.width.toInt(), _size.height.toInt());
  try {
    return (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  } finally {
    image.dispose();
    picture.dispose();
  }
}

int _redMinusBlue(ByteData pixels, int x, int y) {
  final i = (y * _size.width.toInt() + x) * 4;
  return pixels.getUint8(i) - pixels.getUint8(i + 2);
}

void main() {
  testWidgets('steep continuous lines cross the viewport; poles do not create vertical strokes', (tester) async {
    await tester.runAsync(() async {
      Future<bool> hasStroke(String function) async {
        final data = await _pixels(
          CartesianPlotPainter(
            plot: CartesianPlot(functions: [function]),
            style: _style,
          ),
        );
        // x=3 projects to about 152px. This strip is away from axes and labels.
        return [
              for (var y = 60; y < 80; y++)
                for (var x = 150; x < 154; x++) _redMinusBlue(data, x, y),
            ].where((v) => v > 140).length >
            8;
      }

      expect(await hasStroke('1000(x-3)'), isTrue);
      expect(await hasStroke('100/(x-3)'), isFalse);
    });
  });

  testWidgets('overlapping surfaces composite back to front on either side of the XY plane', (tester) async {
    final plot = SpatialPlot(xMin: -1, xMax: 1, yMin: -1, yMax: 1, zMin: -1, zMax: 1, surfaces: ['0.5', '-0.5']);
    await tester.runAsync(() async {
      for (final sign in [1, -1]) {
        final data = await _pixels(
          SpatialPlotPainter(plot: plot, style: _style, size: _size, yaw: 0, pitch: sign * math.pi / 2),
        );
        // Red is nearer when viewed from +z; blue is nearer from -z.
        expect(sign * _redMinusBlue(data, 74, 67), greaterThan(15));
      }
    });
  });
}
