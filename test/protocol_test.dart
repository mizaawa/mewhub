import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/factory.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/ai/provider.dart';
import 'package:mewhub/ai/provider_config.dart';
import 'package:mewhub/ai/share_codec.dart';
import 'package:mewhub/chat/accumulator.dart';

class Captured {
  Captured(this.body, this.headers, this.path, this.parts, this.usage);
  final Map<String, dynamic> body;
  final Map<String, String> headers;
  final String path;
  final List<Part> parts;
  final TokenUsage usage;
}

/// Starts a loopback HTTP server that records the request and replies with a
/// canned SSE stream, then runs the provider against it end to end.
Future<Captured> runAgainst(
  ProviderConfig Function(String base) config,
  List<String> events,
  GenerationParams params, {
  List<ChatMessage>? messages,
  void Function(List<Part> parts)? onParts,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final seen = Completer<(Map<String, dynamic>, Map<String, String>, String)>();
  server.listen((req) async {
    final raw = await utf8.decodeStream(req);
    final headers = <String, String>{};
    req.headers.forEach((k, v) => headers[k] = v.join(','));
    seen.complete((jsonDecode(raw) as Map<String, dynamic>, headers, req.uri.toString()));
    req.response.headers.contentType = ContentType('text', 'event-stream');
    for (final e in events) {
      req.response.write(e);
      await req.response.flush();
    }
    await req.response.close();
  });
  try {
    final provider = providerFor(config('http://127.0.0.1:${server.port}/v1'));
    final acc = PartAccumulator();
    await for (final c in provider.stream(messages ?? [ChatMessage.text(Role.user, 'hi')], params)) {
      acc.add(c);
      onParts?.call(List.unmodifiable(acc.parts));
    }
    acc.closeAll();
    final (body, headers, path) = await seen.future;
    return Captured(body, headers, path, acc.parts, acc.usage);
  } finally {
    await server.close(force: true);
  }
}

String sse(Map<String, dynamic> j, {String? event}) =>
    '${event == null ? '' : 'event: $event\n'}data: ${jsonEncode(j)}\n\n';

Map<String, dynamic> chatDelta(Map<String, dynamic> delta, {String? finish}) => {
  'choices': [
    {'delta': delta, 'finish_reason': ?finish},
  ],
};

final reasoningTools = ModelConfig(
  modelId: 'test-model',
  abilities: {ModelAbility.tool, ModelAbility.reasoning},
  input: {Modality.text, Modality.image},
);

const timeTool = ToolSpec(
  name: 'get_time_info',
  description: 'time',
  parameters: {'type': 'object', 'properties': <String, dynamic>{}},
);

void main() {
  test('OpenAI Chat: request shape, reasoning, tool call deltas, usage', () async {
    final r = await runAgainst(
      (b) => ProviderConfig(kind: ProviderKind.openai, name: 'x', baseUrl: b, apiKey: 'k1,k2'),
      [
        sse(chatDelta({'reasoning_content': 'thinking'})),
        sse(chatDelta({'content': 'Hello'})),
        sse(
          chatDelta({
            'tool_calls': [
              {
                'index': 0,
                'id': 'call_1',
                'function': {'name': 'get_time_info', 'arguments': '{"a"'},
              },
            ],
          }),
        ),
        sse(
          chatDelta({
            'tool_calls': [
              {
                'index': 0,
                'function': {'arguments': ':1}'},
              },
            ],
          }, finish: 'tool_calls'),
        ),
        sse({
          'choices': <dynamic>[],
          'usage': {'prompt_tokens': 12, 'completion_tokens': 7},
        }),
        'data: [DONE]\n\n',
      ],
      GenerationParams(model: reasoningTools, reasoning: ReasoningLevel.high, tools: [timeTool], temperature: 0.5),
    );
    expect(r.path, '/v1/chat/completions');
    expect(r.headers['authorization'], startsWith('Bearer k'));
    expect(r.body['stream'], isTrue);
    expect(r.body['stream_options'], {'include_usage': true});
    expect(r.body['reasoning_effort'], 'high');
    expect((r.body['tools'] as List).single['function']['name'], 'get_time_info');
    expect(r.parts[0], isA<ReasoningPart>());
    expect((r.parts[1] as TextPart).text, 'Hello');
    final tool = r.parts[2] as ToolPart;
    expect(tool.callId, 'call_1');
    expect(tool.inputJson, {'a': 1});
    expect(r.usage.input, 12);
    expect(r.usage.output, 7);
  });

  test('OpenAI Chat: inline think tags split across chunks become reasoning', () async {
    final r = await runAgainst((b) => ProviderConfig(kind: ProviderKind.openai, name: 'x', baseUrl: b, apiKey: 'k'), [
      sse(chatDelta({'content': '<thi'})),
      sse(chatDelta({'content': 'nk>plan</th'})),
      sse(chatDelta({'content': 'ink>Answer'}, finish: 'stop')),
      'data: [DONE]\n\n',
    ], GenerationParams(model: ModelConfig(modelId: 'qwen')));
    expect((r.parts[0] as ReasoningPart).text, 'plan');
    expect((r.parts[1] as TextPart).text, 'Answer');
  });

  test('OpenAI Chat: custom body overrides support nested paths and deletion', () async {
    final r = await runAgainst(
      (b) => ProviderConfig(kind: ProviderKind.openai, name: 'x', baseUrl: b, apiKey: 'k'),
      ['data: [DONE]\n\n'],
      GenerationParams(
        model: ModelConfig(modelId: 'm'),
        temperature: 0.7,
        extraBodies: const [CustomBody('extra.top_k', '20'), CustomBody('temperature', 'null')],
      ),
    );
    expect(r.body['extra'], {'top_k': 20});
    expect(r.body.containsKey('temperature'), isFalse);
  });

  test('OpenAI Responses: reasoning summary, encrypted content, function call', () async {
    final searchStatuses = <(String, bool)>[];
    final r = await runAgainst(
      (b) => ProviderConfig(kind: ProviderKind.openai, name: 'x', baseUrl: b, apiKey: 'k', useResponsesApi: true),
      [
        sse({
          'type': 'response.output_item.added',
          'item': {
            'type': 'web_search_call',
            'id': 'ws_1',
            'status': 'in_progress',
            'action': {'type': 'search', 'query': 'Flutter documentation'},
          },
        }),
        sse({'type': 'response.web_search_call.in_progress', 'item_id': 'ws_1'}),
        sse({'type': 'response.web_search_call.searching', 'item_id': 'ws_1'}),
        sse({'type': 'response.web_search_call.completed', 'item_id': 'ws_1'}),
        sse({
          'type': 'response.output_item.done',
          'item': {
            'type': 'web_search_call',
            'id': 'ws_1',
            'status': 'completed',
            'action': {'type': 'search', 'query': 'Flutter documentation'},
          },
        }),
        sse({'type': 'response.reasoning_summary_text.delta', 'item_id': 'rs_1', 'delta': 'Plan'}),
        sse({
          'type': 'response.output_item.done',
          'item': {'type': 'reasoning', 'id': 'rs_1', 'encrypted_content': 'ENC'},
        }),
        sse({'type': 'response.output_text.delta', 'item_id': 'msg_1', 'delta': 'Done'}),
        sse({
          'type': 'response.output_item.added',
          'item': {
            'type': 'function_call',
            'id': 'fc_1',
            'call_id': 'call_9',
            'name': 'get_time_info',
            'arguments': '',
          },
        }),
        sse({'type': 'response.function_call_arguments.delta', 'item_id': 'fc_1', 'delta': '{}'}),
        sse({
          'type': 'response.completed',
          'response': {
            'status': 'completed',
            'usage': {
              'input_tokens': 20,
              'output_tokens': 5,
              'input_tokens_details': {'cached_tokens': 10},
            },
          },
        }),
      ],
      GenerationParams(
        model: reasoningTools,
        reasoning: ReasoningLevel.medium,
        tools: [timeTool],
        useBuiltInSearch: true,
      ),
      messages: [ChatMessage.text(Role.system, 'sys'), ChatMessage.text(Role.user, 'hi')],
      onParts: (parts) {
        final searches = parts.whereType<ServerToolPart>().toList();
        if (searches.isNotEmpty) {
          final search = searches.single;
          final status = ((search.meta?['status'] as String?) ?? '', search.done);
          if (searchStatuses.isEmpty || searchStatuses.last != status) searchStatuses.add(status);
        }
      },
    );
    expect(r.path, '/v1/responses');
    expect(r.body['store'], isFalse);
    expect(r.body['instructions'], 'sys');
    expect(r.body['reasoning'], {'summary': 'auto', 'effort': 'medium'});
    expect(r.body['include'], ['reasoning.encrypted_content']);
    expect((r.body['tools'] as List).map((tool) => (tool as Map)['type']), contains('web_search'));
    final search = r.parts.whereType<ServerToolPart>().single;
    expect(search.done, isTrue);
    expect(search.meta?['status'], 'completed');
    expect((search.input as Map)['query'], 'Flutter documentation');
    expect(search.startedAt, isNotNull);
    expect(search.finishedAt, isNotNull);
    expect(searchStatuses.map((e) => e.$1).toList(), ['in_progress', 'searching', 'completed']);
    expect(searchStatuses.map((e) => e.$2).toList(), [false, false, true]);
    final reasoning = r.parts[1] as ReasoningPart;
    expect(reasoning.text, 'Plan');
    expect(reasoning.meta?['enc'], 'ENC');
    expect(reasoning.meta?['rid'], 'rs_1');
    expect((r.parts[2] as TextPart).text, 'Done');
    expect((r.parts[3] as ToolPart).callId, 'call_9');
    expect(r.usage.cached, 10);
  });

  test('Anthropic: thinking + signature, tool_use, cache usage, headers', () async {
    final r = await runAgainst(
      (b) => ProviderConfig(kind: ProviderKind.anthropic, name: 'c', baseUrl: b, apiKey: 'ak', promptCaching: true),
      [
        sse({
          'type': 'message_start',
          'message': {
            'usage': {'input_tokens': 3, 'cache_read_input_tokens': 100, 'output_tokens': 1},
          },
        }, event: 'message_start'),
        sse({
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'thinking', 'thinking': ''},
        }),
        sse({
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'thinking_delta', 'thinking': 'hmm'},
        }),
        sse({
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'signature_delta', 'signature': 'SIG'},
        }),
        sse({'type': 'content_block_stop', 'index': 0}),
        sse({
          'type': 'content_block_start',
          'index': 1,
          'content_block': {'type': 'tool_use', 'id': 'toolu_1', 'name': 'get_time_info', 'input': <String, dynamic>{}},
        }),
        sse({
          'type': 'content_block_delta',
          'index': 1,
          'delta': {'type': 'input_json_delta', 'partial_json': '{"x":2}'},
        }),
        sse({'type': 'content_block_stop', 'index': 1}),
        sse({
          'type': 'message_delta',
          'delta': {'stop_reason': 'tool_use'},
          'usage': {'output_tokens': 9},
        }),
        sse({'type': 'message_stop'}),
      ],
      GenerationParams(model: reasoningTools, reasoning: ReasoningLevel.high, tools: [timeTool], temperature: 0.3),
      messages: [ChatMessage.text(Role.system, 'sys'), ChatMessage.text(Role.user, 'hi')],
    );
    expect(r.path, '/v1/messages');
    expect(r.headers['x-api-key'], 'ak');
    expect(r.headers['anthropic-version'], '2023-06-01');
    expect(r.body['thinking'], {'type': 'adaptive', 'display': 'summarized'});
    expect(r.body['output_config'], {'effort': 'high'});
    expect(r.body.containsKey('temperature'), isFalse, reason: 'sampling params are rejected with thinking on');
    expect((r.body['system'] as List).single['cache_control'], {'type': 'ephemeral'});
    final reasoning = r.parts[0] as ReasoningPart;
    expect(reasoning.text, 'hmm');
    expect(reasoning.meta?['signature'], 'SIG');
    expect((r.parts[1] as ToolPart).inputJson, {'x': 2});
    expect(r.usage.input, 103);
    expect(r.usage.cached, 100);
    expect(r.usage.output, 9);
  });

  test('Anthropic: history replays signed thinking and tool results', () async {
    final history = [
      ChatMessage.text(Role.user, 'what time'),
      ChatMessage(
        role: Role.assistant,
        parts: const [
          ReasoningPart('need tool', meta: {'signature': 'S1'}),
          ToolPart(callId: 't1', name: 'get_time_info', input: '{}', output: '{"iso":"x"}'),
          TextPart('It is x'),
        ],
      ),
      ChatMessage.text(Role.user, 'thanks'),
    ];
    final r = await runAgainst(
      (b) => ProviderConfig(kind: ProviderKind.anthropic, name: 'c', baseUrl: b, apiKey: 'k'),
      [
        sse({'type': 'message_stop'}),
      ],
      GenerationParams(model: reasoningTools),
      messages: history,
    );
    final msgs = r.body['messages'] as List;
    expect(msgs.map((m) => m['role']).toList(), ['user', 'assistant', 'user', 'assistant', 'user']);
    final first = msgs[1]['content'] as List;
    expect(first[0], {'type': 'thinking', 'thinking': 'need tool', 'signature': 'S1'});
    expect(first[1]['type'], 'tool_use');
    expect((msgs[2]['content'] as List).single['type'], 'tool_result');
    expect((msgs[3]['content'] as List).single['text'], 'It is x');
  });

  test('Gemini: thoughts, function call signature, grounding, usage', () async {
    final r = await runAgainst(
      (b) => ProviderConfig(kind: ProviderKind.google, name: 'g', baseUrl: b, apiKey: 'gk'),
      [
        sse({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'ponder', 'thought': true},
                  {
                    'functionCall': {'name': 'get_time_info', 'args': <String, dynamic>{}},
                    'thoughtSignature': 'TS',
                  },
                ],
              },
            },
          ],
        }),
        sse({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Answer'},
                ],
              },
              'finishReason': 'STOP',
              'groundingMetadata': {
                'groundingChunks': [
                  {
                    'web': {'uri': 'https://a.example', 'title': 'A'},
                  },
                ],
              },
            },
          ],
          'usageMetadata': {'promptTokenCount': 8, 'candidatesTokenCount': 4, 'thoughtsTokenCount': 2},
        }),
      ],
      GenerationParams(
        model: ModelConfig(modelId: 'gemini-2.5-flash', abilities: {ModelAbility.tool, ModelAbility.reasoning}),
        reasoning: ReasoningLevel.low,
        tools: [timeTool],
      ),
    );
    expect(r.path, '/v1/models/gemini-2.5-flash:streamGenerateContent?alt=sse');
    expect(r.headers['x-goog-api-key'], 'gk');
    expect(r.body['generationConfig']['thinkingConfig'], {'thinkingBudget': 1024, 'includeThoughts': true});
    expect((r.body['tools'] as List).first['functionDeclarations'], isNotEmpty);
    expect((r.parts[0] as ReasoningPart).text, 'ponder');
    expect((r.parts[1] as ToolPart).meta?['thoughtSignature'], 'TS');
    expect((r.parts[2] as TextPart).text, 'Answer');
    expect((r.parts[3] as CitationsPart).items.single.url, 'https://a.example');
    expect(r.usage.output, 6);
  });

  test('Gemini 3: thinking levels', () async {
    Future<Map<String, dynamic>> cfg(ReasoningLevel l) async {
      final r = await runAgainst(
        (b) => ProviderConfig(kind: ProviderKind.google, name: 'g', baseUrl: b, apiKey: 'gk'),
        [
          sse({'candidates': <dynamic>[]}),
        ],
        GenerationParams(
          model: ModelConfig(modelId: 'gemini-3-pro-preview', abilities: {ModelAbility.reasoning}),
          reasoning: l,
        ),
      );
      return r.body['generationConfig']['thinkingConfig'] as Map<String, dynamic>;
    }

    expect((await cfg(ReasoningLevel.off))['thinkingLevel'], 'minimal');
    expect((await cfg(ReasoningLevel.medium))['thinkingLevel'], 'medium');
    expect((await cfg(ReasoningLevel.max))['thinkingLevel'], 'high');
    expect((await cfg(ReasoningLevel.auto)).containsKey('thinkingLevel'), isFalse);
  });

  test('Provider share codes: native round trip and RikkaHub import', () {
    final p = ProviderConfig(
      kind: ProviderKind.anthropic,
      name: 'Claude',
      baseUrl: 'https://api.anthropic.com/v1',
      apiKey: 'secret',
      models: [ModelConfig(modelId: 'claude-x')],
    );
    final withKey = ProviderShareCodec.decode(ProviderShareCodec.encode(p)).single;
    expect(withKey.kind, ProviderKind.anthropic);
    expect(withKey.apiKey, 'secret');
    expect(withKey.models.single.modelId, 'claude-x');
    expect(withKey.id, isNot(p.id));
    final noKey = ProviderShareCodec.decode(ProviderShareCodec.encode(p, includeKey: false)).single;
    expect(noKey.apiKey, isEmpty);

    final rikka = jsonEncode({
      'type': 'openai',
      'name': 'Relay',
      'baseUrl': 'https://relay.example/v1',
      'apiKey': 'sk-x',
      'useResponseApi': true,
      'models': [
        {
          'modelId': 'gpt-x',
          'inputModalities': ['TEXT', 'IMAGE'],
          'abilities': ['TOOL'],
        },
      ],
    });
    final imported = ProviderShareCodec.decode('ai-provider:v1:${base64.encode(utf8.encode(rikka))}').single;
    expect(imported.kind, ProviderKind.openai);
    expect(imported.useResponsesApi, isTrue);
    expect(imported.models.single.vision, isTrue);
    expect(imported.models.single.tools, isTrue);
  });
}
