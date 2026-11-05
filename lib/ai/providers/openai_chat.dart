import 'dart:convert';

import '../../core/net.dart';
import '../../core/sse.dart';
import '../../core/util.dart';
import '../encoding.dart';
import '../message.dart';
import '../provider.dart';
import '../provider_config.dart';
import 'openai_common.dart';

/// OpenAI Chat Completions (`/chat/completions`) and the many compatible gateways.
class OpenAiChatProvider extends AiProvider with OpenAiCommon {
  OpenAiChatProvider(super.config);

  @override
  Stream<StreamChunk> stream(List<ChatMessage> messages, GenerationParams p, {CancelToken? cancel}) async* {
    final url = Uri.parse('${config.trimmedBaseUrl}${config.chatPath}');
    final body = mergeBody(await _buildBody(messages, p), p);
    final headers = mergeHeaders({
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${nextKey()}',
      'Accept': p.stream ? 'text/event-stream' : 'application/json',
    }, p);

    if (!p.stream) {
      final j = asMap(await Net.json('POST', url, headers: headers, body: body, cancel: cancel));
      yield* _parseFull(j);
      return;
    }

    final res = await Net.send('POST', url, headers: headers, body: jsonEncode(body), cancel: cancel);
    final calls = <int, String>{}; // index -> callId
    final thinkTag = _ThinkTagState();
    await for (final ev in parseSse(res.stream)) {
      if (ev.data == '[DONE]') break;
      final j = asMapOrNull(tryJsonDecode(ev.data));
      if (j == null) continue;
      if (j['error'] != null) {
        throw ApiException(extractErrorMessage(ev.data, 'stream error'));
      }
      final usage = asMapOrNull(j['usage']);
      if (usage != null) yield UsageChunk(parseChatUsage(usage));
      for (final c in asList(j['choices'])) {
        final choice = asMap(c);
        final delta = asMap(choice['delta'] ?? choice['message']);
        final reasoning = asStrOrNull(delta['reasoning_content']) ?? asStrOrNull(delta['reasoning']);
        if (reasoning != null && reasoning.isNotEmpty) yield ReasoningDelta(reasoning);
        final details = delta['reasoning_details'];
        if (details is List && details.isNotEmpty) {
          yield ReasoningDelta('', meta: {'details_append': details});
        }
        final content = delta['content'];
        if (content is String && content.isNotEmpty) {
          for (final chunk in thinkTag.feed(content)) {
            yield chunk;
          }
        } else if (content is List) {
          for (final item in content) {
            final m = asMap(item);
            if (m['type'] == 'text') yield TextDelta(asStr(m['text']));
            if (m['type'] == 'thinking') {
              final th = m['thinking'];
              if (th is String) yield ReasoningDelta(th);
              if (th is List) {
                for (final x in th) {
                  yield ReasoningDelta(asStr(asMap(x)['text']));
                }
              }
            }
          }
        }
        for (final img in asList(delta['images'])) {
          final u = asStrOrNull(asMap(asMap(img)['image_url'])['url']);
          if (u != null) yield ImageChunk(u);
        }
        for (final tc in asList(delta['tool_calls'])) {
          final call = asMap(tc);
          final idx = asInt(call['index'], calls.length);
          final fn = asMap(call['function']);
          final id = asStrOrNull(call['id']);
          if (!calls.containsKey(idx) || (id != null && id.isNotEmpty && id != calls[idx])) {
            final callId = (id == null || id.isEmpty) ? 'call_${newId().substring(0, 8)}' : id;
            calls[idx] = callId;
            yield ToolCallStart(callId, asStr(fn['name']));
          }
          final args = asStrOrNull(fn['arguments']);
          if (args != null && args.isNotEmpty) yield ToolCallDelta(calls[idx]!, args);
        }
        final annotations = asList(delta['annotations']);
        if (annotations.isNotEmpty) yield CitationChunk(parseUrlCitations(annotations));
        final finish = asStrOrNull(choice['finish_reason']);
        if (finish != null) {
          for (final chunk in thinkTag.flush()) {
            yield chunk;
          }
          yield FinishChunk(finish);
        }
      }
    }
    for (final chunk in thinkTag.flush()) {
      yield chunk;
    }
  }

  Stream<StreamChunk> _parseFull(Map<String, dynamic> j) async* {
    final usage = asMapOrNull(j['usage']);
    for (final c in asList(j['choices'])) {
      final msg = asMap(asMap(c)['message']);
      final reasoning = asStrOrNull(msg['reasoning_content']) ?? asStrOrNull(msg['reasoning']);
      if (reasoning != null && reasoning.isNotEmpty) yield ReasoningDelta(reasoning);
      final content = asStrOrNull(msg['content']);
      if (content != null) {
        final st = _ThinkTagState();
        for (final ch in [...st.feed(content), ...st.flush()]) {
          yield ch;
        }
      }
      for (final tc in asList(msg['tool_calls'])) {
        final call = asMap(tc);
        final fn = asMap(call['function']);
        final id = asStr(call['id'], 'call_${newId().substring(0, 8)}');
        yield ToolCallStart(id, asStr(fn['name']));
        yield ToolCallDelta(id, asStr(fn['arguments']));
      }
      yield FinishChunk(asStrOrNull(asMap(c)['finish_reason']));
    }
    if (usage != null) yield UsageChunk(parseChatUsage(usage));
  }

  Future<Map<String, dynamic>> _buildBody(List<ChatMessage> messages, GenerationParams p) async {
    final host = Uri.tryParse(config.trimmedBaseUrl)?.host ?? '';
    final body = <String, dynamic>{
      'model': p.model.modelId,
      'messages': await _buildMessages(messages, p.model, host),
      'stream': p.stream,
    };
    if (p.stream && host != 'api.mistral.ai') {
      body['stream_options'] = {'include_usage': true};
    }
    final noSampling = isOpenAiReasoningModel(p.model.modelId) && p.reasoning.enabled;
    if (!noSampling) {
      if (p.temperature != null) body['temperature'] = p.temperature;
      if (p.topP != null) body['top_p'] = p.topP;
    }
    if (p.maxTokens != null) {
      if (host == 'api.openai.com') {
        body['max_completion_tokens'] = p.maxTokens;
      } else {
        body['max_tokens'] = p.maxTokens;
      }
    }
    if (host == 'openrouter.ai' && p.model.imageOutput) {
      body['modalities'] = ['image', 'text'];
    }
    if (p.model.reasoning) applyChatReasoning(body, host, p);
    if (p.model.tools && p.tools.isNotEmpty) {
      body['tools'] = [
        for (final t in p.tools)
          {
            'type': 'function',
            'function': {'name': t.name, 'description': t.description, 'parameters': t.parameters},
          },
      ];
    }
    if (p.useBuiltInSearch && host == 'openrouter.ai') {
      body['plugins'] = [
        {'id': 'web'},
      ];
    }
    return body;
  }

  Future<List<Map<String, dynamic>>> _buildMessages(List<ChatMessage> messages, ModelConfig model, String host) async {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      switch (m.role) {
        case Role.system:
          out.add({'role': 'system', 'content': m.text});
        case Role.user:
          out.add({'role': 'user', 'content': await _userContent(m, model)});
        case Role.assistant:
          _assistantMessages(m, out, host);
        case Role.tool:
          break;
      }
    }
    return out;
  }

  Future<dynamic> _userContent(ChatMessage m, ModelConfig model) async {
    final parts = <Map<String, dynamic>>[];
    for (final p in m.parts) {
      switch (p) {
        case TextPart(:final text):
          if (text.isNotEmpty) parts.add({'type': 'text', 'text': text});
        case ImagePart(:final url):
          if (!model.vision) continue;
          final enc = await MediaEncoder.encodeImage(url);
          if (enc != null) {
            parts.add({
              'type': 'image_url',
              'image_url': {'url': enc.dataUri},
            });
          }
        case DocumentPart():
          parts.add({'type': 'text', 'text': documentAsText(p)});
        default:
          break;
      }
    }
    if (parts.length == 1 && parts.first['type'] == 'text') return parts.first['text'];
    if (parts.isEmpty) return '';
    return parts;
  }

  /// One assistant turn may contain several tool rounds; split it into
  /// assistant(tool_calls) + tool messages per round.
  void _assistantMessages(ChatMessage m, List<Map<String, dynamic>> out, String host) {
    final text = StringBuffer();
    final reasoning = StringBuffer();
    List<dynamic>? reasoningDetails;
    final calls = <ToolPart>[];

    void flush() {
      if (text.isEmpty && calls.isEmpty && reasoning.isEmpty) return;
      final msg = <String, dynamic>{'role': 'assistant', 'content': text.toString()};
      if (config.includeHistoryReasoning && (reasoning.isNotEmpty || reasoningDetails != null)) {
        if (host == 'openrouter.ai' && reasoningDetails != null) {
          msg['reasoning_details'] = reasoningDetails;
        } else if (calls.isNotEmpty || host == 'api.deepseek.com' || host == 'api.moonshot.cn') {
          msg['reasoning_content'] = reasoning.toString();
        }
      }
      if (calls.isNotEmpty) {
        msg['tool_calls'] = [
          for (final c in calls)
            {
              'id': c.callId,
              'type': 'function',
              'function': {'name': c.name, 'arguments': c.input.isEmpty ? '{}' : c.input},
            },
        ];
      }
      out.add(msg);
      for (final c in calls) {
        out.add({'role': 'tool', 'tool_call_id': c.callId, 'content': c.output ?? ''});
      }
      text.clear();
      reasoning.clear();
      reasoningDetails = null;
      calls.clear();
    }

    for (final p in m.parts) {
      switch (p) {
        case ReasoningPart():
          if (calls.isNotEmpty) flush();
          reasoning.write(p.text);
          final d = p.meta?['details'];
          if (d is List) reasoningDetails = d;
        case TextPart():
          if (calls.isNotEmpty) flush();
          text.write(p.text);
        case ToolPart():
          if (p.executed) calls.add(p);
        default:
          break;
      }
    }
    flush();
  }
}

/// Splits inline `<think>...</think>` tags (Qwen / DeepSeek distills via
/// some gateways) into reasoning chunks while streaming.
class _ThinkTagState {
  bool _inThink = false;
  bool _started = false;
  String _pending = '';

  List<StreamChunk> feed(String s) {
    final out = <StreamChunk>[];
    var buf = _pending + s;
    _pending = '';
    while (buf.isNotEmpty) {
      if (!_inThink) {
        if (!_started) {
          final trimmed = buf.trimLeft();
          if (trimmed.isEmpty) {
            _pending = buf;
            return out;
          }
          if ('<think>'.startsWith(trimmed) && trimmed.length < 7) {
            _pending = buf;
            return out;
          }
          _started = true;
          if (trimmed.startsWith('<think>')) {
            _inThink = true;
            buf = trimmed.substring(7);
            continue;
          }
        }
        out.add(TextDelta(buf));
        return out;
      }
      final end = buf.indexOf('</think>');
      if (end >= 0) {
        if (end > 0) out.add(ReasoningDelta(buf.substring(0, end)));
        out.add(const ReasoningEnd());
        _inThink = false;
        buf = buf.substring(end + 8).replaceFirst(RegExp(r'^\s+'), '');
        continue;
      }
      // Keep a tail that might be the start of `</think>`.
      var keep = 0;
      for (var k = 7; k >= 1; k--) {
        if (buf.length >= k && '</think>'.startsWith(buf.substring(buf.length - k))) {
          keep = k;
          break;
        }
      }
      final emit = buf.substring(0, buf.length - keep);
      if (emit.isNotEmpty) out.add(ReasoningDelta(emit));
      _pending = buf.substring(buf.length - keep);
      return out;
    }
    return out;
  }

  List<StreamChunk> flush() {
    final out = <StreamChunk>[];
    if (_pending.isNotEmpty) {
      out.add(_inThink ? ReasoningDelta(_pending) : TextDelta(_pending));
      _pending = '';
    }
    if (_inThink) {
      out.add(const ReasoningEnd());
      _inThink = false;
    }
    return out;
  }
}
