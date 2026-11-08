import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../chat/chat_controller.dart';
import '../../core/i18n.dart';
import '../../core/util.dart';
import '../../data/assistant.dart';
import '../../data/models_misc.dart';
import '../../data/settings.dart';
import '../../state/app_state.dart';
import '../../state/settings_store.dart';
import '../../tools/app_tools.dart';
import '../../tools/mcp.dart';
import '../pages/extensions_pages.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';

const mcpConnectedColor = Color(0xFF5E9E6E);

String _assistantName(Assistant a) => a.name.trim().isEmpty ? 'MewBot' : a.name.trim();

/// Live MCP state of the servers one assistant uses.
class McpOverview {
  const McpOverview({
    required this.total,
    required this.active,
    required this.connected,
    required this.connecting,
    required this.failed,
    required this.tools,
  });

  final int total;
  final int active;
  final int connected;
  final int connecting;
  final int failed;

  /// Enabled tools across connected active servers.
  final int tools;

  factory McpOverview.of(AppSettings s, Assistant a, McpManager mcp) {
    var active = 0, connected = 0, connecting = 0, failed = 0, tools = 0;
    for (final cfg in s.mcpServers) {
      if (!cfg.enabled || !a.mcpServerIds.contains(cfg.id)) continue;
      active++;
      final client = mcp.client(cfg.id);
      switch (client?.status) {
        case McpStatus.connected:
          connected++;
          tools += client!.tools.where((t) => !cfg.disabledTools.contains(t.name)).length;
        case McpStatus.connecting:
          connecting++;
        case McpStatus.error:
          failed++;
        case McpStatus.idle || null:
          break;
      }
    }
    return McpOverview(
      total: s.mcpServers.length,
      active: active,
      connected: connected,
      connecting: connecting,
      failed: failed,
      tools: tools,
    );
  }

  String get summary {
    if (total == 0) return t('添加服务器', 'Add a server');
    if (active == 0) return t('未启用 · 共 $total 个', 'Off · $total available');
    if (failed > 0) return t('$failed 个连接失败', '$failed failed to connect');
    if (connected == 0 && connecting > 0) return t('连接中…', 'Connecting…');
    if (connected > 0) return t('$active 个服务器 · $tools 工具', '$active on · $tools tools');
    return t('已启用 $active 个', '$active enabled');
  }

  /// Short form for the composer entry card.
  String get compact {
    if (total == 0) return t('添加服务器', 'Add server');
    if (active == 0) return t('未启用', 'Off');
    if (failed > 0) return t('$failed 个失败', '$failed failed');
    if (connected == 0 && connecting > 0) return t('连接中…', 'Connecting…');
    if (connected > 0) return t('$tools 个工具', '$tools tools');
    return t('已启用 $active 个', '$active on');
  }

  Color? dot(ColorScheme scheme) {
    if (active == 0) return null;
    if (failed > 0) return scheme.error;
    if (connecting > 0) return const Color(0xFFD9A441);
    return connected > 0 ? mcpConnectedColor : scheme.outline;
  }
}

/// What the extension drawer currently adds to one chat.
class ExtensionsOverview {
  const ExtensionsOverview({
    required this.activeModes,
    required this.lorebooks,
    required this.memory,
    required this.quickMessages,
  });

  final List<String> activeModes;
  final int lorebooks;
  final bool memory;
  final int quickMessages;

  int get activeCount => activeModes.length + lorebooks + (memory ? 1 : 0);

  factory ExtensionsOverview.of(AppSettings s, Assistant a, Set<String> chatModes) {
    final modeIds = {...a.modeIds, ...chatModes};
    return ExtensionsOverview(
      activeModes: [
        for (final m in s.modes)
          if (modeIds.contains(m.id)) m.name,
      ],
      lorebooks: s.lorebooks.where((b) => b.enabled && a.lorebookIds.contains(b.id)).length,
      memory: a.enableMemory,
      quickMessages: s.quickMessages.length,
    );
  }

  String get summary {
    final parts = [
      ...activeModes,
      if (lorebooks > 0) t('世界书 $lorebooks', 'Lorebooks $lorebooks'),
      if (memory) t('记忆', 'Memory'),
    ];
    if (parts.isNotEmpty) return parts.join(' · ');
    if (quickMessages > 0) return t('快捷短语 $quickMessages 条', '$quickMessages quick messages');
    return t('短语 · 模式 · 世界书 · 记忆', 'Phrases · modes · lore · memory');
  }

  /// Short form for the composer entry card.
  String get compact {
    if (activeCount > 0) return t('$activeCount 项生效中', '$activeCount active');
    if (quickMessages > 0) return t('$quickMessages 条短语', '$quickMessages phrases');
    return t('短语 · 世界书', 'Phrases · lore');
  }
}

/// Turns an MCP server on or off for one assistant. Turning it on also
/// enables the server itself and starts connecting in the background.
void setMcpServerActive(SettingsStore store, McpManager mcp, String assistantId, String serverId, bool on) {
  store.update(
    (s) => s.copyWith(
      assistants: [
        for (final a in s.assistants)
          a.id == assistantId
              ? a.copyWith(mcpServerIds: on ? {...a.mcpServerIds, serverId} : ({...a.mcpServerIds}..remove(serverId)))
              : a,
      ],
      mcpServers: on ? [for (final m in s.mcpServers) m.id == serverId ? m.copyWith(enabled: true) : m] : null,
    ),
  );
  final cfg = store.value.mcpServers.where((m) => m.id == serverId).firstOrNull;
  if (on && cfg != null) unawaited(connectMcpQuietly(mcp, cfg));
}

/// Connects without throwing; failures are shown through the client status.
Future<void> connectMcpQuietly(McpManager mcp, McpServerConfig cfg) async {
  try {
    await mcp.ensure(cfg);
  } catch (_) {}
}

/// Links a lorebook to one assistant (and makes sure the book itself is on).
void setLorebookActive(SettingsStore store, String assistantId, String bookId, bool on) => store.update(
  (s) => s.copyWith(
    assistants: [
      for (final a in s.assistants)
        a.id == assistantId
            ? a.copyWith(lorebookIds: on ? {...a.lorebookIds, bookId} : ({...a.lorebookIds}..remove(bookId)))
            : a,
    ],
    lorebooks: on ? [for (final b in s.lorebooks) b.id == bookId ? b.copyWith(enabled: true) : b] : null,
  ),
);

/// Opens a half-height drawer that can be pulled up to full height.
Future<T?> showQuickSheet<T>(BuildContext context, Widget Function(ScrollController scroll) builder) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.58,
        minChildSize: 0.32,
        maxChildSize: 0.94,
        snap: true,
        snapSizes: const [0.58],
        builder: (ctx, scroll) => builder(scroll),
      ),
    );

Future<void> showMcpQuickSheet(BuildContext context, ChatController chat) =>
    showQuickSheet<void>(context, (scroll) => McpQuickSheet(chat: chat, scroll: scroll));

Future<void> showExtensionsQuickSheet(
  BuildContext context,
  ChatController chat, {
  required ValueChanged<String> onQuickMessage,
}) => showQuickSheet<void>(
  context,
  (scroll) => ExtensionsQuickSheet(chat: chat, scroll: scroll, onQuickMessage: onQuickMessage),
);

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.icon, required this.title, required this.subtitle, this.action});
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 20, color: scheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tt.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  const _GroupLabel(this.label, {this.trailing});
  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 14, 16, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelLarge
                  ?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Rounded card used for every row in both drawers.
class _ToggleCard extends StatelessWidget {
  const _ToggleCard({
    super.key,
    required this.leading,
    required this.title,
    this.subtitle,
    this.badge,
    this.value,
    this.onChanged,
    this.onTap,
    this.trailing,
  });

  final Widget leading;
  final String title;
  final Widget? subtitle;
  final String? badge;
  final bool? value;
  final ValueChanged<bool>? onChanged;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final on = value ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Material(
        color: on ? scheme.primary.withValues(alpha: 0.09) : scheme.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: on ? scheme.primary.withValues(alpha: 0.30) : scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap ?? (onChanged == null || value == null ? null : () => onChanged!(!on)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (badge != null) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: scheme.primary.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                badge!,
                                style: tt.labelSmall?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (subtitle != null) ...[const SizedBox(height: 2), subtitle!],
                    ],
                  ),
                ),
                ?trailing,
                if (value != null) Switch(value: on, onChanged: onChanged),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget _muted(BuildContext context, String text, {Color? color, int maxLines = 1}) => Text(
  text,
  maxLines: maxLines,
  overflow: TextOverflow.ellipsis,
  style: Theme.of(context).textTheme.bodySmall
      ?.copyWith(color: color ?? Theme.of(context).colorScheme.onSurfaceVariant),
);

class McpQuickSheet extends StatefulWidget {
  const McpQuickSheet({super.key, required this.chat, required this.scroll});
  final ChatController chat;
  final ScrollController scroll;

  @override
  State<McpQuickSheet> createState() => _McpQuickSheetState();
}

class _McpQuickSheetState extends State<McpQuickSheet> {
  @override
  void initState() {
    super.initState();
    // Bring active servers up so the status shown is real, not stale.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final s = context.read<SettingsStore>().value;
      final mcp = context.read<AppState>().mcp;
      final a = widget.chat.assistant;
      for (final cfg in s.mcpServers) {
        final status = mcp.client(cfg.id)?.status;
        if (cfg.enabled && a.mcpServerIds.contains(cfg.id) && status != McpStatus.connected) {
          unawaited(connectMcpQuietly(mcp, cfg));
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final mcp = context.read<AppState>().mcp;
    return ListenableBuilder(
      listenable: Listenable.merge([mcp, widget.chat]),
      builder: (context, _) {
        final s = store.value;
        final a = widget.chat.assistant;
        final model = widget.chat.resolvedModel?.model;
        final overview = McpOverview.of(s, a, mcp);
        final items = <Widget>[
          _SheetHeader(
            icon: Icons.extension_rounded,
            title: t('MCP 服务器', 'MCP servers'),
            subtitle: t('${_assistantName(a)} · ${overview.summary}', '${_assistantName(a)} · ${overview.summary}'),
            action: IconButton(
              tooltip: t('管理 MCP', 'Manage MCP'),
              icon: const Icon(Icons.tune_rounded),
              onPressed: () => Navigator.of(context).pushNamed('/settings/mcp'),
            ),
          ),
          if (model != null && !model.tools)
            _Notice(
              icon: Icons.info_outline_rounded,
              text: t(
                '当前模型「${model.displayName}」未开启工具调用，MCP 工具不会发送给它。可在供应商 → 模型里开启「工具」能力。',
                'Tool calling is off for "${model.displayName}", so MCP tools are not sent. Enable the Tools ability in the provider\'s model settings.',
              ),
            ),
        ];
        if (s.mcpServers.isEmpty) {
          items.add(
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: EmptyState(
                icon: Icons.extension_outlined,
                title: t('还没有 MCP 服务器', 'No MCP servers'),
                subtitle: t(
                  '添加 Streamable HTTP 或 SSE 服务器后，可以在这里一键开关',
                  'Add a Streamable HTTP or SSE server, then toggle it here',
                ),
                action: FilledButton.tonalIcon(
                  onPressed: () => McpPage.edit(context, McpServerConfig()),
                  icon: const Icon(Icons.add_rounded),
                  label: Text(t('添加服务器', 'Add server')),
                ),
              ),
            ),
          );
        } else {
          for (var i = 0; i < s.mcpServers.length; i++) {
            final cfg = s.mcpServers[i];
            items.add(
              EntranceFx(
                index: i,
                dy: 8,
                child: _McpServerCard(
                  key: ValueKey('mcp-quick-${cfg.id}'),
                  cfg: cfg,
                  client: mcp.client(cfg.id),
                  active: cfg.enabled && a.mcpServerIds.contains(cfg.id),
                  onChanged: (on) => setMcpServerActive(store, mcp, a.id, cfg.id, on),
                ),
              ),
            );
          }
          items.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: OutlinedButton.icon(
                onPressed: () => McpPage.edit(context, McpServerConfig()),
                icon: const Icon(Icons.add_rounded),
                label: Text(t('添加服务器', 'Add server')),
              ),
            ),
          );
        }
        return ListView(
          controller: widget.scroll,
          padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
          children: items,
        );
      },
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFD9A441).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: const Color(0xFFB7862B)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurface)),
          ),
        ],
      ),
    );
  }
}

class _McpServerCard extends StatelessWidget {
  const _McpServerCard({
    super.key,
    required this.cfg,
    required this.client,
    required this.active,
    required this.onChanged,
  });
  final McpServerConfig cfg;
  final McpClient? client;
  final bool active;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = active ? (client?.status ?? McpStatus.idle) : McpStatus.idle;
    final tools = client?.tools ?? const <McpTool>[];
    final enabledTools = tools.where((t) => !cfg.disabledTools.contains(t.name)).length;
    final (color, label) = switch (status) {
      McpStatus.connected => (mcpConnectedColor, t('已连接', 'Connected')),
      McpStatus.connecting => (const Color(0xFFD9A441), t('连接中…', 'Connecting…')),
      McpStatus.error => (scheme.error, client?.error ?? t('连接失败', 'Connection failed')),
      McpStatus.idle => (scheme.outline, active ? t('等待连接', 'Waiting') : t('未启用', 'Off')),
    };
    return _ToggleCard(
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          IconBadge(Icons.extension_outlined, color: active ? scheme.primary : scheme.onSurfaceVariant),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 11,
              height: 11,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.surfaceContainerLowest, width: 2),
              ),
            ),
          ),
        ],
      ),
      title: cfg.name.isEmpty ? (Uri.tryParse(cfg.url)?.host ?? cfg.url) : cfg.name,
      badge: status == McpStatus.connected ? '$enabledTools/${tools.length} tools' : null,
      subtitle: Row(
        children: [
          if (status == McpStatus.connecting)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.6, color: color)),
            ),
          Flexible(child: _muted(context, label, color: status == McpStatus.error ? scheme.error : null, maxLines: 2)),
        ],
      ),
      value: active,
      onChanged: onChanged,
      onTap: status == McpStatus.connected ? () => _openTools(context) : null,
      trailing: status == McpStatus.error
          ? IconButton(
              tooltip: t('重新连接', 'Reconnect'),
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () => connectMcpQuietly(context.read<AppState>().mcp, cfg),
            )
          : status == McpStatus.connected
          ? IconButton(
              tooltip: t('选择工具', 'Choose tools'),
              icon: const Icon(Icons.checklist_rounded),
              onPressed: () => _openTools(context),
            )
          : null,
    );
  }

  void _openTools(BuildContext context) {
    final c = client;
    if (c == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => McpToolsSheet(cfg: cfg, tools: c.tools, server: c.serverName),
    );
  }
}

enum ExtensionTab { quick, modes, lorebooks, memory }

class ExtensionsQuickSheet extends StatefulWidget {
  const ExtensionsQuickSheet({
    super.key,
    required this.chat,
    required this.scroll,
    required this.onQuickMessage,
    this.initialTab,
  });
  final ChatController chat;
  final ScrollController scroll;
  final ValueChanged<String> onQuickMessage;
  final ExtensionTab? initialTab;

  @override
  State<ExtensionsQuickSheet> createState() => _ExtensionsQuickSheetState();
}

class _ExtensionsQuickSheetState extends State<ExtensionsQuickSheet> {
  late ExtensionTab _tab = widget.initialTab ?? _firstUseful();
  List<MemoryItem>? _memories;

  ExtensionTab _firstUseful() {
    final s = context.read<SettingsStore>().value;
    if (s.quickMessages.isNotEmpty) return ExtensionTab.quick;
    if (s.modes.isNotEmpty) return ExtensionTab.modes;
    if (s.lorebooks.isNotEmpty) return ExtensionTab.lorebooks;
    return ExtensionTab.quick;
  }

  @override
  void initState() {
    super.initState();
    _loadMemories();
  }

  Future<void> _loadMemories() async {
    final a = widget.chat.assistant;
    final db = context.read<AppState>().db;
    try {
      final list = await memoriesForPrompt(db, assistantId: a.useGlobalMemory ? null : a.id);
      if (mounted) setState(() => _memories = list);
    } catch (_) {
      if (mounted) setState(() => _memories = const []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    return ListenableBuilder(
      listenable: widget.chat,
      builder: (context, _) {
        final s = store.value;
        final a = widget.chat.assistant;
        final overview = ExtensionsOverview.of(s, a, widget.chat.modeIds);
        final counts = {
          ExtensionTab.quick: s.quickMessages.length,
          ExtensionTab.modes: overview.activeModes.length,
          ExtensionTab.lorebooks: overview.lorebooks,
          ExtensionTab.memory: _memories?.length ?? 0,
        };
        final labels = {
          ExtensionTab.quick: (Icons.bolt_rounded, t('快捷短语', 'Quick')),
          ExtensionTab.modes: (Icons.toggle_on_outlined, t('模式', 'Modes')),
          ExtensionTab.lorebooks: (Icons.menu_book_outlined, t('世界书', 'Lorebooks')),
          ExtensionTab.memory: (Icons.psychology_outlined, t('记忆', 'Memory')),
        };
        return ListView(
          controller: widget.scroll,
          padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
          children: [
            _SheetHeader(
              icon: Icons.auto_awesome_mosaic_outlined,
              title: t('扩展', 'Extensions'),
              subtitle: '${_assistantName(a)} · ${overview.summary}',
            ),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (final tab in ExtensionTab.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        key: ValueKey('ext-tab-${tab.name}'),
                        avatar: Icon(labels[tab]!.$1, size: 17),
                        label: Text(counts[tab]! > 0 ? '${labels[tab]!.$2} ${counts[tab]}' : labels[tab]!.$2),
                        selected: _tab == tab,
                        showCheckmark: false,
                        onSelected: (_) => setState(() => _tab = tab),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              child: KeyedSubtree(key: ValueKey(_tab), child: _body(context, store, s, a)),
            ),
          ],
        );
      },
    );
  }

  Widget _body(BuildContext context, SettingsStore store, AppSettings s, Assistant a) => switch (_tab) {
    ExtensionTab.quick => _quick(context, s),
    ExtensionTab.modes => _modes(context, store, s, a),
    ExtensionTab.lorebooks => _lorebooks(context, store, s, a),
    ExtensionTab.memory => _memory(context, store, a),
  };

  Widget _empty(BuildContext context, IconData icon, String title, String subtitle, String route) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: EmptyState(
      icon: icon,
      title: title,
      subtitle: subtitle,
      action: FilledButton.tonalIcon(
        onPressed: () => Navigator.of(context).pushNamed(route),
        icon: const Icon(Icons.tune_rounded),
        label: Text(t('去管理', 'Manage')),
      ),
    ),
  );

  Widget _manage(BuildContext context, String route) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
    child: OutlinedButton.icon(
      onPressed: () => Navigator.of(context).pushNamed(route),
      icon: const Icon(Icons.tune_rounded),
      label: Text(t('管理', 'Manage')),
    ),
  );

  Widget _quick(BuildContext context, AppSettings s) {
    if (s.quickMessages.isEmpty) {
      return _empty(
        context,
        Icons.bolt_rounded,
        t('还没有快捷短语', 'No quick messages'),
        t('常用的提问保存成短语后，点一下就能填进输入框', 'Save frequent prompts and insert them with one tap'),
        '/settings/quick',
      );
    }
    return Column(
      children: [
        for (var i = 0; i < s.quickMessages.length; i++)
          EntranceFx(
            index: i,
            dy: 8,
            child: _ToggleCard(
              key: ValueKey('quick-${s.quickMessages[i].id}'),
              leading: const IconBadge(Icons.short_text_rounded),
              title: s.quickMessages[i].title.isEmpty ? s.quickMessages[i].content : s.quickMessages[i].title,
              subtitle: _muted(context, s.quickMessages[i].content, maxLines: 2),
              trailing: const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Icon(Icons.north_west_rounded, size: 18),
              ),
              onTap: () {
                Navigator.of(context).pop();
                widget.onQuickMessage(s.quickMessages[i].content);
              },
            ),
          ),
        _manage(context, '/settings/quick'),
      ],
    );
  }

  Widget _modes(BuildContext context, SettingsStore store, AppSettings s, Assistant a) {
    if (s.modes.isEmpty) {
      return _empty(
        context,
        Icons.toggle_on_outlined,
        t('还没有模式', 'No modes'),
        t('模式是一段可开关的提示词，例如学习模式', 'A mode is a prompt snippet you can switch on, like Learning'),
        '/settings/prompts',
      );
    }
    return Column(
      children: [
        for (var i = 0; i < s.modes.length; i++)
          () {
            final m = s.modes[i];
            final always = a.modeIds.contains(m.id);
            final on = always || widget.chat.modeIds.contains(m.id);
            return EntranceFx(
              index: i,
              dy: 8,
              child: _ToggleCard(
                key: ValueKey('mode-${m.id}'),
                leading: IconBadge(Icons.toggle_on_outlined, color: on ? null : Theme.of(context).colorScheme.outline),
                title: m.name.isEmpty ? t('未命名模式', 'Untitled mode') : m.name,
                badge: always ? t('助手常开', 'Always on') : null,
                subtitle: _muted(
                  context,
                  always ? t('在助手设置里设为常开，这里不能关闭', 'Always on for this assistant') : m.content,
                  maxLines: 2,
                ),
                value: on,
                onChanged: always ? null : (_) => widget.chat.toggleMode(m.id),
              ),
            );
          }(),
        _manage(context, '/settings/prompts'),
      ],
    );
  }

  Widget _lorebooks(BuildContext context, SettingsStore store, AppSettings s, Assistant a) {
    if (s.lorebooks.isEmpty) {
      return _empty(
        context,
        Icons.menu_book_outlined,
        t('还没有世界书', 'No lorebooks'),
        t('世界书条目会在聊天出现关键词时自动注入', 'Lorebook entries are injected when their keywords appear'),
        '/settings/prompts',
      );
    }
    return Column(
      children: [
        for (var i = 0; i < s.lorebooks.length; i++)
          () {
            final b = s.lorebooks[i];
            final on = b.enabled && a.lorebookIds.contains(b.id);
            final entries = b.entries.where((e) => e.enabled).length;
            return EntranceFx(
              index: i,
              dy: 8,
              child: _ToggleCard(
                key: ValueKey('lore-${b.id}'),
                leading: IconBadge(Icons.menu_book_outlined, color: on ? null : Theme.of(context).colorScheme.outline),
                title: b.name.isEmpty ? t('未命名', 'Untitled') : b.name,
                badge: t('$entries/${b.entries.length} 条', '$entries/${b.entries.length}'),
                subtitle: _muted(
                  context,
                  !b.enabled
                      ? t('世界书已停用，打开后同时启用', 'Disabled; turning on enables it')
                      : (b.description.isEmpty
                            ? t('作用于「${_assistantName(a)}」', 'For ${_assistantName(a)}')
                            : b.description),
                ),
                value: on,
                onChanged: (v) => setLorebookActive(store, a.id, b.id, v),
                trailing: IconButton(
                  tooltip: t('编辑条目', 'Edit entries'),
                  icon: const Icon(Icons.edit_note_rounded),
                  onPressed: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => LorebookPage(id: b.id))),
                ),
              ),
            );
          }(),
        _manage(context, '/settings/prompts'),
      ],
    );
  }

  Widget _memory(BuildContext context, SettingsStore store, Assistant a) {
    final scheme = Theme.of(context).colorScheme;
    final list = _memories;
    void saveAssistant(Assistant next) => store.upsertAssistant(next);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ToggleCard(
          key: const ValueKey('memory-enabled'),
          leading: const IconBadge(Icons.bookmark_added_outlined),
          title: t('长期记忆', 'Long-term memory'),
          subtitle: _muted(context, t('模型可以记住并更新你的偏好', 'The model can remember your preferences')),
          value: a.enableMemory,
          onChanged: (v) {
            saveAssistant(a.copyWith(enableMemory: v));
            _loadMemories();
          },
        ),
        if (a.enableMemory)
          _ToggleCard(
            key: const ValueKey('memory-global'),
            leading: const IconBadge(Icons.public_rounded),
            title: t('只用全局记忆', 'Global memory only'),
            subtitle: _muted(
              context,
              a.useGlobalMemory
                  ? t('新记忆存到全局，所有助手共享', 'New memories are shared with every assistant')
                  : t('新记忆只属于这个助手，同时也能读取全局记忆', 'New memories stay with this assistant; global ones are read too'),
              maxLines: 2,
            ),
            value: a.useGlobalMemory,
            onChanged: (v) {
              saveAssistant(a.copyWith(useGlobalMemory: v));
              _loadMemories();
            },
          ),
        _GroupLabel(
          t('当前可见的记忆', 'Visible memories'),
          trailing: list == null
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : Text('${list.length}', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.primary)),
        ),
        if (list != null && list.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: _muted(
              context,
              a.enableMemory
                  ? t('还没有记忆。聊天中模型会自动记下值得长期保存的信息。', 'No memories yet. The model saves useful facts as you chat.')
                  : t('开启长期记忆后，模型会在聊天中自动保存偏好。', 'Turn on long-term memory to let the model save preferences.'),
              maxLines: 3,
            ),
          ),
        if (list != null)
          for (var i = 0; i < list.length && i < 30; i++)
            EntranceFx(
              index: i,
              dy: 6,
              child: _ToggleCard(
                key: ValueKey('memory-${list[i].id}'),
                leading: IconBadge(list[i].assistantId == null ? Icons.public_rounded : Icons.person_outline_rounded),
                title: list[i].content,
                subtitle: _muted(
                  context,
                  '${list[i].assistantId == null ? t('全局', 'Global') : _assistantName(a)} · ${formatDateTime(list[i].updatedAt)}',
                ),
                trailing: IconButton(
                  tooltip: t('删除记忆', 'Delete memory'),
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () async {
                    final db = context.read<AppState>().db;
                    await db.deleteMemory(list[i].id);
                    await _loadMemories();
                  },
                ),
              ),
            ),
        _manage(context, '/settings/memory'),
      ],
    );
  }
}
