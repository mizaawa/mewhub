import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/provider_config.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/state/settings_store.dart';
import 'package:mewhub/ui/settings/provider_detail_page.dart';
import 'package:mewhub/ui/settings/providers_page.dart';
import 'package:mewhub/ui/theme.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late SettingsStore store;
  const urls = {
    ProviderKind.openai: 'https://api.openai.com/v1',
    ProviderKind.anthropic: 'https://api.anthropic.com/v1',
    ProviderKind.google: 'https://generativelanguage.googleapis.com/v1beta',
  };
  const protocols = [
    ('OpenAI Responses', ProviderKind.openai, true),
    ('Anthropic', ProviderKind.anthropic, false),
    ('Gemini', ProviderKind.google, false),
    ('OpenAI Chat', ProviderKind.openai, false),
  ];
  const fixtureProviderId = 'provider-import-fixture';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mewhub_provider_import');
    AppPaths.support = tmp;
    AppPaths.cache = tmp;
    FlutterSecureStorage.setMockInitialValues({});
    store = await SettingsStore.load();
    store.update((s) => s.copyWith(language: AppLang.zh, providers: []));
    await store.flush();
  });

  tearDown(() async {
    await store.flush();
    await tmp.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: store,
        child: MaterialApp(theme: MewTheme.light(0), home: page),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> selectProtocol(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.byType(DropdownButton<String>));
    await tester.tap(find.byType(DropdownButton<String>));
    await tester.runAsync(store.flush);
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.runAsync(store.flush);
    await tester.pumpAndSettle();
  }

  for (final lang in [AppLang.zh, AppLang.en]) {
    testWidgets('creation keeps an import-method menu and opens API key settings: ${lang.name}', (tester) async {
      store.update((s) => s.copyWith(language: lang));
      await tester.runAsync(store.flush);
      await mount(tester, const ProvidersPage());
      final idsBeforeCancel = store.value.providers.map((provider) => provider.id).toSet();
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      final sheet = find.byType(BottomSheet);
      expect(store.value.providers.map((provider) => provider.id).toSet(), idsBeforeCancel);
      Navigator.of(tester.element(sheet)).pop();
      await tester.pumpAndSettle();
      expect(store.value.providers.map((provider) => provider.id).toSet(), idsBeforeCancel);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      final option = lang == AppLang.zh ? '从 API KEY 导入' : 'Import from API key';
      expect(find.text(lang == AppLang.zh ? '选择导入方式' : 'Choose import method'), findsOneWidget);
      expect(find.text(option), findsOneWidget);
      expect(find.text('OpenAI Chat Completions'), findsNothing);
      expect(find.text('Anthropic Messages'), findsNothing);
      expect(find.text('Google Gemini'), findsNothing);
      await tester.tap(find.text(option));
      await tester.pump();
      await tester.runAsync(store.flush);
      await tester.pumpAndSettle();
      expect(find.byType(ProviderDetailPage), findsOneWidget);
      expect(find.widgetWithText(TextField, 'API Key'), findsOneWidget);
      expect(find.byType(DropdownButton<String>), findsOneWidget);
      final detail = tester.widget<ProviderDetailPage>(find.byType(ProviderDetailPage));
      expect(idsBeforeCancel.contains(detail.providerId), isFalse);
      expect(store.value.providers.length, idsBeforeCancel.length + 1);
      final created = store.value.providers.firstWhere((provider) => provider.id == detail.providerId);
      expect(created.kind, ProviderKind.openai);
      expect(created.baseUrl, urls[ProviderKind.openai]);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  for (final initial in ProviderKind.values) {
    testWidgets('default Base URL follows protocol changes from ${initial.name}', (tester) async {
      final provider = ProviderConfig(id: fixtureProviderId, kind: initial, name: 'Fixture', baseUrl: urls[initial]!);
      store.upsertProvider(provider);
      await tester.runAsync(store.flush);
      await mount(tester, ProviderDetailPage(providerId: provider.id));
      for (final (label, kind, responses) in protocols) {
        await selectProtocol(tester, label);
        final current = store.value.providers.firstWhere((provider) => provider.id == fixtureProviderId);
        expect(current.kind, kind);
        expect(current.useResponsesApi, responses);
        expect(current.baseUrl, urls[kind]);
        final field = tester.widget<TextField>(find.widgetWithText(TextField, 'Base URL'));
        expect(field.controller!.text, current.baseUrl);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  for (final custom in ['https://zayuapi.com/v1', 'zayuapi.com', 'https://api.openai.com/v1/proxy']) {
    testWidgets('protocol changes preserve an edited Base URL: $custom', (tester) async {
      final provider = ProviderConfig(
        id: fixtureProviderId,
        kind: ProviderKind.openai,
        name: 'Fixture',
        baseUrl: urls[ProviderKind.openai]!,
      );
      store.upsertProvider(provider);
      await tester.runAsync(store.flush);
      await mount(tester, ProviderDetailPage(providerId: provider.id));
      await tester.enterText(find.widgetWithText(TextField, 'Base URL'), custom);
      // Keep the edit focused and unsubmitted while changing the protocol.
      tester.widget<DropdownButton<String>>(find.byType(DropdownButton<String>)).onChanged!('anthropic');
      await tester.runAsync(store.flush);
      await tester.pumpAndSettle();
      final afterFocusedSwitch = store.value.providers.firstWhere((provider) => provider.id == fixtureProviderId);
      expect(afterFocusedSwitch.kind, ProviderKind.anthropic);
      expect(afterFocusedSwitch.baseUrl, custom);
      for (final (label, kind, responses) in protocols) {
        await selectProtocol(tester, label);
        final current = store.value.providers.firstWhere((provider) => provider.id == fixtureProviderId);
        expect(current.kind, kind);
        expect(current.useResponsesApi, responses);
        expect(current.baseUrl, custom);
        final field = tester.widget<TextField>(find.widgetWithText(TextField, 'Base URL'));
        expect(field.controller!.text, current.baseUrl);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}
