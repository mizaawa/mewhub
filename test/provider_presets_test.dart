import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mewhub/ai/factory.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/ai/provider.dart';
import 'package:mewhub/ai/provider_config.dart';
import 'package:mewhub/core/site_icon.dart';
import 'package:mewhub/data/defaults.dart';
import 'package:mewhub/data/provider_branding.dart';
import 'package:mewhub/data/settings.dart';

void main() {
  test('fresh install has Zako Responses first, /usage and all bundled website icons', () {
    final list = AppSettings.initial().providers;
    final p = list.first;
    expect(p.name, 'Zako AI');
    expect(p.isZako, isTrue);
    expect(p.baseUrl, 'https://api.zayuapi.com');
    expect(p.kind, ProviderKind.openai);
    expect(p.useResponsesApi, isTrue);
    expect(p.balanceUrl.replaceAll('{{baseUrl}}', p.trimmedBaseUrl), 'https://api.zayuapi.com/usage');
    expect(p.apiKey, isEmpty);
    expect(p.enabled, isTrue);
    expect(list.any((p) => p.id == 'p-ollama'), isFalse);
    for (final provider in list) {
      expect(provider.iconAsset, isNotNull, reason: provider.name);
      expect(File(provider.iconAsset!).readAsBytesSync().take(4), [137, 80, 78, 71]);
    }
  });

  test('existing settings preserve custom providers and restore the required Zako preset', () {
    final custom = ProviderConfig(
      id: 'custom',
      kind: ProviderKind.openai,
      name: 'My gateway',
      baseUrl: 'https://example.com/v1',
      apiKey: 'fixture-key',
      models: [ModelConfig(id: 'model', modelId: 'custom-model')],
    );
    final old = {
      'providers': [
        custom.toJson(),
        {'id': 'p-ollama', 'builtIn': true, 'name': 'Ollama (local)', 'baseUrl': 'http://localhost:11434/v1'},
        {'id': 'user-ollama', 'name': 'My local service', 'baseUrl': 'http://localhost:11434/v1'},
      ],
      'chatModelId': 'model',
    };
    final s = AppSettings.fromJson(old);
    expect(s.providers.map((p) => p.id), [zakoProviderId, 'custom', 'user-ollama']);
    expect(s.providers[1].toJson(), custom.toJson());
    expect(s.chatModelId, 'model');
    final restored = AppSettings.fromJson(s.toJson());
    expect(restored.providers.where((p) => p.isZako), hasLength(1));
    final deleted = s.copyWith(providers: s.providers.where((p) => !p.isZako).toList());
    expect(AppSettings.fromJson(deleted.toJson()).providers.first.isZako, isTrue);
  });

  test('existing Zako keeps user data while its official identity and endpoint are restored', () {
    final p = zakoProvider().copyWith(
      apiKey: 'fixture-key',
      enabled: true,
      balancePath: 'remaining',
      responsesPath: '/custom/responses',
      models: [ModelConfig(modelId: 'my-model')],
    );
    final list = normalizeProviders([defaultProviders()[1], p]);
    expect(list.first, same(p));
    expect(list.first.name, 'Zako AI');
    expect(list.first.baseUrl, zakoBaseUrl);
    expect(list.first.builtIn, isTrue);
    expect(list.first.enabled, isTrue);
    expect(list.first.apiKey, 'fixture-key');
    expect(list.first.balancePath, 'remaining');
    expect(list.first.responsesPath, '/custom/responses');
    expect(list.first.models.single.modelId, 'my-model');
    expect(list.where((p) => p.isZako), hasLength(1));
  });

  test('normalization repairs tampered Zako name and base URL', () {
    final tampered = zakoProvider().copyWith(name: 'Editable name', baseUrl: 'https://example.invalid', enabled: false);
    final locked = normalizeProviders([tampered]).single;
    expect(locked.name, 'Zako AI');
    expect(locked.baseUrl, zakoBaseUrl);
    expect(locked.builtIn, isTrue);
    expect(locked.enabled, isTrue);
  });

  test('normalization locks Zako on and stably groups enabled providers first', () {
    final defaults = defaultProviders();
    final offA = defaults[1];
    final onA = defaults[2].copyWith(enabled: true);
    final offB = defaults[3];
    final onB = defaults[4].copyWith(enabled: true);
    final zako = zakoProvider().copyWith(enabled: false, apiKey: 'fixture-key');
    final list = normalizeProviders([offA, onA, offB, zako, onB]);
    expect(list.map((p) => p.id), [zakoProviderId, onA.id, onB.id, offA.id, offB.id]);
    expect(list.first.enabled, isTrue);
    expect(list.first.apiKey, 'fixture-key');
    expect(normalizeProviders(list).map((p) => p.id), list.map((p) => p.id));
    expect(normalizeProviders([]).single.isZako, isTrue);
    final restored = AppSettings.fromJson({'providerPresetsVersion': 1, 'providers': []});
    expect(restored.providers.single.isZako, isTrue);
    expect(restored.providers.single.enabled, isTrue);
  });

  test('Zako uses the Responses protocol and the root /responses endpoint', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <(String, String, String?)>[];
    server.listen((req) async {
      requests.add((req.method, req.uri.path, req.headers.value('Authorization')));
      final body = jsonDecode(await utf8.decodeStream(req)) as Map;
      expect(body['model'], 'fixture-model');
      expect(body['input'], isNotEmpty);
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'status': 'completed',
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': 'pong'},
              ],
            },
          ],
        }),
      );
      await req.response.close();
    });
    try {
      final config = zakoProvider().copyWith(baseUrl: 'http://127.0.0.1:${server.port}', apiKey: 'fixture-key');
      final chunks = await providerFor(config).stream([
        ChatMessage.text(Role.user, 'ping'),
      ], GenerationParams(model: ModelConfig(modelId: 'fixture-model'), stream: false)).toList();
      expect(requests, [('POST', '/responses', 'Bearer fixture-key')]);
      expect(chunks.whereType<TextDelta>().map((c) => c.text).join(), 'pong');
    } finally {
      await server.close(force: true);
    }
  });

  test('live icon resolves declared relative URLs and never sends provider credentials', () async {
    final png = File('assets/providers/zako.png').readAsBytesSync();
    final seen = <http.Request>[];
    final client = MockClient((req) async {
      seen.add(req);
      if (req.url.path.isEmpty) return http.Response("<link href='/brand.png?x=1&amp;y=2' rel='shortcut icon'>", 200);
      return http.Response.bytes(png, 200);
    });
    final icon = await loadSiteIcon(Uri.parse(zakoBaseUrl), client: client);
    expect(icon, png);
    expect(seen.last.url.toString(), '$zakoBaseUrl/brand.png?x=1&y=2');
    for (final req in seen) {
      expect(req.headers.containsKey('authorization'), isFalse);
      expect(req.headers.containsKey('x-api-key'), isFalse);
    }
    client.close();
  });

  test('live icon follows a changed embedded site icon, including API access notices', () async {
    final icons = ['zako', 'deepseek'].map((name) => File('assets/providers/$name.png').readAsBytesSync()).toList();
    var visit = 0;
    final client = MockClient(
      (_) async =>
          http.Response('<img alt="site icon" src="data:image/png;base64,${base64Encode(icons[visit++])}">', 403),
    );
    expect(await loadSiteIcon(Uri.parse(zakoBaseUrl), client: client), icons[0]);
    expect(await loadSiteIcon(Uri.parse(zakoBaseUrl), client: client), icons[1]);
    expect(visit, 2);
    client.close();
  });

  test('invalid favicon or offline request yields the bundled fallback', () async {
    final invalid = MockClient((_) async => http.Response('<html>not an icon</html>', 200));
    expect(await loadSiteIcon(Uri.parse(zakoBaseUrl), client: invalid), isNull);
    invalid.close();
    final offline = MockClient((_) async => throw const SocketException('offline'));
    expect(await loadSiteIcon(Uri.parse(zakoBaseUrl), client: offline), isNull);
    offline.close();
  });
}
