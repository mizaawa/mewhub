import 'dart:io';

import '../ai/message.dart';
import '../ai/provider_config.dart';
import '../core/i18n.dart';
import '../core/util.dart';
import '../data/assistant.dart';
import '../data/models_misc.dart';
import '../data/settings.dart';

/// Expands `{{var}}` placeholders in system prompts and templates.
class Placeholders {
  static const keys = {
    'cur_date': ('当前日期', 'Current date'),
    'cur_time': ('当前时间', 'Current time'),
    'cur_datetime': ('日期时间', 'Date & time'),
    'weekday': ('星期', 'Weekday'),
    'model_id': ('模型 ID', 'Model ID'),
    'model_name': ('模型名称', 'Model name'),
    'locale': ('语言区域', 'Locale'),
    'timezone': ('时区', 'Timezone'),
    'system_version': ('系统版本', 'OS version'),
    'device_info': ('设备信息', 'Device'),
    'user': ('用户昵称', 'User nickname'),
    'char': ('助手名称', 'Assistant name'),
  };

  static String apply(String text, {required AppSettings s, required Assistant a, ModelConfig? model}) {
    if (!text.contains('{{')) return text;
    final now = DateTime.now();
    const wd = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    final values = <String, String>{
      'cur_date': formatDate(now),
      'cur_time': formatTime(now),
      'cur_datetime': formatDateTime(now),
      'weekday': wd[now.weekday - 1],
      'model_id': model?.modelId ?? '',
      'model_name': model?.displayName ?? '',
      'locale': Platform.localeName,
      'timezone': now.timeZoneName,
      'system_version': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'device_info': Platform.operatingSystem,
      'user': s.display.userName.isEmpty ? 'user' : s.display.userName,
      'char': a.name.isEmpty ? 'assistant' : a.name,
    };
    return text.replaceAllMapped(RegExp(r'\{\{\s*([a-zA-Z_]+)\s*\}\}'), (m) => values[m.group(1)!] ?? m.group(0)!);
  }

  /// Message template: `{{message}}`, `{{role}}`, `{{time}}`, `{{date}}`.
  static String template(String tpl, ChatMessage m) {
    if (tpl.trim().isEmpty || tpl.trim() == '{{message}}') return m.text;
    return tpl
        .replaceAll(RegExp(r'\{\{\s*message\s*\}\}'), m.text)
        .replaceAll(RegExp(r'\{\{\s*role\s*\}\}'), m.role.name)
        .replaceAll(RegExp(r'\{\{\s*time\s*\}\}'), formatTime(m.createdAt))
        .replaceAll(RegExp(r'\{\{\s*date\s*\}\}'), formatDate(m.createdAt));
  }
}

class _Injection {
  _Injection(this.content, this.position, this.depth, this.role, this.priority);
  final String content;
  final InjectPosition position;
  final int depth;
  final Role role;
  final int priority;
}

/// Builds the final message list sent to the provider.
class PromptBuilder {
  static List<ChatMessage> build({
    required AppSettings settings,
    required Assistant assistant,
    required ModelConfig model,
    required List<ChatMessage> history,
    String? customSystemPrompt,
    Set<String> extraModeIds = const {},
    List<MemoryItem> memories = const [],
    List<String> recentTitles = const [],
    List<String> toolHints = const [],
  }) {
    // 1. Visible history, minus empty / errored placeholders.
    var msgs = history.where((m) => !(m.role == Role.assistant && m.isEmpty && !m.hasToolCalls)).toList();

    // Context compression: start from the last summary marker.
    final cut = msgs.lastIndexWhere((m) => m.parts.any((p) => p is TextPart && p.meta?['summary'] == true));
    if (cut > 0) msgs = msgs.sublist(cut);

    // 2. Message limit (keep whole tool rounds by cutting at user messages).
    if (assistant.contextMessages > 0 && msgs.length > assistant.contextMessages) {
      var start = msgs.length - assistant.contextMessages;
      while (start < msgs.length && msgs[start].role != Role.user) {
        start++;
      }
      if (start < msgs.length) msgs = msgs.sublist(start);
    }

    // 3. Preset messages (few-shot / character greeting) go first.
    final preset = assistant.presetMessages;

    // 4. Templates + user-scope regexes on user text.
    msgs = [
      for (final m in msgs)
        if (m.role == Role.user)
          m.copyWith(
            parts: [
              for (final p in m.parts)
                if (p is TextPart)
                  p.copyWith(
                    text: applyRegexes(
                      Placeholders.template(assistant.messageTemplate, m.copyWith(parts: [p])),
                      assistant.regexes,
                      RegexScope.user,
                      visual: false,
                    ),
                  )
                else
                  p,
            ],
          )
        else if (m.role == Role.assistant)
          m.copyWith(
            parts: [
              for (final p in m.parts)
                if (p is TextPart)
                  p.copyWith(text: applyRegexes(p.text, assistant.regexes, RegexScope.assistant, visual: false))
                else
                  p,
            ],
          )
        else
          m,
    ];

    // 5. System prompt.
    final sys = StringBuffer();
    final base = customSystemPrompt?.trim().isNotEmpty == true ? customSystemPrompt! : assistant.systemPrompt;
    final injections = _collectInjections(settings, assistant, [...preset, ...msgs], extraModeIds);
    for (final i in injections.where((e) => e.position == InjectPosition.beforeSystem)) {
      sys.writeln(i.content);
      sys.writeln();
    }
    if (base.trim().isNotEmpty) sys.writeln(Placeholders.apply(base, s: settings, a: assistant, model: model));
    for (final i in injections.where((e) => e.position == InjectPosition.afterSystem)) {
      sys.writeln();
      sys.writeln(i.content);
    }
    if (memories.isNotEmpty) {
      sys.writeln();
      sys.writeln('<memories>');
      sys.writeln('Long-term memories about the user (use when relevant, keep them private):');
      for (final m in memories) {
        sys.writeln('- [${m.id.substring(0, 8)}] ${m.content}');
      }
      sys.writeln('</memories>');
    }
    if (recentTitles.isNotEmpty) {
      sys.writeln();
      sys.writeln('<recent_chats>');
      for (final t in recentTitles) {
        sys.writeln('- $t');
      }
      sys.writeln('</recent_chats>');
    }
    for (final h in toolHints) {
      sys.writeln();
      sys.writeln(h);
    }

    final out = <ChatMessage>[
      if (sys.toString().trim().isNotEmpty) ChatMessage.text(Role.system, sys.toString().trim()),
      ...preset.map(
        (m) => m.copyWith(
          parts: [
            for (final p in m.parts)
              if (p is TextPart)
                p.copyWith(
                  text: Placeholders.apply(p.text, s: settings, a: assistant, model: model),
                )
              else
                p,
          ],
        ),
      ),
    ];

    // 6. In-chat injections.
    final chat = [...msgs];
    final top = injections.where((e) => e.position == InjectPosition.topOfChat).toList();
    final bottom = injections.where((e) => e.position == InjectPosition.bottomOfChat).toList();
    final depth = injections.where((e) => e.position == InjectPosition.atDepth).toList();
    for (final d in depth) {
      final idx = (chat.length - d.depth).clamp(0, chat.length);
      chat.insert(idx, ChatMessage.text(d.role, d.content));
    }
    if (bottom.isNotEmpty) {
      final lastUser = chat.lastIndexWhere((m) => m.role == Role.user);
      final idx = lastUser < 0 ? chat.length : lastUser;
      for (final b in bottom.reversed) {
        chat.insert(idx, ChatMessage.text(b.role, b.content));
      }
    }
    for (final t in top.reversed) {
      chat.insert(0, ChatMessage.text(t.role, t.content));
    }
    out.addAll(chat);
    return out;
  }

  static List<_Injection> _collectInjections(
    AppSettings s,
    Assistant a,
    List<ChatMessage> msgs,
    Set<String> extraModeIds,
  ) {
    final out = <_Injection>[];
    final modeIds = {...a.modeIds, ...extraModeIds};
    for (final m in s.modes) {
      if (modeIds.contains(m.id) && m.content.trim().isNotEmpty) {
        out.add(_Injection(m.content, m.position, m.depth, m.role, 1 << 20));
      }
    }
    for (final book in s.lorebooks) {
      if (!book.enabled || !a.lorebookIds.contains(book.id)) continue;
      for (final e in book.entries) {
        final ctx = msgs.reversed.take(e.scanDepth).map((m) => m.text).join('\n');
        if (e.triggered(ctx) && e.content.trim().isNotEmpty) {
          out.add(_Injection(e.content, e.position, e.depth, e.role, e.priority));
        }
      }
    }
    out.sort((x, y) => y.priority.compareTo(x.priority));
    return out;
  }

  /// Plain-text transcript used by title / suggestion / compress prompts.
  static String transcript(List<ChatMessage> msgs, {int maxChars = 6000}) {
    final lines = <String>[];
    var size = 0;
    for (final m in msgs.reversed) {
      if (m.role != Role.user && m.role != Role.assistant) continue;
      final line = '${m.role == Role.user ? 'User' : 'Assistant'}: ${m.text.trim()}';
      if (size + line.length > maxChars && lines.isNotEmpty) break;
      lines.add(line.length > maxChars ? line.substring(0, maxChars) : line);
      size += line.length;
    }
    return lines.reversed.join('\n');
  }

  static String get localeLabel => I18n.isZh ? 'Simplified Chinese' : 'English';
}
