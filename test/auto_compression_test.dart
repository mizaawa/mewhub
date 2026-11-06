import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/ai/provider_config.dart';
import 'package:mewhub/chat/auto_compression.dart';
import 'package:mewhub/chat/prompt_builder.dart';
import 'package:mewhub/data/conversation.dart';
import 'package:mewhub/data/settings.dart';

MessageNode node(ChatMessage message) => MessageNode(messages: [message]);

Conversation conversation(List<ChatMessage> messages) =>
    Conversation(assistantId: 'assistant', nodes: [for (final message in messages) node(message)]);

void main() {
  test('auto-compression setting persists and can be disabled', () {
    final settings = AppSettings.initial();
    expect(settings.autoCompress, isTrue);
    expect(settings.autoCompressThreshold, 98);
    expect(AppSettings.fromJson(settings.copyWith(autoCompress: false).toJson()).autoCompress, isFalse);
    expect(AppSettings.fromJson(settings.copyWith(autoCompressThreshold: 92).toJson()).autoCompressThreshold, 92);
  });

  test('compresses completed history at the default 98% threshold', () {
    final messages = [
      ChatMessage.text(Role.user, 'first question'),
      ChatMessage.text(Role.assistant, 'first answer').copyWith(usage: const TokenUsage(input: 90, output: 8)),
      ChatMessage.text(Role.user, 'next question'),
    ];
    expect(AutoCompressionPlan.forConversation(conversation(messages), 100)?.endIndex, 1);
    expect(AutoCompressionPlan.forConversation(conversation(messages), 101), isNull);
    expect(AutoCompressionPlan.forConversation(conversation(messages), 101, thresholdPercent: 95)?.endIndex, 1);
  });

  test('recompresses from the last checkpoint and ignores older usage', () {
    final marker = ChatMessage(
      role: Role.user,
      parts: [
        const TextPart('summary', meta: {'summary': true}),
      ],
    );
    final messages = [
      ChatMessage.text(Role.user, 'old'),
      ChatMessage.text(Role.assistant, 'old answer').copyWith(usage: const TokenUsage(input: 99)),
      marker,
      ChatMessage.text(Role.assistant, 'new answer').copyWith(usage: const TokenUsage(input: 98)),
      ChatMessage.text(Role.user, 'next'),
    ];
    final plan = AutoCompressionPlan.forConversation(conversation(messages), 100);
    expect(plan?.startIndex, 2);
    expect(plan?.endIndex, 3);

    final stale = [...messages]..[3] = ChatMessage.text(Role.assistant, 'no usage');
    expect(AutoCompressionPlan.forConversation(conversation(stale), 100), isNull);
  });

  test('does not compress an unresolved tool call', () {
    final messages = [
      ChatMessage.text(Role.user, 'run tool'),
      ChatMessage(
        role: Role.assistant,
        parts: [const ToolPart(callId: '1', name: 'tool', input: '{}')],
        usage: const TokenUsage(input: 98),
      ),
      ChatMessage.text(Role.user, 'next'),
    ];
    expect(AutoCompressionPlan.forConversation(conversation(messages), 100), isNull);
  });

  test('checkpoint preserves the visible tree but sends only summary and newer messages', () {
    final messages = [
      ChatMessage.text(Role.user, 'old question'),
      ChatMessage.text(Role.assistant, 'old answer'),
      ChatMessage.text(Role.user, 'new question'),
    ];
    final original = conversation(messages);
    final checkpointed = insertCompressionCheckpoint(original, original.nodes[1].id, 'summary');
    expect(checkpointed.nodes.length, 4);
    expect(checkpointed.currentMessages.first.text, 'old question');
    expect(checkpointed.currentMessages.last.text, 'new question');
    final settings = AppSettings.initial();
    final prompt = PromptBuilder.build(
      settings: settings,
      assistant: settings.currentAssistant,
      model: ModelConfig(modelId: 'test-model'),
      history: checkpointed.currentMessages,
    );
    expect(prompt.where((message) => message.role != Role.system).map((message) => message.text), [
      'summary',
      'new question',
    ]);
  });
}
