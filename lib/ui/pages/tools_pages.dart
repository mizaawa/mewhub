import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ai/factory.dart';
import '../../ai/provider_config.dart';
import '../../chat/helpers.dart';
import '../../core/attachments.dart';
import '../../core/i18n.dart';
import '../../core/net.dart';
import '../../core/paths.dart';
import '../../core/util.dart';
import '../../data/backup.dart';
import '../../data/database.dart';
import '../../data/settings.dart';
import '../../state/app_state.dart';
import '../../state/settings_store.dart';
import '../chat/model_picker.dart';
import '../settings/config_transfer_pages.dart';
import '../export.dart';
import '../widgets/common.dart';
import '../widgets/image_viewer.dart';
import '../widgets/markdown_view.dart';
import '../widgets/motion.dart';

export 'usage_stats_page.dart' show StatsPage;

class BackupPage extends StatefulWidget {
  const BackupPage({super.key});

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  bool _busy = false;
  bool _secrets = true;
  List<WebDavFile>? _remote;

  Future<void> _run(Future<void> Function() f) async {
    setState(() => _busy = true);
    try {
      await f();
    } catch (e) {
      if (mounted) toast(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Uint8List> _build() {
    final app = context.read<AppState>();
    final store = context.read<SettingsStore>();
    return BackupService(app.db).build(store.value, includeSecrets: _secrets);
  }

  Future<void> _restoreBytes(Uint8List bytes) async {
    final app = context.read<AppState>();
    final store = context.read<SettingsStore>();
    final ok = await confirm(
      context,
      t('从备份恢复？', 'Restore from backup?'),
      message: t('设置会被替换，对话会按 ID 合并。', 'Settings are replaced; chats are merged by id.'),
      ok: t('恢复', 'Restore'),
    );
    if (!ok) return;
    final s = await BackupService(app.db).restore(bytes, store.value);
    store.replace(s);
    await store.flush();
    app.favoriteIds = await app.db.favoriteMessageIds();
    await app.refreshList();
    app.newChat();
    if (mounted) toast(context, t('恢复完成', 'Restored'));
  }

  Future<void> _exportLocal() => _run(() async {
    final store = context.read<SettingsStore>();
    final bytes = await _build();
    final saved = await saveBytes(bytes, BackupService.fileName(), mime: 'application/zip');
    if (saved) {
      store.update((s) => s.copyWith(lastBackupAt: DateTime.now()));
      if (mounted) toast(context, t('已导出 ${formatBytes(bytes.length)}', 'Exported ${formatBytes(bytes.length)}'));
    }
  });

  Future<void> _importLocal() => _run(() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
    if (files.isEmpty) return;
    await _restoreBytes(await files.first.readAsBytes());
  });

  Future<void> _webdavUpload() => _run(() async {
    final s = context.read<SettingsStore>();
    final bytes = await _build();
    await WebDavClient(s.value.webDav).upload(BackupService.fileName(), bytes);
    s.update((x) => x.copyWith(lastBackupAt: DateTime.now()));
    await _webdavList();
    if (mounted) toast(context, t('已上传', 'Uploaded'));
  });

  Future<void> _webdavList() async {
    final s = context.read<SettingsStore>().value;
    final list = await WebDavClient(s.webDav).list();
    if (mounted) setState(() => _remote = list);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final s = store.value;
    final dav = s.webDav;
    return Scaffold(
      appBar: AppBar(
        title: Text(t('备份与恢复', 'Backup & restore')),
        bottom: _busy
            ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2))
            : null,
      ),
      body: AbsorbPointer(
        absorbing: _busy,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 40),
          children: [
            SettingsGroup(
              title: t('扫码传输配置', 'Transfer config by QR'),
              footer: t(
                '把供应商、模型、助手、MCP、世界书等配置传到另一台设备。聊天记录请用下面的备份文件。',
                'Move providers, models, assistants, MCP servers and lorebooks to another device. Use a backup file for chats.',
              ),
              children: [_QrTransferCard(includeSecrets: _secrets)],
            ),
            SettingsGroup(
              index: 1,
              title: t('本地', 'Local'),
              footer: s.lastBackupAt == null
                  ? t('还没有备份过', 'Never backed up')
                  : t('上次备份：${formatDateTime(s.lastBackupAt!)}', 'Last backup: ${formatDateTime(s.lastBackupAt!)}'),
              children: [
                SwitchListTile(
                  secondary: const IconBadge(Icons.key_rounded),
                  title: Text(t('包含 API Key 等密钥', 'Include API keys & passwords')),
                  subtitle: Text(t('同时作用于二维码传输；关闭后可以放心分享', 'Also applies to QR transfer; turn off to share safely')),
                  value: _secrets,
                  onChanged: (v) => setState(() => _secrets = v),
                ),
                ListTile(
                  leading: const IconBadge(Icons.upload_file_rounded),
                  title: Text(t('导出备份文件', 'Export backup file')),
                  onTap: _exportLocal,
                ),
                ListTile(
                  leading: const IconBadge(Icons.restore_page_outlined),
                  title: Text(t('从文件恢复', 'Restore from file')),
                  onTap: _importLocal,
                ),
              ],
            ),
            SettingsGroup(
              index: 2,
              title: 'WebDAV',
              children: [
                ListTile(
                  leading: const IconBadge(Icons.cloud_outlined),
                  title: Text(t('服务器', 'Server')),
                  subtitle: Text(dav.url.isEmpty ? t('未配置（坚果云、Nextcloud 等）', 'Not set (Nextcloud, etc.)') : dav.url),
                  onTap: () async {
                    final url = await promptText(
                      context,
                      'WebDAV URL',
                      initial: dav.url,
                      hint: 'https://dav.jianguoyun.com/dav/',
                    );
                    if (url == null || !context.mounted) return;
                    final user = await promptText(context, t('用户名', 'Username'), initial: dav.username);
                    if (user == null || !context.mounted) return;
                    final pass = await promptText(
                      context,
                      t('密码 / 应用密码', 'Password / app password'),
                      initial: dav.password,
                    );
                    if (pass == null) return;
                    store.update(
                      (x) => x.copyWith(
                        webDav: dav.copyWith(url: url.trim(), username: user.trim(), password: pass),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const IconBadge(Icons.folder_open_outlined),
                  title: Text(t('远程目录', 'Remote folder')),
                  subtitle: Text(dav.path),
                  onTap: () async {
                    final v = await promptText(context, t('远程目录', 'Remote folder'), initial: dav.path);
                    if (v != null) store.update((x) => x.copyWith(webDav: dav.copyWith(path: v.trim())));
                  },
                ),
                ListTile(
                  enabled: dav.configured,
                  leading: const IconBadge(Icons.cloud_upload_outlined),
                  title: Text(t('立即备份到 WebDAV', 'Back up to WebDAV now')),
                  onTap: _webdavUpload,
                ),
                ListTile(
                  enabled: dav.configured,
                  leading: const IconBadge(Icons.cloud_download_outlined),
                  title: Text(t('查看远程备份', 'Browse remote backups')),
                  onTap: () => _run(_webdavList),
                ),
                if (_remote != null)
                  for (final f in _remote!)
                    ListTile(
                      leading: const Icon(Icons.archive_outlined),
                      title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${formatBytes(f.size)}${f.modified == null ? '' : ' · ${formatDateTime(f.modified!.toLocal())}'}',
                      ),
                      onTap: () => _run(() async => _restoreBytes(await WebDavClient(dav).download(f.href))),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline_rounded),
                        onPressed: () => _run(() async {
                          await WebDavClient(dav).delete(f.href);
                          await _webdavList();
                        }),
                      ),
                    ),
              ],
            ),
            SettingsGroup(
              index: 3,
              title: t('存储', 'Storage'),
              children: [
                FutureBuilder<int>(
                  future: AppPaths.dirSize(AppPaths.support),
                  builder: (context, snap) => ListTile(
                    leading: const IconBadge(Icons.sd_storage_outlined),
                    title: Text(t('应用数据', 'App data')),
                    subtitle: Text(snap.hasData ? formatBytes(snap.data!) : t('计算中…', 'Calculating…')),
                  ),
                ),
                ListTile(
                  leading: IconBadge(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
                  title: Text(
                    t('清空所有对话', 'Delete all chats'),
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                  onTap: () async {
                    final app = context.read<AppState>();
                    if (!await confirm(
                      context,
                      t('清空所有对话、记忆和收藏？', 'Delete all chats, memories and favorites?'),
                      message: t('此操作无法撤销，建议先导出备份。', 'This cannot be undone. Export a backup first.'),
                      destructive: true,
                    )) {
                      return;
                    }
                    await app.db.wipe();
                    app.favoriteIds.clear();
                    await app.refreshList();
                    app.newChat();
                    if (context.mounted) toast(context, t('已清空', 'Deleted'));
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Two side-by-side tiles: show this device's config as QR codes, or scan
/// another device's codes.
class _QrTransferCard extends StatelessWidget {
  const _QrTransferCard({required this.includeSecrets});
  final bool includeSecrets;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(10),
    child: Row(
      children: [
        Expanded(
          child: _TransferTile(
            key: const ValueKey('config-qr-send'),
            icon: Icons.qr_code_2_rounded,
            title: t('展示二维码', 'Show QR'),
            subtitle: includeSecrets ? t('含密钥', 'With keys') : t('不含密钥', 'No keys'),
            filled: true,
            onTap: () =>
                Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => ConfigQrSendPage(includeSecrets: includeSecrets))),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _TransferTile(
            key: const ValueKey('config-qr-scan'),
            icon: Icons.qr_code_scanner_rounded,
            title: t('扫码接收', 'Scan'),
            subtitle: t('从另一台设备', 'From another device'),
            onTap: () =>
                Navigator.of(context).push(MaterialPageRoute<bool>(builder: (_) => const ConfigQrReceivePage())),
          ),
        ),
      ],
    ),
  );
}

class _TransferTile extends StatelessWidget {
  const _TransferTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.filled = false,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final fg = filled ? scheme.onPrimary : scheme.primary;
    return Pressable(
      onTap: onTap,
      scale: 0.96,
      child: Container(
        height: 104,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: filled
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [scheme.primary, Color.lerp(scheme.primary, const Color(0xFFE7B98F), 0.45)!],
                )
              : null,
          color: filled ? null : scheme.secondaryContainer.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 28, color: fg),
            const Spacer(),
            Text(
              title,
              style: tt.titleSmall?.copyWith(color: filled ? Colors.white : null, fontWeight: FontWeight.w700),
            ),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tt.labelSmall?.copyWith(
                color: filled ? Colors.white.withValues(alpha: 0.85) : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TranslatorPage extends StatefulWidget {
  const TranslatorPage({super.key});

  @override
  State<TranslatorPage> createState() => _TranslatorPageState();
}

class _TranslatorPageState extends State<TranslatorPage> {
  final _src = TextEditingController();
  String _out = '';
  bool _busy = false;
  CancelToken? _cancel;
  static const _langs = {
    'Simplified Chinese': '简体中文',
    'Traditional Chinese': '繁體中文',
    'English': 'English',
    'Japanese': '日本語',
    'Korean': '한국어',
    'French': 'Français',
    'German': 'Deutsch',
    'Spanish': 'Español',
    'Russian': 'Русский',
  };
  late String _target = _initialTarget();

  String _initialTarget() {
    final saved = context.read<SettingsStore>().value.translateTarget;
    if (_langs.containsKey(saved)) return saved;
    return I18n.isZh ? 'English' : 'Simplified Chinese';
  }

  @override
  void dispose() {
    _src.dispose();
    _cancel?.cancel();
    super.dispose();
  }

  Future<void> _go() async {
    if (_busy) {
      _cancel?.cancel();
      return;
    }
    final text = _src.text.trim();
    if (text.isEmpty) return;
    final s = context.read<SettingsStore>().value;
    setState(() {
      _busy = true;
      _out = '';
    });
    _cancel = CancelToken();
    try {
      final r = await AiHelpers.translate(
        s,
        text,
        _target,
        db: context.read<AppState>().db,
        cancel: _cancel,
        onDelta: (v) => mounted ? setState(() => _out = v) : null,
      );
      if (mounted) setState(() => _out = r);
    } catch (e) {
      if (mounted && !(_cancel?.isCancelled ?? false)) toast(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t('翻译', 'Translate'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          EntranceFx(
            child: TextField(
              controller: _src,
              minLines: 5,
              maxLines: 12,
              decoration: InputDecoration(
                hintText: t('输入或粘贴要翻译的内容', 'Type or paste text to translate'),
                suffixIcon: IconButton(icon: const Icon(Icons.clear_rounded), onPressed: _src.clear),
              ),
            ),
          ),
          const SizedBox(height: 12),
          EntranceFx(
            index: 1,
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _target,
                    decoration: InputDecoration(labelText: t('目标语言', 'Target language')),
                    items: [for (final e in _langs.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _target = v);
                      context.read<SettingsStore>().update((s) => s.copyWith(translateTarget: v));
                    },
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _go,
                  icon: Icon(_busy ? Icons.stop_rounded : Icons.translate_rounded),
                  label: Text(_busy ? t('停止', 'Stop') : t('翻译', 'Translate')),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            child: _out.isEmpty && !_busy
                ? const SizedBox(width: double.infinity)
                : Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLowest,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_out.isEmpty)
                          const Center(child: TypingDots())
                        else
                          MarkdownView(data: _out, selectable: true),
                        if (_out.isNotEmpty && !_busy)
                          Align(
                            alignment: Alignment.centerRight,
                            child: IconButton(
                              icon: const Icon(Icons.copy_rounded),
                              onPressed: () => copyText(context, _out),
                            ),
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class ImageGenPage extends StatefulWidget {
  const ImageGenPage({super.key});

  @override
  State<ImageGenPage> createState() => _ImageGenPageState();
}

class _ImageGenPageState extends State<ImageGenPage> {
  final _prompt = TextEditingController();
  final List<String> _images = [];
  bool _busy = false;

  static const _imageSizes = {'1024x1024', '1024x1536', '1536x1024'};

  String? _selectedModelId(AppSettings settings) =>
      settings.findModel(settings.lastImageGenModelId)?.model.id ?? settings.imageModelId;

  @override
  void dispose() {
    _prompt.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    final store = context.read<SettingsStore>();
    final s = store.value;
    final r = s.findModel(_selectedModelId(s));
    if (r == null) {
      toast(context, t('先选择一个绘图模型', 'Pick an image model first'), error: true);
      return;
    }
    if (_prompt.text.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final out = await providerFor(r.provider).generateImage(
        r.model,
        _prompt.text.trim(),
        size: _imageSizes.contains(s.lastImageGenSize) ? s.lastImageGenSize : '1024x1024',
      );
      final stored = <String>[];
      for (final u in out) {
        if (u.startsWith('data:')) {
          final bytes = await imageBytesFor(u);
          if (bytes != null) stored.add(await Attachments.storeBytes(bytes, 'png'));
        } else {
          stored.add(u);
        }
      }
      if (mounted) setState(() => _images.insertAll(0, stored));
    } catch (e) {
      if (mounted) toast(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsStore>().value;
    final model = s.findModel(_selectedModelId(s));
    final size = _imageSizes.contains(s.lastImageGenSize) ? s.lastImageGenSize : '1024x1024';
    return Scaffold(
      appBar: AppBar(title: Text(t('绘图', 'Images'))),
      body: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(16),
            sliver: SliverList.list(
              children: [
                EntranceFx(
                  child: TextField(
                    controller: _prompt,
                    minLines: 3,
                    maxLines: 8,
                    decoration: InputDecoration(hintText: t('描述你想要的画面…', 'Describe the image…')),
                  ),
                ),
                const SizedBox(height: 12),
                EntranceFx(
                  index: 1,
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const ValueKey('imagegen-model-picker'),
                          onPressed: () async {
                            final settingsStore = context.read<SettingsStore>();
                            final id = await pickModel(context, selected: model?.model.id, type: ModelType.image);
                            if (!mounted) return;
                            if (id == null || id.isEmpty) return;
                            settingsStore.update((s) => s.copyWith(lastImageGenModelId: id));
                          },
                          icon: const Icon(Icons.brush_outlined),
                          label: Text(
                            model?.model.displayName ?? t('选择模型', 'Pick model'),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      DropdownButton<String>(
                        value: size,
                        underline: const SizedBox.shrink(),
                        borderRadius: BorderRadius.circular(14),
                        items: const [
                          DropdownMenuItem(value: '1024x1024', child: Text('1:1')),
                          DropdownMenuItem(value: '1024x1536', child: Text('2:3')),
                          DropdownMenuItem(value: '1536x1024', child: Text('3:2')),
                        ],
                        onChanged: (v) {
                          if (v != null) context.read<SettingsStore>().update((s) => s.copyWith(lastImageGenSize: v));
                        },
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _busy ? null : _go,
                        child: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : Text(t('生成', 'Generate')),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_images.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.brush_outlined,
                title: t('还没有作品', 'Nothing yet'),
                subtitle: t('支持 OpenAI 图像接口、Imagen 与 Gemini 生图模型', 'OpenAI Images, Imagen and Gemini image models'),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 260,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                itemCount: _images.length,
                itemBuilder: (context, i) => EntranceFx(
                  index: i,
                  child: GestureDetector(
                    onTap: () => openImageViewer(context, _images[i]),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image(image: imageProviderFor(_images[i]), fit: BoxFit.cover),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

enum _SearchScope { currentAssistant, allAssistants }

class _SearchPageState extends State<SearchPage> {
  List<SearchHit> _hits = [];
  Timer? _debounce;
  String _q = '';
  final _query = TextEditingController();
  _SearchScope _scope = _SearchScope.currentAssistant;
  ConversationSearchSort _sort = ConversationSearchSort.relevance;
  bool _loading = false;
  int _searchGeneration = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    setState(() {
      _q = v;
      _hits = [];
      _loading = false;
    });
    _searchGeneration++;
    _debounce?.cancel();
    if (v.trim().isNotEmpty) _debounce = Timer(const Duration(milliseconds: 300), _search);
  }

  Future<void> _search() async {
    _debounce?.cancel();
    final query = _q.trim();
    if (query.isEmpty) {
      _searchGeneration++;
      if (mounted) setState(() => _hits = []);
      return;
    }
    final generation = ++_searchGeneration;
    final assistantId = _scope == _SearchScope.currentAssistant
        ? context.read<SettingsStore>().value.currentAssistantId
        : null;
    setState(() {
      _loading = true;
      _hits = [];
    });
    try {
      final hits = await context.read<AppState>().db.search(query, assistantId: assistantId, sort: _sort);
      if (mounted && generation == _searchGeneration) setState(() => _hits = hits);
    } catch (e) {
      if (mounted && generation == _searchGeneration) toast(context, '$e', error: true);
    } finally {
      if (mounted && generation == _searchGeneration) setState(() => _loading = false);
    }
  }

  void _changeScope(_SearchScope scope) {
    if (_scope == scope) return;
    setState(() => _scope = scope);
    _search();
  }

  void _changeSort(ConversationSearchSort sort) {
    if (_sort == sort) return;
    setState(() => _sort = sort);
    _search();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: Text(t('搜索消息', 'Search messages')),
            actions: [
              PopupMenuButton<ConversationSearchSort>(
                key: const ValueKey('message-search-sort'),
                tooltip: t('排序', 'Sort results'),
                initialValue: _sort,
                onSelected: _changeSort,
                icon: const Icon(Icons.sort_rounded),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: ConversationSearchSort.relevance,
                    child: _sortLabel(ConversationSearchSort.relevance, t('相关度', 'Relevance')),
                  ),
                  PopupMenuItem(
                    value: ConversationSearchSort.newest,
                    child: _sortLabel(ConversationSearchSort.newest, t('最新优先', 'Newest first')),
                  ),
                  PopupMenuItem(
                    value: ConversationSearchSort.oldest,
                    child: _sortLabel(ConversationSearchSort.oldest, t('最早优先', 'Oldest first')),
                  ),
                ],
              ),
              IconButton(
                key: const ValueKey('message-search-refresh'),
                tooltip: t('重新搜索', 'Search again'),
                onPressed: _search,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: TextField(
                key: const ValueKey('message-search-query'),
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: _onChanged,
                onSubmitted: (_) => _search(),
                decoration: InputDecoration(
                  hintText: t('搜索消息内容…', 'Search message content…'),
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _q.isEmpty
                      ? null
                      : IconButton(
                          tooltip: t('清除', 'Clear'),
                          onPressed: () {
                            _query.clear();
                            _onChanged('');
                          },
                          icon: const Icon(Icons.close_rounded),
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(40),
                    borderSide: BorderSide(color: scheme.primary, width: 1.5),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(40),
                    borderSide: BorderSide(color: scheme.outlineVariant),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(40),
                    borderSide: BorderSide(color: scheme.primary, width: 2),
                  ),
                ),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SegmentedButton<_SearchScope>(
                key: const ValueKey('message-search-scope'),
                showSelectedIcon: true,
                segments: [
                  ButtonSegment(value: _SearchScope.currentAssistant, label: Text(t('当前助手', 'Current assistant'))),
                  ButtonSegment(value: _SearchScope.allAssistants, label: Text(t('所有助手', 'All assistants'))),
                ],
                selected: {_scope},
                onSelectionChanged: (selection) => _changeScope(selection.first),
              ),
            ),
          ),
          if (_loading)
            SliverToBoxAdapter(
              child: LinearProgressIndicator(
                key: const ValueKey('message-search-loading'),
                minHeight: 2,
                color: scheme.primary,
              ),
            ),
          if (_q.trim().isEmpty || (!_loading && _hits.isEmpty))
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text(
                  _q.trim().isEmpty
                      ? t('输入关键词并搜索消息', 'Enter a keyword to search messages')
                      : t('没有找到匹配的消息', 'No matching messages found'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            )
          else if (_hits.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate((context, index) {
                  final hit = _hits[index];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: EntranceFx(
                      index: index,
                      child: Card(
                        color: scheme.surfaceContainerLow,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                          title: Text(
                            hit.title.isEmpty ? t('未命名对话', 'Untitled chat') : hit.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: _Highlighted(text: hit.snippet, query: _q, color: scheme.primary),
                          ),
                          trailing: Text(formatDateTime(hit.updatedAt), style: Theme.of(context).textTheme.labelSmall),
                          onTap: () async {
                            await context.read<AppState>().openConversation(hit.conversationId);
                            if (context.mounted) Navigator.of(context).popUntil((route) => route.isFirst);
                          },
                        ),
                      ),
                    ),
                  );
                }, childCount: _hits.length),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sortLabel(ConversationSearchSort sort, String label) => Row(
    children: [
      Expanded(child: Text(label)),
      if (_sort == sort) const Icon(Icons.check_rounded, size: 18),
    ],
  );
}

class _Highlighted extends StatelessWidget {
  const _Highlighted({required this.text, required this.query, required this.color});
  final String text;
  final String query;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return Text(text, maxLines: 3, overflow: TextOverflow.ellipsis);
    final spans = <TextSpan>[];
    final lower = text.toLowerCase();
    var start = 0;
    while (true) {
      final i = lower.indexOf(q, start);
      if (i < 0) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (i > start) spans.add(TextSpan(text: text.substring(start, i)));
      spans.add(
        TextSpan(
          text: text.substring(i, i + q.length),
          style: TextStyle(color: color, fontWeight: FontWeight.w700, backgroundColor: color.withValues(alpha: 0.12)),
        ),
      );
      start = i + q.length;
    }
    return Text.rich(TextSpan(children: spans), maxLines: 3, overflow: TextOverflow.ellipsis);
  }
}

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(t('关于', 'About'))),
      body: FutureBuilder<PackageInfo>(
        future: PackageInfo.fromPlatform(),
        builder: (context, snap) => ListView(
          children: [
            const SizedBox(height: 24),
            Center(
              child: EntranceFx(
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.5, end: 1),
                  duration: const Duration(milliseconds: 1000),
                  curve: Curves.elasticOut,
                  builder: (context, v, child) => Transform.scale(scale: v, child: child),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: Image.asset('assets/images/icon.png', width: 96, height: 96),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Center(
              child: Text(
                'MewHub',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            Center(
              child: Text(
                snap.hasData ? 'v${snap.data!.version} (${snap.data!.buildNumber})' : '',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
            ),
            SettingsGroup(
              index: 1,
              children: [
                ListTile(
                  leading: const IconBadge(Icons.code_rounded),
                  title: const Text('GitHub'),
                  subtitle: const Text('github.com/mizaawa/mewhub'),
                  onTap: () =>
                      launchUrl(Uri.parse('https://github.com/mizaawa/mewhub'), mode: LaunchMode.externalApplication),
                ),
                ListTile(
                  leading: const IconBadge(Icons.shield_outlined),
                  title: Text(t('隐私', 'Privacy')),
                  subtitle: Text(
                    t(
                      '所有数据只保存在本机；只会请求你配置的 API 地址。没有统计、没有广告。',
                      'All data stays on this device; requests go only to the APIs you configure. No analytics, no ads.',
                    ),
                  ),
                ),
                ListTile(
                  leading: const IconBadge(Icons.gavel_rounded),
                  title: Text(t('开源许可', 'Open-source licenses')),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: 'MewHub',
                    applicationVersion: snap.data?.version,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
