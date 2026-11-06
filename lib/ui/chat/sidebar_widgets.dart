import 'package:flutter/material.dart';

import '../../core/i18n.dart';

class SidebarQuickLinks extends StatelessWidget {
  const SidebarQuickLinks({
    super.key,
    required this.searchOpen,
    required this.onHistory,
    required this.onSearch,
    required this.onImages,
    required this.onTranslate,
  });

  final bool searchOpen;
  final VoidCallback onHistory;
  final VoidCallback onSearch;
  final VoidCallback onImages;
  final VoidCallback onTranslate;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _link(
        context,
        key: const ValueKey('sidebar-history'),
        icon: Icons.history_rounded,
        label: t('聊天历史', 'Chat history'),
        onTap: onHistory,
        trailing: IconButton(
          key: const ValueKey('sidebar-history-search'),
          tooltip: searchOpen ? t('关闭搜索', 'Close search') : t('搜索对话', 'Search chats'),
          onPressed: onSearch,
          icon: Icon(searchOpen ? Icons.close_rounded : Icons.search_rounded),
        ),
      ),
      _link(
        context,
        key: const ValueKey('sidebar-media'),
        icon: Icons.photo_library_outlined,
        label: t('媒体创作', 'Media creation'),
        onTap: onImages,
      ),
      _link(
        context,
        key: const ValueKey('sidebar-translate'),
        icon: Icons.translate_rounded,
        label: t('AI 翻译', 'AI translation'),
        onTap: onTranslate,
      ),
    ],
  );

  Widget _link(
    BuildContext context, {
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 1),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: key,
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
            child: Row(
              children: [
                Icon(icon, size: 23, color: scheme.onSurface),
                const SizedBox(width: 16),
                Expanded(child: Text(label, style: Theme.of(context).textTheme.titleMedium)),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SidebarChatToolbar extends StatelessWidget {
  const SidebarChatToolbar({
    super.key,
    required this.allAssistants,
    required this.sortByTitle,
    required this.onNewChat,
    required this.onToggleAssistants,
    required this.onToggleSort,
  });

  final bool allAssistants;
  final bool sortByTitle;
  final VoidCallback onNewChat;
  final VoidCallback onToggleAssistants;
  final VoidCallback onToggleSort;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
      child: Row(
        children: [
          Container(
            key: const ValueKey('sidebar-chat-tab'),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
            decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(30)),
            child: Text(
              t('聊天', 'Chats'),
              style: TextStyle(color: scheme.onSecondaryContainer, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('sidebar-new-chat'),
                onPressed: onNewChat,
                icon: const Icon(Icons.create_new_folder_outlined, size: 20),
                label: Text(t('新建', 'New')),
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('sidebar-assistant-filter'),
            tooltip: allAssistants ? t('显示当前助手', 'Current assistant') : t('显示全部助手', 'All assistants'),
            onPressed: onToggleAssistants,
            icon: Icon(allAssistants ? Icons.groups_rounded : Icons.person_outline_rounded),
          ),
          IconButton(
            key: const ValueKey('sidebar-sort'),
            tooltip: sortByTitle ? t('按最近排序', 'Sort by recent') : t('按名称排序', 'Sort by name'),
            onPressed: onToggleSort,
            icon: const Icon(Icons.sort_rounded),
          ),
        ],
      ),
    );
  }
}

class SidebarBottomActions extends StatelessWidget {
  const SidebarBottomActions({super.key, required this.onNavigate});

  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = [
      (Icons.translate_rounded, t('翻译', 'Translate'), '/translator', 'translator'),
      (Icons.auto_awesome_rounded, t('绘图', 'Images'), '/imagegen', 'images'),
      (Icons.favorite_border_rounded, t('收藏', 'Favorites'), '/favorites', 'favorites'),
      (Icons.manage_search_rounded, t('搜索', 'Search'), '/search', 'search'),
      (Icons.settings_outlined, t('设置', 'Settings'), '/settings', 'settings'),
    ];
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
        child: Row(
          children: [
            for (final entry in entries)
              Expanded(
                child: Center(
                  child: IconButton.filledTonal(
                    key: ValueKey('sidebar-nav-${entry.$4}'),
                    tooltip: entry.$2,
                    style: IconButton.styleFrom(
                      shape: const CircleBorder(),
                      backgroundColor: scheme.secondaryContainer,
                    ),
                    onPressed: () => onNavigate(entry.$3),
                    icon: Icon(entry.$1, size: 22),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
