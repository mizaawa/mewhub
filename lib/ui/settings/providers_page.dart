import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../ai/provider_config.dart';
import '../../ai/share_codec.dart';
import '../../core/i18n.dart';
import '../../data/provider_branding.dart';
import '../../state/settings_store.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';
import '../widgets/provider_logo.dart';
import 'provider_detail_page.dart';
import 'qr_pages.dart';

enum _ProviderImportMethod { apiKey }

class ProvidersPage extends StatelessWidget {
  const ProvidersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final official = store.value.providers.where((p) => p.isZako).firstOrNull;
    final list = store.value.providers.where((p) => !p.isZako).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(t('供应商', 'Providers')),
        actions: [
          IconButton(
            tooltip: t('扫码导入', 'Scan QR'),
            icon: const Icon(Icons.qr_code_scanner_rounded),
            onPressed: () async {
              final code = await Navigator.of(context)
                  .push<String>(MaterialPageRoute(builder: (_) => const QrScanPage()));
              if (code != null && context.mounted) await importProviderCode(context, code);
            },
          ),
          IconButton(
            tooltip: t('从剪贴板导入', 'Import from clipboard'),
            icon: const Icon(Icons.content_paste_go_rounded),
            onPressed: () async {
              final d = await Clipboard.getData(Clipboard.kTextPlain);
              if (d?.text == null || !context.mounted) return;
              await importProviderCode(context, d!.text!);
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(context, store),
        icon: const Icon(Icons.add_rounded),
        label: Text(t('添加', 'Add')),
      ),
      body: ReorderableListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
        header: official == null
            ? null
            : Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _ProviderCard(p: official),
              ),
        itemCount: list.length,
        onReorderItem: (from, to) => store.update((s) {
          final l = s.providers.where((p) => !p.isZako).toList();
          final item = l.removeAt(from);
          l.insert(to, item);
          return s.copyWith(providers: [?official, ...l]);
        }),
        proxyDecorator: (child, i, anim) => Material(
          color: Colors.transparent,
          child: ScaleTransition(scale: Tween(begin: 1.0, end: 1.03).animate(anim), child: child),
        ),
        itemBuilder: (context, i) {
          final p = list[i];
          return Padding(
            key: ValueKey(p.id),
            padding: const EdgeInsets.only(bottom: 10),
            child: EntranceFx(
              index: i,
              child: _ProviderCard(p: p),
            ),
          );
        },
      ),
    );
  }

  Future<void> _add(BuildContext context, SettingsStore store) async {
    final method = await showModalBottomSheet<_ProviderImportMethod>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(t('选择导入方式', 'Choose import method'), style: Theme.of(ctx).textTheme.titleMedium),
            ),
            ListTile(
              leading: const IconBadge(Icons.key_rounded),
              title: Text(t('从 API KEY 导入', 'Import from API key')),
              subtitle: Text(t('填写 API Key 和接口地址', 'Enter an API key and base URL')),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => Navigator.pop(ctx, _ProviderImportMethod.apiKey),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (method == null || !context.mounted) return;
    final p = switch (method) {
      _ProviderImportMethod.apiKey => ProviderConfig(
        kind: ProviderKind.openai,
        name: t('自定义供应商', 'Custom provider'),
        baseUrl: ProviderKind.openai.defaultBaseUrl,
      ),
    };
    store.upsertProvider(p);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProviderDetailPage(providerId: p.id)));
  }
}

class _ProviderCard extends StatelessWidget {
  const _ProviderCard({required this.p});
  final ProviderConfig p;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final store = context.read<SettingsStore>();
    final hasKey = p.keys.isNotEmpty;
    return Pressable(
      scale: 0.98,
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProviderDetailPage(providerId: p.id))),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        decoration: BoxDecoration(
          color: p.enabled ? scheme.surfaceContainerLowest : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: p.enabled ? scheme.primary.withValues(alpha: 0.35) : scheme.outlineVariant),
        ),
        child: Row(
          children: [
            ProviderLogo(provider: p, size: 42),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          p.name,
                          style: Theme.of(context).textTheme.titleSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (p.isZako) ...[const SizedBox(width: 6), const OfficialProviderTag()],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      _Tag(p.protocolLabel),
                      _Tag(t('${p.models.length} 个模型', '${p.models.length} models')),
                      if (!hasKey) _Tag(t('未填 Key', 'No key'), warn: true),
                    ],
                  ),
                ],
              ),
            ),
            if (!p.isZako)
              Switch(
                value: p.enabled,
                onChanged: (v) => store.upsertProvider(p.copyWith(enabled: v)),
              ),
          ],
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.label, {this.warn = false});
  final String label;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = warn ? scheme.error : scheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(7)),
      child: Text(label, style: TextStyle(fontSize: 11, color: c)),
    );
  }
}

Future<void> importProviderCode(BuildContext context, String code) async {
  final store = context.read<SettingsStore>();
  try {
    final list = ProviderShareCodec.decode(code);
    if (list.isEmpty) throw const FormatException('empty');
    final ok = await confirm(
      context,
      t('导入 ${list.length} 个供应商？', 'Import ${list.length} provider(s)?'),
      message: list.map((e) => '• ${e.name} (${e.protocolLabel})\n  ${e.baseUrl}').join('\n'),
      ok: t('导入', 'Import'),
    );
    if (!ok) return;
    for (final p in list) {
      store.upsertProvider(p);
    }
    if (context.mounted) toast(context, t('导入成功', 'Imported'));
  } catch (e) {
    if (context.mounted) toast(context, t('无法识别的配置: $e', 'Unrecognised config: $e'), error: true);
  }
}
