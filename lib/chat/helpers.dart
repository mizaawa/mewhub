import '../ai/factory.dart';
import '../ai/message.dart';
import '../ai/provider.dart';
import '../ai/provider_config.dart';
import '../core/i18n.dart';
import '../core/net.dart';
import '../data/database.dart';
import '../data/settings.dart';
import 'prompt_builder.dart';

/// One-shot completions used by background features (title, suggestions,
/// translation, OCR, compression).
class AiHelpers {
  static Future<String> complete(
    AppSettings s,
    String? modelId,
    List<ChatMessage> messages, {
    ReasoningLevel reasoning = ReasoningLevel.off,
    CancelToken? cancel,
    void Function(String partial)? onDelta,
    AppDatabase? db,
    String source = 'chat',
  }) async {
    final r = s.findModel(modelId) ?? s.findModel(s.chatModelId);
    if (r == null) throw ApiException(t('没有可用的模型', 'No model available'));
    final ai = providerFor(r.provider);
    final buf = StringBuffer();
    var usage = const TokenUsage();
    await for (final c in ai.stream(
      messages,
      GenerationParams(model: r.model, reasoning: reasoning, stream: true),
      cancel: cancel,
    )) {
      if (c is TextDelta) {
        buf.write(c.text);
        onDelta?.call(buf.toString());
      } else if (c is UsageChunk) {
        usage = usage.merge(c.usage);
      }
    }
    if (db != null && !usage.isEmpty) {
      await db.recordUsage(r.model.id, r.model.displayName, usage.input, usage.output, usage.cached, source: source);
    }
    return _stripThink(buf.toString()).trim();
  }

  static String _stripThink(String s) => s.replaceAll(RegExp(r'<think>[\s\S]*?</think>'), '');

  static Future<String?> title(AppSettings s, List<ChatMessage> msgs, {AppDatabase? db}) async {
    final prompt = s.titlePrompt
        .replaceAll('{locale}', PromptBuilder.localeLabel)
        .replaceAll('{content}', PromptBuilder.transcript(msgs, maxChars: 3000));
    final out = await complete(s, s.titleModelId, [ChatMessage.text(Role.user, prompt)], db: db, source: 'title');
    final line = out.split('\n').map((e) => e.trim()).firstWhere((e) => e.isNotEmpty, orElse: () => '');
    final cleaned = line.replaceAll(RegExp(r'''^["'“”《「#*\s]+|["'“”》」*\s.。]+$'''), '');
    return cleaned.isEmpty ? null : (cleaned.length > 40 ? cleaned.substring(0, 40) : cleaned);
  }

  static Future<List<String>> suggestions(AppSettings s, List<ChatMessage> msgs, {AppDatabase? db}) async {
    final prompt = s.suggestionPrompt
        .replaceAll('{locale}', PromptBuilder.localeLabel)
        .replaceAll('{content}', PromptBuilder.transcript(msgs, maxChars: 3000));
    final out = await complete(
      s,
      s.suggestionModelId ?? s.titleModelId,
      [ChatMessage.text(Role.user, prompt)],
      db: db,
      source: 'suggestions',
    );
    return out
        .split('\n')
        .map((e) => e.replaceFirst(RegExp(r'^\s*([-*•]|\d+[.)、])\s*'), '').trim())
        .where((e) => e.isNotEmpty && e.length <= 60)
        .take(4)
        .toList();
  }

  static Future<String> translate(
    AppSettings s,
    String text,
    String targetLang, {
    void Function(String)? onDelta,
    CancelToken? cancel,
    AppDatabase? db,
  }) {
    final prompt = s.translatePrompt.replaceAll('{target_lang}', targetLang).replaceAll('{source_text}', text);
    return complete(
      s,
      s.translateModelId ?? s.titleModelId,
      [ChatMessage.text(Role.user, prompt)],
      onDelta: onDelta,
      cancel: cancel,
      db: db,
      source: 'translation',
    );
  }

  static Future<String> ocr(AppSettings s, String imageUrl, {AppDatabase? db}) => complete(
    s,
    s.ocrModelId,
    [ChatMessage(role: Role.user, parts: [ImagePart(imageUrl), TextPart(s.ocrPrompt)])],
    db: db,
    source: 'ocr',
  );

  static Future<String> compress(
    AppSettings s,
    String? modelId,
    List<ChatMessage> history, {
    String extra = '',
    AppDatabase? db,
  }) {
    var prompt = s.compressPrompt.replaceAll('{locale}', PromptBuilder.localeLabel);
    if (extra.trim().isNotEmpty) prompt += '\n\nAdditional instructions from user: $extra';
    final convo = history.where((m) => m.role == Role.user || m.role == Role.assistant).map((m) {
      return ChatMessage(role: m.role, parts: [TextPart(m.text)]);
    }).toList();
    return complete(s, modelId, [...convo, ChatMessage.text(Role.user, prompt)], db: db, source: 'compression');
  }
}
