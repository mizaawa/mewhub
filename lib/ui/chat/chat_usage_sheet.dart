import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../ai/message.dart';
import '../../core/i18n.dart';
import '../../core/util.dart';
import '../../data/conversation.dart';
import '../theme.dart';
import '../widgets/motion.dart';

/// Token usage of the visible branch of one conversation.
class ChatUsageSummary {
  const ChatUsageSummary({required this.total, required this.replies, required this.models, required this.lastRequest});

  final TokenUsage total;

  /// Assistant replies that reported usage.
  final int replies;

  /// Per-model totals, largest first.
  final List<({String name, TokenUsage usage, int replies})> models;

  /// Usage of the newest reply. Its input approximates the current context size.
  final TokenUsage? lastRequest;

  double get cacheRate => total.input == 0 ? 0 : total.cached / total.input;

  factory ChatUsageSummary.of(Conversation c) {
    var total = const TokenUsage();
    var replies = 0;
    TokenUsage? last;
    final byModel = <String, ({String name, TokenUsage usage, int replies})>{};
    for (final m in c.currentMessages) {
      final u = m.usage;
      if (m.role != Role.assistant || u == null || u.isEmpty) continue;
      total = total + u;
      replies++;
      last = u;
      final key = m.modelId ?? m.modelName ?? '';
      final prev = byModel[key];
      byModel[key] = (
        name: (m.modelName?.isNotEmpty ?? false) ? m.modelName! : (prev?.name ?? t('未知模型', 'Unknown model')),
        usage: (prev?.usage ?? const TokenUsage()) + u,
        replies: (prev?.replies ?? 0) + 1,
      );
    }
    final models = byModel.values.toList()..sort((a, b) => b.usage.total.compareTo(a.usage.total));
    return ChatUsageSummary(total: total, replies: replies, models: models, lastRequest: last);
  }
}

Future<void> showChatUsageSheet(BuildContext context, Conversation conversation, {int? contextLength}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => ChatUsageSheet(summary: ChatUsageSummary.of(conversation), contextLength: contextLength),
    );

class ChatUsageSheet extends StatelessWidget {
  const ChatUsageSheet({super.key, required this.summary, this.contextLength});
  final ChatUsageSummary summary;
  final int? contextLength;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final s = summary;
    final u = s.total;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.data_usage_rounded, size: 20, color: scheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t('本对话用量', 'Chat usage'), style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      Text(
                        t('当前分支 · ${s.replies} 次回复', 'Visible branch · ${s.replies} replies'),
                        style: tt.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (u.isEmpty)
              _Empty(scheme: scheme, tt: tt)
            else ...[
              EntranceFx(child: _Hero(usage: u)),
              const SizedBox(height: 12),
              EntranceFx(index: 1, child: _Split(usage: u)),
              const SizedBox(height: 12),
              EntranceFx(
                index: 2,
                child: Row(
                  children: [
                    Expanded(
                      child: _Stat(
                        icon: Icons.bolt_rounded,
                        label: t('缓存命中', 'Cached'),
                        value: formatTokens(u.cached),
                        hint: '${(s.cacheRate * 100).toStringAsFixed(1)}%',
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _Stat(
                        icon: Icons.psychology_alt_outlined,
                        label: t('思考', 'Reasoning'),
                        value: u.reasoning > 0 ? formatTokens(u.reasoning) : '—',
                        hint: u.output == 0 || u.reasoning == 0
                            ? t('未上报', 'Not reported')
                            : t(
                                '占输出 ${(u.reasoning * 100 / u.output).toStringAsFixed(0)}%',
                                '${(u.reasoning * 100 / u.output).toStringAsFixed(0)}% of output',
                              ),
                      ),
                    ),
                  ],
                ),
              ),
              if (s.lastRequest != null && (contextLength ?? 0) > 0) ...[
                const SizedBox(height: 12),
                EntranceFx(
                  index: 3,
                  child: _ContextBar(used: s.lastRequest!.total, limit: contextLength!),
                ),
              ],
              if (s.models.length > 1) ...[
                const SizedBox(height: 18),
                Text(
                  t('按模型', 'By model'),
                  style: tt.labelLarge?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < s.models.length; i++)
                  EntranceFx(
                    index: 4 + i,
                    child: _ModelRow(item: s.models[i], share: s.models[i].usage.total / math.max(1, u.total)),
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _Surface extends StatelessWidget {
  const _Surface({required this.child, this.padding = const EdgeInsets.all(14)});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: child,
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.usage});
  final TokenUsage usage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary, Color.lerp(scheme.primary, MewThemeColors.of(context).accentGlow, 0.45)!],
        ),
        boxShadow: [
          BoxShadow(color: scheme.primary.withValues(alpha: 0.25), blurRadius: 18, offset: const Offset(0, 8)),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t('合计 Token', 'Total tokens'),
                  style: tt.labelMedium?.copyWith(color: Colors.white.withValues(alpha: 0.85)),
                ),
                const SizedBox(height: 2),
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0, end: usage.total.toDouble()),
                  duration: const Duration(milliseconds: 700),
                  curve: Curves.easeOutCubic,
                  builder: (context, v, _) => Text(
                    _grouped(v.round()),
                    key: const ValueKey('chat-usage-total'),
                    style: tt.headlineMedium?.copyWith(color: Colors.white, fontWeight: FontWeight.w800, height: 1.1),
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.auto_graph_rounded, size: 34, color: Colors.white.withValues(alpha: 0.55)),
        ],
      ),
    );
  }
}

/// Input / output proportion bar with both numbers.
class _Split extends StatelessWidget {
  const _Split({required this.usage});
  final TokenUsage usage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final output = Color.lerp(scheme.primary, MewThemeColors.of(context).accentPartner, 0.55)!;
    final inShare = usage.total == 0 ? 0.5 : usage.input / usage.total;
    Widget side(IconData icon, String label, int value, Color color, CrossAxisAlignment align) => Column(
      crossAxisAlignment: align,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(label, style: tt.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
        const SizedBox(height: 2),
        Text(_grouped(value), style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      ],
    );
    return _Surface(
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: side(
                  Icons.north_rounded,
                  t('输入', 'Input'),
                  usage.input,
                  scheme.primary,
                  CrossAxisAlignment.start,
                ),
              ),
              Expanded(
                child: side(Icons.south_rounded, t('输出', 'Output'), usage.output, output, CrossAxisAlignment.end),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.5, end: inShare),
            duration: const Duration(milliseconds: 650),
            curve: Curves.easeOutCubic,
            builder: (context, share, _) => ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                height: 10,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      flex: math.max(1, (share * 1000).round()),
                      child: ColoredBox(color: scheme.primary),
                    ),
                    const SizedBox(width: 2),
                    Expanded(
                      flex: math.max(1, ((1 - share) * 1000).round()),
                      child: ColoredBox(color: output),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text('${(inShare * 100).toStringAsFixed(0)}%', style: tt.labelSmall?.copyWith(color: scheme.primary)),
              const Spacer(),
              Text('${((1 - inShare) * 100).toStringAsFixed(0)}%', style: tt.labelSmall?.copyWith(color: output)),
            ],
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.label, required this.value, required this.hint});
  final IconData icon;
  final String label;
  final String value;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return _Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: scheme.primary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: tt.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(value, style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          Text(
            hint,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: tt.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// How full the model's context window was on the newest request.
class _ContextBar extends StatelessWidget {
  const _ContextBar({required this.used, required this.limit});
  final int used;
  final int limit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final ratio = (used / limit).clamp(0.0, 1.0);
    final color = ratio >= 0.9 ? scheme.error : (ratio >= 0.7 ? const Color(0xFFD9A441) : scheme.primary);
    return _Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.memory_rounded, size: 16, color: color),
              const SizedBox(width: 6),
              Expanded(child: Text(t('最近一次请求的上下文', 'Context on last request'), style: tt.labelMedium)),
              Text(
                '${formatTokens(used)} / ${formatTokens(limit)}',
                style: tt.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: ratio),
            duration: const Duration(milliseconds: 700),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => LinearProgressIndicator(
              value: v,
              minHeight: 8,
              borderRadius: BorderRadius.circular(6),
              color: color,
              backgroundColor: scheme.surfaceContainerHigh,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t('已用 ${(ratio * 100).toStringAsFixed(1)}%', '${(ratio * 100).toStringAsFixed(1)}% used'),
            style: tt.labelSmall?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({required this.item, required this.share});
  final ({String name, TokenUsage usage, int replies}) item;
  final double share;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: tt.bodyMedium),
              ),
              Text(
                '${formatTokens(item.usage.total)} · ${t('${item.replies} 次', '${item.replies}×')}',
                style: tt.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: share.clamp(0.0, 1.0),
            minHeight: 5,
            borderRadius: BorderRadius.circular(4),
            backgroundColor: scheme.surfaceContainerHigh,
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.scheme, required this.tt});
  final ColorScheme scheme;
  final TextTheme tt;

  @override
  Widget build(BuildContext context) => _Surface(
    padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
    child: Column(
      children: [
        Icon(Icons.hourglass_empty_rounded, size: 30, color: scheme.primary),
        const SizedBox(height: 8),
        Text(t('还没有用量记录', 'No usage yet'), style: tt.titleSmall),
        const SizedBox(height: 2),
        Text(
          t('模型返回 Token 用量后会显示在这里', 'Token counts appear here once the model reports them'),
          textAlign: TextAlign.center,
          style: tt.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    ),
  );
}

/// 1234567 -> 1,234,567
String _grouped(int n) {
  final s = n.abs().toString();
  final b = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}
