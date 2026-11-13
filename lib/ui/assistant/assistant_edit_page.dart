import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/message.dart';
import '../../chat/prompt_builder.dart';
import '../../core/attachments.dart';
import '../../core/i18n.dart';
import '../../data/assistant.dart';
import '../../state/settings_store.dart';
import '../chat/composer.dart';
import '../chat/model_picker.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';

class AssistantEditPage extends StatefulWidget {
  const AssistantEditPage({super.key, required this.assistantId});
  final String assistantId;

  @override
  State<AssistantEditPage> createState() => _AssistantEditPageState();
}

class _AssistantEditPageState extends State<AssistantEditPage> with SingleTickerProviderStateMixin {
  late final SettingsStore _store = context.read<SettingsStore>();
  late Assistant _a = _store.value.assistantById(widget.assistantId)!;
  late final TabController _tabs = TabController(length: 4, vsync: this);
  late final _name = TextEditingController(text: _a.name);
  late final _prompt = TextEditingController(text: _a.systemPrompt);
  late final _greeting = TextEditingController(text: _a.greeting);
  late final _template = TextEditingController(text: _a.messageTemplate);

  @override
  void dispose() {
    _tabs.dispose();
    for (final c in [_name, _prompt, _greeting, _template]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save(Assistant a) {
    setState(() => _a = a);
    _store.upsertAssistant(a);
  }

  void _saveText() => _save(
    _a.copyWith(
      name: _name.text.trim(),
      systemPrompt: _prompt.text,
      greeting: _greeting.text,
      messageTemplate: _template.text.trim().isEmpty ? '{{message}}' : _template.text,
    ),
  );

  Future<void> _avatar() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) {
        const emojis = [
          '🐱',
          '🐶',
          '🦊',
          '🐰',
          '🐻',
          '🐼',
          '🐨',
          '🦄',
          '🐧',
          '🦉',
          '🌸',
          '🍀',
          '⭐',
          '🔥',
          '💡',
          '📚',
          '🎨',
          '🎵',
          '🧠',
          '🤖',
          '👩‍💻',
          '🧑‍🏫',
          '🧙',
          '🌐',
        ];
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final e in emojis)
                      Pressable(
                        onTap: () => Navigator.pop(ctx, e),
                        child: Container(
                          width: 48,
                          height: 48,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: Theme.of(ctx).colorScheme.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(e, style: const TextStyle(fontSize: 24)),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.pop(ctx, '__image__'),
                    icon: const Icon(Icons.photo_outlined),
                    label: Text(t('从相册选择', 'Choose from Photos')),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (choice == null) return;
    if (choice == '__image__') {
      final p = await Attachments.pickAvatar();
      if (p != null) _save(_a.copyWith(avatar: p));
    } else {
      _save(_a.copyWith(avatar: choice));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, _) => _saveText(),
      child: Scaffold(
        appBar: AppBar(
          title: Text(_a.name.isEmpty ? t('助手', 'Assistant') : _a.name),
          bottom: TabBar(
            controller: _tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: t('基础', 'Basics')),
              Tab(text: t('参数', 'Parameters')),
              Tab(text: t('工具', 'Tools')),
              Tab(text: t('高级', 'Advanced')),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabs,
          children: [_basics(context), _params(context), _tools(context), _advanced(context)],
        ),
      ),
    );
  }

  Widget _basics(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final model = _store.value.findModel(_a.chatModelId);
    return ListView(
      padding: const EdgeInsets.only(bottom: 40),
      children: [
        const SizedBox(height: 16),
        Center(
          child: Pressable(
            onTap: _avatar,
            child: Stack(
              children: [
                Hero(
                  tag: 'assistant-${_a.id}',
                  child: AvatarView(value: _a.avatar, fallback: _a.name, size: 88),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                    child: const Icon(Icons.edit_rounded, size: 14, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ),
        SettingsGroup(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _name,
                decoration: InputDecoration(labelText: t('名称', 'Name')),
                onChanged: (_) => setState(() {}),
                onEditingComplete: _saveText,
              ),
            ),
            ListTile(
              leading: const IconBadge(Icons.auto_awesome_outlined),
              title: Text(t('使用模型', 'Model')),
              subtitle: Text(model?.model.displayName ?? t('跟随全局默认', 'Use global default')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () async {
                final id = await pickModel(context, selected: _a.chatModelId, allowNone: true);
                if (id == null) return;
                _save(_a.copyWith(chatModelId: id.isEmpty ? null : id));
                // An explicit assistant model wins over the last one picked in chat.
                _store.update((s) => s.copyWith(lastChatModelId: null));
              },
            ),
          ],
        ),
        SettingsGroup(
          index: 1,
          title: t('系统提示词', 'System prompt'),
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _prompt,
                    minLines: 6,
                    maxLines: 18,
                    decoration: InputDecoration(hintText: t('你是一只可爱的猫娘助手…', 'You are a helpful assistant…')),
                    onChanged: (_) => _saveText(),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final e in Placeholders.keys.entries)
                        ActionChip(
                          label: Text('{{${e.key}}}', style: const TextStyle(fontSize: 12)),
                          tooltip: I18n.isZh ? e.value.$1 : e.value.$2,
                          onPressed: () {
                            final sel = _prompt.selection;
                            final text = '{{${e.key}}}';
                            final start = sel.isValid ? sel.start : _prompt.text.length;
                            final end = sel.isValid ? sel.end : _prompt.text.length;
                            _prompt.text = _prompt.text.replaceRange(start, end, text);
                            _prompt.selection = TextSelection.collapsed(offset: start + text.length);
                            _saveText();
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        SettingsGroup(
          index: 2,
          title: t('开场白', 'Greeting'),
          footer: t('新对话开始时显示的第一条助手消息', 'First assistant message in new chats'),
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(controller: _greeting, minLines: 2, maxLines: 8, onChanged: (_) => _saveText()),
            ),
          ],
        ),
        _presetSection(context),
      ],
    );
  }

  Widget _presetSection(BuildContext context) {
    final msgs = _a.presetMessages;
    return SettingsGroup(
      index: 3,
      title: t('预设消息（Few-shot）', 'Preset messages (few-shot)'),
      footer: t('每次请求都放在对话最前面', 'Sent before the chat in every request'),
      children: [
        for (var i = 0; i < msgs.length; i++)
          ListTile(
            leading: Icon(msgs[i].role == Role.user ? Icons.person_outline_rounded : Icons.smart_toy_outlined),
            title: Text(msgs[i].text, maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: IconButton(
              icon: const Icon(Icons.remove_circle_outline_rounded),
              onPressed: () => _save(_a.copyWith(presetMessages: [...msgs]..removeAt(i))),
            ),
            onTap: () async {
              final v = await promptText(context, t('编辑', 'Edit'), initial: msgs[i].text, maxLines: 8);
              if (v == null) return;
              final list = [...msgs];
              list[i] = ChatMessage.text(msgs[i].role, v);
              _save(_a.copyWith(presetMessages: list));
            },
          ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () => _addPreset(Role.user),
                  icon: const Icon(Icons.person_add_alt_rounded),
                  label: Text(t('用户消息', 'User message')),
                ),
              ),
              Expanded(
                child: TextButton.icon(
                  onPressed: () => _addPreset(Role.assistant),
                  icon: const Icon(Icons.add_comment_outlined),
                  label: Text(t('助手消息', 'Assistant message')),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _addPreset(Role role) async {
    final v = await promptText(
      context,
      role == Role.user ? t('用户消息', 'User message') : t('助手消息', 'Assistant message'),
      maxLines: 8,
    );
    if (v == null || v.trim().isEmpty) return;
    _save(_a.copyWith(presetMessages: [..._a.presetMessages, ChatMessage.text(role, v)]));
  }

  Widget _params(BuildContext context) {
    String fmt(double? v) => v == null ? t('默认', 'Default') : v.toStringAsFixed(2);
    return ListView(
      padding: const EdgeInsets.only(bottom: 40),
      children: [
        SettingsGroup(
          title: t('采样', 'Sampling'),
          children: [
            _SliderTile(
              key: const ValueKey('assistant-temperature'),
              icon: Icons.thermostat_rounded,
              title: 'Temperature',
              description: t(
                '控制回答的随机程度。调低（0～0.5）更稳定、严谨，适合写代码、翻译和查资料；'
                    '调高（1 以上）更发散、有创意，适合写作和头脑风暴，但也更容易跑题。'
                    '关闭开关则使用模型自己的默认值。',
                'How random the replies are. Lower (0–0.5) is steadier and more precise, good for code, '
                    'translation and facts; higher (above 1) is more varied and creative, good for writing and '
                    'brainstorming, but drifts off topic more easily. Switch it off to use the model default.',
              ),
              label: fmt(_a.temperature),
              enabled: _a.temperature != null,
              value: _a.temperature ?? 0.7,
              min: 0,
              max: 2,
              onToggle: (on) => _save(_a.copyWith(temperature: on ? 0.7 : null)),
              onChanged: (v) => _save(_a.copyWith(temperature: double.parse(v.toStringAsFixed(2)))),
            ),
            _SliderTile(
              key: const ValueKey('assistant-top-p'),
              icon: Icons.filter_alt_outlined,
              title: 'Top P',
              description: t(
                '核采样：每写一个词，只在概率加起来排前 P 的候选词里挑。数值越小用词越保守、集中，'
                    '1 表示不做限制。通常只调 Temperature 和 Top P 其中一个，另一个保持默认即可。',
                'Nucleus sampling: each word is picked only from the most likely candidates whose '
                    'probabilities add up to P. Smaller values keep the wording safer and more focused; 1 means '
                    'no limit. Usually tune either Temperature or Top P and leave the other at its default.',
              ),
              label: fmt(_a.topP),
              enabled: _a.topP != null,
              value: _a.topP ?? 1,
              min: 0,
              max: 1,
              onToggle: (on) => _save(_a.copyWith(topP: on ? 1.0 : null)),
              onChanged: (v) => _save(_a.copyWith(topP: double.parse(v.toStringAsFixed(2)))),
            ),
          ],
        ),
        SettingsGroup(
          index: 1,
          title: t('输出', 'Output'),
          children: [
            ListTile(
              leading: const IconBadge(Icons.psychology_alt_rounded),
              title: Text(t('思考强度', 'Reasoning effort')),
              subtitle: Text(reasoningLabel(_a.reasoning)),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => showModalBottomSheet<void>(
                context: context,
                builder: (ctx) => ReasoningSheet(
                  initial: _a.reasoning,
                  onChanged: (v) {
                    _save(_a.copyWith(reasoning: v));
                    _store.update((s) => s.copyWith(lastReasoning: v));
                  },
                ),
              ),
            ),
            ListTile(
              leading: const IconBadge(Icons.notes_rounded),
              title: Text(t('最大输出 tokens', 'Max output tokens')),
              subtitle: Text(_a.maxTokens?.toString() ?? t('默认', 'Default')),
              onTap: () async {
                final v = await promptText(
                  context,
                  t('最大输出 tokens', 'Max output tokens'),
                  initial: _a.maxTokens?.toString() ?? '',
                  hint: t('留空使用默认', 'Empty = default'),
                );
                if (v == null) return;
                _save(_a.copyWith(maxTokens: int.tryParse(v.trim())));
              },
            ),
            ListTile(
              leading: const IconBadge(Icons.history_rounded),
              title: Text(t('上下文消息数', 'Context messages')),
              subtitle: Text(_a.contextMessages == 0 ? t('不限制', 'Unlimited') : '${_a.contextMessages}'),
              onTap: () async {
                final v = await promptText(
                  context,
                  t('上下文消息数', 'Context messages'),
                  initial: '${_a.contextMessages}',
                  hint: t('0 表示不限制', '0 = unlimited'),
                );
                if (v == null) return;
                _save(_a.copyWith(contextMessages: int.tryParse(v.trim()) ?? 0));
              },
            ),
            SwitchListTile(
              secondary: const IconBadge(Icons.stream_rounded),
              title: Text(t('流式输出', 'Streaming')),
              value: _a.stream,
              onChanged: (v) => _save(_a.copyWith(stream: v)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _tools(BuildContext context) {
    final s = _store.value;
    Set<LocalTool> toggle(LocalTool t, bool on) => on ? {..._a.localTools, t} : ({..._a.localTools}..remove(t));
    return ListView(
      padding: const EdgeInsets.only(bottom: 40),
      children: [
        SettingsGroup(
          title: t('能力', 'Capabilities'),
          children: [
            SwitchListTile(
              secondary: const IconBadge(Icons.travel_explore_rounded),
              title: Text(t('联网搜索', 'Web search')),
              subtitle: Text(s.currentSearch?.label ?? t('未配置搜索服务', 'No search service')),
              value: _a.enableWebSearch,
              onChanged: (v) => _save(_a.copyWith(enableWebSearch: v)),
            ),
            SwitchListTile(
              secondary: const IconBadge(Icons.bookmark_added_outlined),
              title: Text(t('长期记忆', 'Long-term memory')),
              subtitle: Text(t('模型可以记住你的偏好', 'The model can remember your preferences')),
              value: _a.enableMemory,
              onChanged: (v) => _save(_a.copyWith(enableMemory: v)),
            ),
            if (_a.enableMemory)
              SwitchListTile(
                secondary: const IconBadge(Icons.public_rounded),
                title: Text(t('使用全局记忆', 'Use global memory')),
                subtitle: Text(t('与其它助手共享记忆', 'Share memories with other assistants')),
                value: _a.useGlobalMemory,
                onChanged: (v) => _save(_a.copyWith(useGlobalMemory: v)),
              ),
            SwitchListTile(
              secondary: const IconBadge(Icons.manage_history_rounded),
              title: Text(t('参考最近对话', 'Reference recent chats')),
              subtitle: Text(t('把最近几次对话的标题告诉模型', 'Tell the model your recent chat titles')),
              value: _a.enableRecentChats,
              onChanged: (v) => _save(_a.copyWith(enableRecentChats: v)),
            ),
            SwitchListTile(
              secondary: const IconBadge(Icons.verified_user_outlined),
              title: Text(t('运行工具前询问', 'Ask before running tools')),
              subtitle: Text(t('每次调用工具前先请你确认', 'Confirm each tool call first')),
              value: _a.toolApproval,
              onChanged: (v) => _save(_a.copyWith(toolApproval: v)),
            ),
          ],
        ),
        SettingsGroup(
          index: 1,
          title: t('本地工具', 'Local tools'),
          children: [
            for (final (tool, icon, title, subtitle) in [
              (
                LocalTool.timeInfo,
                Icons.schedule_rounded,
                t('时间日期', 'Date & time'),
                t('获取当前日期、时间和时区', 'Current date, time and zone'),
              ),
              (
                LocalTool.calculator,
                Icons.calculate_outlined,
                t('计算器', 'Calculator'),
                t('精确计算算式与常用函数', 'Exact maths and functions'),
              ),
              (
                LocalTool.cartesianPlot,
                Icons.grid_on_rounded,
                t('平面直角坐标系显示', 'Cartesian coordinate plot'),
                t('绘制函数和点，可全屏编辑', 'Graphs with a full-screen editor'),
              ),
              (
                LocalTool.clipboard,
                Icons.content_paste_rounded,
                t('剪贴板（需确认）', 'Clipboard (asks first)'),
                t('读取或写入剪贴板中的文字', 'Read or write clipboard text'),
              ),
              (
                LocalTool.deviceInfo,
                Icons.smartphone_rounded,
                t('设备信息', 'Device info'),
                t('获取系统版本、语言和电量', 'OS version, locale, battery'),
              ),
            ])
              SwitchListTile(
                secondary: IconBadge(icon),
                title: Text(title),
                subtitle: Text(subtitle),
                value: _a.localTools.contains(tool),
                onChanged: (v) => _save(_a.copyWith(localTools: toggle(tool, v))),
              ),
          ],
        ),
        SettingsGroup(
          index: 2,
          title: 'MCP',
          footer: s.mcpServers.isEmpty ? t('在 设置 → MCP 中添加服务器', 'Add servers in Settings → MCP') : null,
          children: [
            for (final m in s.mcpServers)
              SwitchListTile(
                secondary: const IconBadge(Icons.extension_outlined),
                title: Text(m.name.isEmpty ? m.url : m.name),
                subtitle: Text(m.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                value: _a.mcpServerIds.contains(m.id),
                onChanged: (v) => _save(
                  _a.copyWith(mcpServerIds: v ? {..._a.mcpServerIds, m.id} : ({..._a.mcpServerIds}..remove(m.id))),
                ),
              ),
            if (s.mcpServers.isEmpty)
              ListTile(
                leading: const IconBadge(Icons.add_rounded),
                title: Text(t('添加 MCP 服务器', 'Add an MCP server')),
                onTap: () => Navigator.of(context).pushNamed('/settings/mcp'),
              ),
          ],
        ),
      ],
    );
  }

  Widget _advanced(BuildContext context) {
    final s = _store.value;
    return ListView(
      padding: const EdgeInsets.only(bottom: 40),
      children: [
        SettingsGroup(
          title: t('消息模板', 'Message template'),
          footer: t('可用变量 {{message}} {{role}} {{time}} {{date}}', 'Variables: {{message}} {{role}} {{time}} {{date}}'),
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: TextField(controller: _template, minLines: 1, maxLines: 6, onChanged: (_) => _saveText()),
            ),
          ],
        ),
        SettingsGroup(
          index: 1,
          title: t('世界书与模式', 'Lorebooks & modes'),
          children: [
            for (final b in s.lorebooks)
              CheckboxListTile(
                secondary: const IconBadge(Icons.menu_book_outlined),
                title: Text(b.name.isEmpty ? t('未命名', 'Untitled') : b.name),
                subtitle: Text(t('${b.entries.length} 条', '${b.entries.length} entries')),
                value: _a.lorebookIds.contains(b.id),
                onChanged: (v) => _save(
                  _a.copyWith(lorebookIds: v == true ? {..._a.lorebookIds, b.id} : ({..._a.lorebookIds}..remove(b.id))),
                ),
              ),
            for (final m in s.modes)
              CheckboxListTile(
                secondary: const IconBadge(Icons.toggle_on_outlined),
                title: Text(m.name),
                subtitle: Text(t('始终开启的模式', 'Always-on mode')),
                value: _a.modeIds.contains(m.id),
                onChanged: (v) =>
                    _save(_a.copyWith(modeIds: v == true ? {..._a.modeIds, m.id} : ({..._a.modeIds}..remove(m.id)))),
              ),
            if (s.lorebooks.isEmpty && s.modes.isEmpty)
              ListTile(title: Text(t('还没有世界书或模式', 'No lorebooks or modes yet'))),
          ],
        ),
        SettingsGroup(
          index: 2,
          title: t('正则替换', 'Regex replacements'),
          children: [
            for (var i = 0; i < _a.regexes.length; i++)
              SwitchListTile(
                title: Text(_a.regexes[i].name.isEmpty ? _a.regexes[i].find : _a.regexes[i].name),
                subtitle: Text(
                  '${_a.regexes[i].find} → ${_a.regexes[i].replace}'
                  '${_a.regexes[i].visualOnly ? t('（仅显示）', ' (display only)') : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                value: _a.regexes[i].enabled,
                onChanged: (v) {
                  final list = [..._a.regexes];
                  list[i] = list[i].copyWith(enabled: v);
                  _save(_a.copyWith(regexes: list));
                },
              ),
            ListTile(
              leading: const IconBadge(Icons.add_rounded),
              title: Text(t('添加正则', 'Add regex')),
              onTap: _addRegex,
            ),
            if (_a.regexes.isNotEmpty)
              ListTile(
                leading: const IconBadge(Icons.clear_all_rounded),
                title: Text(t('清空正则', 'Remove all')),
                onTap: () => _save(_a.copyWith(regexes: const [])),
              ),
          ],
        ),
        SettingsGroup(
          index: 3,
          title: t('聊天背景', 'Chat background'),
          children: [
            ListTile(
              leading: const IconBadge(Icons.wallpaper_rounded),
              title: Text(_a.background == null ? t('选择背景图', 'Choose image') : t('更换背景图', 'Change image')),
              trailing: _a.background == null
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => _save(_a.copyWith(background: null)),
                    ),
              onTap: () async {
                final p = await Attachments.pickBackground();
                if (p != null) _save(_a.copyWith(background: p));
              },
            ),
            if (_a.background != null)
              _SliderTile(
                icon: Icons.opacity_rounded,
                title: t('不透明度', 'Opacity'),
                label: '${(_a.backgroundOpacity * 100).round()}%',
                enabled: true,
                value: _a.backgroundOpacity,
                min: 0.05,
                max: 1,
                onChanged: (v) => _save(_a.copyWith(backgroundOpacity: v)),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _addRegex() async {
    final find = TextEditingController();
    final replace = TextEditingController();
    var visual = false;
    final scopes = {RegexScope.assistant};
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(t('添加正则', 'Add regex')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: find,
                decoration: InputDecoration(labelText: t('查找（正则）', 'Find (regex)')),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: replace,
                decoration: InputDecoration(labelText: t(r'替换为（支持 $1）', r'Replace ($1 groups)')),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                children: [
                  FilterChip(
                    label: Text(t('用户', 'User')),
                    selected: scopes.contains(RegexScope.user),
                    onSelected: (v) => set(() => v ? scopes.add(RegexScope.user) : scopes.remove(RegexScope.user)),
                  ),
                  FilterChip(
                    label: Text(t('助手', 'Assistant')),
                    selected: scopes.contains(RegexScope.assistant),
                    onSelected: (v) =>
                        set(() => v ? scopes.add(RegexScope.assistant) : scopes.remove(RegexScope.assistant)),
                  ),
                ],
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(t('仅影响显示', 'Display only')),
                value: visual,
                onChanged: (v) => set(() => visual = v ?? false),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('取消', 'Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('添加', 'Add'))),
          ],
        ),
      ),
    );
    if (ok == true && find.text.isNotEmpty) {
      try {
        RegExp(find.text);
        _save(
          _a.copyWith(
            regexes: [
              ..._a.regexes,
              AssistantRegex(find: find.text, replace: replace.text, scopes: scopes, visualOnly: visual),
            ],
          ),
        );
      } catch (e) {
        if (mounted) toast(context, t('正则无效：$e', 'Invalid regex: $e'), error: true);
      }
    }
    find.dispose();
    replace.dispose();
  }
}

class _SliderTile extends StatelessWidget {
  const _SliderTile({
    super.key,
    required this.icon,
    required this.title,
    required this.label,
    required this.enabled,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.description,
    this.onToggle,
  });
  final IconData icon;
  final String title;
  final String label;
  final bool enabled;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  /// What the parameter does, shown under the title for people who have
  /// never met it before.
  final String? description;
  final ValueChanged<bool>? onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconBadge(icon),
              const SizedBox(width: 16),
              Expanded(child: Text(title, style: tt.bodyLarge)),
              Text(label, style: tt.labelLarge?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
              if (onToggle != null) Switch(value: enabled, onChanged: onToggle),
            ],
          ),
          if (description != null)
            Padding(
              // Lines up with the title, past the icon badge.
              padding: const EdgeInsets.fromLTRB(50, 2, 8, 2),
              child: Text(description!, style: tt.bodySmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.45)),
            ),
          AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: enabled
                ? Slider(
                    value: value.clamp(min, max),
                    min: min,
                    max: max,
                    divisions: ((max - min) * 20).round(),
                    onChanged: onChanged,
                  )
                : const SizedBox(width: double.infinity, height: 6),
          ),
        ],
      ),
    );
  }
}
