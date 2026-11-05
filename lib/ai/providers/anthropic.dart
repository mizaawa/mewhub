import 'dart:convert';

import '../../core/net.dart';
import '../../core/sse.dart';
import '../../core/util.dart';
import '../encoding.dart';
import '../message.dart';
import '../provider.dart';
import '../provider_config.dart';
import 'openai_common.dart' show documentAsText;

const _anthropicVersion = '2023-06-01';

/// Anthropic Messages API (`/v1/messages`).
class AnthropicProvider extends AiProvider {
  AnthropicProvider(super.config);

  Map<String, String> _headers(GenerationParams? p) => mergeHeaders({
    'Content-Type': 'application/json',
    'x-api-key': nextKey(),
    'anthropic-version': _anthropicVersion,
  }, p);

  @override
  Future<List<RemoteModel>> listModels() async {
    final out = <RemoteModel>[];
    String? after;
    for (var page = 0; page < 10; page++) {
      final q = <String, String>{'limit': '1000'};
      if (after != null) q['after_id'] = after;
      final uri = Uri.parse('${config.trimmedBaseUrl}/models').replace(queryParameters: q);
      final j = asMap(await Net.json('GET', uri, headers: _headers(null), timeout: const Duration(seconds: 30)));
      for (final e in asList(j['data'])) {
        final m = asMap(e);
        out.add(RemoteModel(asStr(m['id']), asStrOrNull(m['display_name'])));
      }
      if (!asBool(j['has_more'])) break;
      after = asStrOrNull(j['last_id']);
      if (after == null) break;
    }
    return out;
  }

  TokenUsage _usage(Map<String, dynamic> u) {
    final cachedRead = asInt(u['cache_read_input_tokens']);
    final cacheWrite = asInt(u['cache_creation_input_tokens']);
    return TokenUsage(
      input: asInt(u['input_tokens']) + cachedRead + cacheWrite,
      output: asInt(u['output_tokens']),
      cached: cachedRead,
    );
  }

  Stream<StreamChunk> _parseFull(Map<String, dynamic> j) async* {
    for (final c in asList(j['content'])) {
      final b = asMap(c);
      switch (b['type']) {
        case 'text':
          yield TextDelta(asStr(b['text']));
        case 'thinking':
          yield ReasoningDelta(asStr(b['thinking']), meta: {'signature': asStr(b['signature'])});
          yield const ReasoningEnd();
        case 'redacted_thinking':
          yield ReasoningDelta('', meta: {'redacted': asStr(b['data'])});
          yield const ReasoningEnd();
        case 'tool_use':
          yield ToolCallStart(asStr(b['id']), asStr(b['name']));
          yield ToolCallDelta(asStr(b['id']), jsonEncode(b['input'] ?? {}));
      }
    }
    final u = asMapOrNull(j['usage']);
    if (u != null) yield UsageChunk(_usage(u));
    yield FinishChunk(asStrOrNull(j['stop_reason']));
  }

  @override
  Stream<StreamChunk> stream(List<ChatMessage> messages, GenerationParams p, {CancelToken? cancel}) async* {
    final url = Uri.parse('${config.trimmedBaseUrl}/messages');
    final body = mergeBody(await _buildBody(messages, p), p);
    if (!p.stream) {
      final j = asMap(await Net.json('POST', url, headers: _headers(p), body: body, cancel: cancel));
      yield* _parseFull(j);
      return;
    }
    final res = await Net.send('POST', url, headers: _headers(p), body: jsonEncode(body), cancel: cancel);
    final blocks = <int, _Block>{};
    var usage = const TokenUsage();
    String? stop;
    await for (final ev in parseSse(res.stream)) {
      final j = asMapOrNull(tryJsonDecode(ev.data));
      if (j == null) continue;
      final type = asStr(j['type'], ev.event ?? '');
      if (type == 'error') {
        throw ApiException(asStr(asMap(j['error'])['message'], 'Anthropic stream error'));
      } else if (type == 'message_start') {
        final u = asMapOrNull(asMap(j['message'])['usage']);
        if (u != null) usage = usage.merge(_usage(u));
      } else if (type == 'content_block_start') {
        final b = asMap(j['content_block']);
        final blk = _Block(asStr(b['type']), asStr(b['id']), asStr(b['name']), b);
        blocks[asInt(j['index'])] = blk;
        yield* _onBlockStart(blk);
      } else if (type == 'content_block_delta') {
        final blk = blocks[asInt(j['index'])];
        if (blk != null) yield* _onDelta(blk, asMap(j['delta']));
      } else if (type == 'content_block_stop') {
        final blk = blocks.remove(asInt(j['index']));
        if (blk != null) yield* _onBlockStop(blk);
      } else if (type == 'message_delta') {
        final u = asMapOrNull(j['usage']);
        if (u != null) usage = usage.merge(_usage(u));
        stop = asStrOrNull(asMap(j['delta'])['stop_reason']) ?? stop;
      } else if (type == 'message_stop') {
        yield UsageChunk(usage);
        yield FinishChunk(stop);
      }
    }
  }

  Stream<StreamChunk> _onBlockStart(_Block blk) async* {
    final b = blk.raw;
    switch (blk.type) {
      case 'tool_use':
        yield ToolCallStart(blk.id, blk.name);
        final input = asMap(b['input']);
        if (input.isNotEmpty) yield ToolCallDelta(blk.id, jsonEncode(input));
      case 'redacted_thinking':
        yield ReasoningDelta('', meta: {'redacted': asStr(b['data'])});
        yield const ReasoningEnd();
      case 'web_search_tool_result':
        yield ServerToolChunk(
          ServerToolPart(
            callId: asStr(b['tool_use_id']),
            name: 'web_search_result',
            output: b['content'],
            meta: {'raw': b},
          ),
        );
        final cites = <Citation>[];
        for (final r in asList(b['content'])) {
          final m = asMap(r);
          final u = asStrOrNull(m['url']);
          if (u != null) cites.add(Citation(title: asStr(m['title'], u), url: u));
        }
        if (cites.isNotEmpty) yield CitationChunk(cites);
    }
  }

  Stream<StreamChunk> _onDelta(_Block blk, Map<String, dynamic> d) async* {
    switch (d['type']) {
      case 'text_delta':
        yield TextDelta(asStr(d['text']));
      case 'thinking_delta':
        yield ReasoningDelta(asStr(d['thinking']));
      case 'signature_delta':
        yield ReasoningDelta('', meta: {'signature': asStr(d['signature'])});
      case 'input_json_delta':
        final partial = asStr(d['partial_json']);
        if (blk.type == 'server_tool_use') {
          blk.input.write(partial);
        } else {
          yield ToolCallDelta(blk.id, partial);
        }
      case 'citations_delta':
        final c = asMap(d['citation']);
        final u = asStrOrNull(c['url']);
        if (u != null) {
          yield CitationChunk([Citation(title: asStr(c['title'], u), url: u, snippet: asStr(c['cited_text']))]);
        }
    }
  }

  Stream<StreamChunk> _onBlockStop(_Block blk) async* {
    if (blk.type == 'thinking') yield const ReasoningEnd();
    if (blk.type == 'server_tool_use') {
      final raw = Map<String, dynamic>.from(blk.raw);
      raw['input'] = tryJsonDecode(blk.input.toString()) ?? <String, dynamic>{};
      yield ServerToolChunk(ServerToolPart(callId: blk.id, name: blk.name, input: raw['input'], meta: {'raw': raw}));
    }
  }

  Map<String, dynamic> get _cache => {'type': 'ephemeral'};

  Future<Map<String, dynamic>> _buildBody(List<ChatMessage> messages, GenerationParams p) async {
    final body = <String, dynamic>{'model': p.model.modelId, 'max_tokens': p.maxTokens ?? 32000, 'stream': p.stream};
    final systemText = messages.where((m) => m.role == Role.system).map((m) => m.text).join('\n\n');
    if (systemText.isNotEmpty) {
      body['system'] = [
        {'type': 'text', 'text': systemText, if (config.promptCaching) 'cache_control': _cache},
      ];
    }
    final thinking = p.model.reasoning && p.reasoning.enabled;
    if (p.model.reasoning) {
      if (!p.reasoning.enabled) {
        body['thinking'] = {'type': 'disabled'};
      } else {
        body['thinking'] = {'type': 'adaptive', 'display': 'summarized'};
        if (p.reasoning != ReasoningLevel.auto) {
          body['output_config'] = {'effort': p.reasoning.effort};
        }
      }
    }
    // Sampling params are rejected while extended thinking is on.
    if (!thinking) {
      if (p.temperature != null) body['temperature'] = p.temperature;
      if (p.topP != null) body['top_p'] = p.topP;
    }
    final tools = <Map<String, dynamic>>[];
    if (p.model.tools) {
      for (final t in p.tools) {
        tools.add({'name': t.name, 'description': t.description, 'input_schema': t.parameters});
      }
    }
    if (p.useBuiltInSearch) {
      tools.add({'type': 'web_search_20250305', 'name': 'web_search', 'max_uses': 5});
    }
    if (tools.isNotEmpty) {
      if (config.promptCaching) tools.last['cache_control'] = _cache;
      body['tools'] = tools;
    }
    final msgs = await _buildMessages(messages, p.model);
    if (config.promptCaching) _markCache(msgs);
    body['messages'] = msgs;
    return body;
  }

  /// Puts a cache breakpoint on the last block of the latest user turn.
  void _markCache(List<Map<String, dynamic>> msgs) {
    for (var i = msgs.length - 1; i >= 0; i--) {
      if (msgs[i]['role'] != 'user') continue;
      final content = msgs[i]['content'];
      if (content is List && content.isNotEmpty) {
        (content.last as Map<String, dynamic>)['cache_control'] = _cache;
      }
      return;
    }
  }

  Future<List<Map<String, dynamic>>> _buildMessages(List<ChatMessage> messages, ModelConfig model) async {
    final out = <Map<String, dynamic>>[];
    void push(String role, List<Map<String, dynamic>> blocks) {
      if (blocks.isEmpty) return;
      if (out.isNotEmpty && out.last['role'] == role) {
        (out.last['content'] as List).addAll(blocks);
      } else {
        out.add({'role': role, 'content': blocks});
      }
    }

    for (final m in messages) {
      if (m.role == Role.system) continue;
      if (m.role == Role.user) {
        final blocks = <Map<String, dynamic>>[];
        for (final part in m.parts) {
          switch (part) {
            case TextPart(:final text):
              if (text.isNotEmpty) blocks.add({'type': 'text', 'text': text});
            case ImagePart(:final url):
              if (!model.vision) continue;
              final enc = await MediaEncoder.encodeImage(url);
              if (enc != null) {
                blocks.add({
                  'type': 'image',
                  'source': {'type': 'base64', 'media_type': enc.mime, 'data': enc.base64},
                });
              }
            case DocumentPart():
              blocks.add({'type': 'text', 'text': documentAsText(part)});
            default:
              break;
          }
        }
        push('user', blocks);
        continue;
      }
      if (m.role != Role.assistant) continue;
      // Each tool round: assistant(text/thinking/tool_use) -> user(tool_result).
      var assistant = <Map<String, dynamic>>[];
      var results = <Map<String, dynamic>>[];
      void flushRound() {
        push('assistant', assistant);
        push('user', results);
        assistant = [];
        results = [];
      }

      for (final part in m.parts) {
        switch (part) {
          case ReasoningPart():
            if (results.isNotEmpty) flushRound();
            final redacted = part.meta?['redacted'];
            final sig = part.meta?['signature'];
            if (redacted is String && redacted.isNotEmpty) {
              assistant.add({'type': 'redacted_thinking', 'data': redacted});
            } else if (sig is String && sig.isNotEmpty) {
              assistant.add({'type': 'thinking', 'thinking': part.text, 'signature': sig});
            }
          case TextPart():
            if (results.isNotEmpty) flushRound();
            if (part.text.isNotEmpty) assistant.add({'type': 'text', 'text': part.text});
          case ToolPart():
            if (!part.executed) continue;
            assistant.add({'type': 'tool_use', 'id': part.callId, 'name': part.name, 'input': part.inputJson});
            results.add({
              'type': 'tool_result',
              'tool_use_id': part.callId,
              'content': part.output ?? '',
              if (part.isError) 'is_error': true,
            });
          case ServerToolPart():
            if (results.isNotEmpty) flushRound();
            final raw = part.meta?['raw'];
            if (raw is Map) assistant.add(Map<String, dynamic>.from(raw));
          default:
            break;
        }
      }
      flushRound();
    }
    // The API requires the conversation to start with a user turn.
    if (out.isNotEmpty && out.first['role'] != 'user') {
      out.insert(0, {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '...'},
        ],
      });
    }
    return out;
  }
}

class _Block {
  _Block(this.type, this.id, this.name, this.raw);
  final String type;
  final String id;
  final String name;
  final Map<String, dynamic> raw;
  final StringBuffer input = StringBuffer();
}
