import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../ai/factory.dart';
import '../../ai/message.dart';
import '../../ai/model_registry.dart';
import '../../ai/provider.dart';
import '../../ai/provider_config.dart';
import '../../ai/share_codec.dart';
import '../../core/i18n.dart';
import '../../core/net.dart';
import '../../core/util.dart';
import '../../state/settings_store.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';
import 'model_edit_sheet.dart';

class ProviderDetailPage extends StatefulWidget {
  const ProviderDetailPage({super.key, required this.providerId});
  final String providerId;

  @override
  State<ProviderDetailPage> createState() => _ProviderDetailPageState();
}

class _ProviderDetailPageState extends State<ProviderDetailPage> {
  late final SettingsStore _store = context.read<SettingsStore>();
  late ProviderConfig _p = _store.value.providers.firstWhere((e) => e.id == widget.providerId);
  late final _name = TextEditingController(text: _p.name);
  late final _url = TextEditingController(text: _p.baseUrl);
  late final _key = TextEditingController(text: _p.apiKey);
  late final _chatPath = TextEditingController(text: _p.chatPath);
  late final _respPath = TextEditingController(text: _p.responsesPath);
  late final _balUrl = TextEditingController(text: _p.balanceUrl);
  late final _balPath = TextEditingController(text: _p.balancePath);
  bool _obscure = true;
  bool _fetching = false;
  String? _balance;

  @override
  void dispose() {
    for (final c in [_name, _url, _key, _chatPath, _respPath, _balUrl, _balPath]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save(ProviderConfig p) {
    setState(() => _p = p);
    _store.upsertProvider(p);
  }

  void _saveFields() => _save(
    _p.copyWith(
      name: _name.text.trim().isEmpty ? _p.name : _name.text.trim(),
      baseUrl: _url.text.trim(),
      apiKey: _key.text.trim(),
      chatPath: _chatPath.text.trim().isEmpty ? '/chat/completions' : _chatPath.text.trim(),
      responsesPath: _respPath.text.trim().isEmpty ? '/responses' : _respPath.text.trim(),
      balanceUrl: _balUrl.text.trim(),
      balancePath: _balPath.text.trim(),
    ),
  );

  Future<void> _fetchModels() async {
    _saveFields();
    setState(() => _fetching = true);
    try {
      final remote = await providerFor(_p).listModels();
      if (!mounted) return;
      final picked = await showModalBottomSheet<List<RemoteModel>>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (ctx) => _RemoteModelSheet(remote: remote, existing: _p.models.map((m) => m.modelId).toSet()),
      );
      if (picked == null || picked.isEmpty) return;
      final existing = _p.models.map((m) => m.modelId).toSet();
      final add = [
        for (final r in picked)
          if (!existing.contains(r.id)) ModelRegistry.guess(r.id, displayName: r.name),
      ];
      _save(_p.copyWith(models: [..._p.models, ...add]));
      if (mounted) toast(context, t('已添加 ${add.length} 个模型', 'Added ${add.length} models'));
    } catch (e) {
      if (mounted) toast(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<void> _test() async {
    _saveFields();
    final chat = _p.models.where((m) => m.type == ModelType.chat).toList();
    if (chat.isEmpty) {
      toast(context, t('先添加一个对话模型', 'Add a chat model first'), error: true);
      return;
    }
    final model = chat.length == 1
        ? chat.first
        : await showModalBottomSheet<ModelConfig>(
            context: context,
            builder: (ctx) => ListView(
              shrinkWrap: true,
              children: [
                for (final m in chat) ListTile(title: Text(m.displayName), onTap: () => Navigator.pop(ctx, m)),
              ],
            ),
          );
    if (model == null || !mounted) return;
    final sw = Stopwatch()..start();
    toast(context, t('测试中…', 'Testing…'));
    try {
      final buf = StringBuffer();
      await for (final c in providerFor(_p).stream([
        ChatMessage.text(Role.user, 'Reply with the single word: pong'),
      ], GenerationParams(model: model, maxTokens: 64, reasoning: ReasoningLevel.off))) {
        if (c is TextDelta) buf.write(c.text);
      }
      if (!mounted) return;
      toast(
        context,
        t(
          '连接成功 ${sw.elapsedMilliseconds}ms：${truncate(buf.toString().trim(), 40)}',
          'OK in ${sw.elapsedMilliseconds}ms: ${truncate(buf.toString().trim(), 40)}',
        ),
      );
    } catch (e) {
      if (mounted) toast(context, t('连接失败：$e', 'Failed: $e'), error: true);
    }
  }

  Future<void> _queryBalance() async {
    _saveFields();
    if (_p.balanceUrl.isEmpty) return;
    try {
      final url = _p.balanceUrl.replaceAll('{{baseUrl}}', _p.trimmedBaseUrl);
      final j = await Net.json(
        'GET',
        Uri.parse(url),
        headers: {'Authorization': 'Bearer ${_p.keys.firstOrNull ?? ''}', 'x-api-key': _p.keys.firstOrNull ?? ''},
      );
      dynamic cur = j;
      for (final seg in _p.balancePath.split('.').where((e) => e.isNotEmpty)) {
        final i = int.tryParse(seg);
        cur = i != null && cur is List ? (i < cur.length ? cur[i] : null) : (cur is Map ? cur[seg] : null);
      }
      setState(() => _balance = cur?.toString() ?? jsonEncode(j));
    } catch (e) {
      if (mounted) toast(context, '$e', error: true);
    }
  }

  void _share() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _ShareSheet(provider: _p),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isOpenAi = _p.kind == ProviderKind.openai;
    return PopScope(
      onPopInvokedWithResult: (didPop, _) => _saveFields(),
      child: Scaffold(
        appBar: AppBar(
          title: Text(_p.name),
          actions: [
            IconButton(tooltip: t('分享', 'Share'), icon: const Icon(Icons.qr_code_2_rounded), onPressed: _share),
            IconButton(
              tooltip: t('删除', 'Delete'),
              icon: Icon(Icons.delete_outline_rounded, color: scheme.error),
              onPressed: () async {
                if (await confirm(context, t('删除「${_p.name}」？', 'Delete "${_p.name}"?'), destructive: true)) {
                  _store.removeProvider(_p.id);
                  if (context.mounted) Navigator.pop(context);
                }
              },
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 40),
          children: [
            SettingsGroup(
              title: t('基本', 'Basics'),
              children: [
                SwitchListTile(
                  secondary: const IconBadge(Icons.power_settings_new_rounded),
                  title: Text(t('启用', 'Enabled')),
                  value: _p.enabled,
                  onChanged: (v) => _save(_p.copyWith(enabled: v)),
                ),
                _Field(controller: _name, label: t('名称', 'Name'), onDone: _saveFields),
                _Field(controller: _url, label: 'Base URL', hint: 'https://api.example.com/v1', onDone: _saveFields),
                _Field(
                  controller: _key,
                  label: 'API Key',
                  hint: t('多个 Key 用逗号或换行分隔，自动轮询', 'Separate multiple keys with commas; rotated per request'),
                  obscure: _obscure,
                  onDone: _saveFields,
                  suffix: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ],
            ),
            SettingsGroup(
              index: 1,
              title: t('协议', 'Protocol'),
              children: [
                ListTile(
                  leading: const IconBadge(Icons.swap_horiz_rounded),
                  title: Text(t('接口类型', 'API type')),
                  trailing: DropdownButton<String>(
                    value: _p.kind == ProviderKind.openai ? (_p.useResponsesApi ? 'responses' : 'chat') : _p.kind.name,
                    underline: const SizedBox.shrink(),
                    borderRadius: BorderRadius.circular(14),
                    items: const [
                      DropdownMenuItem(value: 'chat', child: Text('OpenAI Chat')),
                      DropdownMenuItem(value: 'responses', child: Text('OpenAI Responses')),
                      DropdownMenuItem(value: 'anthropic', child: Text('Anthropic')),
                      DropdownMenuItem(value: 'google', child: Text('Gemini')),
                    ],
                    onChanged: (v) => _save(switch (v) {
                      'responses' => _p.copyWith(kind: ProviderKind.openai, useResponsesApi: true),
                      'anthropic' => _p.copyWith(kind: ProviderKind.anthropic),
                      'google' => _p.copyWith(kind: ProviderKind.google),
                      _ => _p.copyWith(kind: ProviderKind.openai, useResponsesApi: false),
                    }),
                  ),
                ),
                if (isOpenAi && !_p.useResponsesApi)
                  _Field(controller: _chatPath, label: t('对话路径', 'Chat path'), onDone: _saveFields),
                if (isOpenAi && _p.useResponsesApi)
                  _Field(controller: _respPath, label: t('Responses 路径', 'Responses path'), onDone: _saveFields),
                if (isOpenAi)
                  SwitchListTile(
                    secondary: const IconBadge(Icons.history_toggle_off_rounded),
                    title: Text(t('回传历史推理内容', 'Send back reasoning history')),
                    subtitle: Text(t('DeepSeek / Kimi 工具调用需要开启', 'Needed for tool calls on some reasoning models')),
                    value: _p.includeHistoryReasoning,
                    onChanged: (v) => _save(_p.copyWith(includeHistoryReasoning: v)),
                  ),
                if (_p.kind == ProviderKind.anthropic)
                  SwitchListTile(
                    secondary: const IconBadge(Icons.savings_outlined),
                    title: Text(t('提示词缓存', 'Prompt caching')),
                    subtitle: Text(t('长对话可大幅降低费用', 'Cuts cost on long chats')),
                    value: _p.promptCaching,
                    onChanged: (v) => _save(_p.copyWith(promptCaching: v)),
                  ),
              ],
            ),
            _modelsSection(context),
            SettingsGroup(
              index: 3,
              title: t('工具', 'Tools'),
              children: [
                ListTile(
                  leading: const IconBadge(Icons.network_check_rounded),
                  title: Text(t('测试连接', 'Test connection')),
                  onTap: _test,
                ),
                _Field(
                  controller: _balUrl,
                  label: t('余额查询 URL', 'Balance URL'),
                  hint: '{{baseUrl}}/user/balance',
                  onDone: _saveFields,
                ),
                _Field(
                  controller: _balPath,
                  label: t('余额 JSON 路径', 'Balance JSON path'),
                  hint: 'data.total_balance',
                  onDone: _saveFields,
                ),
                ListTile(
                  leading: const IconBadge(Icons.account_balance_wallet_outlined),
                  title: Text(t('查询余额', 'Query balance')),
                  subtitle: _balance == null ? null : Text(_balance!),
                  enabled: _p.balanceUrl.isNotEmpty || _balUrl.text.isNotEmpty,
                  onTap: _queryBalance,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _modelsSection(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final models = _p.models;
    return EntranceFx(
      index: 2,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 0, 4),
              child: Row(
                children: [
                  Text(
                    t('模型', 'Models'),
                    style: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${models.length}',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _fetching ? null : _fetchModels,
                    icon: _fetching
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.cloud_download_outlined, size: 18),
                    label: Text(t('获取', 'Fetch')),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      final m = await editModel(context, null);
                      if (m != null) _save(_p.copyWith(models: [..._p.models, m]));
                    },
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: Text(t('添加', 'Add')),
                  ),
                ],
              ),
            ),
            Card(
              clipBehavior: Clip.antiAlias,
              child: models.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: Text(
                          t('点「获取」从接口拉取模型列表', 'Tap "Fetch" to load models from the API'),
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    )
                  : Column(
                      children: [
                        for (var i = 0; i < models.length; i++) ...[
                          if (i > 0) const Divider(indent: 64, height: 1),
                          _modelTile(context, models[i]),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _modelTile(BuildContext context, ModelConfig m) {
    final scheme = Theme.of(context).colorScheme;
    final caps = [
      if (m.vision) Icons.image_outlined,
      if (m.tools) Icons.build_outlined,
      if (m.reasoning) Icons.psychology_alt_outlined,
      if (m.imageOutput) Icons.brush_outlined,
    ];
    return Dismissible(
      key: ValueKey('m-${m.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: scheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: Icon(Icons.delete_outline_rounded, color: scheme.onErrorContainer),
      ),
      onDismissed: (_) => _save(_p.copyWith(models: _p.models.where((e) => e.id != m.id).toList())),
      child: ListTile(
        leading: AvatarView(value: '', fallback: m.modelId, size: 34),
        title: Text(m.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(m.modelId, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final c in caps)
              Padding(
                padding: const EdgeInsets.only(left: 3),
                child: Icon(c, size: 15, color: scheme.primary),
              ),
          ],
        ),
        onTap: () async {
          final edited = await editModel(context, m);
          if (edited != null) {
            _save(_p.copyWith(models: [for (final e in _p.models) e.id == m.id ? edited : e]));
          }
        },
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    this.hint,
    this.obscure = false,
    this.suffix,
    required this.onDone,
  });
  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool obscure;
  final Widget? suffix;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
    child: Focus(
      onFocusChange: (f) {
        if (!f) onDone();
      },
      child: TextField(
        controller: controller,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: !obscure,
        maxLines: 1,
        decoration: InputDecoration(labelText: label, hintText: hint, suffixIcon: suffix),
        onSubmitted: (_) => onDone(),
      ),
    ),
  );
}

class _RemoteModelSheet extends StatefulWidget {
  const _RemoteModelSheet({required this.remote, required this.existing});
  final List<RemoteModel> remote;
  final Set<String> existing;

  @override
  State<_RemoteModelSheet> createState() => _RemoteModelSheetState();
}

class _RemoteModelSheetState extends State<_RemoteModelSheet> {
  final Set<String> _sel = {};
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final list = widget.remote.where((r) => _q.isEmpty || r.id.toLowerCase().contains(_q.toLowerCase())).toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.8,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search_rounded),
                      hintText: t('筛选', 'Filter'),
                    ),
                    onChanged: (v) => setState(() => _q = v),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () => setState(() {
                    final ids = list.map((e) => e.id).where((e) => !widget.existing.contains(e));
                    if (ids.every(_sel.contains)) {
                      _sel.removeAll(ids);
                    } else {
                      _sel.addAll(ids);
                    }
                  }),
                  child: Text(t('全选', 'All')),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: list.length,
              itemBuilder: (context, i) {
                final r = list[i];
                final have = widget.existing.contains(r.id);
                return CheckboxListTile(
                  value: have || _sel.contains(r.id),
                  onChanged: have ? null : (v) => setState(() => v == true ? _sel.add(r.id) : _sel.remove(r.id)),
                  title: Text(r.name ?? r.id, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: r.name != null && r.name != r.id
                      ? Text(r.id, maxLines: 1, overflow: TextOverflow.ellipsis)
                      : null,
                  secondary: AvatarView(value: '', fallback: r.id, size: 32),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _sel.isEmpty
                      ? null
                      : () => Navigator.pop(context, widget.remote.where((r) => _sel.contains(r.id)).toList()),
                  child: Text(t('添加 ${_sel.length} 个', 'Add ${_sel.length}')),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({required this.provider});
  final ProviderConfig provider;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  bool _withKey = false;

  @override
  Widget build(BuildContext context) {
    final code = ProviderShareCodec.encode(widget.provider, includeKey: _withKey);
    final tooBig = code.length > 2800;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t('分享供应商配置', 'Share provider'), style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: tooBig
                  ? SizedBox(
                      key: const ValueKey('big'),
                      height: 120,
                      child: Center(
                        child: Text(t('配置太大，无法生成二维码，请复制文本', 'Too large for a QR code, copy the text instead')),
                      ),
                    )
                  : Container(
                      key: ValueKey(_withKey),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
                      child: QrImageView(data: code, size: 240, backgroundColor: Colors.white),
                    ),
            ),
            SwitchListTile(
              title: Text(t('包含 API Key', 'Include API key')),
              subtitle: Text(t('只分享给信任的人', 'Only share with people you trust')),
              value: _withKey,
              onChanged: (v) => setState(() => _withKey = v),
            ),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => copyText(context, code),
                    icon: const Icon(Icons.copy_rounded),
                    label: Text(t('复制', 'Copy')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => SharePlus.instance.share(ShareParams(text: code)),
                    icon: const Icon(Icons.ios_share_rounded),
                    label: Text(t('分享', 'Share')),
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
