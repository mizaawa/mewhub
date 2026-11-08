import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/ai/provider_config.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/data/settings.dart';
import 'package:mewhub/ui/chat/composer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory sandbox;
  late File source;
  final sent = <List<Part>>[];
  var gallerySelections = 0;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('mewhub_camera_composer_');
    AppPaths.support = sandbox;
    AppPaths.cache = sandbox;
    await AppPaths.files.create();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(const Rect.fromLTWH(0, 0, 100, 80), Paint()..color = Colors.blue);
    final picture = recorder.endRecording();
    final image = await picture.toImage(100, 80);
    final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
    source = File('${sandbox.path}/camera.png');
    await source.writeAsBytes(png.buffer.asUint8List());
    image.dispose();
    picture.dispose();
    sent.clear();
    gallerySelections = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/image_picker'),
      (call) async {
        if (call.method == 'pickImage') {
          expect((call.arguments as Map)['source'], 0);
          return source.path;
        }
        expect(call.method, 'pickMultiImage');
        gallerySelections++;
        expect((call.arguments as Map)['limit'], 9);
        return [source.path, source.path];
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugin.csdcorp.com/speech_to_text'),
      (_) async => null,
    );
  });

  tearDown(() async {
    for (final name in ['plugins.flutter.io/image_picker', 'plugin.csdcorp.com/speech_to_text']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        MethodChannel(name),
        null,
      );
    }
    await sandbox.delete(recursive: true);
  });

  Future<void> showComposer(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: Composer(
              settings: AppSettings(currentAssistantId: 'test'),
              generating: false,
              onSend: (parts) async => sent.add(parts),
              onStop: () {},
              modelLabel: 'Vision',
              onPickModel: () {},
              searchEnabled: false,
              onToggleSearch: () {},
              reasoning: ReasoningLevel.off,
              onReasoning: (_) {},
              supportsReasoning: false,
              supportsVision: true,
              onCompress: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> capture(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('拍照')));
    await _waitUntil(tester, () => find.text('编辑图片').evaluate().isNotEmpty);
  }

  Future<void> chooseGallery(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('相册')));
    await _waitUntil(tester, () => find.byKey(const ValueKey('composer-photo-editor-0')).evaluate().isNotEmpty);
  }

  Future<void> confirmPhoto(WidgetTester tester) async {
    await tester.runAsync(() => tester.tap(find.text('确认')));
    await tester.pump();
  }

  testWidgets('camera waits for confirmation and sends the edited file', (tester) async {
    await showComposer(tester);
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    final plus = find.byIcon(Icons.add_rounded);
    expect(plus, findsOneWidget);
    expect(
      tester.widget<AnimatedRotation>(find.ancestor(of: plus, matching: find.byType(AnimatedRotation))).turns,
      0.125,
    );
    await tester.tap(plus);
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedRotation>(find.ancestor(of: plus, matching: find.byType(AnimatedRotation))).turns, 0);
    await tester.enterText(find.byType(TextField), 'draft');
    await capture(tester);
    expect(sent, isEmpty);
    expect(
      find.descendant(
        of: find.byType(Composer, skipOffstage: false),
        matching: find.byType(Image, skipOffstage: false),
      ),
      findsNothing,
    );
    await tester.tap(find.byIcon(Icons.rotate_right_rounded));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('确认')));
    await _waitUntil(
      tester,
      () =>
          find.byType(Composer).evaluate().isNotEmpty &&
          find
              .descendant(of: find.byType(Composer), matching: find.byType(CircularProgressIndicator))
              .evaluate()
              .isEmpty,
    );
    expect(sent, isEmpty);
    expect(find.descendant(of: find.byType(Composer), matching: find.byType(Image)), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'draft');
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();
    expect(sent, hasLength(1));
    final part = sent.single.whereType<ImagePart>().single;
    final result = await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(await File(AppPaths.resolve(part.url)).readAsBytes());
      final frame = await codec.getNextFrame();
      final size = Size(frame.image.width.toDouble(), frame.image.height.toDouble());
      frame.image.dispose();
      codec.dispose();
      return size;
    });
    expect(result, const Size(80, 100));
    expect(AppPaths.files.listSync(), hasLength(1));
    expect(source.existsSync(), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancelling photo editing keeps the draft and removes the temporary attachment', (tester) async {
    await showComposer(tester);
    await tester.enterText(find.byType(TextField), 'draft');
    await capture(tester);
    await tester.runAsync(() => tester.tap(find.byIcon(Icons.arrow_back_rounded)));
    await _waitUntil(tester, () => find.byType(Composer).evaluate().isNotEmpty && AppPaths.files.listSync().isEmpty);
    expect(sent, isEmpty);
    expect(find.descendant(of: find.byType(Composer), matching: find.byType(Image)), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'draft');
    expect(source.existsSync(), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('gallery photos are edited individually before entering the composer', (tester) async {
    await showComposer(tester);
    await tester.enterText(find.byType(TextField), 'draft');
    await chooseGallery(tester);

    expect(gallerySelections, 1);
    expect(sent, isEmpty);
    expect(find.byKey(const ValueKey('composer-photo-editor-1')), findsNothing);
    await confirmPhoto(tester);
    await _waitUntil(tester, () => find.byKey(const ValueKey('composer-photo-editor-1')).evaluate().isNotEmpty);
    expect(find.byKey(const ValueKey('composer-photo-editor-1')), findsOneWidget);
    expect(find.descendant(of: find.byType(Composer, skipOffstage: false), matching: find.byType(Image)), findsNothing);

    await confirmPhoto(tester);
    await _waitUntil(
      tester,
      () =>
          find.byType(Composer).evaluate().isNotEmpty &&
          find
              .descendant(of: find.byType(Composer), matching: find.byType(CircularProgressIndicator))
              .evaluate()
              .isEmpty,
    );
    expect(sent, isEmpty);
    expect(find.descendant(of: find.byType(Composer), matching: find.byType(Image)), findsNWidgets(2));
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'draft');
    expect(AppPaths.files.listSync(), hasLength(2));

    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();
    expect(sent, hasLength(1));
    expect(sent.single.whereType<ImagePart>(), hasLength(2));
    expect(AppPaths.files.listSync(), hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancelling a later gallery edit keeps confirmed photos and cleans picked originals', (tester) async {
    await showComposer(tester);
    await chooseGallery(tester);
    await confirmPhoto(tester);
    await _waitUntil(tester, () => find.byKey(const ValueKey('composer-photo-editor-1')).evaluate().isNotEmpty);
    await tester.runAsync(() => tester.tap(find.byIcon(Icons.arrow_back_rounded)));
    await _waitUntil(
      tester,
      () =>
          find.byType(Composer).evaluate().isNotEmpty &&
          find
              .descendant(of: find.byType(Composer), matching: find.byType(CircularProgressIndicator))
              .evaluate()
              .isEmpty,
    );
    expect(sent, isEmpty);
    expect(find.descendant(of: find.byType(Composer), matching: find.byType(Image)), findsOneWidget);
    expect(AppPaths.files.listSync(), hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });
}

Future<void> _waitUntil(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200; i++) {
    await tester.runAsync(() async {
      await tester.pump(const Duration(milliseconds: 50));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    if (ready()) {
      await tester.pumpAndSettle();
      return;
    }
  }
  expect(ready(), isTrue, reason: 'Camera/editor operation did not finish');
}
