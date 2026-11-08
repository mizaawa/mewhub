import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/i18n.dart';
import '../../core/release_update.dart';
import '../../data/chat_folder.dart';
import '../../data/usage_statistics.dart';
import '../../state/app_state.dart';

/// A compact update card in the gap between the profile and today's usage.
class SidebarReleaseNotice extends StatefulWidget {
  const SidebarReleaseNotice({super.key, this.releaseUpdate});

  /// Allows a deterministic release result in widget tests.
  final Future<ReleaseUpdate?>? releaseUpdate;

  @override
  State<SidebarReleaseNotice> createState() => _SidebarReleaseNoticeState();
}

class _SidebarReleaseNoticeState extends State<SidebarReleaseNotice> {
  late Future<ReleaseUpdate?> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.releaseUpdate ?? checkForReleaseUpdate();
  }

  @override
  void didUpdateWidget(SidebarReleaseNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.releaseUpdate != oldWidget.releaseUpdate) {
      _future = widget.releaseUpdate ?? checkForReleaseUpdate();
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<ReleaseUpdate?>(
    future: _future,
    builder: (context, snapshot) {
      final update = snapshot.data;
      if (update == null) return const SizedBox.shrink();
      final scheme = Theme.of(context).colorScheme;
      final version = update.version.startsWith('v') ? update.version : 'v${update.version}';
      return Padding(
        padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
        child: Material(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            key: const ValueKey('release-update-notice'),
            borderRadius: BorderRadius.circular(16),
            onTap: () async {
              try {
                await launchUrl(update.url, mode: LaunchMode.externalApplication);
              } catch (_) {
                // Keep the drawer usable if no browser is available.
              }
            },
            child: SizedBox(
              height: 52,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    Icon(Icons.new_releases_rounded, size: 21, color: scheme.onSecondaryContainer),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        t('有新版本 $version', 'New version $version'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700, color: scheme.onSecondaryContainer),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      t('查看', 'View'),
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.primary),
                    ),
                    const SizedBox(width: 3),
                    Icon(Icons.chevron_right_rounded, size: 18, color: scheme.primary),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

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

class SidebarTodayUsage extends StatefulWidget {
  const SidebarTodayUsage({super.key});

  @override
  State<SidebarTodayUsage> createState() => _SidebarTodayUsageState();
}

class _SidebarTodayUsageState extends State<SidebarTodayUsage> {
  Future<List<Map<String, Object?>>>? _future;
  int _revision = -1;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (_future == null || _revision != app.listRevision.value) {
      _revision = app.listRevision.value;
      _future = app.db.usageByDay(days: 1);
    }
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      child: Material(
        color: scheme.primaryContainer.withValues(alpha: 0.45),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: InkWell(
          key: const ValueKey('sidebar-today-token'),
          borderRadius: BorderRadius.circular(18),
          onTap: () => Navigator.of(context).pushNamed('/settings/stats'),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: FutureBuilder<List<Map<String, Object?>>>(
              future: _future,
              builder: (context, snapshot) {
                var input = 0;
                var output = 0;
                var cached = 0;
                for (final row in snapshot.data ?? const <Map<String, Object?>>[]) {
                  input += (row['input'] as num?)?.toInt() ?? 0;
                  output += (row['output'] as num?)?.toInt() ?? 0;
                  cached += (row['cached'] as num?)?.toInt() ?? 0;
                }
                final total = input + output;
                final cacheRate = input == 0 ? 0.0 : (cached / input).clamp(0.0, 1.0);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(t('今日 Token', 'Today’s tokens'), style: Theme.of(context).textTheme.labelLarge),
                        ),
                        Text(
                          t(
                            '缓存命中 ${(cacheRate * 100).toStringAsFixed(1)}%',
                            'Cache hit ${(cacheRate * 100).toStringAsFixed(1)}%',
                          ),
                          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.primary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      statisticsNumber(total),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Row(
                        children: [
                          Expanded(
                            flex: input == 0 ? 1 : input,
                            child: Container(height: 8, color: scheme.primary),
                          ),
                          Expanded(
                            flex: output == 0 ? 1 : output,
                            child: Container(height: 8, color: scheme.tertiary),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 9),
                    Row(
                      children: [
                        Expanded(child: _usageLabel(context, scheme.primary, t('输入', 'Input'), input)),
                        Expanded(child: _usageLabel(context, scheme.tertiary, t('输出', 'Output'), output)),
                      ],
                    ),
                    const SizedBox(height: 3),
                    _usageLabel(context, scheme.secondary, t('缓存读取', 'Cache read'), cached),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _usageLabel(BuildContext context, Color color, String label, int value) => Row(
    children: [
      Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
      ),
      const SizedBox(width: 5),
      Text('$label  ${statisticsNumber(value)}', style: Theme.of(context).textTheme.labelSmall),
    ],
  );
}

class SidebarChatToolbar extends StatelessWidget {
  const SidebarChatToolbar({
    super.key,
    required this.folders,
    required this.selectedFolderId,
    required this.sortByCreation,
    required this.onNewFolder,
    required this.onSelectFolder,
    required this.onRenameFolder,
    required this.onDeleteFolder,
    required this.onSortChanged,
  });

  final List<ChatFolder> folders;
  final String? selectedFolderId;
  final bool sortByCreation;
  final VoidCallback onNewFolder;
  final ValueChanged<String?> onSelectFolder;
  final ValueChanged<ChatFolder> onRenameFolder;
  final ValueChanged<ChatFolder> onDeleteFolder;
  final ValueChanged<bool> onSortChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _folderChip(context, null, t('聊天', 'Chats')),
                  for (final folder in folders) _folderChip(context, folder, folder.name),
                  TextButton.icon(
                    key: const ValueKey('sidebar-new-folder'),
                    onPressed: onNewFolder,
                    icon: const Icon(Icons.create_new_folder_outlined, size: 20),
                    label: Text(t('新建', 'New')),
                  ),
                ],
              ),
            ),
          ),
          PopupMenuButton<bool>(
            key: const ValueKey('sidebar-sort'),
            tooltip: t('聊天记录排序', 'Sort conversations'),
            onSelected: onSortChanged,
            icon: const Icon(Icons.sort_rounded),
            itemBuilder: (context) => [
              PopupMenuItem(
                value: false,
                child: Row(
                  children: [
                    Expanded(child: Text(t('按更新时间', 'By update time'))),
                    if (!sortByCreation) const Icon(Icons.check_rounded, size: 18),
                  ],
                ),
              ),
              PopupMenuItem(
                value: true,
                child: Row(
                  children: [
                    Expanded(child: Text(t('按创建时间', 'By creation time'))),
                    if (sortByCreation) const Icon(Icons.check_rounded, size: 18),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _folderChip(BuildContext context, ChatFolder? folder, String label) {
    final scheme = Theme.of(context).colorScheme;
    final selected = selectedFolderId == folder?.id;
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: InkWell(
        key: folder == null ? const ValueKey('sidebar-chat-tab') : ValueKey('sidebar-folder-${folder.id}'),
        borderRadius: BorderRadius.circular(30),
        onTap: () => onSelectFolder(folder?.id),
        onLongPress: folder == null ? null : () => _folderMenu(context, folder),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? scheme.secondaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(30),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? scheme.onSecondaryContainer : scheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }

  void _folderMenu(BuildContext context, ChatFolder folder) => showModalBottomSheet<void>(
    context: context,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: Text(t('重命名文件夹', 'Rename folder')),
            onTap: () {
              Navigator.pop(sheet);
              onRenameFolder(folder);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded),
            title: Text(t('删除文件夹', 'Delete folder')),
            onTap: () {
              Navigator.pop(sheet);
              onDeleteFolder(folder);
            },
          ),
        ],
      ),
    ),
  );
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
      (Icons.history_rounded, t('历史', 'History'), '/history', 'history'),
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
