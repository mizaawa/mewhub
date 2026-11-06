import 'dart:convert';

import '../core/util.dart';
import 'provider_config.dart';

/// Provider share codes.
///
/// Native format: `mewhub-provider:v1:<base64url(json)>`.
/// Also accepts RikkaHub's `ai-provider:v1:<base64(json)>` and plain JSON
/// (single object or list), so configs can be moved between apps.
class ProviderShareCodec {
  static const prefix = 'mewhub-provider:v1:';
  static const rikkaPrefix = 'ai-provider:v1:';

  static String encode(ProviderConfig p, {bool includeKey = true}) {
    final json = p.toJson(withSecrets: includeKey, withModels: true)
      ..remove('id')
      ..remove('proxyId');
    return '$prefix${base64Url.encode(utf8.encode(jsonEncode(json)))}';
  }

  static List<ProviderConfig> decode(String raw) {
    final s = raw.trim();
    if (s.startsWith(prefix)) {
      return [
        _fromNative(asMap(jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(s.substring(prefix.length))))))),
      ];
    }
    if (s.startsWith(rikkaPrefix)) {
      final body = s.substring(rikkaPrefix.length);
      final bytes = _decodeAnyBase64(body);
      return [_fromRikka(asMap(jsonDecode(utf8.decode(bytes))))];
    }
    final j = tryJsonDecode(s);
    if (j is List) {
      return j.whereType<Map<dynamic, dynamic>>().map((e) => _fromAny(asMap(e))).whereType<ProviderConfig>().toList();
    }
    if (j is Map) {
      final m = asMap(j);
      if (m['providers'] is List) {
        return asList(m['providers'])
            .whereType<Map<dynamic, dynamic>>()
            .map((e) => _fromAny(asMap(e)))
            .whereType<ProviderConfig>()
            .toList();
      }
      final p = _fromAny(m);
      if (p != null) return [p];
    }
    throw const FormatException('Unrecognised provider code');
  }

  static List<int> _decodeAnyBase64(String s) {
    final cleaned = s.replaceAll(RegExp(r'\s'), '');
    try {
      return base64.decode(base64.normalize(cleaned));
    } catch (_) {
      return base64Url.decode(base64Url.normalize(cleaned));
    }
  }

  static ProviderConfig _fromNative(Map<String, dynamic> j) =>
      ProviderConfig.fromJson({...j, 'id': newId(), 'builtIn': false});

  static ProviderConfig? _fromAny(Map<String, dynamic> j) {
    if (j['kind'] != null && j['baseUrl'] != null) return _fromNative(j);
    if (j['type'] != null && (j['baseUrl'] != null || j['apiKey'] != null)) return _fromRikka(j);
    // Generic: {name, baseUrl|base_url|apiHost, apiKey|api_key, type?}
    final base = asStr(j['baseUrl'] ?? j['base_url'] ?? j['apiHost'] ?? j['api_base'] ?? j['url']);
    if (base.isEmpty) return null;
    final type = asStr(j['type'] ?? j['protocol']).toLowerCase();
    final kind = type.contains('anthropic') || type.contains('claude')
        ? ProviderKind.anthropic
        : type.contains('gemini') || type.contains('google')
        ? ProviderKind.google
        : ProviderKind.openai;
    return ProviderConfig(
      kind: kind,
      name: asStr(j['name'], 'Imported'),
      baseUrl: base,
      apiKey: asStr(j['apiKey'] ?? j['api_key'] ?? j['key']),
      useResponsesApi: type.contains('response'),
    );
  }

  /// RikkaHub `ProviderSetting` JSON (`type`: openai / claude / google).
  static ProviderConfig _fromRikka(Map<String, dynamic> j) {
    final type = asStr(j['type']).toLowerCase();
    final kind = switch (type) {
      'claude' => ProviderKind.anthropic,
      'google' => ProviderKind.google,
      _ => ProviderKind.openai,
    };
    final models = <ModelConfig>[];
    for (final m in asList(j['models'])) {
      final mm = asMap(m);
      final id = asStr(mm['modelId']);
      if (id.isEmpty) continue;
      final input = asList(mm['inputModalities']).map((e) => e.toString().toLowerCase()).toSet();
      final output = asList(mm['outputModalities']).map((e) => e.toString().toLowerCase()).toSet();
      final abilities = asList(mm['abilities']).map((e) => e.toString().toLowerCase()).toSet();
      models.add(
        ModelConfig(
          modelId: id,
          displayName: asStrOrNull(mm['displayName']),
          type: asStr(mm['type']).toUpperCase() == 'IMAGE' ? ModelType.image : ModelType.chat,
          input: {Modality.text, if (input.contains('image')) Modality.image},
          output: {Modality.text, if (output.contains('image')) Modality.image},
          abilities: {
            if (abilities.contains('tool')) ModelAbility.tool,
            if (abilities.contains('reasoning')) ModelAbility.reasoning,
          },
        ),
      );
    }
    return ProviderConfig(
      kind: kind,
      name: asStr(j['name'], 'Imported'),
      enabled: asBool(j['enabled'], true),
      apiKey: asStr(j['apiKey']),
      baseUrl: asStr(j['baseUrl'], switch (kind) {
        ProviderKind.anthropic => 'https://api.anthropic.com/v1',
        ProviderKind.google => 'https://generativelanguage.googleapis.com/v1beta',
        ProviderKind.openai => 'https://api.openai.com/v1',
      }),
      models: models,
      useResponsesApi: asBool(j['useResponseApi']),
      chatPath: asStr(j['chatCompletionsPath'], '/chat/completions'),
      promptCaching: asBool(j['promptCaching']),
    );
  }
}
