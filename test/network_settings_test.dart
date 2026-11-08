import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:mewhub/core/i18n.dart';
import 'package:mewhub/core/net.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/core/retry.dart';
import 'package:mewhub/data/network_settings.dart';
import 'package:mewhub/data/settings.dart';
import 'package:mewhub/state/settings_store.dart';
import 'package:mewhub/ui/pages/misc_settings.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late SettingsStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mewhub_network_test');
    AppPaths.support = temp;
    AppPaths.cache = temp;
    FlutterSecureStorage.setMockInitialValues({});
    store = await SettingsStore.load();
    I18n.apply(AppLang.zh);
  });

  tearDown(() async {
    await store.flush();
    await temp.delete(recursive: true);
  });

  group('NetworkSettings', () {
    test('provides comfortable defaults and round-trips all controls', () {
      const defaults = NetworkSettings();
      expect(defaults.connectTimeoutSeconds, 30);
      expect(defaults.responseTimeoutSeconds, 120);
      expect(defaults.maxRetries, 5);
      expect(defaults.retryDelaySeconds, 1);
      expect(defaults.maxRetryDelaySeconds, 60);
      expect(defaults.exponentialBackoff, isTrue);
      expect(defaults.retryOnRateLimit, isTrue);
      expect(defaults.retryOnServerError, isTrue);
      expect(defaults.respectRetryAfter, isTrue);

      final saved = AppSettings.initial().copyWith(network: defaults.copyWith(maxRetries: 7));
      expect(AppSettings.fromJson(saved.toJson()).network.maxRetries, 7);
    });

    test('applies configured timeouts to the shared network client', () {
      expect(NetConfig.connectTimeout, const Duration(seconds: 30));
      expect(NetConfig.responseTimeout, const Duration(seconds: 120));
      store.update(
        (s) => s.copyWith(network: s.network.copyWith(connectTimeoutSeconds: 45, responseTimeoutSeconds: 180)),
      );
      expect(NetConfig.connectTimeout, const Duration(seconds: 45));
      expect(NetConfig.responseTimeout, const Duration(seconds: 180));
    });

    test('migrates missing values and clamps malformed or out-of-range values', () {
      expect(NetworkSettings.fromJson({}).toJson(), const NetworkSettings().toJson());
      final parsed = NetworkSettings.fromJson({
        'connectTimeoutSeconds': 0,
        'responseTimeoutSeconds': '30000',
        'maxRetries': -3,
        'retryDelaySeconds': 300,
        'maxRetryDelaySeconds': 1,
        'retryOnRateLimit': false,
      });
      expect(parsed.connectTimeoutSeconds, 5);
      expect(parsed.responseTimeoutSeconds, 1800);
      expect(parsed.maxRetries, 0);
      expect(parsed.retryDelaySeconds, 60);
      expect(parsed.maxRetryDelaySeconds, 60);
      expect(parsed.retryOnRateLimit, isFalse);
    });

    testWidgets('saves network preferences and shows them in the Network menu', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      store.update((s) => s.copyWith(language: AppLang.zh, network: s.network.copyWith(maxRetries: 7)));
      I18n.apply(AppLang.zh);
      final stored = await tester.runAsync(() async {
        await store.flush();
        return AppSettings.fromJson(
          jsonDecode(await File(AppPaths.settingsPath).readAsString()) as Map<String, dynamic>,
        );
      });
      expect(stored!.network.maxRetries, 7);

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: store,
          child: const MaterialApp(home: NetworkSettingsPage()),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('网络'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('响应超时'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('响应超时'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('最大重试次数'), 300, scrollable: find.byType(Scrollable).first);
      expect(find.text('7 次'), findsOneWidget);
      await tester.tap(find.text('最大重试次数'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.enterText(find.byType(TextFormField), '21');
      await tester.tap(find.text('保存'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('请输入 0–20 之间的整数'), findsOneWidget);
      expect(store.value.network.maxRetries, 7);
      await tester.enterText(find.byType(TextFormField), '3');
      await tester.tap(find.text('保存'));
      await tester.pump();
      await tester.runAsync(store.flush);
      await tester.pump(const Duration(milliseconds: 300));
      expect(store.value.network.maxRetries, 3);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('retryStream', () {
    test('makes exactly five retries after the initial request', () async {
      var attempts = 0;
      await expectLater(
        retryStream<int>(
          () {
            attempts++;
            return Stream<int>.error(ApiException('temporarily unavailable', status: 503));
          },
          cancel: CancelToken(),
          settings: const NetworkSettings(retryDelaySeconds: 1, maxRetryDelaySeconds: 1),
        ).toList(),
        throwsA(isA<ApiException>()),
      );
      expect(attempts, 6);
    });

    test('never replays a reply after the first streamed event', () async {
      var attempts = 0;
      final received = <int>[];
      await expectLater(
        retryStream<int>(
          () {
            attempts++;
            return Stream<int>.multi((controller) {
              controller.add(7);
              controller.addError(ApiException('connection lost', status: 503));
              controller.close();
            });
          },
          cancel: CancelToken(),
          settings: const NetworkSettings(retryDelaySeconds: 1),
        ).listen(received.add).asFuture<void>(),
        throwsA(isA<ApiException>()),
      );
      expect(received, [7]);
      expect(attempts, 1);
    });

    test('does not retry authentication errors or when retry is disabled', () async {
      var attempts = 0;
      for (final (:settings, :enabled, :status) in [
        (settings: const NetworkSettings(), enabled: false, status: 503),
        (settings: const NetworkSettings(), enabled: true, status: 401),
        (settings: const NetworkSettings(maxRetries: 0), enabled: true, status: 503),
      ]) {
        await expectLater(
          retryStream<int>(
            () {
              attempts++;
              return Stream<int>.error(ApiException('failure', status: status));
            },
            cancel: CancelToken(),
            settings: settings,
            enabled: enabled,
          ).toList(),
          throwsA(isA<ApiException>()),
        );
      }
      expect(attempts, 3);
    });

    test('cancels a pending retry wait immediately', () async {
      final cancel = CancelToken();
      final pending = retryStream<int>(
        () => Stream<int>.error(ApiException('temporarily unavailable', status: 503)),
        cancel: cancel,
        settings: const NetworkSettings(retryDelaySeconds: 1),
      ).toList();
      await Future<void>.delayed(Duration.zero);
      cancel.cancel();
      await expectLater(pending, throwsA(isA<http.RequestAbortedException>()));
    });

    test('caps exponential delays and honors a shorter Retry-After', () {
      const settings = NetworkSettings(retryDelaySeconds: 2, maxRetryDelaySeconds: 8);
      expect(retryDelay(settings, 0), const Duration(seconds: 2));
      expect(retryDelay(settings, 1), const Duration(seconds: 4));
      expect(retryDelay(settings, 5), const Duration(seconds: 8));
      expect(retryDelay(settings, 0, retryAfter: const Duration(seconds: 5)), const Duration(seconds: 5));
      expect(retryDelay(settings, 0, retryAfter: const Duration(seconds: 30)), isNull);
      expect(
        retryDelay(settings.copyWith(respectRetryAfter: false), 0, retryAfter: const Duration(seconds: 30)),
        const Duration(seconds: 2),
      );
      expect(isRetryableNetworkError(ApiException('rate limited', status: 429), settings), isTrue);
      expect(
        isRetryableNetworkError(ApiException('rate limited', status: 429), settings.copyWith(retryOnRateLimit: false)),
        isFalse,
      );
      expect(isRetryableNetworkError(ApiException('server failure', status: 503), settings), isTrue);
      expect(
        isRetryableNetworkError(ApiException('bad gateway', status: 502), settings.copyWith(retryOnServerError: false)),
        isFalse,
      );
    });
  });

  test('Retry-After accepts seconds and HTTP dates', () {
    expect(parseRetryAfter('12'), const Duration(seconds: 12));
    expect(
      parseRetryAfter('Thu, 01 Jan 1970 00:00:12 GMT', now: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true)),
      const Duration(seconds: 12),
    );
    expect(parseRetryAfter('invalid'), isNull);
  });

  test('the response timeout aborts a connection that never sends headers', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final previousTimeout = NetConfig.responseTimeout;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = Completer<void>();
      server.listen((request) async {
        if (!received.isCompleted) received.complete();
        await request.drain<void>();
        // Intentionally withhold the response headers until the test aborts it.
      });
      NetConfig.responseTimeout = const Duration(milliseconds: 100);
      Net.reconfigure();
      try {
        await expectLater(
          Net.send('GET', Uri.parse('http://127.0.0.1:${server.port}/stalled')),
          throwsA(isA<ApiException>().having((error) => error.cause, 'timeout cause', isA<TimeoutException>())),
        );
        await received.future;
      } finally {
        NetConfig.responseTimeout = previousTimeout;
        Net.reconfigure();
        await server.close(force: true);
      }
    }, _LoopbackHttpOverrides());
  });

  test('the response timeout also ends a stream that stops producing data', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final previousTimeout = NetConfig.responseTimeout;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final received = Completer<void>();
      server.listen((request) async {
        request.response.headers.contentType = ContentType.text;
        request.response.write('first chunk');
        await request.response.flush();
        if (!received.isCompleted) received.complete();
        // Leave the response open so its body stalls until timeout.
      });
      NetConfig.responseTimeout = const Duration(milliseconds: 100);
      Net.reconfigure();
      try {
        final response = await Net.send('GET', Uri.parse('http://127.0.0.1:${server.port}/stalled-body'));
        await received.future;
        await expectLater(response.stream.bytesToString(), throwsA(isA<TimeoutException>()));
      } finally {
        NetConfig.responseTimeout = previousTimeout;
        Net.reconfigure();
        await server.close(force: true);
      }
    }, _LoopbackHttpOverrides());
  });

  test('a stalled 401 error body preserves the status and is not retryable', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.statusCode = 401;
        request.response.write('unauthorized');
        await request.response.flush();
      });
      Net.reconfigure();
      try {
        await expectLater(
          Net.send(
            'GET',
            Uri.parse('http://127.0.0.1:${server.port}/unauthorized'),
            timeout: const Duration(milliseconds: 150),
          ),
          throwsA(
            isA<ApiException>()
                .having((e) => e.status, 'HTTP status', 401)
                .having((e) => isRetryableNetworkError(e, const NetworkSettings()), 'retryable', false),
          ),
        );
      } finally {
        Net.reconfigure();
        await server.close(force: true);
      }
    }, _LoopbackHttpOverrides());
  });

  test('continuous response chunks may outlive the response timeout', () async {
    await HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.bufferOutput = false;
        for (var i = 0; i < 6; i++) {
          request.response.write('$i');
          await request.response.flush();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await request.response.close();
      });
      Net.reconfigure();
      try {
        expect(
          await Net.text(
            'GET',
            Uri.parse('http://127.0.0.1:${server.port}/active'),
            timeout: const Duration(milliseconds: 400),
          ),
          '012345',
        );
      } finally {
        Net.reconfigure();
        await server.close(force: true);
      }
    }, _LoopbackHttpOverrides());
  });
}
