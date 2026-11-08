import 'dart:async';

import 'package:flutter/material.dart';

import '../../ai/message.dart';
import '../../core/i18n.dart';
import '../../core/util.dart';
import '../../data/assistant.dart';
import '../../data/conversation.dart';
import '../../data/settings.dart';
import '../widgets/common.dart';
import '../widgets/image_viewer.dart';
import '../widgets/markdown_view.dart';
import '../widgets/motion.dart';
import 'reasoning_card.dart';
import 'tool_card.dart';

enum MessageAction {
  copy,
  edit,
  regenerate,
  branchPrev,
  branchNext,
  delete,
  fork,
  translate,
  speak,
  favorite,
  share,
  select,
}

String? fontFamilyFor(ChatFont f) => switch (f) {
  ChatFont.system => null,
  ChatFont.serif => 'serif',
  ChatFont.mono => 'monospace',
};

/// Renders one message node (with branch switcher and actions).
class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.node,
    required this.index,
    required this.assistant,
    required this.display,
    required this.streaming,
    required this.isLast,
    required this.favorite,
    required this.onAction,
    required this.onApprove,
    this.error,
  });

  final MessageNode node;
  final int index;
  final Assistant assistant;
  final DisplaySettings display;
  final bool streaming;
  final bool isLast;
  final bool favorite;
  final void Function(MessageAction a) onAction;
  final void Function(String callId, bool approved) onApprove;
  final String? error;

  ChatMessage get m => node.current;

  @override
  Widget build(BuildContext context) {
    final isUser = m.role == Role.user;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      child: isUser ? _user(context) : _assistant(context),
    );
  }

  Widget _user(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = applyRegexes(m.text, assistant.regexes, RegexScope.user, visual: true);
    final images = m.parts.whereType<ImagePart>().toList();
    final docs = m.parts.whereType<DocumentPart>().toList();
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [scheme.primary.withValues(alpha: 0.95), Color.lerp(scheme.primary, const Color(0xFFE7B98F), 0.35)!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
          bottomLeft: Radius.circular(20),
          bottomRight: Radius.circular(6),
        ),
        boxShadow: [
          BoxShadow(color: scheme.primary.withValues(alpha: 0.18), blurRadius: 14, offset: const Offset(0, 5)),
        ],
      ),
      child: SelectableText(
        text,
        style: TextStyle(
          color: Colors.white,
          fontSize: 15.5 * display.fontScale,
          height: 1.5,
          fontFamily: fontFamilyFor(display.chatFont),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (images.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.end,
              children: [for (final img in images) _Thumb(url: img.url)],
            ),
          ),
        if (docs.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.end,
              children: [for (final d in docs) _DocChip(doc: d)],
            ),
          ),
        if (text.trim().isNotEmpty) GestureDetector(onLongPress: () => _menu(context), child: bubble),
        _footer(context, alignEnd: true),
      ],
    );
  }

  Widget _assistant(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final children = <Widget>[];
    final parts = m.parts;
    final hasVisible = parts.any(
      (p) => switch (p) {
        TextPart(:final text) => text.trim().isNotEmpty,
        ReasoningPart(:final text) => text.trim().isNotEmpty || !p.finished,
        _ => true,
      },
    );
    for (final p in parts) {
      switch (p) {
        case ReasoningPart():
          if (display.showThinking && (p.text.trim().isNotEmpty || (streaming && !p.finished))) {
            children.add(
              ReasoningCard(
                key: ValueKey('r-${m.id}-${p.startedAt?.microsecondsSinceEpoch}'),
                part: streaming ? p : p.copyWith(finishedAt: p.finishedAt ?? DateTime.now()),
                streaming: streaming,
                autoCollapse: display.autoCollapseThinking,
                fontScale: display.fontScale,
              ),
            );
          }
        case TextPart(:final text):
          final shown = applyRegexes(text, assistant.regexes, RegexScope.assistant, visual: true);
          if (shown.trim().isEmpty) continue;
          children.add(
            MarkdownView(
              data: shown,
              latex: display.latex,
              codeWrap: display.codeWrap,
              lineNumbers: display.codeLineNumbers,
              fontScale: display.fontScale,
              fontFamily: fontFamilyFor(display.chatFont),
            ),
          );
        case ToolPart():
          children.add(
            ToolCard(
              key: ValueKey('t-${p.callId}'),
              part: p,
              onApprove: () => onApprove(p.callId, true),
              onDeny: () => onApprove(p.callId, false),
            ),
          );
        case ServerToolPart():
          if (p.name != 'web_search_result') {
            children.add(_ServerToolChip(key: ValueKey('s-${p.callId}'), part: p));
          }
        case ImagePart(:final url):
          children.add(NetworkImageTile(url: url));
        case CitationsPart(:final items):
          children.add(CitationChips(items: items));
        case DocumentPart():
          children.add(_DocChip(doc: p));
      }
    }
    if (streaming && (!hasVisible || _waitingAfterTool)) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: TypingDots(color: scheme.primary),
        ),
      );
    }
    if (m.translation != null && m.translation!.isNotEmpty) {
      children.add(
        Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHigh.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.translate_rounded, size: 14, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    t('译文', 'Translation'),
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.primary),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              MarkdownView(data: m.translation!, latex: display.latex, fontScale: display.fontScale * 0.95),
            ],
          ),
        ),
      );
    }
    final err = m.error ?? (isLast ? error : null);
    if (err != null && !streaming) {
      children.add(_ErrorCard(message: err, onRetry: () => onAction(MessageAction.regenerate)));
    }

    final content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
    final body = display.bubbleAssistant
        ? Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(6),
                topRight: Radius.circular(20),
                bottomLeft: Radius.circular(20),
                bottomRight: Radius.circular(20),
              ),
            ),
            child: content,
          )
        : content;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _assistantHeader(context),
        const SizedBox(height: 6),
        GestureDetector(onLongPress: () => _menu(context), child: body),
        _footer(context, alignEnd: false),
      ],
    );
  }

  bool get _waitingAfterTool {
    if (m.parts.isEmpty) return true;
    final last = m.parts.last;
    return last is ToolPart && last.executed;
  }

  Widget _assistantHeader(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final name = display.showModelName ? (m.modelName ?? assistant.name) : assistant.name;
    return Row(
      children: [
        AvatarView(value: assistant.avatar, fallback: m.modelName ?? assistant.name, size: 28),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            name.isEmpty ? 'MewBot' : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        if (display.showTimestamps) ...[
          const SizedBox(width: 8),
          Text(
            formatTime(m.createdAt),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  Widget _footer(BuildContext context, {required bool alignEnd}) {
    final scheme = Theme.of(context).colorScheme;
    if (streaming) return const SizedBox(height: 4);
    final branches = node.messages.length;
    final usage = m.usage;
    final mute = Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    final items = <Widget>[
      if (branches > 1) ...[
        _MiniButton(
          icon: Icons.chevron_left_rounded,
          onTap: node.selected > 0 ? () => onAction(MessageAction.branchPrev) : null,
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Text('${node.selected + 1}/$branches', key: ValueKey(node.selected), style: mute),
        ),
        _MiniButton(
          icon: Icons.chevron_right_rounded,
          onTap: node.selected < branches - 1 ? () => onAction(MessageAction.branchNext) : null,
        ),
        const SizedBox(width: 4),
      ],
      _MiniButton(icon: Icons.copy_rounded, onTap: () => onAction(MessageAction.copy)),
      if (m.role == Role.assistant) ...[
        _MiniButton(icon: Icons.refresh_rounded, onTap: () => onAction(MessageAction.regenerate)),
        _MiniButton(icon: Icons.volume_up_outlined, onTap: () => onAction(MessageAction.speak)),
        _MiniButton(
          icon: favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          color: favorite ? const Color(0xFFE07A8B) : null,
          onTap: () => onAction(MessageAction.favorite),
        ),
      ] else
        _MiniButton(icon: Icons.edit_outlined, onTap: () => onAction(MessageAction.edit)),
      _MiniButton(icon: Icons.more_horiz_rounded, onTap: () => _menu(context)),
      if (display.showTokenUsage && usage != null && !usage.isEmpty) ...[
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            '↑${formatTokens(usage.input)} ↓${formatTokens(usage.output)}'
            '${usage.cached > 0 ? ' · ${t('缓存', 'cache')} ${formatTokens(usage.cached)}' : ''}',
            style: mute,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ];
    return EntranceFx(
      dy: 4,
      child: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(mainAxisAlignment: alignEnd ? MainAxisAlignment.end : MainAxisAlignment.start, children: items),
      ),
    );
  }

  void _menu(BuildContext context) {
    final isAssistant = m.role == Role.assistant;
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        Widget tile(IconData i, String label, MessageAction a, {bool danger = false}) {
          final color = danger ? Theme.of(ctx).colorScheme.error : null;
          return ListTile(
            leading: Icon(i, color: color),
            title: Text(label, style: TextStyle(color: color)),
            onTap: () {
              Navigator.pop(ctx);
              onAction(a);
            },
          );
        }

        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                tile(Icons.copy_rounded, t('复制', 'Copy'), MessageAction.copy),
                tile(Icons.text_fields_rounded, t('选择文本', 'Select text'), MessageAction.select),
                tile(Icons.edit_outlined, t('编辑', 'Edit'), MessageAction.edit),
                if (isAssistant) tile(Icons.refresh_rounded, t('重新生成', 'Regenerate'), MessageAction.regenerate),
                tile(Icons.translate_rounded, t('翻译', 'Translate'), MessageAction.translate),
                if (isAssistant) tile(Icons.volume_up_outlined, t('朗读', 'Read aloud'), MessageAction.speak),
                tile(Icons.call_split_rounded, t('从这里分叉新对话', 'Fork from here'), MessageAction.fork),
                tile(Icons.ios_share_rounded, t('分享', 'Share'), MessageAction.share),
                tile(Icons.delete_outline_rounded, t('删除', 'Delete'), MessageAction.delete, danger: true),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton({required this.icon, this.onTap, this.color});
  final IconData icon;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = color ?? scheme.onSurfaceVariant.withValues(alpha: onTap == null ? 0.3 : 0.75);
    return Pressable(
      onTap: onTap,
      scale: 0.85,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          transitionBuilder: (child, a) => ScaleTransition(scale: a, child: child),
          child: Icon(icon, key: ValueKey('$icon$color'), size: 17, color: c),
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => openImageViewer(context, url),
    child: Hero(
      tag: 'img-$url',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Image(image: imageProviderFor(url), width: 110, height: 110, fit: BoxFit.cover),
      ),
    ),
  );
}

class _DocChip extends StatelessWidget {
  const _DocChip({required this.doc});
  final DocumentPart doc;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = doc.extractedText == null ? '' : ' · ${formatTokens(doc.extractedText!.length)} chars';
    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(12)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.description_outlined, size: 18, color: scheme.primary),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '${doc.fileName}$size',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerToolChip extends StatefulWidget {
  const _ServerToolChip({super.key, required this.part});
  final ServerToolPart part;

  @override
  State<_ServerToolChip> createState() => _ServerToolChipState();
}

class _ServerToolChipState extends State<_ServerToolChip> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    if (!widget.part.done) _startTicker();
  }

  @override
  void didUpdateWidget(_ServerToolChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.part.done && widget.part.done) {
      _ticker?.cancel();
    } else if (oldWidget.part.done && !widget.part.done) {
      _startTicker();
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final part = widget.part;
    final input = asMap(part.input);
    final q = input['query'] ?? asMap(input['action'])['query'] ?? '';
    final seconds = part.startedAt == null
        ? ''
        : ' · ${((part.finishedAt ?? DateTime.now()).difference(part.startedAt!).inMilliseconds / 1000).toStringAsFixed(1)}s';
    final status = asStr(part.meta?['status']);
    final label = part.name == 'web_search'
        ? '${toolLabel(part.name)} · ${switch (status) {
            'completed' => t('搜索完成', 'Search complete'),
            'searching' => t('正在搜索', 'Searching'),
            _ => t('搜索已启动', 'Starting search'),
          }}$seconds${q.toString().isEmpty ? '' : ': $q'}'
        : '${toolLabel(part.name)}${q.toString().isEmpty ? '' : ': $q'}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(toolIcon(part.name), size: 16, color: scheme.primary),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return EntranceFx(
      child: Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        decoration: BoxDecoration(
          color: scheme.errorContainer.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, size: 18, color: scheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                message,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onErrorContainer),
              ),
            ),
            TextButton(onPressed: onRetry, child: Text(t('重试', 'Retry'))),
          ],
        ),
      ),
    );
  }
}
