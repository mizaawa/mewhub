import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/ui/chat/image_editor.dart';

void main() {
  late Directory sandbox;
  late String sourceUri;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('mewhub_image_editor_');
    AppPaths.support = sandbox;
    AppPaths.cache = sandbox;
    await AppPaths.files.create(recursive: true);
    final bytes = await _solidPng(100, 80, const Color(0xFF3366CC));
    sourceUri = 'data:image/png;base64,${base64Encode(bytes)}';
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  testWidgets('crop, rotate, draw and confirm exports the edited image', (tester) async {
    await tester.pumpWidget(MaterialApp(home: _EditorHost(imageUrl: sourceUri)));
    final canvas = find.byKey(const ValueKey('image-editor-canvas'));
    await tester.tap(find.text('Open editor'));
    await _waitFor(tester, canvas);
    expect(canvas, findsOneWidget);

    await tester.tap(find.byIcon(Icons.crop_rounded));
    await tester.pump();
    final canvasRect = tester.getRect(canvas);
    final cropStart = canvasRect.topLeft + Offset(canvasRect.width * 0.1, canvasRect.height * 0.1);
    final cropEnd = canvasRect.topLeft + Offset(canvasRect.width * 0.9, canvasRect.height * 0.9);
    final cropGesture = await tester.startGesture(cropStart);
    await cropGesture.moveTo(cropEnd);
    await cropGesture.up();
    await tester.pump();

    await tester.tap(find.byIcon(Icons.rotate_right_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.brush_rounded));
    await tester.pump();

    final rotatedRect = tester.getRect(canvas);
    final markStart = rotatedRect.topLeft + Offset(rotatedRect.width * 0.2, rotatedRect.height * 0.5);
    final markEnd = rotatedRect.topLeft + Offset(rotatedRect.width * 0.8, rotatedRect.height * 0.5);
    final markGesture = await tester.startGesture(markStart);
    await markGesture.moveTo(markEnd);
    await markGesture.up();
    await tester.pump();

    await tester.runAsync(() => tester.tap(find.text('确认')));
    await _waitFor(tester, find.text('Open editor'));
    expect(find.text('Open editor'), findsOneWidget);

    final saved = tester.widget<Text>(find.byKey(const ValueKey('saved-url'))).data;
    expect(saved, isNotNull);
    final output = await tester.runAsync(() async {
      final file = File(AppPaths.resolve(saved!));
      final exists = await file.exists();
      final codec = await ui.instantiateImageCodec(await file.readAsBytes());
      final frame = await codec.getNextFrame();
      final rgba = (await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final center = (40 * frame.image.width + 32) * 4;
      final result = (
        exists: exists,
        width: frame.image.width,
        height: frame.image.height,
        red: rgba.getUint8(center),
        green: rgba.getUint8(center + 1),
      );
      frame.image.dispose();
      codec.dispose();
      return result;
    });
    expect(output?.exists, isTrue);
    expect(output?.width, inInclusiveRange(64, 65));
    expect(output?.height, 80);
    expect(output!.red, greaterThan(100));
    expect(output.red, greaterThan(output.green));
  });

  testWidgets('cancel exports nothing and preserves the input', (tester) async {
    await tester.pumpWidget(MaterialApp(home: _EditorHost(imageUrl: sourceUri)));
    await tester.tap(find.text('Open editor'));
    await _waitFor(tester, find.byKey(const ValueKey('image-editor-canvas')));
    await tester.tap(find.byIcon(Icons.rotate_right_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_back_rounded));
    await tester.pumpAndSettle();
    expect(find.text('not-saved'), findsOneWidget);
    expect(AppPaths.files.listSync(), isEmpty);
  });
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

Future<Uint8List> _solidPng(int width, int height, Color color) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = color);
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
                final url = await Navigator.of(context)
                    .push<String>(MaterialPageRoute(builder: (_) => ImageEditorPage(imageUrl: widget.imageUrl)));
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
