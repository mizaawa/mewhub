import '../ai/message.dart';
import '../ai/provider_config.dart';
import 'assistant.dart';
import 'provider_branding.dart';

const defaultAssistantId = '00000000-0000-4000-8000-00000000c47a';
const defaultAssistantAvatar = '🐱';

const defaultTitlePrompt = '''I will give you some dialogue content in the `<content>` block.
Summarize the conversation between user and assistant into a short title.
1. The title language should match the user's primary language ({locale} if unclear)
2. Do not use punctuation or other special symbols
3. Reply with the title only
4. No more than 12 characters for CJK, 6 words otherwise

<content>
{content}
</content>''';

const defaultSuggestionPrompt =
    '''I will provide chat content in the `<content>` block, between the User and the AI assistant.
Act as the **User** and write 3 short follow-up messages the user is likely to send next.

Rules:
1. One suggestion per line, no numbering, bullets or quotes
2. Use the conversation's language ({locale} if unclear)
3. Each suggestion under 20 characters for CJK, 10 words otherwise
4. Imitate the user's previous style
5. You are the User, not the Assistant

<content>
{content}
</content>''';

const defaultTranslatePrompt = '''You are a translation expert. Translate the text in <source_text> into {target_lang}.
Keep the meaning, tone and formatting (including Markdown). Reply with the translation only.

<source_text>
{source_text}
</source_text>''';

const defaultOcrPrompt = '''Transcribe all text in the image accurately, preserving structure with Markdown.
If the image contains no text, describe it in detail instead. Reply with the result only.''';

const defaultCompressPrompt = '''Stop and write a structured summary of the conversation so far. The summary replaces the history as context, so anything left out is lost.
Do not call tools. Use this Markdown structure and omit empty sections:

[Summary of previous conversation]

## User Goals
## Key Context
## Decisions and Conclusions
## Tool Results and Artifacts
## Open Items
## Current State

Write in the conversation's language ({locale} if unclear). Be specific; quote exact names, values and code.''';

const learningModePrompt = '''The user is STUDYING and asked you to follow these strict rules for this chat:
1. Get to know the user's goals and level first (keep it light).
2. Build on what they already know.
3. Guide, don't hand over answers: use questions, hints and small steps.
4. Check understanding; offer short recaps.
5. Vary the rhythm: explanations, questions, practice.
Never solve homework outright. Work through problems one step at a time, asking one question per step.''';

List<Assistant> defaultAssistants() => [
  Assistant(id: defaultAssistantId, name: 'MewBot', avatar: defaultAssistantAvatar, systemPrompt: ''),
  Assistant(
    name: '翻译官 Translator',
    avatar: '🌐',
    systemPrompt: 'You are a professional translator. If the user writes Chinese, translate into natural English; otherwise translate into Simplified Chinese. Reply with the translation only.',
    temperature: 0.3,
    localTools: const {},
  ),
  Assistant(
    name: '代码助手 Coder',
    avatar: '👩‍💻',
    systemPrompt: 'You are a senior software engineer. Give correct, idiomatic, production-ready code. Explain trade-offs briefly. Use fenced code blocks with language tags.',
    temperature: 0.2,
  ),
];

List<ModeInjection> defaultModes() => [
  ModeInjection(id: '00000000-0000-4000-8000-0000000000a1', name: '学习模式 Learning', content: learningModePrompt),
];

ModelConfig _m(
  String id, {
  String? name,
  bool vision = true,
  bool tools = true,
  bool reasoning = false,
  int ctx = 128000,
  bool imageOut = false,
}) => ModelConfig(
  modelId: id,
  displayName: name,
  input: {Modality.text, if (vision) Modality.image},
  output: {Modality.text, if (imageOut) Modality.image},
  abilities: {if (tools) ModelAbility.tool, if (reasoning) ModelAbility.reasoning},
  contextLength: ctx,
);

/// Built-in provider templates. Keys are empty; users fill in their own.
List<ProviderConfig> defaultProviders() => [
  zakoProvider(),
  ProviderConfig(
    id: 'p-openai',
    kind: ProviderKind.openai,
    name: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    useResponsesApi: true,
    builtIn: true,
    enabled: false,
    models: [
      _m('gpt-5.1', name: 'GPT-5.1', reasoning: true, ctx: 272000),
      _m('gpt-5-mini', name: 'GPT-5 mini', reasoning: true, ctx: 272000),
      _m('gpt-4.1', name: 'GPT-4.1', ctx: 1000000),
    ],
  ),
  ProviderConfig(
    id: 'p-anthropic',
    kind: ProviderKind.anthropic,
    name: 'Anthropic',
    baseUrl: 'https://api.anthropic.com/v1',
    builtIn: true,
    enabled: false,
    promptCaching: true,
    models: [
      _m('claude-sonnet-4-5', name: 'Claude Sonnet 4.5', reasoning: true, ctx: 200000),
      _m('claude-opus-4-1', name: 'Claude Opus 4.1', reasoning: true, ctx: 200000),
      _m('claude-haiku-4-5', name: 'Claude Haiku 4.5', reasoning: true, ctx: 200000),
    ],
  ),
  ProviderConfig(
    id: 'p-gemini',
    kind: ProviderKind.google,
    name: 'Gemini',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
    builtIn: true,
    enabled: false,
    models: [
      _m('gemini-2.5-pro', name: 'Gemini 2.5 Pro', reasoning: true, ctx: 1048576),
      _m('gemini-2.5-flash', name: 'Gemini 2.5 Flash', reasoning: true, ctx: 1048576),
      _m('gemini-2.5-flash-image', name: 'Nano Banana', tools: false, imageOut: true, ctx: 32768),
    ],
  ),
  ProviderConfig(
    id: 'p-deepseek',
    kind: ProviderKind.openai,
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com/v1',
    builtIn: true,
    enabled: false,
    balanceUrl: '{{baseUrl}}/user/balance',
    balancePath: 'balance_infos.0.total_balance',
    models: [
      _m('deepseek-chat', name: 'DeepSeek Chat', vision: false),
      _m('deepseek-reasoner', name: 'DeepSeek Reasoner', vision: false, reasoning: true),
    ],
  ),
  ProviderConfig(
    id: 'p-openrouter',
    kind: ProviderKind.openai,
    name: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    builtIn: true,
    enabled: false,
    balanceUrl: '{{baseUrl}}/credits',
    balancePath: 'data.total_credits',
  ),
  ProviderConfig(
    id: 'p-siliconflow',
    kind: ProviderKind.openai,
    name: '硅基流动 SiliconFlow',
    baseUrl: 'https://api.siliconflow.cn/v1',
    builtIn: true,
    enabled: false,
    balanceUrl: '{{baseUrl}}/user/info',
    balancePath: 'data.totalBalance',
  ),
  ProviderConfig(
    id: 'p-moonshot',
    kind: ProviderKind.openai,
    name: '月之暗面 Moonshot',
    baseUrl: 'https://api.moonshot.cn/v1',
    builtIn: true,
    enabled: false,
    balanceUrl: '{{baseUrl}}/users/me/balance',
    balancePath: 'data.available_balance',
  ),
  ProviderConfig(
    id: 'p-dashscope',
    kind: ProviderKind.openai,
    name: '阿里云百炼 Bailian',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    builtIn: true,
    enabled: false,
  ),
  ProviderConfig(
    id: 'p-volc',
    kind: ProviderKind.openai,
    name: '火山引擎 Volcengine',
    baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
    builtIn: true,
    enabled: false,
  ),
  ProviderConfig(
    id: 'p-zhipu',
    kind: ProviderKind.openai,
    name: '智谱 Zhipu',
    baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    builtIn: true,
    enabled: false,
  ),
  ProviderConfig(
    id: 'p-xai',
    kind: ProviderKind.openai,
    name: 'xAI',
    baseUrl: 'https://api.x.ai/v1',
    builtIn: true,
    enabled: false,
  ),
];

ProviderConfig zakoProvider() => ProviderConfig(
  id: zakoProviderId,
  kind: ProviderKind.openai,
  name: 'Zako AI',
  baseUrl: zakoBaseUrl,
  useResponsesApi: true,
  balanceUrl: '{{baseUrl}}/usage',
  builtIn: true,
  enabled: true,
);

/// Lock Zako's official identity, URL and enabled state; keep it pinned first.
/// Filtering preserves the user's relative order within each group.
List<ProviderConfig> normalizeProviders(List<ProviderConfig> providers) {
  final stored = providers.where((p) => p.isZako).firstOrNull;
  final official = stored == null
      ? zakoProvider()
      : stored.builtIn && stored.enabled && stored.name == 'Zako AI' && stored.baseUrl == zakoBaseUrl
      ? stored
      : ProviderConfig.fromJson({
          ...stored.toJson(),
          'name': 'Zako AI',
          'baseUrl': zakoBaseUrl,
          'builtIn': true,
          'enabled': true,
        });
  final others = providers.where((p) => !p.isZako && !(p.builtIn && p.id == 'p-ollama')).toList();
  return [official, ...others.where((p) => p.enabled), ...others.where((p) => !p.enabled)];
}

/// Seed used for preset messages of new assistants.
ChatMessage greetingMessage(String text) => ChatMessage.text(Role.assistant, text);
