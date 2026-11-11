import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

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
import 'chat_navigation.dart';
import 'chat_quick_sheets.dart';
import 'chat_usage_sheet.dart';
import 'composer.dart';
import 'message_bubble.dart';
import 'model_picker.dart';

/// The follow motion keeps the same retargeted curve while reaching the new
/// bottom in half the time of v1.3.0.
const chatFollowTimeConstantMs = 42.5;
const chatNavigationVisibleDuration = Duration(milliseconds: 1500);

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with SingleTickerProviderStateMixin {
  final _scaffold = GlobalKey<ScaffoldState>();
  final _composer = GlobalKey<ComposerState>();
  final _scroll = ScrollController(keepScrollOffset: false);
  final _list = ListController();
  final _messageKeys = <String, GlobalKey>{};
  late final Ticker _motion;
  Duration? _lastFrame;
  Timer? _navigationTimer;
  bool _stickToBottom = true;
  bool _showJump = false;
  bool _readingHistory = false;
  bool _recentScroll = false;
  bool _userScrolling = false;
  bool _moving = false;
  bool _followScheduled = false;
  int? _seekIndex;
  ChatController? _bound;

  /// Height of everything docked at the bottom (suggestions + composer).
  /// The list runs behind the dock and pads its end by this much, so the
  /// last message still settles right above the input.
  final _dock = ValueNotifier<double>(0);

  double get _readingInset => MediaQuery.paddingOf(context).top + kToolbarHeight + 24;
  bool get _atBottom => _scroll.hasClients && _scroll.position.extentAfter <= 2;

  /// The measured dock, or a close estimate for the very first frame.
  double _dockInset(double measured) => measured > 0 ? measured : 120 + MediaQuery.paddingOf(context).bottom;

  /// Space after the last message: the dock plus the old breathing room.
  double get _listEndPadding => _dockInset(_dock.value) + 12;

  void _onDockHeight(double height) {
    if ((height - _dock.value).abs() > 0.5) _dock.value = height;
  }

  @override
  void initState() {
    super.initState();
    _motion = createTicker(_tick);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _bound?.removeListener(_onChat);
    _navigationTimer?.cancel();
    _motion.dispose();
    _list.dispose();
    _scroll.dispose();
    _dock.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_moving && !_motion.isActive && !_userScrolling) {
      _stickToBottom = _atBottom;
    }
    _updateNavigation();
  }

  void _updateNavigation() {
    if (!mounted) return;
    final reading = !_stickToBottom && !_atBottom;
    final show = reading && _recentScroll && !_userScrolling && !_motion.isActive;
    if (_showJump != show || _readingHistory != reading) {
      setState(() {
        _showJump = show;
        _readingHistory = reading;
      });
    }
  }

  void _recordScrollActivity({required bool started}) {
    // Match RikkaHub's isRecentScroll effect: arm on scroll start, restart the
    // 1.5 s expiry on stop, and only reveal while the list is stationary.
    // A stream update or viewport resize must never re-arm the controls.
    _navigationTimer?.cancel();
    if (started) _recentScroll = true;
    _navigationTimer = Timer(chatNavigationVisibleDuration, () {
      if (!mounted) return;
      _recentScroll = false;
      _updateNavigation();
    });
    _updateNavigation();
  }

  void _hideNavigation() {
    _navigationTimer?.cancel();
    _recentScroll = false;
    if (_showJump && mounted) setState(() => _showJump = false);
  }

  void _stopMotion() {
    _motion.stop();
    _lastFrame = null;
    _seekIndex = null;
  }

  bool _onScrollNotification(ScrollNotification notification) {
    // Horizontal code/table scrolling must not change the chat's follow mode.
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical || _moving) return false;
    if ((notification is ScrollStartNotification && notification.dragDetails != null) ||
        (notification is UserScrollNotification && notification.direction != ScrollDirection.idle)) {
      if (!_userScrolling) {
        _stopMotion();
        _userScrolling = true;
        _stickToBottom = false;
        _recordScrollActivity(started: true);
      }
    } else if (notification is ScrollEndNotification && _userScrolling) {
      _userScrolling = false;
      _stickToBottom = _atBottom;
      if (_stickToBottom) {
        _hideNavigation();
        _scheduleFollow();
      } else {
        _recordScrollActivity(started: false);
      }
    }
    _updateNavigation();
    return false;
  }

  void _scheduleFollow() {
    if (_followScheduled) return;
    _followScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _followScheduled = false;
      if (!mounted || !_scroll.hasClients || !_list.isAttached) return;
      if (_stickToBottom && !_userScrolling) _startMotion();
      _updateNavigation();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _startMotion() {
    if (!_motion.isActive) {
      _lastFrame = null;
      _motion.start();
    }
    _updateNavigation();
  }

  double _targetOffset() {
    final count = _list.numberOfItems;
    if (count == 0) return 0;
    final index = _seekIndex;
    final target = index == null ? _scroll.position.maxScrollExtent : _messageOffset(index.clamp(0, count - 1));
    return target.clamp(_scroll.position.minScrollExtent, _scroll.position.maxScrollExtent);
  }

  double _messageOffset(int index) {
    final node = _bound!.conversation.nodes[index];
    final render = _messageKeys[node.id]?.currentContext?.findRenderObject();
    if (render is RenderBox && render.hasSize) {
      return RenderAbstractViewport.of(render).getOffsetToReveal(render, 0).offset - _readingInset;
    }
    // Seek through unbuilt messages using the list's cached extents, then use
    // the actual render position once the target enters the viewport.
    var offset = 0.0;
    for (var i = 0; i < index; i++) {
      offset += _list.extentForIndex(i).$1;
    }
    return offset;
  }

  void _tick(Duration elapsed) {
    if (!_scroll.hasClients || !_list.isAttached || _userScrolling || (!_stickToBottom && _seekIndex == null)) {
      _stopMotion();
      return;
    }
    final target = _targetOffset();
    final delta = target - _scroll.offset;
    final dt = _lastFrame == null ? 16.0 : (elapsed - _lastFrame!).inMicroseconds / 1000;
    _lastFrame = elapsed;
    // Retarget the same motion every frame. New tokens never restart an
    // animation, and a drag cancels following before moving a single pixel.
    final finished = delta.abs() < 0.5 || MediaQuery.disableAnimationsOf(context);
    final next = finished
        ? target
        : _scroll.offset + delta * (1 - math.exp(-dt.clamp(1, 64) / chatFollowTimeConstantMs));
    _moving = true;
    if (next != _scroll.offset) _scroll.jumpTo(next);
    _moving = false;
    if (finished) {
      final jumpedToMessage = _seekIndex != null;
      _stopMotion();
      if (jumpedToMessage) _recordScrollActivity(started: false);
    }
    _updateNavigation();
  }

  int? _adjacentUser({required bool next}) {
    if (!_list.isAttached || !_scroll.hasClients) return null;
    final nodes = _bound!.conversation.nodes;
    if (nodes.isEmpty) return null;
    final visible = _list.visibleRange;
    var current = _seekIndex ?? visible?.$1 ?? 0;
    if (_seekIndex == null && visible != null) {
      final readingLine = _scroll.offset + 2;
      for (var i = visible.$1; i <= visible.$2 && i < nodes.length; i++) {
        if (_messageOffset(i) <= readingLine) current = i;
      }
    }
    for (var i = current + (next ? 1 : -1); i >= 0 && i < nodes.length; i += next ? 1 : -1) {
      if (nodes[i].role == Role.user) return i;
    }
    return null;
  }

  void _jumpToMessage(int index) {
    _stopMotion();
    _stickToBottom = false;
    _userScrolling = false;
    _seekIndex = index;
    _recordScrollActivity(started: true);
    _startMotion();
  }

  void _bind(ChatController c) {
    if (identical(_bound, c)) return;
    _bound?.removeListener(_onChat);
    _bound = c;
    _messageKeys.clear();
    c.addListener(_onChat);
    _stopMotion();
    _navigationTimer?.cancel();
    _showJump = false;
    _readingHistory = false;
    _recentScroll = false;
    _userScrolling = false;
    _stickToBottom = true;
    _scrollToBottom(animate: false);
  }

  void _onChat() {
    final c = _bound;
    if (c == null || !mounted) return;
    if (c.lastError != null && !c.generating && c.conversation.nodes.isEmpty) {
      toast(context, c.lastError!, error: true);
      c.lastError = null;
    }
    if (_stickToBottom) _scheduleFollow();
  }

  void _scrollToBottom({bool animate = true}) {
    _stopMotion();
    _stickToBottom = true;
    _userScrolling = false;
    _hideNavigation();
    final bound = _bound;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(bound, _bound) || !_scroll.hasClients || !_list.isAttached || !_stickToBottom) return;
      if (!animate) {
        _moving = true;
        final count = _list.numberOfItems;
        if (count > 0) {
          // Reveal the end padding together with the last message: it now
          // spans the whole dock, and leaving it to the follow motion would
          // visibly scroll every freshly opened chat.
          _list.jumpToItem(
            index: count - 1,
            scrollController: _scroll,
            alignment: 1,
            rect: Rect.fromLTWH(0, 0, 1, _list.extentForIndex(count - 1).$1 + _listEndPadding),
          );
        }
        _moving = false;
      }
      _startMotion();
      _updateNavigation();
    });
    // Also used from a tap without a conversation update.
    WidgetsBinding.instance.ensureVisualUpdate();
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
    // The message id survives the round trip; an index may not, because a
    // reply can still be streaming while the editor is open.
    if (resend) {
      await c.editAndResend(m.id, parts);
    } else {
      await c.editInPlace(m.id, parts);
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
      final out = await AiHelpers.translate(store.value, m.text, target, db: context.read<AppState>().db);
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
      final summary = await AiHelpers.compress(
        store.value,
        c.resolvedModel?.model.id,
        c.conversation.currentMessages,
        db: context.read<AppState>().db,
      );
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
      listenable: Listenable.merge([c, app.mcp]),
      builder: (context, _) {
        final conv = c.conversation;
        final a = c.assistant;
        final resolved = c.resolvedModel;
        final model = resolved?.model;
        final mcpOverview = McpOverview.of(s, a, app.mcp);
        final extensions = ExtensionsOverview.of(s, a, c.modeIds);
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
            Positioned.fill(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ShaderMask(
                    key: const ValueKey('chat-top-fade'),
                    blendMode: BlendMode.dstIn,
                    shaderCallback: (bounds) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0x26000000), Colors.black],
                      stops: [0, 0.6, 1],
                    ).createShader(Rect.fromLTWH(0, 0, bounds.width, math.min(_readingInset, bounds.height))),
                    child: _messages(context, c, conv),
                  ),
                  // Floating controls keep clear of the dock as it grows.
                  ValueListenableBuilder<double>(
                    valueListenable: _dock,
                    builder: (context, measured, _) {
                      final dock = _dockInset(measured);
                      return Stack(
                        fit: StackFit.expand,
                        children: [
                          if (_readingHistory && c.generating)
                            Positioned(
                              bottom: dock + 16,
                              left: 0,
                              right: 72,
                              child: Center(
                                child: StreamingBelow(
                                  key: const ValueKey('streaming-below'),
                                  onTap: () => _scrollToBottom(),
                                ),
                              ),
                            ),
                          Positioned(
                            right: 16,
                            bottom: dock + 16,
                            child: ListenableBuilder(
                              listenable: _scroll,
                              builder: (context, _) => ChatNavigation(
                                visible: _showJump,
                                onTop: () => _jumpToMessage(0),
                                onPrevious: _adjacentUser(next: false) == null
                                    ? null
                                    : () {
                                        final index = _adjacentUser(next: false);
                                        if (index != null) _jumpToMessage(index);
                                      },
                                onNext: _adjacentUser(next: true) == null
                                    ? null
                                    : () {
                                        final index = _adjacentUser(next: true);
                                        if (index != null) _jumpToMessage(index);
                                      },
                                onBottom: () => _scrollToBottom(),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _DockMeasure(
                onHeight: _onDockHeight,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Suggestions(
                      items: c.generating ? const [] : conv.suggestions,
                      onTap: (v) => c.send([TextPart(v)]),
                    ),
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
                      onCompress: () => _compress(c),
                      mcpLabel: mcpOverview.compact,
                      mcpDot: mcpOverview.dot(Theme.of(context).colorScheme),
                      mcpActive: mcpOverview.active > 0,
                      onOpenMcp: () => showMcpQuickSheet(context, c),
                      extensionsLabel: extensions.compact,
                      extensionsActive: extensions.activeCount,
                      onOpenExtensions: () => showExtensionsQuickSheet(
                        context,
                        c,
                        onQuickMessage: (v) => _composer.currentState?.setText(v),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
        final scaffold = Scaffold(
          key: _scaffold,
          backgroundColor: Colors.transparent,
          extendBodyBehindAppBar: true,
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
          onPressed: () => context.read<AppState>().newChat(),
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
      case 'usage':
        if (!mounted) return;
        await showChatUsageSheet(context, conv, contextLength: c.resolvedModel?.model.contextLength);
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
    if (conv.nodes.isEmpty) {
      return ValueListenableBuilder<double>(
        valueListenable: _dock,
        builder: (context, measured, child) => Padding(
          padding: EdgeInsets.only(top: _readingInset, bottom: _dockInset(measured)),
          child: child,
        ),
        child: _Welcome(onPick: (v) => _composer.currentState?.setText(v)),
      );
    }
    final nodes = conv.nodes;
    final indices = {for (var i = 0; i < nodes.length; i++) nodes[i].id: i};
    _messageKeys.removeWhere((id, _) => !indices.containsKey(id));
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.depth == 0 && notification.metrics.axis == Axis.vertical) _scheduleFollow();
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: CustomScrollView(
          key: ValueKey(conv.id),
          controller: _scroll,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverPadding(
              padding: EdgeInsets.only(top: _readingInset),
              sliver: SuperSliverList(
                listController: _list,
                delegate: SliverChildBuilderDelegate(
                  childCount: nodes.length,
                  findChildIndexCallback: (key) => key is ValueKey<String> ? indices[key.value] : null,
                  (context, i) {
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
                    // Stable identity keeps expanded code/reasoning state while appending.
                    return KeyedSubtree(
                      key: ValueKey(node.id),
                      child: SizedBox(key: _messageKeys.putIfAbsent(node.id, GlobalKey.new), child: child),
                    );
                  },
                ),
              ),
            ),
            // Room for the dock, which floats over the end of the list. It is a
            // sliver of its own: resizing it never touches the list's padding,
            // which message offsets are read from while navigation builds.
            SliverToBoxAdapter(
              child: ValueListenableBuilder<double>(
                valueListenable: _dock,
                builder: (context, measured, _) => SizedBox(height: _dockInset(measured) + 12),
              ),
            ),
          ],
        ),
      ),
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

/// Follow-up suggestions floating just above the composer. The row itself
/// has no background, so the conversation stays visible between the pills.
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
              height: 42,
              child: ListView.separated(
                key: const ValueKey('chat-suggestions'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 6),
                clipBehavior: Clip.none,
                itemCount: items.length,
                separatorBuilder: (context, i) => const SizedBox(width: 8),
                itemBuilder: (context, i) => EntranceFx(
                  index: i,
                  dy: 8,
                  child: Pressable(
                    onTap: () => onTap(items[i]),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(10, 0, 12, 0),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: scheme.primary.withValues(alpha: 0.22)),
                        boxShadow: [
                          BoxShadow(
                            color: scheme.shadow.withValues(alpha: 0.08),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.subdirectory_arrow_right_rounded, size: 14, color: scheme.primary),
                          const SizedBox(width: 5),
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

/// Reports its child's height after layout, so the list behind the dock can
/// pad its end by exactly that much.
class _DockMeasure extends SingleChildRenderObjectWidget {
  const _DockMeasure({required this.onHeight, required super.child});
  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderDockMeasure(onHeight);

  @override
  void updateRenderObject(BuildContext context, _RenderDockMeasure renderObject) => renderObject.onHeight = onHeight;
}

class _RenderDockMeasure extends RenderProxyBox {
  _RenderDockMeasure(this.onHeight);
  ValueChanged<double> onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final height = size.height;
    if (height == _reported) return;
    _reported = height;
    // Layout cannot rebuild widgets; hand the size over right after this frame.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final latest = _reported;
      if (attached && latest != null) onHeight(latest);
    });
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
