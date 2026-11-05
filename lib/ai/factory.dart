import 'provider.dart';
import 'provider_config.dart';
import 'providers/anthropic.dart';
import 'providers/google.dart';
import 'providers/openai_chat.dart';
import 'providers/openai_responses.dart';

AiProvider providerFor(ProviderConfig c) => switch (c.kind) {
  ProviderKind.openai => c.useResponsesApi ? OpenAiResponsesProvider(c) : OpenAiChatProvider(c),
  ProviderKind.anthropic => AnthropicProvider(c),
  ProviderKind.google => GoogleProvider(c),
};
