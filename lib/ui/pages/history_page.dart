import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n.dart';
import '../../core/util.dart';
import '../../data/conversation.dart';
import '../../data/database.dart';
import '../../state/app_state.dart';
import '../../state/settings_store.dart';
import '../widgets/common.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  final Map<String, Conversation> _undoSnapshots = {};

  List<ConversationSummary> _conversations(AppState app, String assistantId) {
    final result = app.conversations.where((item) => item.assistantId == assistantId).toList();
    result.sort((a, b) {
      if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    return result;
  }

  Future<void> _deleteAll(AppState app, List<ConversationSummary> conversations) async {
    if (!await confirm(
      context,
      t('清理当前助手的聊天记录？', 'Delete this assistant’s chats?'),
      message: t('已置顶的聊天会保留。此操作无法撤销。', 'Pinned chats will be kept. This cannot be undone.'),
      ok: t('清理', 'Delete'),
      destructive: true,
    )) {
      return;
    }
    for (final conversation in conversations.where((item) => !item.pinned).toList()) {
      await app.deleteConversation(conversation.id);
    }
  }

  Future<void> _captureForUndo(AppState app, ConversationSummary item) async {
    final active = app.chat.conversation;
    final conversation = active.id == item.id ? active : await app.db.getConversation(item.id);
    if (conversation != null) _undoSnapshots[item.id] = conversation;
  }

  Future<void> _delete(AppState app, ConversationSummary item) async {
    await app.deleteConversation(item.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(t('已删除聊天', 'Chat deleted')),
        action: SnackBarAction(
          label: t('撤销', 'Undo'),
          onPressed: () {
            final snapshot = _undoSnapshots.remove(item.id);
            if (snapshot != null) unawaited(_restore(app, snapshot));
          },
        ),
      ),
    );
  }

  Future<void> _restore(AppState app, Conversation conversation) async {
    await app.db.saveConversation(conversation);
    await app.refreshList();
  }

  Future<bool> _confirmDelete(AppState app, ConversationSummary item) async {
    await _captureForUndo(app, item);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final assistantId = context.watch<SettingsStore>().value.currentAssistantId;
    final conversations = _conversations(app, assistantId);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(t('聊天历史', 'Chat history')),
        actions: [
          IconButton(
            key: const ValueKey('history-search-messages'),
            tooltip: t('搜索消息', 'Search messages'),
            onPressed: () => Navigator.of(context).pushNamed('/search'),
            icon: const Icon(Icons.travel_explore_rounded),
          ),
          IconButton(
            key: const ValueKey('history-delete-all'),
            tooltip: t('清理未置顶聊天', 'Delete unpinned chats'),
            onPressed: conversations.any((item) => !item.pinned) ? () => _deleteAll(app, conversations) : null,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
      body: conversations.isEmpty
          ? EmptyState(icon: Icons.forum_outlined, title: t('还没有聊天记录', 'No chat history'))
          : ListView.separated(
              key: const ValueKey('history-conversation-list'),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: conversations.length,
              separatorBuilder: (_, _) => const SizedBox(height: 6),
              itemBuilder: (context, index) => _tile(context, app, conversations[index], scheme),
            ),
    );
  }

  Widget _tile(BuildContext context, AppState app, ConversationSummary item, ColorScheme scheme) {
    final title = item.title.trim().isEmpty
        ? (item.preview.trim().isEmpty ? t('新对话', 'New chat') : item.preview.trim())
        : item.title.trim();
    return Dismissible(
      key: ValueKey('history-dismiss-${item.id}'),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) => _confirmDelete(app, item),
      onDismissed: (_) => unawaited(_delete(app, item)),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(18)),
        child: Icon(Icons.delete_outline_rounded, color: scheme.onErrorContainer),
      ),
      child: Card(
        key: ValueKey('history-item-${item.id}'),
        margin: EdgeInsets.zero,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () async {
            await app.openConversation(item.id);
            if (context.mounted) Navigator.of(context).pop();
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (app.isGenerating(item.id)) ...[
                            const SizedBox(width: 8),
                            SizedBox(
                              key: ValueKey('history-generating-${item.id}'),
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        formatDateTime(item.createdAt),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: ValueKey('history-pin-${item.id}'),
                  tooltip: item.pinned ? t('取消置顶', 'Unpin chat') : t('置顶', 'Pin chat'),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => app.togglePin(item.id, !item.pinned),
                  icon: Icon(
                    item.pinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                    color: item.pinned ? scheme.primary : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
