import '../../core/net.dart';
import '../../core/util.dart';
import '../message.dart';
import '../provider.dart';
import '../provider_config.dart';

bool isOpenAiReasoningModel(String id) {
  final s = id.toLowerCase();
  return RegExp(r'(^|/)o[1-9]').hasMatch(s) || s.contains('gpt-5') || s.contains('gpt-6') || s.contains('gpt-oss');
}

TokenUsage parseChatUsage(Map<String, dynamic> u) => TokenUsage(
  input: asInt(u['prompt_tokens'] ?? u['input_tokens']),
  output: asInt(u['completion_tokens'] ?? u['output_tokens']),
  cached: asInt(asMap(u['prompt_tokens_details'])['cached_tokens'] ?? u['prompt_cache_hit_tokens']),
  reasoning: asInt(asMap(u['completion_tokens_details'])['reasoning_tokens']),
);

List<Citation> parseUrlCitations(List<dynamic> annotations) {
  final out = <Citation>[];
  for (final a in annotations) {
    final m = asMap(a);
    final c = asMap(m['url_citation'] ?? m);
    final url = asStrOrNull(c['url']);
    if (url != null) out.add(Citation(title: asStr(c['title'], url), url: url));
  }
  return out;
}

String documentAsText(DocumentPart d) {
  final text = d.extractedText ?? '';
  return '<file name="${d.fileName}" type="${d.mime}">\n$text\n</file>';
}

/// Vendor-specific reasoning switches for Chat Completions.
void applyChatReasoning(Map<String, dynamic> body, String host, GenerationParams p) {
  final level = p.reasoning;
  final onOff = {'type': level.enabled ? 'enabled' : 'disabled'};
  switch (host) {
    case 'openrouter.ai':
      body['reasoning'] = switch (level) {
        ReasoningLevel.off => {'effort': 'none'},
        ReasoningLevel.auto => {'enabled': true},
        // OpenRouter maps an effort to the nearest level the model supports.
        _ => {'effort': level.effort},
      };
    case 'api.deepseek.com':
      body['thinking'] = onOff;
      if (level.enabled && level != ReasoningLevel.auto) {
        body['reasoning_effort'] = level == ReasoningLevel.max ? 'max' : 'high';
      }
    case 'ark.cn-beijing.volces.com':
    case 'open.bigmodel.cn':
    case 'api.moonshot.cn':
    case 'api.xiaomimimo.com':
      body['thinking'] = onOff;
    case 'dashscope.aliyuncs.com':
    case 'api.siliconflow.cn':
    case 'aiping.cn':
      if (level != ReasoningLevel.auto) body['enable_thinking'] = level.enabled;
      if (level.enabled && level != ReasoningLevel.auto) body['thinking_budget'] = level.budget;
    case 'generativelanguage.googleapis.com':
      if (level != ReasoningLevel.auto) {
        body['reasoning_effort'] = level.enabled
            ? (level.index > ReasoningLevel.high.index ? 'high' : level.effort)
            : 'none';
      }
    case 'api.mistral.ai':
      break;
    default:
      if (level != ReasoningLevel.auto) {
        body['reasoning_effort'] = switch (level) {
          ReasoningLevel.off => isOpenAiReasoningModel(p.model.modelId) ? 'minimal' : 'none',
          _ => openAiEffort(p.model.modelId, level),
        };
      }
  }
}

mixin OpenAiCommon on AiProvider {
  @override
  Future<List<RemoteModel>> listModels() async {
    final j = await Net.json(
      'GET',
      Uri.parse('${config.trimmedBaseUrl}/models'),
      headers: mergeHeaders({'Authorization': 'Bearer ${nextKey()}'}, null),
      timeout: const Duration(seconds: 30),
      providerId: config.id,
    );
    final data = j is Map ? asList(j['data'] ?? j['models']) : asList(j);
    final out = <RemoteModel>[];
    for (final e in data) {
      if (e is String) {
        out.add(RemoteModel(e));
      } else {
        final m = asMap(e);
        final id = asStrOrNull(m['id']) ?? asStrOrNull(m['name']);
        if (id != null) out.add(RemoteModel(id, asStrOrNull(m['display_name']) ?? asStrOrNull(m['name'])));
      }
    }
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  @override
  Future<List<String>> generateImage(ModelConfig model, String prompt, {int n = 1, String size = '1024x1024'}) async {
    final body = <String, dynamic>{'model': model.modelId, 'prompt': prompt, 'n': n};
    if (size.isNotEmpty) body['size'] = size;
    if (!model.modelId.toLowerCase().contains('gpt-image')) body['response_format'] = 'b64_json';
    final j = asMap(
      await Net.json(
        'POST',
        Uri.parse('${config.trimmedBaseUrl}/images/generations'),
        headers: mergeHeaders({'Authorization': 'Bearer ${nextKey()}'}, null),
        body: body,
        timeout: const Duration(minutes: 5),
        providerId: config.id,
      ),
    );
    final out = <String>[];
    for (final e in asList(j['data'])) {
      final m = asMap(e);
      final b64 = asStrOrNull(m['b64_json']);
      if (b64 != null) {
        out.add('data:image/png;base64,$b64');
      } else if (m['url'] != null) {
        out.add(asStr(m['url']));
      }
    }
    if (out.isEmpty) throw ApiException('No image returned');
    return out;
  }
}
