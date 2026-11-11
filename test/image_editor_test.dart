import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/ui/chat/image_editor.dart';
import 'package:mewhub/ui/theme.dart';

const _canvasKey = ValueKey('image-editor-canvas');

void main() {
  late Directory sandbox;
  late String sourceUri;

  setUp(() async {
    I18n.apply(AppLang.zh);
    sandbox = await Directory.systemTemp.createTemp('mewhub_image_editor_');
    AppPaths.support = sandbox;
    AppPaths.cache = sandbox;
    await AppPaths.files.create(recursive: true);
    // 100 x 80, red on the left half and blue on the right half, so every
    // export can be checked for both its size and which part was kept.
    sourceUri = 'data:image/png;base64,${base64Encode(await _splitPng(100, 80))}';
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  Future<void> openEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: MewTheme.light(0),
        home: _EditorHost(imageUrl: sourceUri),
      ),
    );
    await tester.tap(find.text('Open editor'));
    await _waitFor(tester, find.byKey(_canvasKey));
  }

  CropGeometry geometry(WidgetTester tester) {
    final paint = tester.widget<CustomPaint>(find.byKey(_canvasKey));
    return (paint.painter! as dynamic).crop as CropGeometry;
  }

  Future<_Output> confirm(WidgetTester tester) async {
    await tester.runAsync(() => tester.tap(find.byKey(const ValueKey('image-editor-confirm'))));
    await _waitFor(tester, find.text('Open editor'));
    final saved = tester.widget<Text>(find.byKey(const ValueKey('saved-url'))).data!;
    expect(saved, isNot('not-saved'));
    return (await tester.runAsync(() => _Output.read(AppPaths.resolve(saved))))!;
  }

  testWidgets('opens with the whole photo framed in the middle and exports it untouched', (tester) async {
    await openEditor(tester);
    final crop = geometry(tester);
    expect(crop.frame.center, offsetMoreOrLessEquals(crop.area.center, epsilon: 0.01));
    expect(crop.frame.width / crop.frame.height, closeTo(100 / 80, 0.001));
    expect(crop.imageRect, rectMoreOrLessEquals(crop.frame, epsilon: 0.01));
    // Free ratio: all four corners and the four edge grips can be dragged.
    expect(find.byKey(const ValueKey('image-editor-aspect-free')), findsOneWidget);
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('image-editor-reset'))).onPressed, isNull);

    final output = await confirm(tester);
    expect((output.width, output.height), (100, 80));
    expect(output.isRed(10, 40), isTrue);
    expect(output.isBlue(90, 40), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dragging a corner crops, then the frame springs back into the middle', (tester) async {
    await openEditor(tester);
    final canvas = tester.getRect(find.byKey(_canvasKey));
    final start = geometry(tester).frame;
    final grab = canvas.topLeft + start.topLeft + const Offset(3, 3);
    final pull = Offset(start.width / 2, start.height / 2);
    final gesture = await tester.startGesture(grab);
    for (var i = 1; i <= 10; i++) {
      await gesture.moveTo(grab + pull * (i / 10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    // The corner follows the finger right away and the opposite one stays.
    final dragged = geometry(tester).frame;
    expect(dragged.width, closeTo(start.width / 2, 0.5));
    expect(dragged.bottomRight, offsetMoreOrLessEquals(start.bottomRight, epsilon: 0.01));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final midway = geometry(tester).frame;
    expect(midway.width, greaterThan(dragged.width), reason: 'the frame grows back while it springs');
    await tester.pumpAndSettle();
    final settled = geometry(tester);
    expect(settled.frame.center, offsetMoreOrLessEquals(settled.area.center, epsilon: 0.5));
    expect(settled.frame.width, closeTo(start.width, 0.5), reason: 'the crop fills the room it had');

    final output = await confirm(tester);
    expect(output.width, inInclusiveRange(49, 51));
    expect(output.height, inInclusiveRange(39, 41));
    expect(output.isBlue(2, 2), isTrue, reason: 'only the right half was kept');
    expect(output.isBlue(output.width - 2, output.height - 2), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pinching zooms into the photo under the fingers', (tester) async {
    await openEditor(tester);
    final canvas = tester.getRect(find.byKey(_canvasKey));
    final center = canvas.topLeft + geometry(tester).frame.center;
    final a = await tester.startGesture(center - const Offset(40, 0), pointer: 1);
    final b = await tester.startGesture(center + const Offset(40, 0), pointer: 2);
    for (var i = 1; i <= 10; i++) {
      await a.moveTo(center - Offset(40 + 4.0 * i, 0));
      await b.moveTo(center + Offset(40 + 4.0 * i, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    final crop = geometry(tester);
    expect(crop.scale, closeTo(crop.minScale * 2, 0.01));
    expect(crop.frame.contains(crop.imageRect.topLeft), isFalse);

    final output = await confirm(tester);
    expect(output.width, inInclusiveRange(49, 51));
    expect(output.height, inInclusiveRange(39, 41));
    expect(output.isRed(10, 20), isTrue);
    expect(output.isBlue(output.width - 10, 20), isTrue);
  });

  testWidgets('the photo cannot be dragged off the frame', (tester) async {
    await openEditor(tester);
    final canvas = tester.getRect(find.byKey(_canvasKey));
    final center = canvas.topLeft + geometry(tester).frame.center;
    await tester.dragFrom(center, const Offset(260, 120));
    await tester.pumpAndSettle();
    final crop = geometry(tester);
    expect(crop.imageRect.left, lessThanOrEqualTo(crop.frame.left + 0.01));
    expect(crop.imageRect.top, lessThanOrEqualTo(crop.frame.top + 0.01));
    final output = await confirm(tester);
    expect((output.width, output.height), (100, 80));
  });

  testWidgets('1:1 keeps the centred square', (tester) async {
    await openEditor(tester);
    await tester.tap(find.byKey(const ValueKey('image-editor-aspect-square')));
    await tester.pumpAndSettle();
    final crop = geometry(tester);
    expect(crop.frame.width, closeTo(crop.frame.height, 0.01));
    expect(crop.ratio, 1);
    final output = await confirm(tester);
    expect((output.width, output.height), (80, 80));
    expect(output.isRed(5, 40), isTrue);
    expect(output.isBlue(75, 40), isTrue);
  });

  testWidgets('rotating turns the photo clockwise', (tester) async {
    await openEditor(tester);
    await tester.tap(find.byKey(const ValueKey('image-editor-rotate')));
    await tester.pumpAndSettle();
    final output = await confirm(tester);
    expect((output.width, output.height), (80, 100));
    // The red left half now sits on top.
    expect(output.isRed(40, 10), isTrue);
    expect(output.isBlue(40, 90), isTrue);
  });

  testWidgets('reset undoes rotation and ratio and disables itself again', (tester) async {
    await openEditor(tester);
    final reset = find.byKey(const ValueKey('image-editor-reset'));
    await tester.tap(find.byKey(const ValueKey('image-editor-rotate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('image-editor-aspect-square')));
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(reset).onPressed, isNotNull);
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(reset).onPressed, isNull);
    expect(geometry(tester).aspect, CropAspect.free);
    final output = await confirm(tester);
    expect((output.width, output.height), (100, 80));
  });

  testWidgets('closing exports nothing and keeps the input', (tester) async {
    await openEditor(tester);
    await tester.tap(find.byKey(const ValueKey('image-editor-rotate')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('image-editor-close')));
    await tester.pumpAndSettle();
    expect(find.text('not-saved'), findsOneWidget);
    expect(AppPaths.files.listSync(), isEmpty);
  });

  group('CropGeometry', () {
    CropGeometry laidOut() =>
        CropGeometry(sourceSize: const Size(100, 80))..layout(const Rect.fromLTWH(0, 0, 300, 400), minFrameSize: 64);

    test('fits the widest frame with the photo just covering it', () {
      final crop = laidOut();
      expect(crop.frame, const Rect.fromLTRB(0, 80, 300, 320));
      expect(crop.scale, 3);
      expect(crop.offset, const Offset(0, 80));
      expect(crop.cropRect(), const Rect.fromLTRB(0, 0, 100, 80));
    });

    test('finds corners first, edges only while the ratio is free', () {
      final crop = laidOut();
      expect(crop.handleAt(const Offset(5, 85), 24), CropHandle.topLeft);
      expect(crop.handleAt(const Offset(150, 90), 24), CropHandle.topEdge);
      expect(crop.handleAt(const Offset(150, 200), 24), isNull);
      crop.selectAspect(CropAspect.square);
      expect(crop.handleAt(Offset(150, crop.frame.top + 5), 24), isNull);
      expect(crop.handleAt(crop.frame.bottomRight, 24), CropHandle.bottomRight);
    });

    test('free resize stays on the photo and above the minimum size', () {
      final crop = laidOut();
      final start = crop.frame;
      crop.resize(CropHandle.leftEdge, start, const Offset(100, 0));
      expect(crop.frame, Rect.fromLTRB(100, start.top, start.right, start.bottom));
      crop.resize(CropHandle.leftEdge, start, const Offset(1000, 0));
      expect(crop.frame.width, 64);
      crop.resize(CropHandle.topLeft, start, const Offset(-50, -50));
      expect(crop.frame, start, reason: 'the frame cannot leave the photo');
    });

    test('a locked ratio keeps its shape and the stronger pull wins', () {
      final crop = laidOut()..selectAspect(CropAspect.square);
      final start = crop.frame;
      expect(start, const Rect.fromLTRB(0, 50, 300, 350));
      crop.resize(CropHandle.bottomRight, start, const Offset(-150, -50));
      expect(crop.frame, const Rect.fromLTRB(0, 50, 250, 300));
    });

    test('springing back keeps the crop and centres the frame', () {
      final crop = laidOut();
      crop.resize(CropHandle.leftEdge, crop.frame, const Offset(150, 0));
      final kept = crop.cropRect();
      expect(kept, const Rect.fromLTRB(50, 0, 100, 80));
      final plan = crop.refit()!;
      expect(plan.factor, closeTo(400 / 240, 1e-9));
      crop.applyRefit(plan, 0.5);
      expect(crop.cropRect(), kept);
      crop.applyRefit(plan, 1);
      expect(crop.frame.center, offsetMoreOrLessEquals(crop.area.center, epsilon: 1e-6));
      expect(crop.frame.height, closeTo(400, 1e-6));
      expect(crop.cropRect(), kept);
      expect(crop.refit(), isNull, reason: 'already in the middle');
    });

    test('pans and zooms are clamped so the frame stays covered', () {
      final crop = laidOut();
      crop.transform(crop.frame.center, const Offset(500, 0), 1);
      expect(crop.offset.dx, crop.frame.left);
      crop.transform(crop.frame.center, Offset.zero, 100);
      expect(crop.scale, crop.maxScale);
      crop.transform(crop.frame.center, Offset.zero, 0.001);
      expect(crop.scale, crop.minScale);
    });

    test('rotation swaps the photo and covers it whole again', () {
      final crop = laidOut()..rotate();
      expect(crop.imageSize, const Size(80, 100));
      expect(crop.cropRect(), const Rect.fromLTRB(0, 0, 80, 100));
      expect(crop.modified, isTrue);
      crop.reset();
      expect(crop.quarterTurns, 0);
      expect(crop.modified, isFalse);
    });
  });
}

class _Output {
  _Output(this.width, this.height, this.rgba);

  final int width;
  final int height;
  final ByteData rgba;

  (int, int, int) _rgb(int x, int y) {
    final i = (y * width + x) * 4;
    return (rgba.getUint8(i), rgba.getUint8(i + 1), rgba.getUint8(i + 2));
  }

  bool isRed(int x, int y) {
    final (r, _, b) = _rgb(x, y);
    return r > 150 && b < 110;
  }

  bool isBlue(int x, int y) {
    final (r, _, b) = _rgb(x, y);
    return b > 150 && r < 110;
  }

  static Future<_Output> read(String path) async {
    final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
    final frame = await codec.getNextFrame();
    final data = (await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final output = _Output(frame.image.width, frame.image.height, data);
    frame.image.dispose();
    codec.dispose();
    return output;
  }
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(() async {
      await tester.pump(const Duration(milliseconds: 50));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    if (finder.evaluate().isNotEmpty) {
      await tester.pumpAndSettle();
      return;
    }
  }
  expect(finder, findsOneWidget);
}

Future<Uint8List> _splitPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, width / 2, height.toDouble()), Paint()..color = const Color(0xFFE53935));
  canvas.drawRect(Rect.fromLTWH(width / 2, 0, width / 2, height.toDouble()), Paint()..color = const Color(0xFF1E64C8));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
  image.dispose();
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

class _EditorHost extends StatefulWidget {
  const _EditorHost({required this.imageUrl});

  final String imageUrl;

  @override
  State<_EditorHost> createState() => _EditorHostState();
}

class _EditorHostState extends State<_EditorHost> {
  String? _savedUrl;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton(
              onPressed: () async {
                final url = await Navigator.of(context).push<String>(
                  MaterialPageRoute(fullscreenDialog: true, builder: (_) => ImageEditorPage(imageUrl: widget.imageUrl)),
                );
                if (mounted) setState(() => _savedUrl = url);
              },
              child: const Text('Open editor'),
            ),
            Text(_savedUrl ?? 'not-saved', key: const ValueKey('saved-url')),
          ],
        ),
      ),
    );
  }
}
