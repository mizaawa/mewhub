import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/ai/model_registry.dart';
import 'package:mewhub/ai/provider.dart';
import 'package:mewhub/ai/provider_config.dart';
import 'package:mewhub/chat/accumulator.dart';
import 'package:mewhub/core/sse.dart';
import 'package:mewhub/data/assistant.dart';
import 'package:mewhub/data/conversation.dart';
import 'package:mewhub/data/settings.dart';
import 'package:mewhub/tools/calculator.dart';

Stream<List<int>> _bytes(List<String> chunks) => Stream.fromIterable(chunks.map(utf8.encode));

void main() {
  group('SSE parser', () {
    test('parses events split across chunks', () async {
      final events = await parseSse(
        _bytes([
          'event: message_start\ndata: {"a"',
          ':1}\n\n',
          ': comment\n',
          'data: line1\ndata: line2\n\n',
          'data: [DONE]\n\n',
        ]),
      ).toList();
      expect(events.length, 3);
      expect(events[0].event, 'message_start');
      expect(jsonDecode(events[0].data), {'a': 1});
      expect(events[1].data, 'line1\nline2');
      expect(events[2].data, '[DONE]');
    });

    test('handles CRLF and bare JSON lines', () async {
      final events = await parseSse(_bytes(['data: {"x":1}\r\n\r\n', '{"y":2}\n'])).toList();
      expect(events.map((e) => jsonDecode(e.data)).toList(), [
        {'x': 1},
        {'y': 2},
      ]);
    });
  });

  group('PartAccumulator', () {
    test('merges text, reasoning and tool calls in order', () {
      final acc = PartAccumulator()
        ..add(const ReasoningDelta('think '))
        ..add(const ReasoningDelta('more', meta: {'signature': 'ab'}))
        ..add(const ReasoningDelta('', meta: {'signature': 'cd'}))
        ..add(const ReasoningEnd())
        ..add(const TextDelta('Hello'))
        ..add(const TextDelta(' world'))
        ..add(const ToolCallStart('c1', 'search_web'))
        ..add(const ToolCallDelta('c1', '{"query":'))
        ..add(const ToolCallDelta('c1', '"cats"}'))
        ..add(const UsageChunk(TokenUsage(input: 10, output: 5)))
        ..add(const UsageChunk(TokenUsage(input: 10, output: 9)));
      expect(acc.parts.length, 3);
      final r = acc.parts[0] as ReasoningPart;
      expect(r.text, 'think more');
      expect(r.meta?['signature'], 'abcd');
      expect(r.finished, isTrue);
      expect((acc.parts[1] as TextPart).text, 'Hello world');
      final tool = acc.parts[2] as ToolPart;
      expect(tool.inputJson, {'query': 'cats'});
      expect(acc.pendingTools.single.callId, 'c1');
      expect(acc.usage.output, 9);
    });

    test('dedupes citations by url', () {
      final acc = PartAccumulator()
        ..add(const CitationChunk([Citation(title: 'a', url: 'https://a')]))
        ..add(const CitationChunk([Citation(title: 'a2', url: 'https://a'), Citation(title: 'b', url: 'https://b')]));
      expect((acc.parts.single as CitationsPart).items.map((e) => e.url), ['https://a', 'https://b']);
    });

    test('updates one native search call and preserves its measured duration', () {
      final started = DateTime.utc(2026, 11, 8, 3);
      final finished = started.add(const Duration(seconds: 2));
      final acc = PartAccumulator()
        ..add(
          ServerToolChunk(
            ServerToolPart(
              callId: 'ws_1',
              name: 'web_search',
              done: false,
              startedAt: started,
              meta: {'status': 'in_progress'},
            ),
          ),
        )
        ..add(
          ServerToolChunk(
            ServerToolPart(callId: 'ws_1', name: 'web_search', done: false, meta: {'status': 'searching'}),
          ),
        )
        ..add(
          ServerToolChunk(
            ServerToolPart(
              callId: 'ws_1',
              name: 'web_search',
              done: true,
              finishedAt: finished,
              meta: {'status': 'completed'},
            ),
          ),
        );

      expect(acc.parts.whereType<ServerToolPart>(), hasLength(1));
      final search = acc.parts.single as ServerToolPart;
      expect(search.done, isTrue);
      expect(search.startedAt?.millisecondsSinceEpoch, started.millisecondsSinceEpoch);
      expect(search.finishedAt?.millisecondsSinceEpoch, finished.millisecondsSinceEpoch);
      expect(search.meta?['status'], 'completed');

      final restored = Part.fromJson(search.toJson()) as ServerToolPart;
      expect(restored.startedAt?.millisecondsSinceEpoch, started.millisecondsSinceEpoch);
      expect(restored.finishedAt?.millisecondsSinceEpoch, finished.millisecondsSinceEpoch);
    });
  });

  group('Serialization', () {
    test('message round-trip keeps all part types', () {
      final m = ChatMessage(
        role: Role.assistant,
        parts: [
          const ReasoningPart('r', meta: {'enc': 'x'}),
          const TextPart('t'),
          const ToolPart(callId: 'c', name: 'n', input: '{}', output: 'o', approval: ToolApproval.approved),
          const ImagePart('files/a.png'),
          const CitationsPart([Citation(title: 'T', url: 'https://u')]),
        ],
        usage: const TokenUsage(input: 1, output: 2),
      );
      final back = ChatMessage.fromJson(jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>);
      expect(back.parts.length, 5);
      expect((back.parts[0] as ReasoningPart).meta?['enc'], 'x');
      expect((back.parts[2] as ToolPart).approval, ToolApproval.approved);
      expect(back.usage?.output, 2);
    });

    test('settings defaults are valid', () {
      final s = AppSettings.initial();
      expect(s.assistants, isNotEmpty);
      expect(s.providers.any((p) => p.kind == ProviderKind.anthropic), isTrue);
      final again = AppSettings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(again.providers.length, s.providers.length);
      expect(again.currentAssistantId, s.currentAssistantId);
    });
  });

  group('Conversation branches', () {
    test('upsert adds a branch and selects it', () {
      var c = Conversation(assistantId: 'a');
      final m1 = ChatMessage.text(Role.assistant, 'v1');
      c = c.upsertMessage('n1', m1);
      final m2 = ChatMessage.text(Role.assistant, 'v2');
      c = c.upsertMessage('n1', m2);
      expect(c.nodes.single.messages.length, 2);
      expect(c.currentMessages.single.text, 'v2');
      c = c.selectBranch('n1', 0);
      expect(c.currentMessages.single.text, 'v1');
    });
  });

  test('model registry guesses capabilities', () {
    final claude = ModelRegistry.guess('claude-sonnet-4-5');
    expect(claude.reasoning && claude.vision && claude.tools, isTrue);
    expect(ModelRegistry.guess('text-embedding-3-small').type, ModelType.embedding);
    expect(ModelRegistry.guess('gpt-image-1').type, ModelType.image);
    expect(ModelRegistry.guess('deepseek-chat').reasoning, isFalse);
  });

  test('calculator', () {
    expect(Calculator.eval('(3+4)^2/7'), 7);
    expect(Calculator.eval('-2*3+sqrt(16)'), -2);
    expect(() => Calculator.eval('2+'), throwsFormatException);
  });

  test('regex replacement with groups', () {
    final r = [
      AssistantRegex(find: r'(\w+)@x', replace: r'[$1]', scopes: const {RegexScope.assistant}),
    ];
    expect(applyRegexes('hi bob@x', r, RegexScope.assistant, visual: false), 'hi [bob]');
    expect(applyRegexes('hi bob@x', r, RegexScope.user, visual: false), 'hi bob@x');
  });
}
