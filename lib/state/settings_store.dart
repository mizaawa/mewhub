import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../ai/provider_config.dart';
import '../core/i18n.dart';
import '../core/net.dart';
import '../core/paths.dart';
import '../core/util.dart';
import '../data/assistant.dart';
import '../data/defaults.dart';
import '../data/provider_branding.dart';
import '../data/models_misc.dart';
import '../data/settings.dart';

/// Holds [AppSettings] and persists them.
///
/// Non-secret settings go to a JSON file in the app sandbox. Secrets (API
/// keys, passwords, auth headers) are split out and kept in the platform
/// keystore (iOS Keychain, Android Keystore-backed storage).
class SettingsStore extends ChangeNotifier {
  SettingsStore._(this._settings);

  static const _secretsKey = 'mewhub.secrets.v1';
  static const _secure = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );

  AppSettings _settings;
  AppSettings get value => _settings;
  Timer? _saveTimer;

  static Future<SettingsStore> load() async {
    final file = File(AppPaths.settingsPath);
    Map<String, dynamic> json = {};
    if (await file.exists()) {
      try {
        json = asMap(jsonDecode(await file.readAsString()));
      } catch (e) {
        // Corrupt file: keep a copy for recovery and start fresh.
        await file.copy('${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}');
      }
    }
    Map<String, dynamic> secrets = {};
    try {
      final raw = await _secure.read(key: _secretsKey);
      if (raw != null) secrets = asMap(jsonDecode(raw));
    } catch (_) {}
    final s = _injectSecrets(AppSettings.fromJson(json), secrets);
    final store = SettingsStore._(s);
    store._applyRuntime();
    return store;
  }

  void update(AppSettings Function(AppSettings s) fn) {
    final next = fn(_settings);
    _settings = next.copyWith(providers: normalizeProviders(next.providers));
    _applyRuntime();
    notifyListeners();
    _scheduleSave();
  }

  void replace(AppSettings s) => update((_) => s);

  void _applyRuntime() {
    I18n.apply(_settings.language);
    final changed = NetConfig.userAgent != _settings.userAgent || NetConfig.proxy != _settings.proxy;
    NetConfig.userAgent = _settings.userAgent;
    NetConfig.proxy = _settings.proxy;
    if (changed) Net.reconfigure();
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), flush);
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    final s = _settings;
    final json = s.toJson(withSecrets: false);
    _stripSecrets(json);
    final file = File(AppPaths.settingsPath);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(file.path);
    try {
      await _secure.write(key: _secretsKey, value: jsonEncode(_extractSecrets(s)));
    } catch (e) {
      debugPrint('secure storage write failed: $e');
    }
  }

  // ------------------------------------------------------------------ secrets

  static Map<String, dynamic> _extractSecrets(AppSettings s) => {
    'providers': {
      for (final p in s.providers)
        if (p.apiKey.isNotEmpty) p.id: p.apiKey,
    },
    'search': {
      for (final e in s.searchServices)
        if (e.apiKey.isNotEmpty) e.id: e.apiKey,
    },
    'mcp': {
      for (final m in s.mcpServers)
        if (m.headers.isNotEmpty) m.id: m.headers,
    },
    'webdav': s.webDav.password,
    'proxy': s.proxy,
  };

  static void _stripSecrets(Map<String, dynamic> json) {
    for (final e in asList(json['searchServices'])) {
      (e as Map)['apiKey'] = '';
    }
    for (final e in asList(json['mcpServers'])) {
      (e as Map)['headers'] = <String, String>{};
    }
    json['proxy'] = '';
  }

  static AppSettings _injectSecrets(AppSettings s, Map<String, dynamic> secrets) {
    final pk = asMap(secrets['providers']);
    final sk = asMap(secrets['search']);
    final mk = asMap(secrets['mcp']);
    return s.copyWith(
      providers: [for (final p in s.providers) pk[p.id] is String ? p.copyWith(apiKey: pk[p.id] as String) : p],
      searchServices: [
        for (final e in s.searchServices) sk[e.id] is String ? e.copyWith(apiKey: sk[e.id] as String) : e,
      ],
      mcpServers: [
        for (final m in s.mcpServers)
          mk[m.id] is Map ? m.copyWith(headers: asMap(mk[m.id]).map((k, v) => MapEntry(k, v.toString()))) : m,
      ],
      webDav: secrets['webdav'] is String ? s.webDav.copyWith(password: secrets['webdav'] as String) : null,
      proxy: secrets['proxy'] is String ? secrets['proxy'] as String : null,
    );
  }

  // ------------------------------------------------------------- conveniences

  void upsertProvider(ProviderConfig p) => update((s) {
    final list = [...s.providers];
    final i = list.indexWhere((e) => e.id == p.id);
    if (i >= 0) {
      list[i] = p;
    } else {
      list.add(p);
    }
    return s.copyWith(providers: list);
  });

  void removeProvider(String id) {
    if (id == zakoProviderId) return;
    update((s) => s.copyWith(providers: s.providers.where((e) => e.id != id).toList()));
  }

  void upsertAssistant(Assistant a) => update((s) {
    final list = [...s.assistants];
    final i = list.indexWhere((e) => e.id == a.id);
    if (i >= 0) {
      list[i] = a;
    } else {
      list.add(a);
    }
    return s.copyWith(assistants: list);
  });

  void removeAssistant(String id) => update((s) {
    if (s.assistants.length <= 1) return s;
    final list = s.assistants.where((e) => e.id != id).toList();
    return s.copyWith(assistants: list, currentAssistantId: s.currentAssistantId == id ? list.first.id : null);
  });

  void upsertMcp(McpServerConfig m) => update((s) {
    final list = [...s.mcpServers];
    final i = list.indexWhere((e) => e.id == m.id);
    if (i >= 0) {
      list[i] = m;
    } else {
      list.add(m);
    }
    return s.copyWith(mcpServers: list);
  });

  void upsertLorebook(Lorebook b) => update((s) {
    final list = [...s.lorebooks];
    final i = list.indexWhere((e) => e.id == b.id);
    if (i >= 0) {
      list[i] = b;
    } else {
      list.add(b);
    }
    return s.copyWith(lorebooks: list);
  });

  @override
  void dispose() {
    flush();
    super.dispose();
  }
}
