import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/data/models_misc.dart';
import 'package:mewhub/data/proxy_config.dart';
import 'package:mewhub/state/settings_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('mewhub_test');
    AppPaths.support = tmp;
    AppPaths.cache = tmp;
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('secrets are kept out of settings.json and restored on load', () async {
    final store = await SettingsStore.load();
    final p = store.value.providers.first;
    store.upsertProvider(p.copyWith(apiKey: 'sk-super-secret', enabled: true));
    store.update(
      (s) => s.copyWith(
        searchServices: [SearchServiceConfig(type: SearchServiceType.tavily, apiKey: 'tvly-secret')],
        webDav: s.webDav.copyWith(url: 'https://dav.example', password: 'dav-secret'),
        mcpServers: [
          McpServerConfig(name: 'm', url: 'https://mcp.example', headers: {'Authorization': 'Bearer mcp-secret'}),
        ],
        proxy: 'user:pass@127.0.0.1:7890',
      ),
    );
    await store.flush();

    final onDisk = await File(AppPaths.settingsPath).readAsString();
    for (final secret in ['sk-super-secret', 'tvly-secret', 'dav-secret', 'mcp-secret', 'user:pass']) {
      expect(onDisk.contains(secret), isFalse, reason: '$secret leaked into settings.json');
    }

    final reloaded = await SettingsStore.load();
    expect(reloaded.value.providers.firstWhere((e) => e.id == p.id).apiKey, 'sk-super-secret');
    expect(reloaded.value.searchServices.single.apiKey, 'tvly-secret');
    expect(reloaded.value.webDav.password, 'dav-secret');
    expect(reloaded.value.mcpServers.single.headers['Authorization'], 'Bearer mcp-secret');
    expect(reloaded.value.proxies.single.url, 'user:pass@127.0.0.1:7890');
    expect(reloaded.value.defaultProxyId, reloaded.value.proxies.single.id);
  });

  test('a corrupt settings file is preserved and defaults are used', () async {
    await File(AppPaths.settingsPath).writeAsString('{not json');
    final store = await SettingsStore.load();
    expect(store.value.assistants, isNotEmpty);
    final backups = tmp.listSync().where((e) => e.path.contains('.corrupt-'));
    expect(backups, isNotEmpty);
  });

  test('proxy URLs and credentials are kept out of settings.json', () async {
    final store = await SettingsStore.load();
    store.update(
      (s) => s.copyWith(
        proxies: [ProxyConfig(id: 'private-proxy', name: 'Private', url: 'socks5://user:pass@proxy.example:1080')],
        defaultProxyId: 'private-proxy',
      ),
    );
    await store.flush();

    final onDisk = await File(AppPaths.settingsPath).readAsString();
    expect(onDisk.contains('proxy.example'), isFalse);
    expect(onDisk.contains('socks5://'), isFalse);
    expect(onDisk.contains('user:pass'), isFalse);

    final reloaded = await SettingsStore.load();
    expect(reloaded.value.proxies.single.url, 'socks5://user:pass@proxy.example:1080');
    expect(reloaded.value.defaultProxyId, 'private-proxy');
  });

  test('concurrent settings flushes are serialized', () async {
    final store = await SettingsStore.load();
    await Future.wait([store.flush(), store.flush(), store.flush()]);
    expect(await File(AppPaths.settingsPath).exists(), isTrue);
  });
}
