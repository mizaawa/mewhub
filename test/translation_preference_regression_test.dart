import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/data/settings.dart';
import 'package:mewhub/state/settings_store.dart';
import 'package:mewhub/ui/pages/tools_pages.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _MemorySettingsStore store;

  setUp(() {
    store = _MemorySettingsStore(AppSettings.initial());
    I18n.apply(AppLang.zh);
  });

  tearDown(() => store.dispose());

  testWidgets('translation target persists after closing and reopening the tool', (tester) async {
    Widget host() => ChangeNotifierProvider<SettingsStore>.value(
      value: store,
      child: const MaterialApp(home: TranslatorPage()),
    );

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('日本語').last);
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(
      tester.widget<DropdownButtonFormField<String>>(find.byType(DropdownButtonFormField<String>)).initialValue,
      'Japanese',
    );
  });
}

class _MemorySettingsStore extends ChangeNotifier implements SettingsStore {
  _MemorySettingsStore(this._value);
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
