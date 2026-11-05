import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/provider_config.dart';
import '../../core/i18n.dart';
import '../../state/settings_store.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';

/// Bottom sheet listing all models of enabled providers.
/// Returns the internal model id, or null when cancelled.
Future<String?> pickModel(
  BuildContext context, {
  String? selected,
  ModelType type = ModelType.chat,
  bool allowNone = false,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.72,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (ctx, scroll) => _ModelPicker(scroll: scroll, selected: selected, type: type, allowNone: allowNone),
    ),
  );
}

class _ModelPicker extends StatefulWidget {
  const _ModelPicker({required this.scroll, this.selected, required this.type, required this.allowNone});
  final ScrollController scroll;
  final String? selected;
  final ModelType type;
  final bool allowNone;

  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final s = store.value;
    final words = _q.toLowerCase().split(' ').where((e) => e.isNotEmpty).toList();
    bool match(ModelConfig m) =>
        words.every((w) => m.modelId.toLowerCase().contains(w) || m.displayName.toLowerCase().contains(w));
    final all = s
        .allModels()
        .where(
          (e) => widget.type == ModelType.chat
              ? e.model.type == ModelType.chat
              : e.model.type == widget.type || e.model.imageOutput,
        )
        .where((e) => match(e.model))
        .toList();
    final favs = all.where((e) => s.favoriteModelIds.contains(e.model.id)).toList();
    final groups = <String, List<({ProviderConfig provider, ModelConfig model})>>{};
    for (final e in all) {
      groups.putIfAbsent(e.provider.id, () => []).add(e);
    }

    final items = <Widget>[];
    var i = 0;
    if (widget.allowNone) {
      items.add(
        ListTile(
          leading: const Icon(Icons.block_rounded),
          title: Text(t('跟随默认', 'Use default')),
          selected: widget.selected == null,
          onTap: () => Navigator.pop(context, ''),
        ),
      );
    }
    if (favs.isNotEmpty) {
      items.add(_header(context, t('收藏', 'Favorites'), Icons.star_rounded));
      for (final e in favs) {
        items.add(EntranceFx(index: i++, child: _tile(context, store, e.provider, e.model)));
      }
    }
    for (final g in groups.entries) {
      final p = g.value.first.provider;
      items.add(_header(context, p.name, Icons.hub_outlined));
      for (final e in g.value) {
        items.add(EntranceFx(index: i++, child: _tile(context, store, p, e.model)));
      }
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: TextField(
            autofocus: false,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded),
              hintText: t('搜索模型', 'Search models'),
            ),
            onChanged: (v) => setState(() => _q = v),
          ),
        ),
        Expanded(
          child: all.isEmpty && !widget.allowNone
              ? EmptyState(
                  icon: Icons.hub_outlined,
                  title: t('还没有可用的模型', 'No models yet'),
                  subtitle: t('在设置 → 供应商中启用供应商并添加模型', 'Enable a provider and add models in Settings → Providers'),
                )
              : ListView(controller: widget.scroll, padding: const EdgeInsets.only(bottom: 24), children: items),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, String label, IconData icon) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Row(
        children: [
          Icon(icon, size: 15, color: scheme.primary),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, SettingsStore store, ProviderConfig p, ModelConfig m) {
    final scheme = Theme.of(context).colorScheme;
    final fav = store.value.favoriteModelIds.contains(m.id);
    final selected = m.id == widget.selected;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ListTile(
        selected: selected,
        selectedTileColor: scheme.primary.withValues(alpha: 0.08),
        leading: AvatarView(value: '', fallback: m.modelId, size: 34),
        title: Text(m.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Wrap(
          spacing: 4,
          runSpacing: 2,
          children: [
            if (m.vision) _Cap(Icons.image_outlined, t('视觉', 'Vision')),
            if (m.tools) _Cap(Icons.build_outlined, t('工具', 'Tools')),
            if (m.reasoning) _Cap(Icons.psychology_alt_outlined, t('推理', 'Reasoning')),
            if (m.imageOutput) _Cap(Icons.brush_outlined, t('生图', 'Image')),
          ],
        ),
        trailing: IconButton(
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
            child: Icon(
              fav ? Icons.star_rounded : Icons.star_outline_rounded,
              key: ValueKey(fav),
              color: fav ? const Color(0xFFE6B450) : null,
            ),
          ),
          onPressed: () => store.update((s) {
            final list = [...s.favoriteModelIds];
            if (!list.remove(m.id)) list.add(m.id);
            return s.copyWith(favoriteModelIds: list);
          }),
        ),
        onTap: () => Navigator.pop(context, m.id),
      ),
    );
  }
}

class _Cap extends StatelessWidget {
  const _Cap(this.icon, this.label);
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: scheme.onSurfaceVariant),
          const SizedBox(width: 3),
          Text(label, style: TextStyle(fontSize: 10.5, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
