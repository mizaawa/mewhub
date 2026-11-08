import 'dart:convert';

import '../../core/net.dart';
import '../../core/sse.dart';
import '../../core/util.dart';
import '../encoding.dart';
import '../message.dart';
import '../provider.dart';
import '../provider_config.dart';
import 'openai_common.dart';

/// OpenAI Responses API (`/responses`), stateless (`store: false`).
/// Reasoning items are replayed with `encrypted_content` so multi-turn
/// tool use keeps the model's chain of thought.
class OpenAiResponsesProvider extends AiProvider with OpenAiCommon {
  OpenAiResponsesProvider(super.config);

  @override
  Stream<StreamChunk> stream(List<ChatMessage> messages, GenerationParams p, {CancelToken? cancel}) async* {
    final url = Uri.parse('${config.trimmedBaseUrl}${config.responsesPath}');
    final body = mergeBody(await _buildBody(messages, p), p);
    final headers = mergeHeaders({
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${nextKey()}',
      'Accept': p.stream ? 'text/event-stream' : 'application/json',
    }, p);

    if (!p.stream) {
      final j = asMap(await Net.json('POST', url, headers: headers, body: body, cancel: cancel, providerId: config.id));
      for (final item in asList(j['output'])) {
        yield* _emitItem(asMap(item), full: true);
      }
      final u = asMapOrNull(j['usage']);
      if (u != null) yield UsageChunk(_usage(u));
      yield FinishChunk(asStrOrNull(j['status']));
      return;
    }

    final res = await Net.send(
      'POST',
      url,
      headers: headers,
      body: jsonEncode(body),
      cancel: cancel,
      providerId: config.id,
    );
    final callByItem = <String, String>{}; // item_id -> call_id
    final argsSeen = <String>{};
    await for (final ev in parseSse(res.stream)) {
      if (ev.data == '[DONE]') break;
      final j = asMapOrNull(tryJsonDecode(ev.data));
      if (j == null) continue;
      final type = asStr(j['type'], ev.event ?? '');
      switch (type) {
        case 'response.output_text.delta':
          yield TextDelta(asStr(j['delta']));
        case 'response.reasoning_summary_text.delta':
        case 'response.reasoning_text.delta':
          yield ReasoningDelta(asStr(j['delta']), meta: {'rid': asStr(j['item_id'])});
        case 'response.reasoning_summary_part.done':
          yield const ReasoningDelta('\n\n');
        case 'response.output_item.added':
          final item = asMap(j['item']);
          if (item['type'] == 'function_call') {
            final callId = asStr(item['call_id'], asStr(item['id']));
            callByItem[asStr(item['id'])] = callId;
            yield ToolCallStart(callId, asStr(item['name']), meta: {'item_id': asStr(item['id'])});
            final args = asStr(item['arguments']);
            if (args.isNotEmpty) {
              argsSeen.add(callId);
              yield ToolCallDelta(callId, args);
            }
          } else if (item['type'] == 'web_search_call') {
            yield ServerToolChunk(
              ServerToolPart(
                callId: asStr(item['id']),
                name: 'web_search',
                input: item['action'],
                done: false,
                startedAt: DateTime.now(),
                meta: {'status': asStr(item['status'], 'in_progress'), 'raw': item},
              ),
            );
          }
        case 'response.function_call_arguments.delta':
          final itemId = asStr(j['item_id']);
          final callId = callByItem[itemId] ?? asStr(j['call_id'], itemId);
          argsSeen.add(callId);
          yield ToolCallDelta(callId, asStr(j['delta']));
        case 'response.output_item.done':
          final item = asMap(j['item']);
          switch (item['type']) {
            case 'reasoning':
              yield ReasoningEnd(
                meta: {
                  'rid': asStr(item['id']),
                  if (item['encrypted_content'] != null) 'enc': item['encrypted_content'],
                },
              );
            case 'function_call':
              final callId = asStr(item['call_id'], asStr(item['id']));
              if (!callByItem.containsValue(callId)) {
                yield ToolCallStart(callId, asStr(item['name']), meta: {'item_id': asStr(item['id'])});
              }
              if (!argsSeen.contains(callId)) yield ToolCallDelta(callId, asStr(item['arguments']));
            case 'web_search_call':
              yield ServerToolChunk(
                ServerToolPart(
                  callId: asStr(item['id']),
                  name: 'web_search',
                  input: item['action'],
                  done: true,
                  finishedAt: DateTime.now(),
                  meta: {'status': 'completed', 'raw': item},
                ),
              );
            case 'image_generation_call':
              final r = asStrOrNull(item['result']);
              if (r != null) yield ImageChunk('data:image/png;base64,$r');
            case 'message':
              for (final c in asList(item['content'])) {
                final ann = asList(asMap(c)['annotations']);
                if (ann.isNotEmpty) yield CitationChunk(parseUrlCitations(ann));
              }
          }
        case 'response.web_search_call.in_progress':
        case 'response.web_search_call.searching':
        case 'response.web_search_call.completed':
          final status = type.substring('response.web_search_call.'.length);
          final now = DateTime.now();
          yield ServerToolChunk(
            ServerToolPart(
              callId: asStr(j['item_id']),
              name: 'web_search',
              input: j['action'],
              done: status == 'completed',
              startedAt: now,
              finishedAt: status == 'completed' ? now : null,
              meta: {'status': status, 'raw': j},
            ),
          );
        case 'response.completed':
        case 'response.incomplete':
          final resp = asMap(j['response']);
          final u = asMapOrNull(resp['usage']);
          if (u != null) yield UsageChunk(_usage(u));
          final reason = asStrOrNull(asMap(resp['incomplete_details'])['reason']);
          yield FinishChunk(reason ?? asStrOrNull(resp['status']));
        case 'response.failed':
          final err = asMap(asMap(j['response'])['error']);
          throw ApiException(asStr(err['message'], 'Response failed'));
        case 'error':
          throw ApiException(asStr(j['message'], asStr(asMap(j['error'])['message'], 'Stream error')));
      }
    }
  }

  Stream<StreamChunk> _emitItem(Map<String, dynamic> item, {bool full = false}) async* {
    switch (item['type']) {
      case 'reasoning':
        for (final s in asList(item['summary'])) {
          yield ReasoningDelta(asStr(asMap(s)['text']), meta: {'rid': asStr(item['id'])});
        }
        yield ReasoningEnd(
          meta: {'rid': asStr(item['id']), if (item['encrypted_content'] != null) 'enc': item['encrypted_content']},
        );
      case 'message':
        for (final c in asList(item['content'])) {
          final m = asMap(c);
          if (m['type'] == 'output_text') yield TextDelta(asStr(m['text']));
          final ann = asList(m['annotations']);
          if (ann.isNotEmpty) yield CitationChunk(parseUrlCitations(ann));
        }
      case 'function_call':
        final callId = asStr(item['call_id'], asStr(item['id']));
        yield ToolCallStart(callId, asStr(item['name']), meta: {'item_id': asStr(item['id'])});
        yield ToolCallDelta(callId, asStr(item['arguments']));
      case 'web_search_call':
        yield ServerToolChunk(
          ServerToolPart(
            callId: asStr(item['id']),
            name: 'web_search',
            input: item['action'],
            done: true,
            meta: {'status': 'completed', 'raw': item},
          ),
        );
    }
  }

  TokenUsage _usage(Map<String, dynamic> u) => TokenUsage(
    input: asInt(u['input_tokens']),
    output: asInt(u['output_tokens']),
    cached: asInt(asMap(u['input_tokens_details'])['cached_tokens']),
    reasoning: asInt(asMap(u['output_tokens_details'])['reasoning_tokens']),
  );

  Future<Map<String, dynamic>> _buildBody(List<ChatMessage> messages, GenerationParams p) async {
    final body = <String, dynamic>{'model': p.model.modelId, 'stream': p.stream, 'store': false};
    final reasoningModel = p.model.reasoning;
    if (!(reasoningModel && isOpenAiReasoningModel(p.model.modelId))) {
      if (p.temperature != null) body['temperature'] = p.temperature;
      if (p.topP != null) body['top_p'] = p.topP;
    }
    if (p.maxTokens != null) body['max_output_tokens'] = p.maxTokens;

    final system = messages.where((m) => m.role == Role.system).map((m) => m.text).join('\n\n');
    if (system.isNotEmpty) body['instructions'] = system;

    if (reasoningModel) {
      final r = <String, dynamic>{};
      if (p.reasoning.enabled) r['summary'] = 'auto';
      if (p.reasoning != ReasoningLevel.auto) {
        r['effort'] = switch (p.reasoning) {
          ReasoningLevel.off => 'minimal',
          _ => openAiEffort(p.model.modelId, p.reasoning),
        };
      }
      if (r.isNotEmpty) body['reasoning'] = r;
      body['include'] = ['reasoning.encrypted_content'];
    }
    if (p.sessionId != null) body['prompt_cache_key'] = p.sessionId;

    final tools = <Map<String, dynamic>>[];
    if (p.model.tools) {
      for (final t in p.tools) {
        tools.add({
          'type': 'function',
          'name': t.name,
          'description': t.description,
          'parameters': t.parameters,
          'strict': false,
        });
      }
    }
    if (p.useBuiltInSearch) {
      tools.add({'type': 'web_search'});
    }
    if (tools.isNotEmpty) body['tools'] = tools;

    body['input'] = await _buildInput(messages, p.model);
    return body;
  }

  Future<List<Map<String, dynamic>>> _buildInput(List<ChatMessage> messages, ModelConfig model) async {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      if (m.role == Role.system) continue;
      if (m.role == Role.user) {
        final content = <Map<String, dynamic>>[];
        for (final part in m.parts) {
          switch (part) {
            case TextPart(:final text):
              if (text.isNotEmpty) content.add({'type': 'input_text', 'text': text});
            case ImagePart(:final url):
              if (!model.vision) continue;
              final enc = await MediaEncoder.encodeImage(url, providerId: config.id);
              if (enc != null) content.add({'type': 'input_image', 'image_url': enc.dataUri});
            case DocumentPart():
              content.add({'type': 'input_text', 'text': documentAsText(part)});
            default:
              break;
          }
        }
        if (content.isNotEmpty) out.add({'role': 'user', 'content': content});
        continue;
      }
      if (m.role != Role.assistant) continue;
      final text = StringBuffer();
      void flushText() {
        if (text.isEmpty) return;
        out.add({
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': text.toString(), 'annotations': []},
          ],
        });
        text.clear();
      }

      final pendingOutputs = <Map<String, dynamic>>[];
      void flushOutputs() {
        out.addAll(pendingOutputs);
        pendingOutputs.clear();
      }

      for (final part in m.parts) {
        switch (part) {
          case ReasoningPart():
            flushOutputs();
            flushText();
            final enc = part.meta?['enc'];
            final rid = part.meta?['rid'];
            if (enc != null && rid != null && config.includeHistoryReasoning) {
              out.add({
                'type': 'reasoning',
                'id': rid,
                'summary': [
                  if (part.text.isNotEmpty) {'type': 'summary_text', 'text': part.text},
                ],
                'encrypted_content': enc,
              });
            }
          case TextPart():
            flushOutputs();
            text.write(part.text);
          case ToolPart():
            if (!part.executed) continue;
            flushText();
            out.add({
              'type': 'function_call',
              'call_id': part.callId,
              'name': part.name,
              'arguments': part.input.isEmpty ? '{}' : part.input,
            });
            pendingOutputs.add({'type': 'function_call_output', 'call_id': part.callId, 'output': part.output ?? ''});
          default:
            break;
        }
      }
      flushOutputs();
      flushText();
    }
    return out;
  }
}
