import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/provider_config.dart';
import '../../core/i18n.dart';
import '../../core/log.dart';
import '../../data/defaults.dart';
import '../../data/models_misc.dart';
import '../../data/settings.dart';
import '../../state/notifications.dart';
import '../../state/settings_store.dart';
import '../chat/model_picker.dart';
import '../settings/network_options.dart';
import '../widgets/code_block.dart';
import '../widgets/common.dart';

/// Default model assignments for each background task.
class DefaultModelsPage extends StatelessWidget {
  const DefaultModelsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final s = store.value;
    Widget row(
      IconData icon,
      String title,
      String sub,
      String? id,
      AppSettings Function(String?) set, {
      ModelType type = ModelType.chat,
      bool allowNone = true,
      int i = 0,
    }) {
      final m = s.findModel(id);
      return ListTile(
        leading: IconBadge(icon),
        title: Text(title),
        subtitle: Text(m == null ? sub : '${m.model.displayName} · ${m.provider.name}'),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: () async {
          final v = await pickModel(context, selected: id, type: type, allowNone: allowNone);
          if (v == null) return;
          store.replace(set(v.isEmpty ? null : v));
        },
      );
    }

    Widget promptRow(String title, String value, String def, AppSettings Function(String) set) => ListTile(
      leading: const IconBadge(Icons.edit_note_rounded),
      title: Text(title),
      subtitle: Text(value, maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () async {
        final v = await promptText(context, title, initial: value, maxLines: 14);
        if (v == null) return;
        store.replace(set(v.trim().isEmpty ? def : v));
      },
    );

    return Scaffold(
      appBar: AppBar(title: Text(t('默认模型', 'Default models'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          SettingsGroup(
            title: t('模型', 'Models'),
            children: [
              row(
                Icons.chat_bubble_outline_rounded,
                t('对话模型', 'Chat model'),
                t('未设置', 'Not set'),
                s.chatModelId,
                (v) => s.copyWith(chatModelId: v, lastChatModelId: null),
                allowNone: false,
              ),
              row(
                Icons.title_rounded,
                t('标题 / 建议模型', 'Title & suggestions'),
                t('跟随对话模型', 'Same as chat model'),
                s.titleModelId,
                (v) => s.copyWith(titleModelId: v),
              ),
              row(
                Icons.translate_rounded,
                t('翻译模型', 'Translation'),
                t('跟随标题模型', 'Same as title model'),
                s.translateModelId,
                (v) => s.copyWith(translateModelId: v),
              ),
              row(
                Icons.document_scanner_outlined,
                t('OCR 模型', 'OCR'),
                t('跟随对话模型', 'Same as chat model'),
                s.ocrModelId,
                (v) => s.copyWith(ocrModelId: v),
              ),
              row(
                Icons.brush_outlined,
                t('绘图模型', 'Image generation'),
                t('未设置', 'Not set'),
                s.imageModelId,
                (v) => s.copyWith(imageModelId: v),
                type: ModelType.image,
              ),
            ],
          ),
          SettingsGroup(
            index: 1,
            title: t('自动化', 'Automation'),
            children: [
              SwitchListTile(
                secondary: const IconBadge(Icons.auto_fix_high_rounded),
                title: Text(t('自动生成标题', 'Auto title')),
                value: s.autoTitle,
                onChanged: (v) => store.update((x) => x.copyWith(autoTitle: v)),
              ),
              SwitchListTile(
                secondary: const IconBadge(Icons.tips_and_updates_outlined),
                title: Text(t('回复后给出追问建议', 'Follow-up suggestions')),
                value: s.suggestions,
                onChanged: (v) => store.update((x) => x.copyWith(suggestions: v)),
              ),
            ],
          ),
          SettingsGroup(
            index: 2,
            title: t('提示词', 'Prompts'),
            children: [
              promptRow(
                t('标题提示词', 'Title prompt'),
                s.titlePrompt,
                defaultTitlePrompt,
                (v) => s.copyWith(titlePrompt: v),
              ),
              promptRow(
                t('建议提示词', 'Suggestion prompt'),
                s.suggestionPrompt,
                defaultSuggestionPrompt,
                (v) => s.copyWith(suggestionPrompt: v),
              ),
              promptRow(
                t('翻译提示词', 'Translation prompt'),
                s.translatePrompt,
                defaultTranslatePrompt,
                (v) => s.copyWith(translatePrompt: v),
              ),
              promptRow(t('OCR 提示词', 'OCR prompt'), s.ocrPrompt, defaultOcrPrompt, (v) => s.copyWith(ocrPrompt: v)),
              promptRow(
                t('压缩提示词', 'Compression prompt'),
                s.compressPrompt,
                defaultCompressPrompt,
                (v) => s.copyWith(compressPrompt: v),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class DisplaySettingsPage extends StatelessWidget {
  const DisplaySettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final d = store.value.display;
    void set(DisplaySettings Function(DisplaySettings) f) => store.update((s) => s.copyWith(display: f(s.display)));
    Widget sw(IconData icon, String title, bool v, ValueChanged<bool> f, {String? sub}) => SwitchListTile(
      secondary: IconBadge(icon),
      title: Text(title),
      subtitle: sub == null ? null : Text(sub),
      value: v,
      onChanged: f,
    );
    return Scaffold(
      appBar: AppBar(title: Text(t('聊天显示', 'Chat display'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          SettingsGroup(
            title: t('个人', 'You'),
            children: [
              ListTile(
                leading: const IconBadge(Icons.badge_outlined),
                title: Text(t('昵称', 'Nickname')),
                subtitle: Text(d.userName.isEmpty ? t('未设置（用于 {{user}}）', 'Not set (used by {{user}})') : d.userName),
                onTap: () async {
                  final v = await promptText(context, t('昵称', 'Nickname'), initial: d.userName);
                  if (v != null) set((x) => x.copyWith(userName: v.trim()));
                },
              ),
            ],
          ),
          SettingsGroup(
            index: 1,
            title: t('文字', 'Text'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Row(
                  children: [
                    const IconBadge(Icons.format_size_rounded),
                    const SizedBox(width: 16),
                    Expanded(child: Text(t('字号', 'Font size'))),
                    Text('${(d.fontScale * 100).round()}%'),
                  ],
                ),
              ),
              Slider(
                value: d.fontScale,
                min: 0.8,
                max: 1.4,
                divisions: 12,
                onChanged: (v) => set((x) => x.copyWith(fontScale: v)),
              ),
              ListTile(
                leading: const IconBadge(Icons.font_download_outlined),
                title: Text(t('字体', 'Font')),
                trailing: DropdownButton<ChatFont>(
                  value: d.chatFont,
                  underline: const SizedBox.shrink(),
                  borderRadius: BorderRadius.circular(14),
                  items: [
                    DropdownMenuItem(value: ChatFont.system, child: Text(t('系统', 'System'))),
                    DropdownMenuItem(value: ChatFont.serif, child: Text(t('衬线', 'Serif'))),
                    DropdownMenuItem(value: ChatFont.mono, child: Text(t('等宽', 'Mono'))),
                  ],
                  onChanged: (v) => set((x) => x.copyWith(chatFont: v)),
                ),
              ),
              sw(
                Icons.functions_rounded,
                t('LaTeX 公式', 'LaTeX math'),
                d.latex,
                (v) => set((x) => x.copyWith(latex: v)),
              ),
              sw(
                Icons.wrap_text_rounded,
                t('代码自动换行', 'Wrap code'),
                d.codeWrap,
                (v) => set((x) => x.copyWith(codeWrap: v)),
              ),
              sw(
                Icons.format_list_numbered_rounded,
                t('代码行号', 'Code line numbers'),
                d.codeLineNumbers,
                (v) => set((x) => x.copyWith(codeLineNumbers: v)),
              ),
            ],
          ),
          SettingsGroup(
            index: 2,
            title: t('消息', 'Messages'),
            children: [
              sw(
                Icons.chat_outlined,
                t('助手气泡', 'Assistant bubble'),
                d.bubbleAssistant,
                (v) => set((x) => x.copyWith(bubbleAssistant: v)),
              ),
              sw(
                Icons.label_outline_rounded,
                t('显示模型名称', 'Show model name'),
                d.showModelName,
                (v) => set((x) => x.copyWith(showModelName: v)),
              ),
              sw(
                Icons.data_usage_rounded,
                t('显示 Token 用量', 'Show token usage'),
                d.showTokenUsage,
                (v) => set((x) => x.copyWith(showTokenUsage: v)),
              ),
              sw(
                Icons.schedule_rounded,
                t('显示时间', 'Show time'),
                d.showTimestamps,
                (v) => set((x) => x.copyWith(showTimestamps: v)),
              ),
              sw(
                Icons.psychology_alt_outlined,
                t('显示思考过程', 'Show reasoning'),
                d.showThinking,
                (v) => set((x) => x.copyWith(showThinking: v)),
              ),
              sw(
                Icons.unfold_less_rounded,
                t('思考完成后自动折叠', 'Collapse reasoning when done'),
                d.autoCollapseThinking,
                (v) => set((x) => x.copyWith(autoCollapseThinking: v)),
              ),
            ],
          ),
          SettingsGroup(
            index: 3,
            title: t('输入', 'Input'),
            children: [
              sw(
                Icons.keyboard_return_rounded,
                t('回车发送', 'Enter to send'),
                d.sendOnEnter,
                (v) => set((x) => x.copyWith(sendOnEnter: v)),
              ),
              sw(Icons.vibration_rounded, t('触感反馈', 'Haptics'), d.haptics, (v) => set((x) => x.copyWith(haptics: v))),
              sw(
                Icons.text_snippet_outlined,
                t('长文本粘贴为文件', 'Send long text as a file'),
                d.pasteLongTextAsFile,
                (v) => set((x) => x.copyWith(pasteLongTextAsFile: v)),
                sub: t('超过 ${d.longTextThreshold} 字时', 'Over ${d.longTextThreshold} characters'),
              ),
              sw(Icons.notifications_active_outlined, t('回复完成通知', 'Notify when reply finishes'), d.notifyOnFinish, (
                v,
              ) async {
                if (v && !await Notifier.requestPermission()) {
                  if (context.mounted) toast(context, t('通知权限被拒绝', 'Notification permission denied'), error: true);
                  return;
                }
                set((x) => x.copyWith(notifyOnFinish: v));
              }),
            ],
          ),
        ],
      ),
    );
  }
}

class SearchSettingsPage extends StatelessWidget {
  const SearchSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final s = store.value;
    return Scaffold(
      appBar: AppBar(title: Text(t('联网搜索', 'Web search'))),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add_rounded),
        label: Text(t('添加', 'Add')),
        onPressed: () async {
          final type = await showModalBottomSheet<SearchServiceType>(
            context: context,
            builder: (ctx) => SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final ty in SearchServiceType.values)
                    ListTile(
                      leading: const Icon(Icons.travel_explore_rounded),
                      title: Text(SearchServiceConfig(type: ty).label),
                      onTap: () => Navigator.pop(ctx, ty),
                    ),
                ],
              ),
            ),
          );
          if (type == null) return;
          store.update(
            (x) => x.copyWith(
              searchServices: [
                ...x.searchServices,
                SearchServiceConfig(type: type),
              ],
            ),
          );
        },
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 100),
        children: [
          SettingsGroup(
            title: t('搜索服务', 'Services'),
            footer: t(
              '点选设为当前服务。Bing 无需 Key；其它服务需要在官网申请 Key。启用"内置联网搜索"的模型会直接使用模型自带搜索。',
              'Tap to make current. Bing needs no key; others need an API key. Models with native search use their own.',
            ),
            children: [
              for (var i = 0; i < s.searchServices.length; i++)
                _SearchTile(index: i, cfg: s.searchServices[i], selected: i == s.searchServiceIndex),
            ],
          ),
        ],
      ),
    );
  }
}

class _SearchTile extends StatelessWidget {
  const _SearchTile({required this.index, required this.cfg, required this.selected});
  final int index;
  final SearchServiceConfig cfg;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final store = context.read<SettingsStore>();
    void save(SearchServiceConfig c) => store.update((x) {
      final l = [...x.searchServices];
      l[index] = c;
      return x.copyWith(searchServices: l);
    });
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
        color: selected ? Theme.of(context).colorScheme.primary : null,
      ),
      title: Text(cfg.label),
      subtitle: Text(
        cfg.needsKey
            ? (cfg.apiKey.isEmpty
                  ? t('未填写 Key', 'No key')
                  : '••••${cfg.apiKey.length > 4 ? cfg.apiKey.substring(cfg.apiKey.length - 4) : ''}')
            : (cfg.type == SearchServiceType.searxng
                  ? (cfg.url.isEmpty ? t('未填写地址', 'No URL') : cfg.url)
                  : t('无需配置', 'No setup')),
      ),
      onTap: () => store.update((x) => x.copyWith(searchServiceIndex: index)),
      trailing: PopupMenuButton<String>(
        onSelected: (v) async {
          if (v == 'key') {
            final k = await promptText(context, 'API Key', initial: cfg.apiKey);
            if (k != null) save(cfg.copyWith(apiKey: k.trim()));
          } else if (v == 'url') {
            final u = await promptText(context, 'URL', initial: cfg.url, hint: 'https://searx.example.com');
            if (u != null) save(cfg.copyWith(url: u.trim()));
          } else if (v == 'n') {
            final n = await promptText(context, t('结果数量', 'Max results'), initial: '${cfg.maxResults}');
            if (n != null) save(cfg.copyWith(maxResults: (int.tryParse(n) ?? 5).clamp(1, 20)));
          } else if (v == 'del') {
            store.update((x) {
              final l = [...x.searchServices]..removeAt(index);
              return x.copyWith(searchServices: l, searchServiceIndex: 0);
            });
          }
        },
        itemBuilder: (context) => [
          if (cfg.needsKey) PopupMenuItem(value: 'key', child: Text(t('设置 Key', 'Set key'))),
          if (cfg.type == SearchServiceType.searxng) PopupMenuItem(value: 'url', child: Text(t('设置地址', 'Set URL'))),
          PopupMenuItem(value: 'n', child: Text(t('结果数量', 'Max results'))),
          PopupMenuItem(value: 'del', child: Text(t('删除', 'Delete'))),
        ],
      ),
    );
  }
}

class TtsSettingsPage extends StatelessWidget {
  const TtsSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final tts = store.value.tts;
    void set(TtsSettings v) => store.update((x) => x.copyWith(tts: v));
    return Scaffold(
      appBar: AppBar(title: Text(t('语音朗读', 'Text to speech'))),
      body: ListView(
        children: [
          SettingsGroup(
            title: t('系统语音', 'System voice'),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Row(
                  children: [
                    const IconBadge(Icons.speed_rounded),
                    const SizedBox(width: 16),
                    Expanded(child: Text(t('语速', 'Rate'))),
                    Text(tts.rate.toStringAsFixed(2)),
                  ],
                ),
              ),
              Slider(
                value: tts.rate,
                min: 0.1,
                max: 1.0,
                divisions: 18,
                onChanged: (v) => set(tts.copyWith(rate: v)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                child: Row(
                  children: [
                    const IconBadge(Icons.graphic_eq_rounded),
                    const SizedBox(width: 16),
                    Expanded(child: Text(t('音调', 'Pitch'))),
                    Text(tts.pitch.toStringAsFixed(2)),
                  ],
                ),
              ),
              Slider(
                value: tts.pitch,
                min: 0.5,
                max: 2.0,
                divisions: 15,
                onChanged: (v) => set(tts.copyWith(pitch: v)),
              ),
              ListTile(
                leading: const IconBadge(Icons.language_rounded),
                title: Text(t('语言', 'Language')),
                subtitle: Text(tts.language.isEmpty ? t('自动', 'Auto') : tts.language),
                onTap: () async {
                  final v = await promptText(
                    context,
                    t('语言代码', 'Language code'),
                    initial: tts.language,
                    hint: 'zh-CN / en-US / ja-JP',
                  );
                  if (v != null) set(tts.copyWith(language: v.trim()));
                },
              ),
              SwitchListTile(
                secondary: const IconBadge(Icons.format_quote_rounded),
                title: Text(t('只朗读引号内的内容', 'Only read quoted text')),
                value: tts.onlyQuoted,
                onChanged: (v) => set(tts.copyWith(onlyQuoted: v)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class NetworkSettingsPage extends StatelessWidget {
  const NetworkSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final s = store.value;
    return Scaffold(
      appBar: AppBar(title: Text(t('网络', 'Network'))),
      body: ListView(
        children: [
          SettingsGroup(
            footer: t(
              '代理格式 host:port，留空使用系统网络。仅对本应用的 API 请求生效。',
              'Proxy as host:port; empty uses the system network. Applies to API requests only.',
            ),
            children: [
              ListTile(
                leading: const IconBadge(Icons.vpn_lock_outlined),
                title: Text(t('HTTP 代理', 'HTTP proxy')),
                subtitle: Text(s.proxy.isEmpty ? t('未设置', 'Not set') : s.proxy),
                onTap: () async {
                  final v = await promptText(
                    context,
                    t('HTTP 代理', 'HTTP proxy'),
                    initial: s.proxy,
                    hint: '127.0.0.1:7890',
                  );
                  if (v != null) store.update((x) => x.copyWith(proxy: v.trim()));
                },
              ),
              ListTile(
                leading: const IconBadge(Icons.badge_outlined),
                title: const Text('User-Agent'),
                subtitle: Text(
                  s.userAgent.isEmpty ? t('默认', 'Default') : s.userAgent,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () async {
                  final v = await promptText(context, 'User-Agent', initial: s.userAgent);
                  if (v != null) store.update((x) => x.copyWith(userAgent: v.trim()));
                },
              ),
            ],
          ),
          const NetworkOptions(),
        ],
      ),
    );
  }
}

class RequestLogsPage extends StatelessWidget {
  const RequestLogsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(t('请求日志', 'Request logs')),
        actions: [IconButton(icon: const Icon(Icons.delete_sweep_outlined), onPressed: AppLog.clear)],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: AppLog.revision,
        builder: (context, _, _) {
          final logs = AppLog.requests;
          if (logs.isEmpty) {
            return EmptyState(
              icon: Icons.receipt_long_outlined,
              title: t('还没有请求', 'No requests yet'),
              subtitle: t(
                '最近 60 条 API 请求会显示在这里（Key 已打码，只保存在内存中）',
                'The last 60 API requests appear here (keys masked, memory only)',
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: logs.length,
            separatorBuilder: (context, i) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final l = logs[i];
              final ok = l.error == null && (l.status ?? 0) < 400;
              final color = l.status == null && l.error == null
                  ? scheme.primary
                  : (ok ? const Color(0xFF5E9E6E) : scheme.error);
              return Card(
                child: ExpansionTile(
                  shape: const Border(),
                  leading: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      l.status?.toString() ?? '…',
                      style: TextStyle(color: color, fontWeight: FontWeight.w700),
                    ),
                  ),
                  title: Text(
                    l.url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: Text(
                    '${l.method} · ${l.time.toIso8601String().substring(11, 19)}${l.duration == null ? '' : ' · ${l.duration!.inMilliseconds}ms'}${l.error == null ? '' : ' · ${l.error}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  children: [
                    CodeBlock(
                      code: l.requestHeaders.entries.map((e) => '${e.key}: ${e.value}').join('\n'),
                      language: 'http',
                      wrap: true,
                    ),
                    if (l.requestBody.isNotEmpty) CodeBlock(code: l.requestBody, language: 'json', wrap: true),
                    if (l.responseBody.isNotEmpty) CodeBlock(code: l.responseBody, language: 'json', wrap: true),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
