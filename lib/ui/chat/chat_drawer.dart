import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n.dart';
import '../../core/util.dart';
import '../../data/database.dart';
import '../../state/app_state.dart';
import '../../state/settings_store.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';

/// Conversation list + navigation. Used as a Drawer on phones and as a
/// permanent side panel on tablets ([embedded]).
class ChatDrawer extends StatefulWidget {
  const ChatDrawer({super.key, this.embedded = false});
  final bool embedded;

  @override
  State<ChatDrawer> createState() => _ChatDrawerState();
}

class _ChatDrawerState extends State<ChatDrawer> {
  String _q = '';
  bool _allAssistants = false;

  void _close() {
    if (!widget.embedded) Navigator.of(context).maybePop();
  }

  String _bucket(DateTime d) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(d.year, d.month, d.day);
    final diff = today.difference(day).inDays;
    if (diff <= 0) return t('今天', 'Today');
    if (diff == 1) return t('昨天', 'Yesterday');
    if (diff < 7) return t('最近 7 天', 'Previous 7 days');
    if (diff < 30) return t('最近 30 天', 'Previous 30 days');
    return '${d.year}-${twoDigits(d.month)}';
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final s = context.watch<SettingsStore>().value;
    final scheme = Theme.of(context).colorScheme;
    final current = app.chat.conversation.id;
    final q = _q.trim().toLowerCase();
    final list = app.conversations
        .where((c) => _allAssistants || c.assistantId == s.currentAssistantId)
        .where((c) => q.isEmpty || c.title.toLowerCase().contains(q) || c.preview.toLowerCase().contains(q))
        .toList();
    final pinned = list.where((c) => c.pinned).toList();
    final rest = list.where((c) => !c.pinned).toList();
    final groups = <String, List<ConversationSummary>>{};
    for (final c in rest) {
      groups.putIfAbsent(_bucket(c.updatedAt), () => []).add(c);
    }

    final items = <Widget>[];
    var idx = 0;
    if (pinned.isNotEmpty) {
      items.add(_Section(icon: Icons.push_pin_rounded, label: t('置顶', 'Pinned')));
      for (final c in pinned) {
        items.add(_tile(context, app, c, c.id == current, idx++));
      }
    }
    for (final g in groups.entries) {
      items.add(_Section(label: g.key));
      for (final c in g.value) {
        items.add(_tile(context, app, c, c.id == current, idx++));
      }
    }

    final content = SafeArea(
      right: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AssistantHeader(onChanged: () => setState(() {})),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      hintText: t('搜索对话', 'Search chats'),
                      isDense: true,
                    ),
                    onChanged: (v) => setState(() => _q = v),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filledTonal(
                  tooltip: _allAssistants ? t('显示当前助手', 'Current assistant') : t('显示全部助手', 'All assistants'),
                  onPressed: () => setState(() => _allAssistants = !_allAssistants),
                  icon: Icon(_allAssistants ? Icons.groups_rounded : Icons.person_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? EmptyState(
                    icon: Icons.forum_outlined,
                    title: q.isEmpty ? t('还没有对话', 'No chats yet') : t('没有匹配的对话', 'No matches'),
                  )
                : ListView(padding: const EdgeInsets.fromLTRB(8, 0, 8, 8), children: items),
          ),
          const Divider(height: 1),
          _NavBar(
            onNavigate: (route) {
              _close();
              Navigator.of(context).pushNamed(route);
            },
          ),
        ],
      ),
    );
    if (widget.embedded) return Material(color: scheme.surface, child: content);
    return Drawer(width: 316, child: content);
  }

  Widget _tile(BuildContext context, AppState app, ConversationSummary c, bool selected, int index) {
    final scheme = Theme.of(context).colorScheme;
    final title = c.title.isEmpty ? (c.preview.isEmpty ? t('新对话', 'New chat') : c.preview) : c.title;
    return EntranceFx(
      key: ValueKey('conv-${c.id}'),
      index: index,
      dy: 8,
      child: Dismissible(
        key: ValueKey('dismiss-${c.id}'),
        direction: DismissDirection.endToStart,
        confirmDismiss: (_) => confirm(context, t('删除这个对话？', 'Delete this chat?'), destructive: true),
        onDismissed: (_) => app.deleteConversation(c.id),
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          margin: const EdgeInsets.symmetric(vertical: 2),
          decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(14)),
          child: Icon(Icons.delete_outline_rounded, color: scheme.onErrorContainer),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 260),
            decoration: BoxDecoration(
              color: selected ? scheme.secondaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: ListTile(
              dense: true,
              title: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w500, fontSize: 14.5),
              ),
              subtitle: c.title.isEmpty || c.preview.isEmpty
                  ? null
                  : Text(
                      c.preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12.5),
                    ),
              onTap: () {
                app.openConversation(c.id);
                _close();
              },
              onLongPress: () => _convMenu(context, app, c),
            ),
          ),
        ),
      ),
    );
  }

  void _convMenu(BuildContext context, AppState app, ConversationSummary c) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(c.pinned ? Icons.push_pin_outlined : Icons.push_pin_rounded),
              title: Text(c.pinned ? t('取消置顶', 'Unpin') : t('置顶', 'Pin')),
              onTap: () {
                Navigator.pop(ctx);
                app.togglePin(c.id, !c.pinned);
              },
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline_rounded),
              title: Text(t('重命名', 'Rename')),
              onTap: () async {
                Navigator.pop(ctx);
                final v = await promptText(context, t('重命名对话', 'Rename chat'), initial: c.title);
                if (v != null) await app.renameConversation(c.id, v.trim());
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline_rounded, color: Theme.of(ctx).colorScheme.error),
              title: Text(t('删除', 'Delete'), style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () async {
                Navigator.pop(ctx);
                if (await confirm(context, t('删除这个对话？', 'Delete this chat?'), destructive: true)) {
                  await app.deleteConversation(c.id);
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.label, this.icon});
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelMedium
        ?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w700);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
      child: Row(
        children: [
          if (icon != null) ...[Icon(icon, size: 13, color: scheme.onSurfaceVariant), const SizedBox(width: 4)],
          Text(label, style: style),
        ],
      ),
    );
  }
}

class _AssistantHeader extends StatelessWidget {
  const _AssistantHeader({required this.onChanged});
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final app = context.read<AppState>();
    final s = store.value;
    final scheme = Theme.of(context).colorScheme;
    final a = s.currentAssistant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: Row(
        children: [
          Expanded(
            child: Pressable(
              onTap: () => _pick(context, store, app),
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Row(
                  children: [
                    AvatarView(value: a.avatar, fallback: a.name, size: 38),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            a.name.isEmpty ? 'Mew' : a.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          Text(
                            t('切换助手', 'Switch assistant'),
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.unfold_more_rounded, size: 18, color: scheme.onSurfaceVariant),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: t('新对话', 'New chat'),
            onPressed: () {
              app.newChat();
              Navigator.of(context).maybePop();
            },
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
    );
  }

  void _pick(BuildContext context, SettingsStore store, AppState app) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) {
        final list = store.value.assistants;
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: 16),
            children: [
              for (var i = 0; i < list.length; i++)
                EntranceFx(
                  index: i,
                  child: ListTile(
                    leading: AvatarView(value: list[i].avatar, fallback: list[i].name),
                    title: Text(list[i].name.isEmpty ? 'Mew' : list[i].name),
                    subtitle: list[i].systemPrompt.isEmpty
                        ? null
                        : Text(list[i].systemPrompt, maxLines: 1, overflow: TextOverflow.ellipsis),
                    selected: list[i].id == store.value.currentAssistantId,
                    onTap: () {
                      Navigator.pop(ctx);
                      app.newChat(assistantId: list[i].id);
                      onChanged();
                    },
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.manage_accounts_outlined),
                title: Text(t('管理助手', 'Manage assistants')),
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).pushNamed('/assistants');
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _NavBar extends StatelessWidget {
  const _NavBar({required this.onNavigate});
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context) {
    final entries = [
      (Icons.translate_rounded, t('翻译', 'Translate'), '/translator'),
      (Icons.brush_outlined, t('绘图', 'Images'), '/imagegen'),
      (Icons.favorite_border_rounded, t('收藏', 'Favorites'), '/favorites'),
      (Icons.manage_search_rounded, t('搜索', 'Search'), '/search'),
      (Icons.settings_outlined, t('设置', 'Settings'), '/settings'),
    ];
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          children: [
            for (final e in entries)
              Expanded(
                child: Tooltip(
                  message: e.$2,
                  child: Pressable(
                    onTap: () => onNavigate(e.$3),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(e.$1, size: 22),
                          const SizedBox(height: 3),
                          Text(e.$2, style: Theme.of(context).textTheme.labelSmall, maxLines: 1),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
