import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/core/net.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/data/provider_branding.dart';
import 'package:mewhub/state/settings_store.dart';
import 'package:mewhub/ui/settings/provider_detail_page.dart';
import 'package:mewhub/ui/settings/providers_page.dart';
import 'package:mewhub/ui/settings/settings_page.dart';
import 'package:mewhub/ui/theme.dart';
import 'package:mewhub/ui/widgets/provider_logo.dart';
import 'package:provider/provider.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late SettingsStore store;
  final launches = <MethodCall>[];
  const launcher = MethodChannel('plugins.flutter.io/url_launcher');

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mewhub_providers');
    AppPaths.support = tmp;
    AppPaths.cache = tmp;
    FlutterSecureStorage.setMockInitialValues({});
    store = await SettingsStore.load();
    I18n.apply(AppLang.zh);
    launches.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(launcher, (call) async {
      launches.add(call);
      return true;
    });
  });

  tearDown(() async {
    await store.flush();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(launcher, null);
    await tmp.delete(recursive: true);
  });

  Widget app(Widget page, {bool dark = false}) => ChangeNotifierProvider.value(
    value: store,
    child: MaterialApp(theme: dark ? MewTheme.dark(0) : MewTheme.light(0), home: page),
  );

  for (final dark in [false, true]) {
    testWidgets('Zako stays first while other providers reorder; dark=$dark', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(const ProvidersPage(), dark: dark));
      await tester.pumpAndSettle();
      expect(find.text('Zako AI'), findsOneWidget);
      expect(find.text('官方'), findsOneWidget);
      expect(find.text('始终启用'), findsNothing);
      expect(tester.getTopLeft(find.text('Zako AI')).dy, lessThan(tester.getTopLeft(find.text('OpenAI')).dy));
      expect(find.byType(ProviderLogo), findsWidgets);
      final logo = tester.widget<ProviderLogo>(find.byType(ProviderLogo).first);
      final logoClip = tester.widget<ClipRRect>(
        find.descendant(of: find.byWidget(logo), matching: find.byType(ClipRRect)),
      );
      expect(logoClip.borderRadius, BorderRadius.circular(logo.size * 0.2));
      final list = tester.widget<ReorderableListView>(find.byType(ReorderableListView));
      list.onReorderItem!(0, 1);
      await tester.runAsync(store.flush);
      await tester.pumpAndSettle();
      expect(store.value.providers.first.id, zakoProviderId);
      expect(store.value.providers[1].name, 'Anthropic');
      expect(store.value.providers[2].name, 'OpenAI');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('Zako top button uses the theme and opens the official website; dark=$dark', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(app(const ProviderDetailPage(providerId: zakoProviderId), dark: dark));
      await tester.pumpAndSettle();
      expect(find.text('前往 Zako AI'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
      expect(find.text('始终启用'), findsNothing);
      expect(find.text('官方供应商无法停用'), findsNothing);
      expect(find.widgetWithText(SwitchListTile, '启用'), findsNothing);
      expect(tester.getTopLeft(find.text('前往 Zako AI')).dy, lessThan(tester.getTopLeft(find.text('基本')).dy));
      expect(find.text(zakoBaseUrl), findsOneWidget);
      await tester.tap(find.text('前往 Zako AI'));
      await tester.pumpAndSettle();
      expect(launches.single.method, 'launch');
      final args = launches.single.arguments as Map;
      expect(args['url'], zakoWebsite);
      expect(args['useWebView'], isFalse);
      expect(args['useSafariVC'], isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }

  testWidgets('settings opens directly with appearance and retains provider navigation', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(const SettingsPage()));
    await tester.pumpAndSettle();
    expect(find.text('MewHub'), findsNothing);
    expect(find.text('外观'), findsOneWidget);
    expect(find.text('供应商'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('enabling another provider moves it above disabled providers but below Zako', (tester) async {
    await tester.pumpWidget(app(const ProvidersPage()));
    await tester.pumpAndSettle();
    Finder geminiSwitch() => find.descendant(
      of: find.ancestor(of: find.text('Gemini'), matching: find.byType(AnimatedContainer)).first,
      matching: find.byType(Switch),
    );
    await tester.tap(geminiSwitch());
    await tester.runAsync(store.flush);
    await tester.pumpAndSettle();
    expect(store.value.providers.take(2).map((p) => p.id), [zakoProviderId, 'p-gemini']);
    expect(tester.getTopLeft(find.text('Zako AI')).dy, lessThan(tester.getTopLeft(find.text('Gemini')).dy));
    expect(tester.getTopLeft(find.text('Gemini')).dy, lessThan(tester.getTopLeft(find.text('OpenAI')).dy));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  test('store rejects disabling or deleting Zako and persists the locked configuration', () async {
    final p = store.value.providers.first.copyWith(apiKey: 'fixture-key', enabled: false);
    store.upsertProvider(p);
    expect(store.value.providers.first.enabled, isTrue);
    store.removeProvider(zakoProviderId);
    expect(store.value.providers.first.id, zakoProviderId);
    expect(store.value.providers.first.apiKey, 'fixture-key');
    store.update((s) => s.copyWith(providers: s.providers.reversed.toList()));
    expect(store.value.providers.first.id, zakoProviderId);
    await store.flush();
    final reloaded = await SettingsStore.load();
    expect(reloaded.value.providers.first.id, zakoProviderId);
    expect(reloaded.value.providers.first.enabled, isTrue);
    expect(reloaded.value.providers.first.apiKey, 'fixture-key');
    store.removeProvider('p-openai');
    expect(store.value.providers.any((p) => p.id == 'p-openai'), isFalse);
    await store.flush();
  });

  testWidgets('balance button requests /usage with the configured key and displays the response', (tester) async {
    final requests = <(String, String?)>[];
    final server = await tester.runAsync(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        requests.add((req.uri.path, req.headers.value('Authorization')));
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"remaining":12.5}');
        await req.response.close();
      });
      return server;
    });
    addTearDown(() => server!.close(force: true));
    // Only the API client uses a real loopback connection; site icons retain
    // Flutter's offline HTTP stub, so this test never contacts an external site.
    HttpOverrides.runWithHttpOverrides(Net.reconfigure, _LoopbackHttpOverrides());
    store.upsertProvider(
      store.value.providers.first.copyWith(baseUrl: 'http://127.0.0.1:${server!.port}', apiKey: 'fixture-key'),
    );
    await tester.runAsync(store.flush);
    I18n.apply(AppLang.zh);
    await tester.pumpWidget(app(const ProviderDetailPage(providerId: zakoProviderId)));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('查询余额'), 300, scrollable: find.byType(Scrollable).first);
    final tile = tester.widget<ListTile>(find.widgetWithText(ListTile, '查询余额'));
    await tester.runAsync(() async {
      await (tile.onTap! as Future<void> Function())().timeout(const Duration(seconds: 10));
      await store.flush();
    });
    await tester.pumpAndSettle();
    expect(requests, [('/usage', 'Bearer fixture-key')]);
    expect(find.text('{"remaining":12.5}'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
