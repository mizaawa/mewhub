import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/attachments.dart';
import '../../core/i18n.dart';
import '../../core/release_update.dart';
import '../../core/util.dart';
import '../../data/chat_folder.dart';
import '../../data/database.dart';
import '../../state/app_state.dart';
import '../../state/settings_store.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';
import 'profile_header.dart';
import 'sidebar_widgets.dart';

/// Conversation list + navigation. Used as a Drawer on phones and as a
/// permanent side panel on tablets ([embedded]).
class ChatDrawer extends StatefulWidget {
  const ChatDrawer({super.key, this.embedded = false, this.releaseUpdate});
  final bool embedded;
  final Future<ReleaseUpdate?>? releaseUpdate;

  @override
  State<ChatDrawer> createState() => _ChatDrawerState();
}

class _ChatDrawerState extends State<ChatDrawer> {
  String? _selectedFolderId;
  final _historyScroll = ScrollController();

  @override
  void dispose() {
    _historyScroll.dispose();
    super.dispose();
  }

  void _close() {
    if (!widget.embedded) Navigator.of(context).maybePop();
  }

  void _scrollToTop() {
    if (_historyScroll.hasClients) {
      _historyScroll.animateTo(0, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
    }
  }

  void _navigate(String route) {
    _close();
    Navigator.of(context).pushNamed(route);
  }

  Future<void> _createFolder(AppState app) async {
    final name = await promptText(context, t('新建文件夹', 'Create folder'));
    if (name == null || !mounted) return;
    final folder = app.createChatFolder(name);
    if (folder == null) {
      toast(context, t('文件夹名称不能为空或已存在', 'Folder name is empty or already exists'), error: true);
      return;
    }
    setState(() => _selectedFolderId = folder.id);
  }

  Future<void> _renameFolder(AppState app, ChatFolder folder) async {
    final name = await promptText(context, t('重命名文件夹', 'Rename folder'), initial: folder.name);
    if (name == null || !mounted) return;
    if (!app.renameChatFolder(folder, name)) {
      toast(context, t('文件夹名称不能为空或已存在', 'Folder name is empty or already exists'), error: true);
    }
  }

  Future<void> _deleteFolder(AppState app, ChatFolder folder) async {
    if (!await confirm(
      context,
      t('删除文件夹？其中的对话将移回聊天列表。', 'Delete folder? Its chats will move to Chats.'),
      destructive: true,
    )) {
      return;
    }
    if (!await app.deleteChatFolder(folder)) {
      if (mounted) {
        toast(context, t('请等待当前回复完成后再删除文件夹', 'Wait for the reply to finish before deleting the folder'), error: true);
      }
      return;
    }
    if (mounted && _selectedFolderId == folder.id) setState(() => _selectedFolderId = null);
  }

  Future<void> _moveToFolder(AppState app, ConversationSummary conversation) async {
    final folders = context
        .read<SettingsStore>()
        .value
        .chatFolders
        .where((folder) => folder.assistantId == conversation.assistantId)
        .toList();
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(title: Text(t('移动到文件夹', 'Move to folder'))),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline_rounded),
              title: Text(t('聊天', 'Chats')),
              onTap: () {
                Navigator.pop(sheet);
                app.moveConversationToFolder(conversation.id, null);
              },
            ),
            for (final folder in folders)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(folder.name),
                onTap: () {
                  Navigator.pop(sheet);
                  app.moveConversationToFolder(conversation.id, folder.id);
                },
              ),
          ],
        ),
      ),
    );
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

  Future<void> _editProfile(SettingsStore store) async {
    final display = store.value.display;
    final name = TextEditingController(text: display.userName);
    var avatar = display.userAvatar;
    try {
      await showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheetContext) => StatefulBuilder(
          builder: (context, setSheetState) => Padding(
            padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(t('个人资料', 'Profile'), style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 18),
                Row(
                  children: [
                    ClipOval(
                      child: AvatarView(value: avatar, fallback: name.text.isEmpty ? 'Mew' : name.text, size: 68),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: TextButton.icon(
                        onPressed: () async {
                          final picked = await Attachments.pickAvatar();
                          if (picked != null && context.mounted) setSheetState(() => avatar = picked);
                        },
                        icon: const Icon(Icons.photo_camera_back_outlined),
                        label: Text(t('更换头像', 'Change photo')),
                      ),
                    ),
                    IconButton(
                      tooltip: t('恢复默认头像', 'Use default avatar'),
                      onPressed: () => setSheetState(() => avatar = ''),
                      icon: const Icon(Icons.restart_alt_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: name,
                  textCapitalization: TextCapitalization.words,
                  maxLength: 40,
                  decoration: InputDecoration(labelText: t('昵称', 'Name'), prefixIcon: const Icon(Icons.badge_outlined)),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () {
                    store.update(
                      (s) => s.copyWith(
                        display: s.display.copyWith(userName: name.text.trim(), userAvatar: avatar),
                      ),
                    );
                    Navigator.of(sheetContext).pop();
                  },
                  child: Text(t('保存', 'Save')),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      name.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final s = context.watch<SettingsStore>().value;
    final scheme = Theme.of(context).colorScheme;
    final current = app.chat.conversation.id;
    final folders = s.chatFolders.where((f) => f.assistantId == s.currentAssistantId).toList();
    if (_selectedFolderId != null && !folders.any((f) => f.id == _selectedFolderId)) {
      _selectedFolderId = null;
    }
    final list = app.conversations
        .where((c) => c.assistantId == s.currentAssistantId)
        .where((c) => c.folder == _selectedFolderId)
        .toList();
    list.sort((a, b) {
      final aDate = s.display.conversationSortByCreation ? a.createdAt : a.updatedAt;
      final bDate = s.display.conversationSortByCreation ? b.createdAt : b.updatedAt;
      return bDate.compareTo(aDate);
    });
    final pinned = list.where((c) => c.pinned).toList();
    final rest = list.where((c) => !c.pinned).toList();
    final groups = <String, List<ConversationSummary>>{};
    for (final c in rest) {
      groups.putIfAbsent(_bucket(s.display.conversationSortByCreation ? c.createdAt : c.updatedAt), () => []).add(c);
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
          UserProfileHeader(
            name: s.display.userName,
            avatar: s.display.userAvatar,
            onTap: () => _editProfile(context.read<SettingsStore>()),
          ),
          SidebarReleaseNotice(releaseUpdate: widget.releaseUpdate),
          const SidebarTodayUsage(),
          SidebarChatToolbar(
            folders: folders,
            selectedFolderId: _selectedFolderId,
            sortByCreation: s.display.conversationSortByCreation,
            onNewFolder: () => _createFolder(app),
            onSelectFolder: (id) {
              setState(() => _selectedFolderId = id);
              _scrollToTop();
            },
            onRenameFolder: (folder) => _renameFolder(app, folder),
            onDeleteFolder: (folder) => _deleteFolder(app, folder),
            onSortChanged: (created) {
              context.read<SettingsStore>().update(
                (s) => s.copyWith(display: s.display.copyWith(conversationSortByCreation: created)),
              );
              _scrollToTop();
            },
          ),
          Expanded(
            child: items.isEmpty
                ? EmptyState(icon: Icons.forum_outlined, title: t('还没有对话', 'No chats yet'))
                : ListView(controller: _historyScroll, padding: const EdgeInsets.fromLTRB(8, 0, 8, 8), children: items),
          ),
          const Divider(height: 1),
          _AssistantHeader(onChanged: () => setState(() {})),
          SidebarBottomActions(onNavigate: _navigate),
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
              visualDensity: const VisualDensity(vertical: -2),
              minVerticalPadding: 2,
              contentPadding: const EdgeInsets.symmetric(horizontal: 18),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: selected ? FontWeight.w700 : FontWeight.w500, fontSize: 14),
                    ),
                  ),
                  if (app.isGenerating(c.id)) ...[
                    const SizedBox(width: 8),
                    SizedBox(
                      key: ValueKey('conversation-generating-${c.id}'),
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
                    ),
                  ],
                ],
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
              leading: const Icon(Icons.drive_file_move_outline),
              title: Text(t('移动到文件夹', 'Move to folder')),
              onTap: () {
                Navigator.pop(ctx);
                _moveToFolder(app, c);
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
    final style = Theme.of(context).textTheme.titleSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 14, 4),
      child: Row(
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: scheme.primary), const SizedBox(width: 5)],
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
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 2),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          key: const ValueKey('sidebar-current-assistant'),
          borderRadius: BorderRadius.circular(18),
          onTap: () => _pick(context, store, app),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
            child: Row(
              children: [
                Icon(Icons.sentiment_satisfied_alt_outlined, size: 24, color: scheme.onSurfaceVariant),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    a.name.isEmpty ? 'MewBot' : a.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                AvatarView(value: a.avatar, fallback: a.name, size: 38),
                const SizedBox(width: 8),
                Icon(Icons.unfold_more_rounded, size: 18, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
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
                    title: Text(list[i].name.isEmpty ? 'MewBot' : list[i].name),
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
