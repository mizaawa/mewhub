import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/message.dart';
import '../../core/i18n.dart';
import '../../core/util.dart';
import '../../data/assistant.dart';
import '../../data/models_misc.dart';
import '../../state/app_state.dart';
import '../../state/settings_store.dart';
import '../../tools/mcp.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';

class McpPage extends StatelessWidget {
  const McpPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final list = store.value.mcpServers;
    return Scaffold(
      appBar: AppBar(title: const Text('MCP')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add_rounded),
        label: Text(t('添加服务器', 'Add server')),
        onPressed: () => edit(context, McpServerConfig()),
      ),
      body: list.isEmpty
          ? EmptyState(
              icon: Icons.extension_outlined,
              title: t('还没有 MCP 服务器', 'No MCP servers'),
              subtitle: t(
                '支持远程 Streamable HTTP 与 SSE 传输。新服务器会自动启用到当前助手，也可以在聊天输入框的 MCP 抽屉里开关。',
                'Remote Streamable HTTP and SSE transports. New servers are enabled for the current assistant; toggle them from the MCP drawer in chat.',
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 100),
              children: [
                for (var i = 0; i < list.length; i++)
                  EntranceFx(
                    index: i,
                    child: _McpTile(cfg: list[i], onEdit: () => edit(context, list[i])),
                  ),
              ],
            ),
    );
  }

  /// Add / edit dialog shared with the chat MCP drawer.
  static Future<void> edit(BuildContext context, McpServerConfig cfg) async {
    final store = context.read<SettingsStore>();
    final name = TextEditingController(text: cfg.name);
    final url = TextEditingController(text: cfg.url);
    final headers = TextEditingController(text: cfg.headers.entries.map((e) => '${e.key}: ${e.value}').join('\n'));
    var transport = cfg.transport;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(cfg.url.isEmpty ? t('添加 MCP 服务器', 'Add MCP server') : t('编辑 MCP 服务器', 'Edit MCP server')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: InputDecoration(labelText: t('名称', 'Name')),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: url,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'URL', hintText: 'https://example.com/mcp'),
                ),
                const SizedBox(height: 10),
                SegmentedButton<McpTransport>(
                  segments: const [
                    ButtonSegment(value: McpTransport.streamableHttp, label: Text('Streamable HTTP')),
                    ButtonSegment(value: McpTransport.sse, label: Text('SSE')),
                  ],
                  selected: {transport},
                  onSelectionChanged: (v) => set(() => transport = v.first),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: headers,
                  minLines: 2,
                  maxLines: 6,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: t('请求头（每行 Key: Value）', 'Headers (Key: Value per line)'),
                    hintText: 'Authorization: Bearer xxx',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('取消', 'Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('保存', 'Save'))),
          ],
        ),
      ),
    );
    if (ok == true) {
      final u = Uri.tryParse(url.text.trim());
      if (u == null || !(u.scheme == 'https' || u.scheme == 'http')) {
        if (context.mounted) toast(context, t('URL 无效', 'Invalid URL'), error: true);
      } else {
        final h = <String, String>{};
        for (final line in headers.text.split('\n')) {
          final i = line.indexOf(':');
          if (i > 0) h[line.substring(0, i).trim()] = line.substring(i + 1).trim();
        }
        final isNew = !store.value.mcpServers.any((m) => m.id == cfg.id);
        final saved = cfg.copyWith(
          name: name.text.trim().isEmpty ? (u.host) : name.text.trim(),
          url: url.text.trim(),
          transport: transport,
          headers: h,
        );
        store.upsertMcp(saved);
        // A new server is useless until an assistant uses it: link it to the
        // current one right away, then connect in the background.
        if (isNew) {
          final a = store.value.currentAssistant;
          store.upsertAssistant(a.copyWith(mcpServerIds: {...a.mcpServerIds, saved.id}));
        }
        if (context.mounted && saved.enabled) {
          final mcp = context.read<AppState>().mcp;
          unawaited(() async {
            try {
              await mcp.ensure(saved);
            } catch (_) {}
          }());
        }
      }
    }
    name.dispose();
    url.dispose();
    headers.dispose();
  }
}

class _McpTile extends StatefulWidget {
  const _McpTile({required this.cfg, required this.onEdit});
  final McpServerConfig cfg;
  final VoidCallback onEdit;

  @override
  State<_McpTile> createState() => _McpTileState();
}

class _McpTileState extends State<_McpTile> {
  bool _testing = false;

  Future<void> _test() async {
    final app = context.read<AppState>();
    setState(() => _testing = true);
    try {
      final c = await app.mcp.ensure(widget.cfg);
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => McpToolsSheet(cfg: widget.cfg, tools: c.tools, server: c.serverName),
      );
    } catch (e) {
      if (mounted) toast(context, t('连接失败：$e', 'Connection failed: $e'), error: true);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.read<SettingsStore>();
    final mcp = context.read<AppState>().mcp;
    return ListenableBuilder(listenable: mcp, builder: (context, _) => _tile(context, store, mcp));
  }

  Widget _tile(BuildContext context, SettingsStore store, McpManager mcp) {
    final client = mcp.client(widget.cfg.id);
    final status = client?.status ?? McpStatus.idle;
    final scheme = Theme.of(context).colorScheme;
    final dot = switch (status) {
      McpStatus.connected => const Color(0xFF5E9E6E),
      McpStatus.error => scheme.error,
      McpStatus.connecting => scheme.primary,
      McpStatus.idle => scheme.outline,
    };
    final used = store.value.assistants.where((a) => a.mcpServerIds.contains(widget.cfg.id)).length;
    final detail = switch (status) {
      McpStatus.connected => '${client!.tools.length} tools',
      McpStatus.connecting => t('连接中…', 'Connecting…'),
      McpStatus.error => client?.error ?? t('连接失败', 'Connection failed'),
      McpStatus.idle => t('$used 个助手使用', 'Used by $used'),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Card(
        child: ListTile(
          leading: Stack(
            clipBehavior: Clip.none,
            children: [
              const IconBadge(Icons.extension_outlined),
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                ),
              ),
            ],
          ),
          title: Text(widget.cfg.name.isEmpty ? widget.cfg.url : widget.cfg.name),
          subtitle: Text(
            '${widget.cfg.transport == McpTransport.sse ? 'SSE' : 'HTTP'} · $detail',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: status == McpStatus.error ? TextStyle(color: scheme.error) : null,
          ),
          onTap: widget.onEdit,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: t('测试并查看工具', 'Test & list tools'),
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.play_circle_outline_rounded),
              ),
              Switch(
                value: widget.cfg.enabled,
                onChanged: (v) {
                  store.upsertMcp(widget.cfg.copyWith(enabled: v));
                  if (!v) unawaited(mcp.disconnect(widget.cfg.id));
                },
              ),
            ],
          ),
          onLongPress: () async {
            if (await confirm(context, t('删除这个服务器？', 'Delete this server?'), destructive: true)) {
              store.update(
                (s) => s.copyWith(
                  mcpServers: s.mcpServers.where((e) => e.id != widget.cfg.id).toList(),
                  assistants: [
                    for (final a in s.assistants) a.copyWith(mcpServerIds: {...a.mcpServerIds}..remove(widget.cfg.id)),
                  ],
                ),
              );
              unawaited(mcp.disconnect(widget.cfg.id));
            }
          },
        ),
      ),
    );
  }
}

class McpToolsSheet extends StatelessWidget {
  const McpToolsSheet({super.key, required this.cfg, required this.tools, required this.server});
  final McpServerConfig cfg;
  final List<McpTool> tools;
  final String server;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final cur = store.value.mcpServers.firstWhere((e) => e.id == cfg.id, orElse: () => cfg);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.7,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Color(0xFF5E9E6E)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('$server · ${tools.length} tools', style: Theme.of(context).textTheme.titleMedium),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final tool in tools)
                  SwitchListTile(
                    title: Text(tool.name),
                    subtitle: Text(tool.description, maxLines: 2, overflow: TextOverflow.ellipsis),
                    value: !cur.disabledTools.contains(tool.name),
                    onChanged: (v) => store.upsertMcp(
                      cur.copyWith(
                        disabledTools: v
                            ? ({...cur.disabledTools}..remove(tool.name))
                            : {...cur.disabledTools, tool.name},
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Lorebooks (keyword-triggered world info) and toggleable modes.
class PromptsPage extends StatelessWidget {
  const PromptsPage({super.key});

  Future<void> _importLorebook(BuildContext context) async {
    final store = context.read<SettingsStore>();
    try {
      final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
      if (files.isEmpty) return;
      final j = asMap(jsonDecode(utf8.decode(await files.first.readAsBytes())));
      Lorebook book;
      if (j['entries'] is Map) {
        // SillyTavern world info: {entries: {"0": {...}}}
        book = Lorebook(
          name: files.first.name.replaceAll('.json', ''),
          entries: [
            for (final e in asMap(j['entries']).values)
              () {
                final m = asMap(e);
                return LoreEntry(
                  name: asStr(m['comment']),
                  enabled: !asBool(m['disable']),
                  keywords: asList(m['key']).map((k) => k.toString()).toList(),
                  constant: asBool(m['constant']),
                  content: asStr(m['content']),
                  priority: asInt(m['order']),
                  depth: asInt(m['depth'], 4),
                  position: switch (asInt(m['position'])) {
                    0 => InjectPosition.beforeSystem,
                    4 => InjectPosition.atDepth,
                    _ => InjectPosition.afterSystem,
                  },
                  caseSensitive: asBool(m['caseSensitive']),
                  scanDepth: asInt(m['scanDepth'], 4),
                );
              }(),
          ],
        );
      } else {
        final data = j['type'] == 'lorebook' ? asMap(j['data']) : j;
        book = Lorebook.fromJson({...data, 'id': newId()});
      }
      store.upsertLorebook(book);
      if (context.mounted) toast(context, t('已导入 ${book.entries.length} 条', 'Imported ${book.entries.length} entries'));
    } catch (e) {
      if (context.mounted) toast(context, t('导入失败：$e', 'Import failed: $e'), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final s = store.value;
    return Scaffold(
      appBar: AppBar(
        title: Text(t('世界书 / 模式', 'Lorebooks & modes')),
        actions: [
          IconButton(
            tooltip: t('导入世界书', 'Import lorebook'),
            icon: const Icon(Icons.file_download_outlined),
            onPressed: () => _importLorebook(context),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          SettingsGroup(
            title: t('模式', 'Modes'),
            footer: t(
              '在聊天输入框「+」→ 扩展 中开关，或在助手中设为常开',
              'Toggle from the composer "+" → Extensions, or make always-on per assistant',
            ),
            children: [
              for (final m in s.modes)
                ListTile(
                  leading: const IconBadge(Icons.toggle_on_outlined),
                  title: Text(m.name),
                  subtitle: Text(m.content, maxLines: 2, overflow: TextOverflow.ellipsis),
                  onTap: () => _editMode(context, m),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () =>
                        store.update((x) => x.copyWith(modes: x.modes.where((e) => e.id != m.id).toList())),
                  ),
                ),
              ListTile(
                leading: const IconBadge(Icons.add_rounded),
                title: Text(t('新建模式', 'New mode')),
                onTap: () => _editMode(context, ModeInjection(name: t('新模式', 'New mode'))),
              ),
            ],
          ),
          SettingsGroup(
            index: 1,
            title: t('世界书', 'Lorebooks'),
            children: [
              for (final b in s.lorebooks)
                ListTile(
                  leading: const IconBadge(Icons.menu_book_outlined),
                  title: Text(b.name.isEmpty ? t('未命名', 'Untitled') : b.name),
                  subtitle: Text(t('${b.entries.length} 条', '${b.entries.length} entries')),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => LorebookPage(id: b.id))),
                ),
              ListTile(
                leading: const IconBadge(Icons.add_rounded),
                title: Text(t('新建世界书', 'New lorebook')),
                onTap: () {
                  final b = Lorebook(name: t('新世界书', 'New lorebook'));
                  store.upsertLorebook(b);
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => LorebookPage(id: b.id)));
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _editMode(BuildContext context, ModeInjection m) async {
    final store = context.read<SettingsStore>();
    final name = await promptText(context, t('名称', 'Name'), initial: m.name);
    if (name == null || !context.mounted) return;
    final content = await promptText(context, t('内容', 'Content'), initial: m.content, maxLines: 14);
    if (content == null) return;
    store.update((x) {
      final list = [...x.modes];
      final i = list.indexWhere((e) => e.id == m.id);
      final updated = m.copyWith(name: name.trim(), content: content);
      if (i >= 0) {
        list[i] = updated;
      } else {
        list.add(updated);
      }
      return x.copyWith(modes: list);
    });
  }
}

class LorebookPage extends StatelessWidget {
  const LorebookPage({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final book = store.value.lorebooks.where((b) => b.id == id).firstOrNull;
    if (book == null) return const Scaffold();
    void save(Lorebook b) => store.upsertLorebook(b);
    return Scaffold(
      appBar: AppBar(
        title: Text(book.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.drive_file_rename_outline_rounded),
            onPressed: () async {
              final v = await promptText(context, t('名称', 'Name'), initial: book.name);
              if (v != null) save(book.copyWith(name: v.trim()));
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () async {
              if (!await confirm(context, t('删除这个世界书？', 'Delete this lorebook?'), destructive: true)) return;
              store.update((s) => s.copyWith(lorebooks: s.lorebooks.where((b) => b.id != id).toList()));
              if (context.mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.add_rounded),
        onPressed: () async {
          final e = await _editEntry(context, LoreEntry(name: t('新条目', 'New entry')));
          if (e != null) save(book.copyWith(entries: [...book.entries, e]));
        },
      ),
      body: book.entries.isEmpty
          ? EmptyState(
              icon: Icons.menu_book_outlined,
              title: t('还没有条目', 'No entries'),
              subtitle: t('条目在最近消息中出现关键词时注入提示词', 'Entries are injected when their keywords appear in recent messages'),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 100),
              children: [
                for (var i = 0; i < book.entries.length; i++)
                  EntranceFx(
                    index: i,
                    child: SwitchListTile(
                      title: Text(
                        book.entries[i].name.isEmpty ? book.entries[i].keywords.join(', ') : book.entries[i].name,
                      ),
                      subtitle: Text(
                        book.entries[i].constant ? t('常驻', 'Always on') : book.entries[i].keywords.join(', '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      value: book.entries[i].enabled,
                      onChanged: (v) {
                        final l = [...book.entries];
                        l[i] = l[i].copyWith(enabled: v);
                        save(book.copyWith(entries: l));
                      },
                      secondary: IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () async {
                          final e = await _editEntry(context, book.entries[i]);
                          if (e == null) return;
                          final l = [...book.entries];
                          l[i] = e;
                          save(book.copyWith(entries: l));
                        },
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  static Future<LoreEntry?> _editEntry(BuildContext context, LoreEntry e) async {
    final name = TextEditingController(text: e.name);
    final keys = TextEditingController(text: e.keywords.join(', '));
    final content = TextEditingController(text: e.content);
    var constant = e.constant;
    var regex = e.useRegex;
    var pos = e.position;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text(t('编辑条目', 'Edit entry')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: InputDecoration(labelText: t('名称', 'Name')),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: keys,
                  decoration: InputDecoration(labelText: t('关键词（逗号分隔）', 'Keywords (comma separated)')),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: content,
                  minLines: 3,
                  maxLines: 10,
                  decoration: InputDecoration(labelText: t('内容', 'Content')),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(t('常驻（无需关键词）', 'Always on')),
                  value: constant,
                  onChanged: (v) => set(() => constant = v ?? false),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(t('关键词为正则', 'Keywords are regex')),
                  value: regex,
                  onChanged: (v) => set(() => regex = v ?? false),
                ),
                DropdownButtonFormField<InjectPosition>(
                  initialValue: pos,
                  decoration: InputDecoration(labelText: t('注入位置', 'Position')),
                  items: [
                    DropdownMenuItem(value: InjectPosition.beforeSystem, child: Text(t('系统提示词之前', 'Before system'))),
                    DropdownMenuItem(value: InjectPosition.afterSystem, child: Text(t('系统提示词之后', 'After system'))),
                    DropdownMenuItem(value: InjectPosition.topOfChat, child: Text(t('对话开头', 'Top of chat'))),
                    DropdownMenuItem(value: InjectPosition.bottomOfChat, child: Text(t('最新消息之前', 'Before latest'))),
                    DropdownMenuItem(value: InjectPosition.atDepth, child: Text(t('指定深度', 'At depth'))),
                  ],
                  onChanged: (v) => set(() => pos = v ?? pos),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('取消', 'Cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(t('保存', 'Save'))),
          ],
        ),
      ),
    );
    final out = ok == true
        ? e.copyWith(
            name: name.text.trim(),
            keywords: keys.text.split(RegExp(r'[,，]')).map((k) => k.trim()).where((k) => k.isNotEmpty).toList(),
            content: content.text,
            constant: constant,
            useRegex: regex,
            position: pos,
          )
        : null;
    name.dispose();
    keys.dispose();
    content.dispose();
    return out;
  }
}

class QuickMessagesPage extends StatelessWidget {
  const QuickMessagesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final list = store.value.quickMessages;
    Future<void> edit(QuickMessage? q) async {
      final title = await promptText(context, t('标题', 'Title'), initial: q?.title ?? '');
      if (title == null || !context.mounted) return;
      final content = await promptText(context, t('内容', 'Content'), initial: q?.content ?? '', maxLines: 8);
      if (content == null || content.trim().isEmpty) return;
      store.update((s) {
        final l = [...s.quickMessages];
        final item = QuickMessage(id: q?.id, title: title.trim(), content: content);
        final i = q == null ? -1 : l.indexWhere((e) => e.id == q.id);
        if (i >= 0) {
          l[i] = item;
        } else {
          l.add(item);
        }
        return s.copyWith(quickMessages: l);
      });
    }

    return Scaffold(
      appBar: AppBar(title: Text(t('快捷短语', 'Quick messages'))),
      floatingActionButton: FloatingActionButton(onPressed: () => edit(null), child: const Icon(Icons.add_rounded)),
      body: list.isEmpty
          ? EmptyState(
              icon: Icons.short_text_rounded,
              title: t('还没有快捷短语', 'No quick messages'),
              subtitle: t(
                '常用的提问可以保存在这里，在输入框「+」→ 扩展 中一键填入',
                'Save frequent prompts and insert them from the composer "+" → Extensions',
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 100),
              children: [
                for (var i = 0; i < list.length; i++)
                  EntranceFx(
                    index: i,
                    child: ListTile(
                      leading: const IconBadge(Icons.short_text_rounded),
                      title: Text(list[i].title.isEmpty ? list[i].content : list[i].title, maxLines: 1),
                      subtitle: Text(list[i].content, maxLines: 2, overflow: TextOverflow.ellipsis),
                      onTap: () => edit(list[i]),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: () => store.update(
                          (s) => s.copyWith(quickMessages: s.quickMessages.where((e) => e.id != list[i].id).toList()),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class MemoryPage extends StatefulWidget {
  const MemoryPage({super.key});

  @override
  State<MemoryPage> createState() => _MemoryPageState();
}

class _MemoryPageState extends State<MemoryPage> {
  List<MemoryItem> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = context.read<AppState>().db;
    final items = await db.allMemories();
    if (mounted) setState(() => (_items = items, _loading = false));
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsStore>().value;
    final db = context.read<AppState>().db;
    final groups = <String?, List<MemoryItem>>{};
    for (final m in _items) {
      groups.putIfAbsent(m.assistantId, () => []).add(m);
    }
    return Scaffold(
      appBar: AppBar(title: Text(t('记忆', 'Memories'))),
      floatingActionButton: FloatingActionButton(
        child: const Icon(Icons.add_rounded),
        onPressed: () async {
          final v = await promptText(context, t('新的全局记忆', 'New global memory'), maxLines: 4);
          if (v == null || v.trim().isEmpty) return;
          await db.saveMemory(MemoryItem(content: v.trim()));
          await _load();
        },
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
          ? EmptyState(
              icon: Icons.psychology_outlined,
              title: t('还没有记忆', 'No memories yet'),
              subtitle: t(
                '在助手的「工具」页开启长期记忆后，模型会自动记住你的偏好',
                'Turn on long-term memory for an assistant and it will remember things',
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 100),
              children: [
                for (final g in groups.entries)
                  SettingsGroup(
                    title: g.key == null
                        ? t('全局', 'Global')
                        : (s.assistantById(g.key!)?.name ?? t('已删除的助手', 'Deleted assistant')),
                    children: [
                      for (final m in g.value)
                        ListTile(
                          title: Text(m.content),
                          subtitle: Text(formatDateTime(m.updatedAt)),
                          onTap: () async {
                            final v = await promptText(
                              context,
                              t('编辑记忆', 'Edit memory'),
                              initial: m.content,
                              maxLines: 6,
                            );
                            if (v == null) return;
                            await db.saveMemory(m.copyWith(content: v.trim()));
                            await _load();
                          },
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline_rounded),
                            onPressed: () async {
                              await db.deleteMemory(m.id);
                              await _load();
                            },
                          ),
                        ),
                    ],
                  ),
              ],
            ),
    );
  }
}

/// Saved (favorited) messages.
class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  List<FavoriteItem>? _items;

  @override
  void initState() {
    super.initState();
    context.read<AppState>().db.favorites().then((v) {
      if (mounted) setState(() => _items = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final items = _items;
    return Scaffold(
      appBar: AppBar(title: Text(t('收藏', 'Favorites'))),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
          ? EmptyState(
              icon: Icons.favorite_border_rounded,
              title: t('还没有收藏', 'No favorites'),
              subtitle: t('点回复下方的 ♡ 收藏', 'Tap ♡ under a reply to save it'),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              separatorBuilder: (context, i) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final f = items[i];
                final snap = asMap(tryJsonDecode(f.snapshot));
                final msg = ChatMessage.fromJson(asMap(snap['message']));
                return EntranceFx(
                  index: i,
                  child: Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
                      title: Text(msg.text, maxLines: 5, overflow: TextOverflow.ellipsis),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text('${asStr(snap['title'], t('对话', 'Chat'))} · ${formatDateTime(f.createdAt)}'),
                      ),
                      onTap: () async {
                        await app.openConversation(f.conversationId);
                        if (context.mounted) Navigator.of(context).popUntil((r) => r.isFirst);
                      },
                      trailing: IconButton(
                        icon: const Icon(Icons.favorite_rounded, color: Color(0xFFE07A8B)),
                        onPressed: () async {
                          await app.db.removeFavorite(f.messageId);
                          app.favoriteIds.remove(f.messageId);
                          setState(() => items.removeAt(i));
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
