import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../ai/encoding.dart';
import '../../core/attachments.dart';
import '../../core/i18n.dart';
import '../../core/paths.dart';

/// Lets a freshly captured photo be adjusted before it enters the composer.
class ImageEditorPage extends StatefulWidget {
  const ImageEditorPage({super.key, required this.imageUrl});

  final String imageUrl;

  @override
  State<ImageEditorPage> createState() => _ImageEditorPageState();
}

class _ImageEditorPageState extends State<ImageEditorPage> {
  static const _colors = [Color(0xFFFF5252), Color(0xFFFFD740), Colors.white];

  ui.Image? _source;
  ui.Image? _oriented;
  bool _loading = true;
  bool _saving = false;
  bool _rotating = false;
  bool _cropMode = false;
  bool _paintMode = false;
  int _quarterTurns = 0;
  int _colorIndex = 0;
  Rect? _crop;
  Rect? _previousCrop;
  Offset? _cropStart;
  final List<_Stroke> _strokes = [];

  bool get _processing => _saving || _rotating;

  @override
  void initState() {
    super.initState();
    unawaited(_loadImage());
  }

  Future<void> _loadImage() async {
    ui.Image? decoded;
    try {
      final bytes = widget.imageUrl.startsWith('data:')
          ? MediaEncoder.decodeDataUri(widget.imageUrl)
          : await File(AppPaths.resolve(widget.imageUrl)).readAsBytes();
      if (bytes == null) throw StateError(t('无法读取图片', 'Unable to load image'));
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        decoded = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
      final source = decoded;
      final oriented = await _orientImage(source, _quarterTurns);
      if (!mounted) {
        oriented.dispose();
        return;
      }
      setState(() {
        _source = source;
        _oriented = oriented;
        _loading = false;
      });
      decoded = null; // Ownership transfers to this state until dispose().
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = '$error';
        });
      }
    } finally {
      decoded?.dispose();
    }
  }

  String? _loadError;

  Future<ui.Image> _orientImage(ui.Image image, int quarterTurns) async {
    final turns = quarterTurns % 4;
    final width = turns.isOdd ? image.height : image.width;
    final height = turns.isOdd ? image.width : image.height;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    switch (turns) {
      case 1:
        canvas.translate(width.toDouble(), 0);
        canvas.rotate(math.pi / 2);
        break;
      case 2:
        canvas.translate(width.toDouble(), height.toDouble());
        canvas.rotate(math.pi);
        break;
      case 3:
        canvas.translate(0, height.toDouble());
        canvas.rotate(3 * math.pi / 2);
        break;
    }
    canvas.drawImage(image, Offset.zero, Paint()..filterQuality = FilterQuality.high);
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(width, height);
    } finally {
      picture.dispose();
    }
  }

  Future<void> _rotate() async {
    final source = _source;
    if (source == null || _processing) return;
    setState(() => _rotating = true);
    final turns = (_quarterTurns + 1) % 4;
    try {
      final result = await _orientImage(source, turns);
      if (!mounted) {
        result.dispose();
        return;
      }
      _oriented?.dispose();
      setState(() {
        _oriented = result;
        _quarterTurns = turns;
        _crop = _rotateRect(_crop);
        for (final stroke in _strokes) {
          for (var i = 0; i < stroke.points.length; i++) {
            final point = stroke.points[i];
            stroke.points[i] = Offset(1 - point.dy, point.dx);
          }
        }
      });
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _rotating = false);
    }
  }

  Rect? _rotateRect(Rect? rect) {
    if (rect == null) return null;
    return Rect.fromLTRB(1 - rect.bottom, rect.left, 1 - rect.top, rect.right);
  }

  Offset _normalized(Offset point, Size size) =>
      Offset((point.dx / size.width).clamp(0.0, 1.0), (point.dy / size.height).clamp(0.0, 1.0));

  void _startGesture(Offset point, Size size) {
    if (_processing) return;
    final normalized = _normalized(point, size);
    setState(() {
      if (_cropMode) {
        _previousCrop = _crop;
        _cropStart = normalized;
        _crop = Rect.fromPoints(normalized, normalized);
      } else if (_paintMode) {
        _strokes.add(_Stroke(color: _colors[_colorIndex], points: [normalized], width: 0.012));
      }
    });
  }

  void _updateGesture(Offset point, Size size) {
    if (_processing) return;
    final normalized = _normalized(point, size);
    setState(() {
      if (_cropMode && _cropStart != null) {
        _crop = Rect.fromPoints(_cropStart!, normalized);
      } else if (_paintMode && _strokes.isNotEmpty) {
        _strokes.last.points.add(normalized);
      }
    });
  }

  void _endGesture() {
    setState(() {
      final crop = _crop;
      if (_cropMode && crop != null && (crop.width < 0.02 || crop.height < 0.02)) {
        _crop = _previousCrop;
      }
      _cropStart = null;
    });
  }

  Future<void> _confirm() async {
    final image = _oriented;
    if (image == null || _processing) return;
    setState(() => _saving = true);
    try {
      final crop = _crop ?? const Rect.fromLTRB(0, 0, 1, 1);
      final x0 = (crop.left * image.width).floor().clamp(0, image.width - 1).toInt();
      final y0 = (crop.top * image.height).floor().clamp(0, image.height - 1).toInt();
      final x1 = (crop.right * image.width).ceil().clamp(x0 + 1, image.width).toInt();
      final y1 = (crop.bottom * image.height).ceil().clamp(y0 + 1, image.height).toInt();
      final width = x1 - x0;
      final height = y1 - y0;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
      canvas.translate(-x0.toDouble(), -y0.toDouble());
      canvas.drawImage(image, Offset.zero, Paint()..filterQuality = FilterQuality.high);
      final strokeScale = math.min(image.width, image.height).toDouble();
      for (final stroke in _strokes) {
        if (stroke.points.isEmpty) continue;
        final path = Path();
        path.moveTo(stroke.points.first.dx * image.width, stroke.points.first.dy * image.height);
        for (final point in stroke.points.skip(1)) {
          path.lineTo(point.dx * image.width, point.dy * image.height);
        }
        final paint = Paint()
          ..color = stroke.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke.width * strokeScale
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        if (stroke.points.length == 1) {
          canvas.drawCircle(
            Offset(stroke.points.first.dx * image.width, stroke.points.first.dy * image.height),
            stroke.width * strokeScale / 2,
            Paint()..color = stroke.color,
          );
        } else {
          canvas.drawPath(path, paint);
        }
      }
      final picture = recorder.endRecording();
      final ui.Image output;
      try {
        output = await picture.toImage(width, height);
      } finally {
        picture.dispose();
      }
      final ByteData? data;
      try {
        data = await output.toByteData(format: ui.ImageByteFormat.png);
      } finally {
        output.dispose();
      }
      if (data == null) throw StateError(t('无法生成编辑后的图片', 'Unable to export edited image'));
      final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      final stored = await Attachments.storeBytes(bytes, 'png');
      if (mounted) {
        setState(() => _saving = false);
        Navigator.of(context).pop(stored);
      } else {
        await Attachments.deleteStored(stored);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  void dispose() {
    _source?.dispose();
    _oriented?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Theme.of(context).colorScheme.primary,
          brightness: Brightness.dark,
        ),
      ),
      child: Builder(builder: _buildEditor),
    );
  }

  Widget _buildEditor(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_processing,
      child: AbsorbPointer(
        absorbing: _processing,
        child: Scaffold(
          backgroundColor: const Color(0xFF101114),
          body: SafeArea(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _loadError != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.broken_image_outlined, size: 42),
                          const SizedBox(height: 12),
                          Text(_loadError!, textAlign: TextAlign.center),
                          const SizedBox(height: 16),
                          FilledButton(onPressed: () => Navigator.pop(context), child: Text(t('返回', 'Back'))),
                        ],
                      ),
                    ),
                  )
                : Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 12, 8),
                        child: Row(
                          children: [
                            IconButton(
                              onPressed: _processing ? null : () => Navigator.pop(context),
                              icon: const Icon(Icons.arrow_back_rounded),
                            ),
                            Text(t('编辑图片', 'Edit photo'), style: Theme.of(context).textTheme.titleMedium),
                            const Spacer(),
                            FilledButton.icon(
                              onPressed: _processing ? null : _confirm,
                              icon: _processing
                                  ? const SizedBox.square(
                                      dimension: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2),
                                    )
                                  : const Icon(Icons.check_rounded, size: 19),
                              label: Text(t('确认', 'Done')),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final image = _oriented!;
                            final aspect = image.width / image.height;
                            final width = math.min(constraints.maxWidth, constraints.maxHeight * aspect).toDouble();
                            final height = width / aspect;
                            final size = Size(width, height);
                            return Center(
                              child: SizedBox.fromSize(
                                size: size,
                                child: GestureDetector(
                                  key: const ValueKey('image-editor-canvas'),
                                  behavior: HitTestBehavior.opaque,
                                  dragStartBehavior: DragStartBehavior.down,
                                  onTapUp: _paintMode ? (d) => _startGesture(d.localPosition, size) : null,
                                  onPanStart: _cropMode || _paintMode
                                      ? (d) => _startGesture(d.localPosition, size)
                                      : null,
                                  onPanUpdate: _cropMode || _paintMode
                                      ? (d) => _updateGesture(d.localPosition, size)
                                      : null,
                                  onPanEnd: (_) => _endGesture(),
                                  onPanCancel: _endGesture,
                                  child: CustomPaint(
                                    painter: _ImageEditPainter(image: image, crop: _crop, strokes: _strokes),
                                    size: size,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              children: [
                                _EditorTool(
                                  icon: Icons.crop_rounded,
                                  label: t('裁剪', 'Crop'),
                                  selected: _cropMode,
                                  onTap: () => setState(() {
                                    _cropMode = !_cropMode;
                                    if (_cropMode) _paintMode = false;
                                  }),
                                ),
                                _EditorTool(icon: Icons.rotate_right_rounded, label: t('旋转', 'Rotate'), onTap: _rotate),
                                _EditorTool(
                                  icon: Icons.brush_rounded,
                                  label: t('画笔', 'Draw'),
                                  selected: _paintMode,
                                  onTap: () => setState(() {
                                    _paintMode = !_paintMode;
                                    if (_paintMode) _cropMode = false;
                                  }),
                                ),
                                if (_paintMode)
                                  IconButton(
                                    tooltip: t('撤销一笔', 'Undo stroke'),
                                    onPressed: _strokes.isEmpty ? null : () => setState(_strokes.removeLast),
                                    icon: const Icon(Icons.undo_rounded),
                                  ),
                                if (_paintMode)
                                  IconButton(
                                    tooltip: t('清除笔迹', 'Clear marks'),
                                    onPressed: () => setState(_strokes.clear),
                                    icon: const Icon(Icons.delete_outline_rounded),
                                  ),
                                if (_cropMode)
                                  IconButton(
                                    tooltip: t('重置裁剪', 'Reset crop'),
                                    onPressed: () => setState(() => _crop = null),
                                    icon: const Icon(Icons.restart_alt_rounded),
                                  ),
                              ],
                            ),
                            if (_paintMode)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    for (var i = 0; i < _colors.length; i++)
                                      GestureDetector(
                                        onTap: () => setState(() => _colorIndex = i),
                                        child: Container(
                                          width: 28,
                                          height: 28,
                                          margin: const EdgeInsets.symmetric(horizontal: 8),
                                          decoration: BoxDecoration(
                                            color: _colors[i],
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: _colorIndex == i ? scheme.primary : Colors.white54,
                                              width: _colorIndex == i ? 3 : 1,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            const SizedBox(height: 6),
                            Text(
                              _cropMode
                                  ? t('在图片上拖动选择要保留的范围', 'Drag on the photo to select the area to keep')
                                  : _paintMode
                                  ? t('在图片上拖动进行标记', 'Draw on the photo to add marks')
                                  : t('可裁剪、旋转或标记后再确认', 'Crop, rotate, or mark the photo before confirming'),
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _Stroke {
  _Stroke({required this.color, required this.points, required this.width});

  final Color color;
  final List<Offset> points;
  final double width;
}

class _ImageEditPainter extends CustomPainter {
  const _ImageEditPainter({required this.image, required this.crop, required this.strokes});

  final ui.Image image;
  final Rect? crop;
  final List<_Stroke> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    final imageRect = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    canvas.drawImageRect(image, imageRect, Offset.zero & size, Paint()..filterQuality = FilterQuality.high);
    for (final stroke in strokes) {
      if (stroke.points.isEmpty) continue;
      final path = Path()..moveTo(stroke.points.first.dx * size.width, stroke.points.first.dy * size.height);
      for (final point in stroke.points.skip(1)) {
        path.lineTo(point.dx * size.width, point.dy * size.height);
      }
      final paint = Paint()
        ..color = stroke.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke.width * math.min(size.width, size.height)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      if (stroke.points.length == 1) {
        canvas.drawCircle(
          Offset(stroke.points.first.dx * size.width, stroke.points.first.dy * size.height),
          stroke.width * math.min(size.width, size.height) / 2,
          Paint()..color = stroke.color,
        );
      } else {
        canvas.drawPath(path, paint);
      }
    }
    final selection = crop;
    if (selection != null && selection != const Rect.fromLTRB(0, 0, 1, 1)) {
      final selected = Rect.fromLTRB(
        selection.left * size.width,
        selection.top * size.height,
        selection.right * size.width,
        selection.bottom * size.height,
      );
      if (selected.width > 1 && selected.height > 1) {
        final shade = Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(Offset.zero & size)
          ..addRect(selected);
        canvas.drawPath(shade, Paint()..color = Colors.black54);
        canvas.drawRect(
          selected,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ImageEditPainter oldDelegate) => true;
}

class _EditorTool extends StatelessWidget {
  const _EditorTool({required this.icon, required this.label, required this.onTap, this.selected = false});

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = selected ? Theme.of(context).colorScheme.primary : Colors.white70;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: color, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}
