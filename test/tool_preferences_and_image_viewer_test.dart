import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/provider_config.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/data/settings.dart';
import 'package:mewhub/state/settings_store.dart';
import 'package:mewhub/ui/pages/tools_pages.dart';
import 'package:mewhub/ui/widgets/image_viewer.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeSettingsStore store;

  setUp(() {
    store = _FakeSettingsStore(AppSettings.initial());
    I18n.apply(AppLang.zh);
  });

  tearDown(() {
    store.dispose();
  });

  Widget app(Widget page) => ChangeNotifierProvider<SettingsStore>.value(
    value: store,
    child: MaterialApp(home: page),
  );

  testWidgets('translation target language survives reopening the page', (tester) async {
    await tester.pumpWidget(app(const TranslatorPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日本語').last);
    await tester.pumpAndSettle();
    expect(store.value.translateTarget, 'Japanese');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app(const TranslatorPage()));
    await tester.pumpAndSettle();
    expect(
      tester.widget<DropdownButtonFormField<String>>(find.byType(DropdownButtonFormField<String>)).initialValue,
      'Japanese',
    );
  });

  testWidgets('image model and aspect ratio survive reopening the page', (tester) async {
    final imageModel = ModelConfig(
      modelId: 'test-image-gen',
      displayName: 'Test Image Model',
      type: ModelType.image,
      output: const {Modality.image},
    );
    final imageProvider = ProviderConfig(
      kind: ProviderKind.openai,
      name: 'Image Test Provider',
      baseUrl: 'https://example.invalid/v1',
      models: [imageModel],
    );
    store.update((s) => s.copyWith(providers: [...s.providers, imageProvider]));

    await tester.pumpWidget(app(const ImageGenPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('imagegen-model-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListTile, 'Test Image Model'));
    await tester.pumpAndSettle();
    expect(store.value.lastImageGenModelId, imageModel.id);

    await tester.tap(find.byType(DropdownButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('3:2').last);
    await tester.pumpAndSettle();
    expect(store.value.lastImageGenSize, '1536x1024');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app(const ImageGenPage()));
    await tester.pumpAndSettle();
    expect(find.text('Test Image Model'), findsOneWidget);
    expect(tester.widget<DropdownButton<String>>(find.byType(DropdownButton<String>)).value, '1536x1024');
  });

  testWidgets('expanded chat image fits and centers in the viewer viewport', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const dataUri =
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j1S8AAAAASUVORK5CYII=';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: NetworkImageTile(url: dataUri, maxHeight: 160)),
        ),
      ),
    );
    openImageViewer(tester.element(find.byType(NetworkImageTile)), dataUri);
    await tester.pumpAndSettle();

    final imageBox = find.byKey(const ValueKey('image-viewer-image-box'));
    expect(imageBox, findsOneWidget);
    expect(tester.getSize(imageBox), const Size(390, 844));
    expect(find.byType(InteractiveViewer), findsOneWidget);
  });
}

class _FakeSettingsStore extends ChangeNotifier implements SettingsStore {
  _FakeSettingsStore(this._value);

  AppSettings _value;

  @override
  AppSettings get value => _value;

  @override
  void update(AppSettings Function(AppSettings s) fn) {
    _value = fn(_value);
    notifyListeners();
  }

  @override
  void replace(AppSettings settings) => update((_) => settings);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
