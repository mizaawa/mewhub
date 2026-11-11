import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ai/message.dart';
import '../../core/i18n.dart';
import '../../core/util.dart';
import '../widgets/code_block.dart';
import '../widgets/motion.dart';

String toolLabel(String name) {
  if (name.startsWith('mcp__')) {
    final parts = name.split('__');
    return parts.length >= 3 ? '${parts[1]} · ${parts.sublist(2).join('__')}' : name;
  }
  return switch (name) {
    'search_web' => t('联网搜索', 'Web search'),
    'scrape_web' => t('读取网页', 'Read page'),
    'get_time_info' => t('获取时间', 'Get time'),
    'clipboard' => t('剪贴板', 'Clipboard'),
    'get_device_info' => t('设备信息', 'Device info'),
    'calculate' => t('计算器', 'Calculator'),
    'memory_save' => t('记住', 'Remember'),
    'memory_update' => t('更新记忆', 'Update memory'),
    'memory_delete' => t('删除记忆', 'Forget'),
    'web_search' => t('内置搜索', 'Built-in search'),
    _ => name,
  };
}

IconData toolIcon(String name) {
  if (name.startsWith('mcp__')) return Icons.extension_rounded;
  return switch (name) {
    'search_web' || 'web_search' || 'web_search_result' => Icons.travel_explore_rounded,
    'scrape_web' => Icons.article_outlined,
    'get_time_info' => Icons.schedule_rounded,
    'clipboard' => Icons.content_paste_rounded,
    'get_device_info' => Icons.smartphone_rounded,
    'calculate' => Icons.calculate_outlined,
    'memory_save' || 'memory_update' || 'memory_delete' => Icons.bookmark_added_outlined,
    _ => Icons.build_circle_outlined,
  };
}

String _pretty(String s) {
  final j = tryJsonDecode(s);
  return j == null ? s : const JsonEncoder.withIndent('  ').convert(j);
}

class ToolCard extends StatefulWidget {
  const ToolCard({super.key, required this.part, this.onApprove, this.onDeny});
  final ToolPart part;
  final VoidCallback? onApprove;
  final VoidCallback? onDeny;

  @override
  State<ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<ToolCard> {
  bool _open = false;

  String _summary() {
    final input = widget.part.inputJson;
    final v = input['query'] ?? input['url'] ?? input['expression'] ?? input['content'] ?? input['action'];
    return v == null ? '' : truncate(v.toString(), 60);
  }

  Widget _leading(ColorScheme scheme, bool running) {
    final p = widget.part;
    if (running) {
      return SizedBox(
        key: const ValueKey('spin'),
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary),
      );
    }
    return Icon(
      p.isError ? Icons.error_outline_rounded : toolIcon(p.name),
      key: const ValueKey('icon'),
      size: 18,
      color: p.isError ? scheme.error : scheme.primary,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = widget.part;
    final running = !p.executed && p.approval != ToolApproval.pending;
    final summary = _summary();
    final title = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: toolLabel(p.name),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (summary.isNotEmpty)
            TextSpan(
              text: '  $summary',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.bodyMedium,
    );
    final header = InkWell(
      onTap: () => setState(() => _open = !_open),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Row(
          children: [
            AnimatedSwitcher(duration: const Duration(milliseconds: 250), child: _leading(scheme, running)),
            const SizedBox(width: 10),
            Flexible(child: title),
            const SizedBox(width: 6),
            AnimatedRotation(
              turns: _open ? 0.5 : 0,
              duration: const Duration(milliseconds: 250),
              child: Icon(Icons.expand_more_rounded, size: 20, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
    final details = Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CodeBlock(code: _pretty(p.input), language: 'json', wrap: true),
          if (p.output != null) CodeBlock(code: _pretty(p.output!), language: 'json', wrap: true),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: running ? 0.08 : 0.05),
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.antiAlias,
        // Ink is painted on the nearest Material. Without one inside the
        // clip it landed on the page below the card and showed up as a grey
        // rectangle around the rounded corners.
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              if (p.pending) _approvalBar(context),
              AnimatedSize(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: _open ? details : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _approvalBar(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return EntranceFx(
      dy: 6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 10, 10),
        child: Row(
          children: [
            Icon(Icons.shield_outlined, size: 16, color: scheme.primary),
            const SizedBox(width: 6),
            Expanded(child: Text(t('允许运行这个工具吗？', 'Allow this tool to run?'), style: style)),
            TextButton(onPressed: widget.onDeny, child: Text(t('拒绝', 'Deny'))),
            const SizedBox(width: 4),
            FilledButton.tonal(onPressed: widget.onApprove, child: Text(t('允许', 'Allow'))),
          ],
        ),
      ),
    );
  }
}

class CitationChips extends StatelessWidget {
  const CitationChips({super.key, required this.items});
  final List<Citation> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (var i = 0; i < items.length && i < 12; i++)
            EntranceFx(
              index: i,
              dy: 6,
              child: _CitationChip(index: i, item: items[i]),
            ),
        ],
      ),
    );
  }
}

class _CitationChip extends StatelessWidget {
  const _CitationChip({required this.index, required this.item});
  final int index;
  final Citation item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = item.title.isEmpty ? (Uri.tryParse(item.url)?.host ?? item.url) : item.title;
    return Pressable(
      onTap: () => launchUrl(Uri.parse(item.url), mode: LaunchMode.externalApplication),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 220),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(10)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 18,
              height: 18,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: scheme.primary.withValues(alpha: 0.15), shape: BoxShape.circle),
              child: Text(
                '${index + 1}',
                style: TextStyle(fontSize: 10, color: scheme.primary, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
