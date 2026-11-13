import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ai/encoding.dart';
import '../../core/attachments.dart';
import '../../core/i18n.dart';
import '../../core/paths.dart';
import '../widgets/motion.dart';
import '../theme.dart';

/// Longest side of the decoded photo and of the exported crop.
const _maxImageSize = 4096;

/// Room around the frame for grabbing its corners. The sides get a little
/// more than RikkaHub's 24 dp because Flutter cannot exclude the system back
/// gesture there, and a corner drag must not close the editor.
const _framePadding = EdgeInsets.symmetric(horizontal: 28, vertical: 24);
const _touchRadius = 24.0;
const _minFrameSize = 64.0;
const _maxZoom = 8.0;

const _scrimColor = Color(0x99000000);
const _lineColor = Colors.white;
const _shadowColor = Color(0x4D000000);

/// Crop ratios that can be picked at the bottom, the same list as RikkaHub.
enum CropAspect {
  free,
  original,
  square(1, 1),
  landscape(4, 3),
  portrait(3, 4),
  wide(16, 9),
  tall(9, 16);

  const CropAspect([this.width = 0, this.height = 0]);
  final int width;
  final int height;

  String get label => switch (this) {
    free => t('自由', 'Free'),
    original => t('原图', 'Original'),
    _ => '$width:$height',
  };
}

/// The parts of the frame that can be dragged: four corners and four edges,
/// each recording which sides of the frame it moves.
enum CropHandle {
  topLeft(movesLeft: true, movesTop: true),
  topRight(movesTop: true, movesRight: true),
  bottomRight(movesRight: true, movesBottom: true),
  bottomLeft(movesLeft: true, movesBottom: true),
  leftEdge(movesLeft: true),
  topEdge(movesTop: true),
  rightEdge(movesRight: true),
  bottomEdge(movesBottom: true);

  const CropHandle({this.movesLeft = false, this.movesTop = false, this.movesRight = false, this.movesBottom = false});
  final bool movesLeft;
  final bool movesTop;
  final bool movesRight;
  final bool movesBottom;
}

/// A frame drag that is springing back into the middle of the canvas.
class CropRefit {
  const CropRefit({
    required this.frame,
    required this.offset,
    required this.scale,
    required this.factor,
    required this.topLeft,
  });

  final Rect frame;
  final Offset offset;
  final double scale;

  /// How much the frame (and the photo with it) grows.
  final double factor;

  /// Where the frame's top-left corner ends up.
  final Offset topLeft;
}

/// Crop geometry in canvas pixels, after RikkaHub's `ImageCropState`.
///
/// The photo, turned clockwise by [quarterTurns], has its top-left corner at
/// [offset] and draws every source pixel as [scale] canvas pixels. The frame
/// always stays on the photo: dragging the photo pans and zooms it, dragging
/// the frame's corners or edges resizes the frame, and after such a drag the
/// frame grows back into the middle together with the photo.
class CropGeometry {
  CropGeometry({required this.sourceSize, this.lockedRatio});

  /// Decoded photo size, before any rotation.
  final Size sourceSize;

  /// Fixed width / height ratio (e.g. 1 for avatars); null allows any frame.
  final double? lockedRatio;

  int quarterTurns = 0;
  CropAspect aspect = CropAspect.free;
  Rect frame = Rect.zero;
  Offset offset = Offset.zero;
  double scale = 1;

  /// Whether anything differs from the freshly opened photo.
  bool modified = false;

  /// Where the frame may go: the canvas minus room for the corner handles.
  Rect area = Rect.zero;
  double minFrameSize = _minFrameSize;

  bool get isReady => !area.isEmpty && !frame.isEmpty;

  /// The photo after rotation, in source pixels.
  Size get imageSize => quarterTurns.isEven ? sourceSize : Size(sourceSize.height, sourceSize.width);

  Rect get imageRect => offset & (imageSize * scale);

  /// The ratio in effect; null while the frame is free.
  double? get ratio =>
      lockedRatio ??
      switch (aspect) {
        CropAspect.free => null,
        CropAspect.original => imageSize.width / imageSize.height,
        _ => aspect.width / aspect.height,
      };

  double get minScale => math.max(frame.width / imageSize.width, frame.height / imageSize.height);

  double get maxScale =>
      math.max(math.min(area.width / imageSize.width, area.height / imageSize.height) * _maxZoom, minScale);

  /// The canvas changed size: everything is laid out again and the previous
  /// crop is dropped. Returns whether anything changed.
  bool layout(Rect area, {double minFrameSize = _minFrameSize}) {
    if (area == this.area) return false;
    this.area = area;
    this.minFrameSize = minFrameSize;
    fit();
    return true;
  }

  void reset() {
    quarterTurns = 0;
    aspect = CropAspect.free;
    modified = false;
    fit();
  }

  void rotate() {
    quarterTurns = (quarterTurns + 1) % 4;
    modified = true;
    fit();
  }

  void selectAspect(CropAspect next) {
    if (lockedRatio != null || next == aspect) return;
    aspect = next;
    modified = true;
    // Going back to free keeps the current frame and only unlocks it.
    if (next != CropAspect.free) fit();
  }

  /// The largest frame with the current ratio, centred, with the photo just
  /// covering it.
  void fit() {
    if (area.isEmpty) return;
    final image = imageSize;
    final r = ratio ?? image.width / image.height;
    final width = math.min(area.width, area.height * r);
    frame = Rect.fromCenter(center: area.center, width: width, height: width / r);
    scale = minScale;
    offset = frame.center - Offset(image.width * scale / 2, image.height * scale / 2);
  }

  /// Pans the photo by [pan] after zooming it [zoom] times around [centroid].
  void transform(Offset centroid, Offset pan, double zoom) {
    final next = (scale * zoom).clamp(minScale, maxScale).toDouble();
    offset = centroid - (centroid - offset) * (next / scale) + pan;
    scale = next;
    modified = true;
    _clampImage();
  }

  /// The photo may never uncover part of the frame.
  void _clampImage() {
    final size = imageSize * scale;
    offset = Offset(
      _coerce(offset.dx, frame.right - size.width, frame.left),
      _coerce(offset.dy, frame.bottom - size.height, frame.top),
    );
  }

  /// The handle under [position], or null when the touch drags the photo.
  CropHandle? handleAt(Offset position, double touchRadius) {
    final corners = <(CropHandle, Offset)>[
      (CropHandle.topLeft, frame.topLeft),
      (CropHandle.topRight, frame.topRight),
      (CropHandle.bottomRight, frame.bottomRight),
      (CropHandle.bottomLeft, frame.bottomLeft),
    ];
    CropHandle? nearest;
    var best = touchRadius * 1.5;
    for (final (handle, corner) in corners) {
      final distance = (corner - position).distance;
      if (distance <= best) {
        best = distance;
        nearest = handle;
      }
    }
    if (nearest != null) return nearest;
    // With a ratio in effect only the corners can be dragged.
    if (ratio != null) return null;
    final withinX = position.dx >= frame.left && position.dx <= frame.right;
    final withinY = position.dy >= frame.top && position.dy <= frame.bottom;
    if (withinY && (position.dx - frame.left).abs() <= touchRadius) return CropHandle.leftEdge;
    if (withinY && (position.dx - frame.right).abs() <= touchRadius) return CropHandle.rightEdge;
    if (withinX && (position.dy - frame.top).abs() <= touchRadius) return CropHandle.topEdge;
    if (withinX && (position.dy - frame.bottom).abs() <= touchRadius) return CropHandle.bottomEdge;
    return null;
  }

  /// [handle] dragged by [delta] from the frame [start] it had when touched.
  void resize(CropHandle handle, Rect start, Offset delta) {
    // The frame has to stay on the photo and inside the area.
    final bounds = imageRect.intersect(area);
    final r = ratio;
    frame = r == null ? _resizeFree(handle, start, delta, bounds) : _resizeLocked(handle, start, delta, bounds, r);
    modified = true;
  }

  Rect _resizeFree(CropHandle handle, Rect start, Offset delta, Rect bounds) {
    // A frame already below the minimum (a very thin photo) is not forced open.
    final minWidth = math.min(minFrameSize, start.width);
    final minHeight = math.min(minFrameSize, start.height);
    var left = start.left;
    var top = start.top;
    var right = start.right;
    var bottom = start.bottom;
    if (handle.movesLeft) left = _coerce(start.left + delta.dx, bounds.left, right - minWidth);
    if (handle.movesRight) right = _coerce(start.right + delta.dx, left + minWidth, bounds.right);
    if (handle.movesTop) top = _coerce(start.top + delta.dy, bounds.top, bottom - minHeight);
    if (handle.movesBottom) bottom = _coerce(start.bottom + delta.dy, top + minHeight, bounds.bottom);
    return Rect.fromLTRB(left, top, right, bottom);
  }

  // The opposite corner stays put; whichever direction the finger pulled
  // further sets the width, and the height follows the ratio.
  Rect _resizeLocked(CropHandle handle, Rect start, Offset delta, Rect bounds, double ratio) {
    final anchorX = handle.movesLeft ? start.right : start.left;
    final anchorY = handle.movesTop ? start.bottom : start.top;
    final pointerX = (handle.movesLeft ? start.left : start.right) + delta.dx;
    final pointerY = (handle.movesTop ? start.top : start.bottom) + delta.dy;
    final wantWidth = handle.movesLeft ? anchorX - pointerX : pointerX - anchorX;
    final wantHeight = handle.movesTop ? anchorY - pointerY : pointerY - anchorY;
    final maxWidth = math.min(
      handle.movesLeft ? anchorX - bounds.left : bounds.right - anchorX,
      (handle.movesTop ? anchorY - bounds.top : bounds.bottom - anchorY) * ratio,
    );
    final minWidth = math.min(math.max(minFrameSize, minFrameSize * ratio), start.width);
    final width = _coerce(math.max(wantWidth, wantHeight * ratio), minWidth, maxWidth);
    final height = width / ratio;
    final left = handle.movesLeft ? anchorX - width : anchorX;
    final top = handle.movesTop ? anchorY - height : anchorY;
    return Rect.fromLTWH(left, top, width, height);
  }

  /// How the frame grows back into the middle after a corner drag, or null
  /// when it is already there.
  CropRefit? refit() {
    if (area.isEmpty || frame.isEmpty) return null;
    final factor = math.max(
      1.0,
      math.min(math.min(area.width / frame.width, area.height / frame.height), maxScale / scale),
    );
    final topLeft = area.center - Offset(frame.width * factor / 2, frame.height * factor / 2);
    if ((factor - 1).abs() < 1e-3 && (topLeft - frame.topLeft).distance < 0.5) return null;
    return CropRefit(frame: frame, offset: offset, scale: scale, factor: factor, topLeft: topLeft);
  }

  /// Moves frame and photo [t] of the way through [plan]. Both follow the
  /// same similarity transform, so the photo keeps covering the frame and
  /// the cropped region never changes along the way.
  void applyRefit(CropRefit plan, double t) {
    final k = ui.lerpDouble(1, plan.factor, t)!;
    final topLeft = Offset.lerp(plan.frame.topLeft, plan.topLeft, t)!;
    frame = topLeft & (plan.frame.size * k);
    offset = topLeft + (plan.offset - plan.frame.topLeft) * k;
    scale = plan.scale * k;
  }

  /// The framed part of the turned photo, in whole source pixels.
  Rect cropRect() {
    final image = imageSize;
    final raw = Rect.fromLTRB(
      (frame.left - offset.dx) / scale,
      (frame.top - offset.dy) / scale,
      (frame.right - offset.dx) / scale,
      (frame.bottom - offset.dy) / scale,
    ).intersect(Offset.zero & image);
    final width = image.width.round();
    final height = image.height.round();
    final left = raw.left.round().clamp(0, width - 1);
    final top = raw.top.round().clamp(0, height - 1);
    final right = raw.right.round().clamp(left + 1, width);
    final bottom = raw.bottom.round().clamp(top + 1, height);
    return Rect.fromLTRB(left.toDouble(), top.toDouble(), right.toDouble(), bottom.toDouble());
  }
}

/// Clamp that settles in the middle when the bounds cross, which floating
/// point error or a frame below the minimum size can cause.
double _coerce(double value, double min, double max) => min > max ? (min + max) / 2 : value.clamp(min, max).toDouble();

/// Draws [image] turned clockwise by [quarterTurns] with its new top-left
/// corner at the origin, one canvas unit per source pixel.
void _paintTurned(Canvas canvas, ui.Image image, int quarterTurns, FilterQuality quality) {
  final width = image.width.toDouble();
  final height = image.height.toDouble();
  final turned = quarterTurns.isOdd ? Size(height, width) : Size(width, height);
  canvas.save();
  canvas.translate(turned.width / 2, turned.height / 2);
  canvas.rotate(quarterTurns * math.pi / 2);
  canvas.translate(-width / 2, -height / 2);
  canvas.drawImage(image, Offset.zero, Paint()..filterQuality = quality);
  canvas.restore();
}

/// Lets a picked or captured photo be cropped before it enters the composer.
///
/// A one-to-one take on RikkaHub's cropper in MewHub colours: close, rotate,
/// reset and a filled confirm button on top; the photo sits in the middle
/// with room around it, pans and pinch-zooms under a fixed frame whose
/// corners (and edges, while the ratio is free) are dragged directly; after
/// a corner drag the frame grows back into the middle together with the
/// photo; ratio toggles run along the bottom.
class ImageEditorPage extends StatefulWidget {
  const ImageEditorPage({super.key, required this.imageUrl});

  final String imageUrl;

  @override
  State<ImageEditorPage> createState() => _ImageEditorPageState();
}

class _ImageEditorPageState extends State<ImageEditorPage> with SingleTickerProviderStateMixin {
  ui.Image? _image;
  CropGeometry? _crop;
  bool _loading = true;
  bool _saving = false;
  String? _loadError;

  /// Thirds are drawn while a finger is down.
  bool _interacting = false;

  /// Fingers on the canvas, in canvas coordinates. Raw pointers instead of a
  /// scale recognizer: like RikkaHub, the frame and photo follow from the very
  /// first move, with no slop before a corner starts moving.
  final Map<int, Offset> _touches = {};

  /// A corner or edge being dragged by one finger.
  CropHandle? _handle;
  int? _handlePointer;
  Offset _handleOrigin = Offset.zero;
  Rect _dragFrame = Rect.zero;

  /// Set once a corner drag ends with other fingers still down; those are
  /// ignored until every finger is up, so they cannot nudge the photo.
  bool _waitForRelease = false;

  late final AnimationController _refit = AnimationController(vsync: this, duration: const Duration(milliseconds: 360))
    ..addListener(_tickRefit);
  CropRefit? _refitPlan;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _refit.dispose();
    _image?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    ui.Image? decoded;
    try {
      final bytes = widget.imageUrl.startsWith('data:')
          ? MediaEncoder.decodeDataUri(widget.imageUrl)
          : await File(AppPaths.resolve(widget.imageUrl)).readAsBytes();
      if (bytes == null) throw StateError(t('无法读取图片', 'Unable to load image'));
      // Huge camera photos are scaled down on decode, like RikkaHub; giving
      // only the width keeps the aspect ratio whatever the EXIF orientation.
      final codec = await ui.instantiateImageCodecWithSize(
        await ui.ImmutableBuffer.fromUint8List(bytes),
        getTargetSize: (width, height) {
          final longest = math.max(width, height);
          if (longest <= _maxImageSize) return const ui.TargetImageSize();
          return ui.TargetImageSize(width: math.max(1, (width * _maxImageSize / longest).round()));
        },
      );
      try {
        decoded = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
      }
      final image = decoded;
      if (!mounted) return;
      setState(() {
        _image = image;
        _crop = CropGeometry(sourceSize: Size(image.width.toDouble(), image.height.toDouble()));
        _loading = false;
      });
      decoded = null; // Owned by this state until dispose().
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

  // ---------------------------------------------------------------- gestures

  void _pointerDown(PointerDownEvent event) {
    final crop = _crop;
    if (crop == null || !crop.isReady || _saving) return;
    // A press stops a spring-back that is still running, right where it is.
    _stopRefit();
    _touches[event.pointer] = event.localPosition;
    if (_touches.length == 1) {
      _waitForRelease = false;
      final handle = crop.handleAt(event.localPosition, _touchRadius);
      if (handle != null) {
        _handle = handle;
        _handlePointer = event.pointer;
        _handleOrigin = event.localPosition;
        _dragFrame = crop.frame;
      }
    }
    if (!_interacting) setState(() => _interacting = true);
  }

  void _pointerMove(PointerMoveEvent event) {
    final crop = _crop;
    if (crop == null || !_touches.containsKey(event.pointer)) return;
    final handle = _handle;
    if (handle != null || _waitForRelease) {
      _touches[event.pointer] = event.localPosition;
      if (handle != null && event.pointer == _handlePointer) {
        setState(() => crop.resize(handle, _dragFrame, event.localPosition - _handleOrigin));
      }
      return;
    }
    // Zoom around where the fingers were, then follow them: the same centroid,
    // zoom and pan RikkaHub derives from every pointer event.
    final before = _touches.values.toList();
    _touches[event.pointer] = event.localPosition;
    final after = _touches.values.toList();
    final from = _centroid(before);
    final to = _centroid(after);
    final spanBefore = _span(before, from);
    final zoom = after.length > 1 && spanBefore > 0 ? _span(after, to) / spanBefore : 1.0;
    if (zoom == 1 && to == from) return;
    setState(() => crop.transform(from, to - from, zoom));
  }

  void _pointerGone(PointerEvent event) {
    if (_touches.remove(event.pointer) == null) return;
    if (event.pointer == _handlePointer) {
      _handle = null;
      _handlePointer = null;
      _waitForRelease = _touches.isNotEmpty;
      _startRefit();
    }
    if (_touches.isEmpty) {
      _waitForRelease = false;
      if (_interacting) setState(() => _interacting = false);
    }
  }

  static Offset _centroid(List<Offset> points) =>
      points.fold(Offset.zero, (sum, p) => sum + p) / points.length.toDouble();

  static double _span(List<Offset> points, Offset centroid) =>
      points.fold(0.0, (sum, p) => sum + (p - centroid).distance) / points.length;

  void _startRefit() {
    final plan = _crop?.refit();
    if (plan == null) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      setState(() => _crop!.applyRefit(plan, 1));
      return;
    }
    _refitPlan = plan;
    unawaited(_refit.forward(from: 0));
  }

  void _tickRefit() {
    final plan = _refitPlan;
    final crop = _crop;
    if (plan == null || crop == null) return;
    setState(() => crop.applyRefit(plan, Curves.easeOutCubic.transform(_refit.value)));
  }

  void _stopRefit() {
    _refit.stop();
    _refitPlan = null;
  }

  // ----------------------------------------------------------------- actions

  void _edit(void Function(CropGeometry crop) change) {
    final crop = _crop;
    if (crop == null || _saving) return;
    _stopRefit();
    // The frame is about to be laid out again; a corner still under a finger
    // must not keep resizing from where it was.
    _handle = null;
    _handlePointer = null;
    _waitForRelease = _touches.isNotEmpty;
    setState(() => change(crop));
  }

  Future<void> _confirm() async {
    final image = _image;
    final crop = _crop;
    if (image == null || crop == null || !crop.isReady || _saving) return;
    _stopRefit();
    setState(() => _saving = true);
    try {
      final region = crop.cropRect();
      final downscale = math.min(1.0, _maxImageSize / math.max(region.width, region.height));
      final width = math.max(1, (region.width * downscale).round());
      final height = math.max(1, (region.height * downscale).round());
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()));
      canvas.scale(width / region.width, height / region.height);
      canvas.translate(-region.left, -region.top);
      _paintTurned(canvas, image, crop.quarterTurns, FilterQuality.high);
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
      if (data == null) throw StateError(t('无法裁剪图片', 'Unable to crop the photo'));
      final stored = await Attachments.storeBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        'png',
      );
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

  // -------------------------------------------------------------------- view

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final crop = _crop;
    final dark = theme.brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: mewSystemUiOverlayStyle(dark ? Brightness.dark : Brightness.light),
      child: PopScope(
        canPop: !_saving,
        child: Scaffold(
          backgroundColor: scheme.surfaceContainer,
          body: SafeArea(
            child: AbsorbPointer(
              absorbing: _saving,
              child: Column(
                children: [
                  _CropTopBar(
                    ready: crop != null,
                    canReset: crop?.modified ?? false,
                    saving: _saving,
                    onClose: () => Navigator.of(context).maybePop(),
                    onRotate: () => _edit((c) => c.rotate()),
                    onReset: () => _edit((c) => c.reset()),
                    onConfirm: _confirm,
                  ),
                  Expanded(child: _body(scheme)),
                  if (crop != null && crop.lockedRatio == null)
                    _CropAspectBar(selected: crop.aspect, onSelect: (a) => _edit((c) => c.selectAspect(a))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _body(ColorScheme scheme) {
    final image = _image;
    final crop = _crop;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (image == null || crop == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.broken_image_outlined, size: 42, color: scheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(_loadError ?? t('无法读取图片', 'Unable to load image'), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: () => Navigator.of(context).maybePop(), child: Text(t('返回', 'Back'))),
            ],
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        final area = Rect.fromLTRB(
          _framePadding.left,
          _framePadding.top,
          math.max(_framePadding.left + 1, size.width - _framePadding.right),
          math.max(_framePadding.top + 1, size.height - _framePadding.bottom),
        );
        // A new canvas size lays everything out again; a running spring-back
        // would only fight it.
        if (crop.layout(area)) _stopRefit();
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _pointerDown,
          onPointerMove: _pointerMove,
          onPointerUp: _pointerGone,
          onPointerCancel: _pointerGone,
          // Zoomed in, the photo would otherwise draw over both bars.
          child: ClipRect(
            child: CustomPaint(
              key: const ValueKey('image-editor-canvas'),
              size: size,
              painter: _CropPainter(image: image, crop: crop, interacting: _interacting),
            ),
          ),
        );
      },
    );
  }
}

/// Close, rotate, reset and confirm.
class _CropTopBar extends StatelessWidget {
  const _CropTopBar({
    required this.ready,
    required this.canReset,
    required this.saving,
    required this.onClose,
    required this.onRotate,
    required this.onReset,
    required this.onConfirm,
  });

  final bool ready;
  final bool canReset;
  final bool saving;
  final VoidCallback onClose;
  final VoidCallback onRotate;
  final VoidCallback onReset;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          IconButton(
            key: const ValueKey('image-editor-close'),
            tooltip: t('取消', 'Cancel'),
            onPressed: saving ? null : onClose,
            icon: const Icon(Icons.close_rounded),
          ),
          const Spacer(),
          IconButton(
            key: const ValueKey('image-editor-rotate'),
            tooltip: t('旋转', 'Rotate'),
            onPressed: ready && !saving ? onRotate : null,
            icon: const Icon(Icons.rotate_90_degrees_cw_outlined),
          ),
          IconButton(
            key: const ValueKey('image-editor-reset'),
            tooltip: t('重置', 'Reset'),
            onPressed: canReset && !saving ? onReset : null,
            icon: const Icon(Icons.sync_rounded),
          ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: IconButton.filled(
              key: const ValueKey('image-editor-confirm'),
              tooltip: t('完成', 'Done'),
              onPressed: ready && !saving ? onConfirm : null,
              style: IconButton.styleFrom(
                backgroundColor: scheme.primary,
                foregroundColor: scheme.onPrimary,
                disabledBackgroundColor: scheme.primary.withValues(alpha: saving ? 0.75 : 0.38),
                minimumSize: const Size(44, 44),
              ),
              icon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: saving
                    ? SizedBox.square(
                        key: const ValueKey('saving'),
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2.2, color: scheme.onPrimary),
                      )
                    : Icon(Icons.check_rounded, key: const ValueKey('check'), color: scheme.onPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Ratio toggles along the bottom. Like Material 3 expressive toggle
/// buttons, the picked one turns from a pill into a rounded square.
class _CropAspectBar extends StatelessWidget {
  const _CropAspectBar({required this.selected, required this.onSelect});

  final CropAspect selected;
  final ValueChanged<CropAspect> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      height: 60,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        itemCount: CropAspect.values.length,
        separatorBuilder: (context, i) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final aspect = CropAspect.values[i];
          final checked = aspect == selected;
          return Semantics(
            button: true,
            selected: checked,
            child: Pressable(
              key: ValueKey('image-editor-aspect-${aspect.name}'),
              onTap: () => onSelect(aspect),
              scale: 0.94,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                constraints: const BoxConstraints(minWidth: 60),
                padding: const EdgeInsets.symmetric(horizontal: 18),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: checked ? scheme.primary : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(checked ? 12 : 20),
                ),
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 240),
                  style: theme.textTheme.labelLarge!.copyWith(
                    color: checked ? scheme.onPrimary : scheme.onSurface,
                    fontWeight: checked ? FontWeight.w700 : FontWeight.w500,
                  ),
                  child: Text(aspect.label, maxLines: 1, softWrap: false),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The photo, a scrim over the part outside the frame, and the frame with
/// its corner (and, while free, edge) grips.
class _CropPainter extends CustomPainter {
  const _CropPainter({required this.image, required this.crop, required this.interacting});

  final ui.Image image;
  final CropGeometry crop;
  final bool interacting;

  @override
  void paint(Canvas canvas, Size size) {
    if (!crop.isReady) return;
    canvas.save();
    canvas.translate(crop.offset.dx, crop.offset.dy);
    canvas.scale(crop.scale);
    _paintTurned(canvas, image, crop.quarterTurns, FilterQuality.medium);
    canvas.restore();

    // Only the photo outside the frame is dimmed; around it is background.
    final visible = crop.imageRect.intersect(Offset.zero & size);
    if (visible.width > 0 && visible.height > 0) {
      canvas.drawPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(visible)
          ..addRect(crop.frame),
        Paint()..color = _scrimColor,
      );
    }
    _paintFrame(canvas);
  }

  void _paintFrame(Canvas canvas) {
    final frame = crop.frame;
    if (interacting) {
      final thirds = Paint()
        ..color = _lineColor.withValues(alpha: 0.6)
        ..strokeWidth = 1;
      for (var i = 1; i <= 2; i++) {
        final x = frame.left + frame.width / 3 * i;
        final y = frame.top + frame.height / 3 * i;
        canvas.drawLine(Offset(x, frame.top), Offset(x, frame.bottom), thirds);
        canvas.drawLine(Offset(frame.left, y), Offset(frame.right, y), thirds);
      }
    }
    canvas.drawRect(
      frame,
      Paint()
        ..color = _lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );

    // Grips sit just outside the frame line, over a faint shadow so they stay
    // visible on bright photos.
    const width = 3.0;
    final length = math.min(20.0, math.min(frame.width, frame.height) / 2);
    final outer = frame.inflate(width / 2);
    final segments = <(Offset, Offset)>[
      (outer.topLeft, outer.topLeft + Offset(length, 0)),
      (outer.topLeft, outer.topLeft + Offset(0, length)),
      (outer.topRight, outer.topRight - Offset(length, 0)),
      (outer.topRight, outer.topRight + Offset(0, length)),
      (outer.bottomRight, outer.bottomRight - Offset(length, 0)),
      (outer.bottomRight, outer.bottomRight - Offset(0, length)),
      (outer.bottomLeft, outer.bottomLeft + Offset(length, 0)),
      (outer.bottomLeft, outer.bottomLeft - Offset(0, length)),
      // While the ratio is free the middle of every edge can be dragged too.
      if (crop.ratio == null) ...[
        (outer.topCenter - Offset(length / 2, 0), outer.topCenter + Offset(length / 2, 0)),
        (outer.bottomCenter - Offset(length / 2, 0), outer.bottomCenter + Offset(length / 2, 0)),
        (outer.centerLeft - Offset(0, length / 2), outer.centerLeft + Offset(0, length / 2)),
        (outer.centerRight - Offset(0, length / 2), outer.centerRight + Offset(0, length / 2)),
      ],
    ];
    final shadow = Paint()
      ..color = _shadowColor
      ..strokeWidth = width + 2
      ..strokeCap = StrokeCap.round;
    final grip = Paint()
      ..color = _lineColor
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    for (final (start, end) in segments) {
      canvas.drawLine(start, end, shadow);
    }
    for (final (start, end) in segments) {
      canvas.drawLine(start, end, grip);
    }
  }

  // The geometry is mutated in place, so there is nothing to compare against.
  @override
  bool shouldRepaint(covariant _CropPainter oldDelegate) => true;
}
