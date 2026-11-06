import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../ai/message.dart';
import '../../chat/chat_controller.dart';
import '../../chat/helpers.dart';
import '../../core/i18n.dart';
import '../../core/paths.dart';
import '../../data/conversation.dart';
import '../../state/app_state.dart';
import '../../state/settings_store.dart';
import '../../state/tts.dart';
import '../export.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';
import 'chat_drawer.dart';
import 'composer.dart';
import 'message_bubble.dart';
import 'model_picker.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _scaffold = GlobalKey<ScaffoldState>();
  final _composer = GlobalKey<ComposerState>();
  final _scroll = ScrollController();
  bool _stickToBottom = true;
  bool _showJump = false;
  ChatController? _bound;
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _bound?.removeListener(_onChat);
    _scroll.dispose();
    super.dispose();
  }

  // The list is reversed: offset 0 is the bottom.
  void _onScroll() {
    final atBottom = _scroll.hasClients && _scroll.offset < 80;
    if (atBottom != _stickToBottom || _showJump == atBottom) {
      setState(() {
        _stickToBottom = atBottom;
        _showJump = !atBottom;
      });
    }
  }

  void _bind(ChatController c) {
    if (identical(_bound, c)) return;
    _bound?.removeListener(_onChat);
    _bound = c;
    c.addListener(_onChat);
    _lastCount = c.conversation.nodes.length;
    _stickToBottom = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  void _onChat() {
    final c = _bound;
    if (c == null || !mounted) return;
    if (c.lastError != null && !c.generating && c.conversation.nodes.isEmpty) {
      toast(context, c.lastError!, error: true);
      c.lastError = null;
    }
    final n = c.conversation.nodes.length;
    if (n != _lastCount) {
      _lastCount = n;
      _scrollToBottom();
    }
  }

  void _scrollToBottom({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      if (animate) {
        _scroll.animateTo(0, duration: const Duration(milliseconds: 380), curve: Curves.easeOutCubic);
      } else {
        _scroll.jumpTo(0);
      }
    });
  }

  Future<void> _onAction(ChatController c, int index, MessageAction a) async {
    final app = context.read<AppState>();
    final store = context.read<SettingsStore>();
    final node = c.conversation.nodes[index];
    final m = node.current;
    switch (a) {
      case MessageAction.copy:
        await copyText(context, m.text);
      case MessageAction.select:
        await _selectText(m.text);
      case MessageAction.edit:
        await _edit(c, index);
      case MessageAction.regenerate:
        await c.regenerate(index);
      case MessageAction.branchPrev:
        await c.selectBranch(index, node.selected - 1);
      case MessageAction.branchNext:
        await c.selectBranch(index, node.selected + 1);
      case MessageAction.delete:
        if (!mounted) return;
        if (await confirm(
          context,
          t('删除这条消息？', 'Delete this message?'),
          message: node.messages.length > 1 ? t('只删除当前分支', 'Only the visible branch is removed') : null,
          destructive: true,
        )) {
          await c.deleteBranch(index);
        }
      case MessageAction.fork:
        app.openForked(c.conversation.fork(index));
        if (mounted) toast(context, t('已创建分叉对话', 'Forked into a new chat'));
      case MessageAction.translate:
        await _translate(c, index);
      case MessageAction.speak:
        await context.read<TtsService>().toggle(m.id, m.text, store.value.tts);
      case MessageAction.favorite:
        await app.toggleFavorite(c.conversation, m);
      case MessageAction.share:
        await SharePlus.instance.share(ShareParams(text: m.text));
    }
  }

  Future<void> _selectText(String text) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: SingleChildScrollView(child: SelectableText(text, style: const TextStyle(fontSize: 16, height: 1.6))),
    ),
  );

  Future<void> _edit(ChatController c, int index) async {
    final m = c.conversation.nodes[index].current;
    final result = await showModalBottomSheet<(String, bool)>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _EditSheet(initial: m.text, isUser: m.role == Role.user),
    );
    if (result == null) return;
    final (text, resend) = result;
    final parts = [...m.parts.where((p) => p is! TextPart), if (text.trim().isNotEmpty) TextPart(text)];
    if (resend) {
      await c.editAndResend(index, parts);
    } else {
      await c.editInPlace(index, parts);
    }
  }

  Future<void> _translate(ChatController c, int index) async {
    final store = context.read<SettingsStore>();
    final m = c.conversation.nodes[index].current;
    if (m.translation != null) {
      await c.setTranslation(index, null);
      return;
    }
    toast(context, t('翻译中…', 'Translating…'));
    try {
      final target = I18n.isZh ? 'Simplified Chinese' : 'English';
      final out = await AiHelpers.translate(store.value, m.text, target);
      await c.setTranslation(index, out);
    } catch (e) {
      if (mounted) toast(context, '$e', error: true);
    }
  }

  Future<void> _compress(ChatController c) async {
    if (c.generating || c.conversation.nodes.length < 2) return;
    final ok = await confirm(
      context,
      t('压缩上下文', 'Compress context'),
      message: t(
        '让模型把目前的对话总结成一条摘要，之后只发送摘要和新消息，节省 token。原消息仍保留在界面上。',
        'The model summarises the chat so far; later requests send only the summary and new messages. Old messages stay visible.',
      ),
      ok: t('压缩', 'Compress'),
    );
    if (!ok || !mounted) return;
    final store = context.read<SettingsStore>();
    toast(context, t('正在总结…', 'Summarising…'));
    try {
      final summary = await AiHelpers.compress(store.value, c.resolvedModel?.model.id, c.conversation.currentMessages);
      final msg = ChatMessage(
        role: Role.user,
        parts: [
          TextPart(summary, meta: const {'summary': true}),
        ],
      );
      c.applyExternal((conv) => conv.upsertMessage('n-${msg.id}', msg));
      if (mounted) toast(context, t('已压缩', 'Compressed'));
    } catch (e) {
      if (mounted) toast(context, '$e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final store = context.watch<SettingsStore>();
    final c = app.chat;
    _bind(c);
    final s = store.value;
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final conv = c.conversation;
        final a = c.assistant;
        final resolved = c.resolvedModel;
        final model = resolved?.model;
        final bg = a.background;
        final body = Stack(
          children: [
            if (bg != null && bg.isNotEmpty)
              Positioned.fill(
                child: Opacity(
                  opacity: a.backgroundOpacity.clamp(0.05, 1.0),
                  child: Image.file(
                    File(AppPaths.resolve(bg)),
                    fit: BoxFit.cover,
                    errorBuilder: (context, e, st) => const SizedBox.shrink(),
                  ),
                ),
              ),
            Column(
              children: [
                Expanded(child: _messages(context, c, conv)),
                _Suggestions(items: c.generating ? const [] : conv.suggestions, onTap: (v) => c.send([TextPart(v)])),
                Composer(
                  key: _composer,
                  settings: s,
                  generating: c.generating,
                  onSend: (parts) async {
                    _stickToBottom = true;
                    _scrollToBottom();
                    await c.send(parts);
                    if (!mounted) return;
                    if (c.lastError != null && conv.nodes.isEmpty) toast(this.context, c.lastError!, error: true);
                    unawaited(app.refreshList());
                  },
                  onStop: c.stop,
                  modelLabel: model?.displayName ?? t('选择模型', 'Pick model'),
                  providerLabel: resolved?.provider.name ?? '',
                  onPickModel: () async {
                    final id = await pickModel(context, selected: model?.id);
                    if (id == null || id.isEmpty) return;
                    await c.setModel(id);
                    // New chats start with the model picked last.
                    store.update((s) => s.copyWith(lastChatModelId: id));
                  },
                  searchEnabled: a.enableWebSearch,
                  onToggleSearch: () {
                    final on = !a.enableWebSearch;
                    store.upsertAssistant(a.copyWith(enableWebSearch: on));
                    toast(context, on ? t('联网搜索已开启', 'Web search on') : t('联网搜索已关闭', 'Web search off'));
                  },
                  reasoning: c.reasoning,
                  onReasoning: (l) => store.update(
                    (s) => s.copyWith(
                      lastReasoning: l,
                      assistants: [for (final x in s.assistants) x.id == a.id ? x.copyWith(reasoning: l) : x],
                    ),
                  ),
                  supportsReasoning: model?.reasoning ?? false,
                  supportsVision: model?.vision ?? true,
                  activeModes: {...a.modeIds, ...c.modeIds},
                  onToggleMode: c.toggleMode,
                  onQuickMessage: (v) => _composer.currentState?.setText(v),
                  onCompress: () => _compress(c),
                ),
              ],
            ),
            Positioned(
              right: 16,
              bottom: 150,
              child: AnimatedScale(
                scale: _showJump ? 1 : 0,
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutBack,
                child: FloatingActionButton.small(
                  heroTag: 'jump',
                  elevation: 2,
                  onPressed: () => _scrollToBottom(),
                  child: const Icon(Icons.keyboard_double_arrow_down_rounded),
                ),
              ),
            ),
          ],
        );
        final scaffold = Scaffold(
          key: _scaffold,
          backgroundColor: Colors.transparent,
          drawer: wide ? null : const ChatDrawer(),
          drawerEdgeDragWidth: 48,
          appBar: _appBar(context, c, wide),
          body: body,
        );
        final page = AmbientBackground(child: scaffold);
        if (!wide) return page;
        return Row(
          children: [
            const SizedBox(width: 320, child: ChatDrawer(embedded: true)),
            VerticalDivider(width: 1, color: Theme.of(context).colorScheme.outlineVariant),
            Expanded(child: page),
          ],
        );
      },
    );
  }

  PreferredSizeWidget _appBar(BuildContext context, ChatController c, bool wide) {
    final scheme = Theme.of(context).colorScheme;
    final conv = c.conversation;
    final a = c.assistant;
    final model = c.resolvedModel;
    final title = conv.title.isEmpty ? (a.name.isEmpty ? 'MewHub' : a.name) : conv.title;
    return AppBar(
      backgroundColor: Colors.transparent,
      leading: wide
          ? null
          : IconButton(icon: const Icon(Icons.menu_rounded), onPressed: () => _scaffold.currentState?.openDrawer()),
      automaticallyImplyLeading: !wide,
      titleSpacing: wide ? 20 : 0,
      title: GestureDetector(
        onTap: () async {
          if (conv.nodes.isEmpty) return;
          final v = await promptText(context, t('重命名对话', 'Rename chat'), initial: conv.title);
          if (v != null) await c.setTitle(v.trim());
          if (context.mounted) unawaited(context.read<AppState>().refreshList());
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(anim),
                  child: child,
                ),
              ),
              child: Text(title, key: ValueKey(title), maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (model != null)
              Text(
                '${model.model.displayName} · ${model.provider.name}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
      actions: [
        IconButton(
          tooltip: t('新对话', 'New chat'),
          icon: const Icon(Icons.edit_square),
          onPressed: c.generating ? null : () => context.read<AppState>().newChat(),
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert_rounded),
          onSelected: (v) => _menuAction(c, v),
          itemBuilder: (context) => [
            PopupMenuItem(value: 'prompt', child: _MenuRow(Icons.tune_rounded, t('本对话系统提示词', 'Chat system prompt'))),
            PopupMenuItem(
              value: 'export_md',
              child: _MenuRow(Icons.description_outlined, t('导出 Markdown', 'Export Markdown')),
            ),
            PopupMenuItem(
              value: 'export_json',
              child: _MenuRow(Icons.data_object_rounded, t('导出 JSON', 'Export JSON')),
            ),
            PopupMenuItem(value: 'usage', child: _MenuRow(Icons.data_usage_rounded, t('用量统计', 'Token usage'))),
            PopupMenuItem(
              value: 'delete',
              child: _MenuRow(Icons.delete_outline_rounded, t('删除对话', 'Delete chat'), color: scheme.error),
            ),
          ],
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Future<void> _menuAction(ChatController c, String v) async {
    final app = context.read<AppState>();
    final conv = c.conversation;
    switch (v) {
      case 'prompt':
        final p = await promptText(
          context,
          t('本对话系统提示词', 'Chat system prompt'),
          initial: conv.customSystemPrompt ?? '',
          hint: t('留空则使用助手设置', 'Empty = use assistant prompt'),
          maxLines: 8,
        );
        if (p != null) await c.setCustomSystemPrompt(p);
      case 'export_md':
        await shareText(ConversationExport.markdown(conv), '${ConversationExport.fileName(conv)}.md');
      case 'export_json':
        await shareText(jsonEncode(conv.toJson()), '${ConversationExport.fileName(conv)}.json');
      case 'usage':
        final u = conv.totalUsage;
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(t('本对话用量', 'Chat usage')),
            content: Text(
              '${t('输入', 'Input')}: ${u.input}\n${t('输出', 'Output')}: ${u.output}\n${t('缓存命中', 'Cached')}: ${u.cached}\n${t('合计', 'Total')}: ${u.total}',
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('好', 'OK')))],
          ),
        );
      case 'delete':
        if (conv.nodes.isEmpty) return;
        if (await confirm(context, t('删除这个对话？', 'Delete this chat?'), destructive: true)) {
          await app.deleteConversation(conv.id);
        }
    }
  }

  Widget _messages(BuildContext context, ChatController c, Conversation conv) {
    final app = context.watch<AppState>();
    final s = context.read<SettingsStore>().value;
    if (conv.nodes.isEmpty) return _Welcome(onPick: (v) => _composer.currentState?.setText(v));
    final nodes = conv.nodes;
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(top: 12, bottom: 12),
      itemCount: nodes.length,
      itemBuilder: (context, rev) {
        final i = nodes.length - 1 - rev;
        final node = nodes[i];
        final isLast = i == nodes.length - 1;
        final streaming = isLast && c.generating && node.role == Role.assistant;
        final bubble = MessageBubble(
          key: ValueKey(node.id),
          node: node,
          index: i,
          assistant: c.assistant,
          display: s.display,
          streaming: streaming,
          isLast: isLast,
          favorite: app.favoriteIds.contains(node.current.id),
          error: isLast ? c.lastError : null,
          onAction: (a) => _onAction(c, i, a),
          onApprove: (id, ok) => c.resolveApproval(id, ok),
        );
        final summary = node.current.parts.any((p) => p is TextPart && p.meta?['summary'] == true);
        final child = summary ? _SummaryDivider(child: bubble) : bubble;
        // Only animate the most recent messages to keep long chats smooth.
        return rev < 2 ? EntranceFx(key: ValueKey('fx-${node.id}'), dy: 18, child: child) : child;
      },
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label, {this.color});
  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 20, color: color),
      const SizedBox(width: 12),
      Text(label, style: TextStyle(color: color)),
    ],
  );
}

class _SummaryDivider extends StatelessWidget {
  const _SummaryDivider({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
          child: Row(
            children: [
              const Expanded(child: Divider()),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  t('以上内容已压缩', 'Context compressed above'),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              const Expanded(child: Divider()),
            ],
          ),
        ),
        child,
      ],
    );
  }
}

class _Suggestions extends StatelessWidget {
  const _Suggestions({required this.items, required this.onTap});
  final List<String> items;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      child: items.isEmpty
          ? const SizedBox(width: double.infinity)
          : SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
                itemCount: items.length,
                separatorBuilder: (context, i) => const SizedBox(width: 8),
                itemBuilder: (context, i) => EntranceFx(
                  index: i,
                  dy: 8,
                  child: Pressable(
                    onTap: () => onTap(items[i]),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: scheme.primary.withValues(alpha: 0.25)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.subdirectory_arrow_right_rounded, size: 14, color: scheme.primary),
                          const SizedBox(width: 6),
                          Text(items[i], style: Theme.of(context).textTheme.labelLarge),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onPick});
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final store = context.watch<SettingsStore>();
    final a = store.value.currentAssistant;
    final hasModel = store.value.allModels().isNotEmpty;
    final ideas = [
      (Icons.lightbulb_outline_rounded, t('帮我想 5 个周末活动', 'Give me 5 weekend ideas')),
      (Icons.translate_rounded, t('把这段话翻译成英文：', 'Translate this into Chinese: ')),
      (Icons.code_rounded, t('用 Dart 写一个防抖函数', 'Write a debounce function in Dart')),
      (Icons.school_outlined, t('用通俗的话解释量子纠缠', 'Explain quantum entanglement simply')),
    ];
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              EntranceFx(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.6, end: 1),
                  duration: const Duration(milliseconds: 900),
                  curve: Curves.elasticOut,
                  builder: (context, v, child) => Transform.scale(scale: v, child: child),
                  child: AvatarView(value: a.avatar.isEmpty ? '🐱' : a.avatar, fallback: a.name, size: 76),
                ),
              ),
              const SizedBox(height: 18),
              EntranceFx(
                index: 1,
                child: Text(
                  a.name.isEmpty ? 'MewHub' : a.name,
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.5),
                ),
              ),
              const SizedBox(height: 6),
              EntranceFx(
                index: 2,
                child: Text(
                  hasModel
                      ? t('今天想聊点什么？', 'What shall we talk about?')
                      : t('先去设置里添加一个供应商吧', 'Add a provider in Settings to begin'),
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 28),
              if (hasModel)
                for (var i = 0; i < ideas.length; i++)
                  EntranceFx(
                    index: i + 3,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Pressable(
                        onTap: () => onPick(ideas[i].$2),
                        child: Container(
                          width: double.infinity,
                          constraints: const BoxConstraints(maxWidth: 420),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerLowest.withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: scheme.outlineVariant),
                          ),
                          child: Row(
                            children: [
                              Icon(ideas[i].$1, size: 20, color: scheme.primary),
                              const SizedBox(width: 12),
                              Expanded(child: Text(ideas[i].$2, style: Theme.of(context).textTheme.bodyMedium)),
                              Icon(Icons.arrow_forward_rounded, size: 16, color: scheme.onSurfaceVariant),
                            ],
                          ),
                        ),
                      ),
                    ),
                  )
              else
                EntranceFx(
                  index: 3,
                  child: FilledButton.icon(
                    onPressed: () => Navigator.of(context).pushNamed('/providers'),
                    icon: const Icon(Icons.hub_outlined),
                    label: Text(t('添加供应商', 'Add a provider')),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EditSheet extends StatefulWidget {
  const _EditSheet({required this.initial, required this.isUser});
  final String initial;
  final bool isUser;

  @override
  State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  late final _c = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t('编辑消息', 'Edit message'), style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
            child: TextField(controller: _c, autofocus: true, maxLines: null, minLines: 4),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context, (_c.text, false)),
                  child: Text(t('仅保存', 'Save only')),
                ),
              ),
              if (widget.isUser) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, (_c.text, true)),
                    child: Text(t('保存并重新发送', 'Save & resend')),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
