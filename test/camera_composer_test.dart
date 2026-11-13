import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/ai/provider_config.dart';
import 'package:mewhub/core/attachments.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/data/settings.dart';
import 'package:mewhub/tools/cartesian_plot.dart';
import 'package:mewhub/ui/chat/composer.dart';
import 'package:mewhub/ui/widgets/cartesian_plot_view.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory sandbox;
  late File source;
  final sent = <List<Part>>[];
  var gallerySelections = 0;
  var cameraAccessDenied = false;

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
    cameraAccessDenied = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/image_picker'),
      (call) async {
        if (call.method == 'retrieve') return null;
        if (call.method == 'pickImage') {
          expect((call.arguments as Map)['source'], 0);
          if (cameraAccessDenied) {
            throw PlatformException(code: 'camera_access_denied', message: 'The user did not allow camera access.');
          }
          return source.path;
        }
        expect(call.method, 'pickMultiImage');
        gallerySelections++;
        expect((call.arguments as Map)['limit'], 9);
        return [source.path, source.path];
      },
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/image_picker'),
      null,
    );
    await sandbox.delete(recursive: true);
  });

  Future<void> showComposer(WidgetTester tester, {bool plotEnabled = false}) async {
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
              plotEnabled: plotEnabled,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The editor is ready once the photo is decoded and its canvas is shown.
  bool editorReady() => find.byKey(const ValueKey('image-editor-canvas')).evaluate().isNotEmpty;

  Future<void> capture(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('拍照')));
    await _waitUntil(tester, editorReady);
  }

  Future<void> chooseGallery(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('相册')));
    await _waitUntil(
      tester,
      () => find.byKey(const ValueKey('composer-photo-editor-0')).evaluate().isNotEmpty && editorReady(),
    );
  }

  test('Android photo picking uses the modern, backwards-compatible contract', () {
    final original = ImagePickerPlatform.instance;
    final android = ImagePickerAndroid();
    try {
      ImagePickerPlatform.instance = android;
      configureAndroidImagePicker();
      expect(android.useAndroidPhotoPicker, isTrue);
    } finally {
      ImagePickerPlatform.instance = original;
    }
  });

  test('restores interrupted chat photo selections after Android restarts the app', () async {
    final marker = File('${sandbox.path}/.pending_chat_image_picker');
    await marker.writeAsString('pending');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/image_picker'),
      (call) async {
        expect(call.method, 'retrieve');
        return {
          'type': 'image',
          'path': source.path,
          'pathList': [source.path],
        };
      },
    );

    expect(await Attachments.recoverLostChatPhotos(), 1);
    expect(await marker.exists(), isFalse);
    final recovered = Attachments.takeRecoveredChatPhotos();
    expect(recovered, hasLength(1));
    expect(await File(AppPaths.resolve(recovered.single.url)).exists(), isTrue);
    expect(Attachments.takeRecoveredChatPhotos(), isEmpty);
  });

  test('recovery keeps readable images when another recovered file disappeared', () async {
    final marker = File('${sandbox.path}/.pending_chat_image_picker');
    await marker.writeAsString('pending');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/image_picker'),
      (call) async => {
        'type': 'image',
        'path': source.path,
        'pathList': ['${sandbox.path}/missing.jpg', source.path],
      },
    );
    expect(await Attachments.recoverLostChatPhotos(), 1);
    expect(Attachments.takeRecoveredChatPhotos(), hasLength(1));
    expect(await Attachments.recoverLostChatPhotos(), 0);
  });

  Future<void> confirmPhoto(WidgetTester tester) async {
    await _waitUntil(tester, editorReady);
    await tester.runAsync(() => tester.tap(find.byKey(const ValueKey('image-editor-confirm'))));
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
    await tester.tap(find.byKey(const ValueKey('image-editor-rotate')));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.byKey(const ValueKey('image-editor-confirm'))));
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

  testWidgets('camera permission denial explains how to restore access', (tester) async {
    cameraAccessDenied = true;
    await showComposer(tester);
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(find.text('拍照')));
    await _waitUntil(tester, () => find.text('相机权限被拒绝。请在系统设置的 MewHub 权限中允许相机，然后重试。').evaluate().isNotEmpty);

    expect(find.text('相机权限被拒绝。请在系统设置的 MewHub 权限中允许相机，然后重试。'), findsOneWidget);
    expect(find.byType(Composer), findsOneWidget);
    expect(sent, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('coordinate editor attaches a real PNG with editable metadata before sending', (tester) async {
    await showComposer(tester, plotEnabled: true);
    await tester.tap(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('composer-plot-entry')));
    await tester.pumpAndSettle();
    expect(find.byType(CartesianPlotPage), findsOneWidget);
    await tester.runAsync(() => tester.tap(find.byKey(const ValueKey('cartesian-attach'))));
    await _waitUntil(tester, () => find.byType(Composer).evaluate().isNotEmpty);
    expect(sent, isEmpty);
    expect(find.descendant(of: find.byType(Composer), matching: find.byType(Image)), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();
    expect(sent, hasLength(1));
    final part = sent.single.whereType<ImagePart>().single;
    final restored = Part.fromJson(jsonDecode(jsonEncode(part.toJson())) as Map<String, dynamic>)! as ImagePart;
    final plot = CartesianPlot.fromJson(restored.meta!['cartesian_plot'] as Map<String, dynamic>);
    expect(plot.functions, CartesianPlot.example().functions);
    final bytes = await tester.runAsync(() => File(AppPaths.resolve(restored.url)).readAsBytes());
    expect(bytes!.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cancelling photo editing keeps the draft and removes the temporary attachment', (tester) async {
    await showComposer(tester);
    await tester.enterText(find.byType(TextField), 'draft');
    await capture(tester);
    await tester.runAsync(() => tester.tap(find.byKey(const ValueKey('image-editor-close'))));
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
    await tester.runAsync(() => tester.tap(find.byKey(const ValueKey('image-editor-close'))));
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
