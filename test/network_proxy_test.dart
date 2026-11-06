import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/core/net.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/data/proxy_config.dart';
import 'package:mewhub/data/settings.dart';
import 'package:mewhub/state/settings_store.dart';
import 'package:mewhub/ui/pages/misc_settings.dart';
import 'package:mewhub/ui/settings/provider_detail_page.dart';
import 'package:mewhub/ui/theme.dart';
import 'package:provider/provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    NetConfig.proxy = '';
    NetConfig.providerProxies = {};
    Net.reconfigure();
  });

  group('ProxyEndpoint', () {
    test('accepts HTTP URLs, SOCKS5 URLs, and legacy host:port without exposing credentials', () {
      final http = ProxyEndpoint.parse('user:p%40ss@proxy.example:8080');
      final socks = ProxyEndpoint.parse('socks5://user:pass@127.0.0.1:1080');
      final legacy = ProxyEndpoint.parse('127.0.0.1:7890');

      expect(http.protocol, ProxyProtocol.http);
      expect(http.username, 'user');
      expect(http.password, 'p@ss');
      expect(socks.protocol, ProxyProtocol.socks5);
      expect(socks.node, '127.0.0.1:1080');
      expect(legacy.port, 7890);
      expect(ProxyConfig(name: '', url: 'socks5://127.0.0.1:1080').displayName, '127.0.0.1:1080');
    });

    test('rejects unsupported schemes and proxy paths', () {
      expect(() => ProxyEndpoint.parse('ftp://proxy.example:21'), throwsFormatException);
      expect(() => ProxyEndpoint.parse('http://proxy.example:8080/path'), throwsFormatException);
    });
  });

  test('provider proxy selection round-trips with settings', () {
    final initial = AppSettings.initial();
    final proxy = ProxyConfig(id: 'proxy-1', name: 'Tokyo', url: 'socks5://127.0.0.1:1080');
    final provider = initial.providers.first.copyWith(proxyId: proxy.id);
    final settings = initial.copyWith(proxies: [proxy], defaultProxyId: proxy.id, providers: [provider]);
    final restored = AppSettings.fromJson(jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>);

    expect(restored.defaultProxyId, proxy.id);
    expect(restored.proxies.single.url, proxy.url);
    expect(restored.providers.single.proxyId, proxy.id);
  });

  test('provider requests use their assigned HTTP proxy and other requests use the default', () async {
    await _realHttp(() async {
      final defaultProxy = await _FakeHttpProxy.start('default');
      final providerProxy = await _FakeHttpProxy.start('provider');
      addTearDown(defaultProxy.close);
      addTearDown(providerProxy.close);
      NetConfig.proxy = defaultProxy.url;
      NetConfig.providerProxies = {'p1': providerProxy.url};
      Net.reconfigure();

      expect(await Net.text('GET', Uri.parse('http://target.invalid/default'), log: false), 'default');
      expect(
        await Net.text('GET', Uri.parse('http://target.invalid/provider'), providerId: 'p1', log: false),
        'provider',
      );
      expect(defaultProxy.paths, ['/default']);
      expect(providerProxy.paths, ['/provider']);
    });
  });

  test('HTTP proxy authentication respects the proxy challenge realm', () async {
    await _realHttp(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final authHeaders = <String?>[];
      server.listen((request) async {
        final authorization = request.headers.value(HttpHeaders.proxyAuthorizationHeader);
        authHeaders.add(authorization);
        if (authorization == 'Basic ${base64Encode(utf8.encode('proxy-user:proxy-pass'))}') {
          request.response.write('authenticated');
        } else {
          request.response.statusCode = HttpStatus.proxyAuthenticationRequired;
          request.response.headers.set(HttpHeaders.proxyAuthenticateHeader, 'Basic realm="fixture"');
        }
        await request.response.close();
      });
      addTearDown(() => server.close(force: true));
      NetConfig.proxy = 'http://proxy-user:proxy-pass@127.0.0.1:${server.port}';
      Net.reconfigure();

      expect(await Net.text('GET', Uri.parse('http://target.invalid/auth'), log: false), 'authenticated');
      expect(authHeaders, [null, 'Basic ${base64Encode(utf8.encode('proxy-user:proxy-pass'))}']);
    });
  });

  test('SOCKS5 client tunnels an HTTP request through the selected proxy', () async {
    await _realHttp(() async {
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      target.listen((request) async {
        request.response.write('through-socks');
        await request.response.close();
      });
      addTearDown(() => target.close(force: true));

      final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <String>[];
      proxy.listen((client) async {
        try {
          final reader = _SocketBuffer(client);
          final greeting = await reader.readBytes(2);
          await reader.readBytes(greeting[1]);
          client.add([5, 0]);
          await client.flush();

          final header = await reader.readBytes(4);
          final host = switch (header[3]) {
            1 => InternetAddress.fromRawAddress(Uint8List.fromList(await reader.readBytes(4))).address,
            4 => InternetAddress.fromRawAddress(Uint8List.fromList(await reader.readBytes(16))).address,
            3 => utf8.decode(await reader.readBytes((await reader.readBytes(1)).single)),
            _ => throw StateError('Unexpected SOCKS address type ${header[3]}'),
          };
          final portBytes = await reader.readBytes(2);
          final port = portBytes[0] * 256 + portBytes[1];
          requests.add('$host:$port');
          final upstream = await Socket.connect(host, port);
          client.add([5, 0, 0, 1, 127, 0, 0, 1, 0, 0]);
          await client.flush();
          reader.forwardTo(upstream);
          upstream.listen(client.add, onError: (Object _, StackTrace _) => client.destroy(), onDone: client.close);
        } catch (_) {
          client.destroy();
        }
      });
      addTearDown(() => proxy.close());
      NetConfig.proxy = 'socks5://127.0.0.1:${proxy.port}';
      Net.reconfigure();

      final body = await Net.text('GET', Uri.parse('http://127.0.0.1:${target.port}/hello'), log: false);
      expect(body, 'through-socks');
      expect(requests, ['127.0.0.1:${target.port}']);
    });
  });

  test('proxy probe measures a successful HTTP CONNECT tunnel', () async {
    final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <String>[];
    proxy.listen((socket) async {
      final lines = socket.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter());
      requests.add(await lines.first);
      socket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      await socket.flush();
    });
    addTearDown(() => proxy.close());

    final elapsed = await Net.probeProxy('http://127.0.0.1:${proxy.port}', timeout: const Duration(seconds: 2));
    expect(elapsed.inMicroseconds, greaterThanOrEqualTo(0));
    expect(requests, ['CONNECT example.com:443 HTTP/1.1']);
  });

  test('authenticated SOCKS5 proxy tunnels HTTPS with certificate verification', () async {
    await _realHttp(() async {
      const certificate = 'test/fixtures/proxy_tls/cert.pem';
      SecurityContext.defaultContext.setTrustedCertificates(certificate);
      final context = SecurityContext()
        ..useCertificateChain(certificate)
        ..usePrivateKey('test/fixtures/proxy_tls/key.pem');
      final target = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
      target.listen((request) async {
        request.response.write('authenticated-https');
        await request.response.close();
      });
      addTearDown(() => target.close(force: true));
      final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final credentials = <String>[];
      final destinations = <String>[];
      proxy.listen((client) async {
        try {
          final reader = _SocketBuffer(client);
          final greeting = await reader.readBytes(2);
          await reader.readBytes(greeting[1]);
          client.add([5, 2]);
          await client.flush();
          final auth = await reader.readBytes(2);
          final username = utf8.decode(await reader.readBytes(auth[1]));
          final password = utf8.decode(await reader.readBytes((await reader.readBytes(1)).single));
          credentials.add('$username:$password');
          client.add([1, 0]);
          await client.flush();
          final header = await reader.readBytes(4);
          final host = switch (header[3]) {
            1 => InternetAddress.fromRawAddress(Uint8List.fromList(await reader.readBytes(4))).address,
            3 => utf8.decode(await reader.readBytes((await reader.readBytes(1)).single)),
            _ => throw StateError('Unexpected address type'),
          };
          final port = await reader.readBytes(2);
          destinations.add('$host:${port[0] * 256 + port[1]}');
          final upstream = await Socket.connect(InternetAddress.loopbackIPv4, target.port);
          client.add([5, 0, 0, 1, 127, 0, 0, 1, 0, 0]);
          await client.flush();
          reader.forwardTo(upstream);
          upstream.listen(client.add, onError: (Object _, StackTrace _) => client.destroy(), onDone: client.close);
        } catch (_) {
          client.destroy();
        }
      });
      addTearDown(() => proxy.close());
      NetConfig.providerProxies = {'tls-provider': 'socks5://user:p%40ss@127.0.0.1:${proxy.port}'};
      Net.reconfigure();
      final body = await Net.text(
        'GET',
        Uri.parse('https://localhost:${target.port}/models'),
        providerId: 'tls-provider',
        log: false,
      ).timeout(const Duration(seconds: 10));
      expect(body, 'authenticated-https');
      expect(credentials, ['user:p@ss']);
      expect(destinations, ['localhost:${target.port}']);
    });
  });

  group('proxy settings UI', () {
    late Directory temp;
    late SettingsStore store;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('mewhub_proxy_test');
      AppPaths.support = temp;
      AppPaths.cache = temp;
      FlutterSecureStorage.setMockInitialValues({});
      store = await SettingsStore.load();
      store.update((settings) => settings.copyWith(language: AppLang.zh));
      await store.flush();
      I18n.apply(AppLang.zh);
    });

    tearDown(() async {
      await temp.delete(recursive: true);
    });

    Widget app(Widget page, {bool dark = false}) => ChangeNotifierProvider.value(
      value: store,
      child: MaterialApp(
        theme: dark ? MewTheme.dark(0) : MewTheme.light(0),
        home: page,
        routes: {'/settings/network/proxies': (_) => const ProxyManagerPage()},
      ),
    );

    for (final dark in [false, true]) {
      testWidgets('proxy list supports add, default, rename, and delete; dark=$dark', (tester) async {
        await tester.pumpWidget(app(const ProxyManagerPage(), dark: dark));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('添加代理'));
        await tester.pumpAndSettle();
        await tester.enterText(find.widgetWithText(TextFormField, '代理地址'), 'socks5://127.0.0.1:1080');
        await tester.tap(find.text('保存'));
        await tester.runAsync(store.flush);
        await tester.pumpAndSettle();
        expect(store.value.proxies.single.displayName, '127.0.0.1:1080');
        await tester.tap(find.text('127.0.0.1:1080'));
        await tester.runAsync(store.flush);
        await tester.pumpAndSettle();
        expect(store.value.defaultProxyId, store.value.proxies.single.id);
        final badge = tester.widget<Container>(
          find.ancestor(of: find.text('默认'), matching: find.byType(Container)).first,
        );
        final theme = Theme.of(tester.element(find.text('默认')));
        expect((badge.decoration! as BoxDecoration).color, theme.colorScheme.primaryContainer);
        await tester.tap(find.byTooltip('管理代理'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('编辑'));
        await tester.pumpAndSettle();
        await tester.enterText(find.widgetWithText(TextFormField, '名称（可选）'), 'Tokyo');
        await tester.tap(find.text('保存'));
        await tester.runAsync(store.flush);
        await tester.pumpAndSettle();
        expect(find.text('Tokyo'), findsOneWidget);
        final proxyId = store.value.proxies.single.id;
        await tester.runAsync(() async {
          store.upsertProvider(store.value.providers.first.copyWith(proxyId: proxyId));
          await store.flush();
        });
        await tester.pump();
        await tester.tap(find.byTooltip('管理代理'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('删除'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, '确定'));
        await tester.runAsync(store.flush);
        await tester.pumpAndSettle();
        expect(store.value.proxies, isEmpty);
        expect(store.value.defaultProxyId, isEmpty);
        expect(store.value.providers.first.proxyId, isEmpty);
        expect(find.text('还没有代理'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('network HTTP proxy entry opens a manageable proxy list', (tester) async {
      await tester.pumpWidget(app(const NetworkSettingsPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('HTTP 代理'));
      await tester.pumpAndSettle();
      expect(find.text('已保存的代理'), findsOneWidget);
      expect(find.text('还没有代理'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('provider can choose a saved proxy or jump to proxy settings when empty', (tester) async {
      final provider = store.value.providers.first;
      await tester.pumpWidget(app(ProviderDetailPage(providerId: provider.id)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('HTTP 代理'));
      await tester.pumpAndSettle();
      expect(find.text('还没有代理'), findsOneWidget);
      await tester.tap(find.text('去设置'));
      await tester.pumpAndSettle();
      expect(find.text('已保存的代理'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('provider can select a saved proxy', (tester) async {
      final provider = store.value.providers.first;
      final proxy = ProxyConfig(id: 'saved-proxy', name: 'Tokyo', url: 'socks5://127.0.0.1:1080');
      await tester.runAsync(() async {
        store.update((s) => s.copyWith(language: AppLang.zh, proxies: [proxy]));
        await store.flush();
      });
      await tester.pumpWidget(app(ProviderDetailPage(providerId: provider.id)));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('HTTP 代理'), 300, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('HTTP 代理'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tokyo').last);
      await tester.runAsync(store.flush);
      await tester.pump();
      expect(store.value.providers.firstWhere((e) => e.id == provider.id).proxyId, proxy.id);
    });
  });
}

Future<T> _realHttp<T>(Future<T> Function() action) => HttpOverrides.runWithHttpOverrides(action, _RealHttpOverrides());

class _RealHttpOverrides extends HttpOverrides {}

class _FakeHttpProxy {
  _FakeHttpProxy(this.server);

  final HttpServer server;
  final paths = <String>[];
  String get url => 'http://127.0.0.1:${server.port}';

  static Future<_FakeHttpProxy> start(String body) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = _FakeHttpProxy(server);
    server.listen((request) async {
      final path = request.uri.path;
      proxy.paths.add(path);
      request.response.write(body);
      await request.response.close();
    });
    return proxy;
  }

  Future<void> close() => server.close(force: true);
}

class _SocketBuffer {
  _SocketBuffer(this.socket) {
    _subscription = socket.listen(
      (data) {
        if (_destination case final destination?) {
          destination.add(data);
        } else {
          _buffer.addAll(data);
          _ready?.complete();
          _ready = null;
        }
      },
      onDone: () {
        _ready?.complete();
        unawaited(_subscription.cancel());
      },
    );
  }

  final Socket socket;
  final _buffer = <int>[];
  late final StreamSubscription<Uint8List> _subscription;
  Completer<void>? _ready;
  Socket? _destination;

  Future<List<int>> readBytes(int length) async {
    while (_buffer.length < length) {
      final ready = _ready = Completer<void>();
      await ready.future;
    }
    return List.generate(length, (_) => _buffer.removeAt(0));
  }

  void forwardTo(Socket destination) {
    _destination = destination;
    if (_buffer.isNotEmpty) {
      destination.add(_buffer);
      _buffer.clear();
    }
  }
}
