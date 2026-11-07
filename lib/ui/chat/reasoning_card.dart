import 'dart:async';

import 'package:flutter/material.dart';

import '../../ai/message.dart';
import '../../core/i18n.dart';
import '../widgets/markdown_view.dart';
import '../widgets/motion.dart';

class ReasoningCard extends StatefulWidget {
  const ReasoningCard({
    super.key,
    required this.part,
    required this.streaming,
    this.autoCollapse = true,
    this.fontScale = 1,
  });
  final ReasoningPart part;
  final bool streaming;
  final bool autoCollapse;
  final double fontScale;

  @override
  State<ReasoningCard> createState() => _ReasoningCardState();
}

class _ReasoningCardState extends State<ReasoningCard> {
  late bool _expanded = !widget.part.finished;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    if (!widget.part.finished) _startTicker();
  }

  @override
  void didUpdateWidget(ReasoningCard old) {
    super.didUpdateWidget(old);
    if (!old.part.finished && widget.part.finished) {
      _ticker?.cancel();
      if (widget.autoCollapse) setState(() => _expanded = false);
    }
  }

  void _startTicker() {
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String get _duration {
    final start = widget.part.startedAt;
    if (start == null) return '';
    final end = widget.part.finishedAt ?? DateTime.now();
    final s = end.difference(start).inMilliseconds / 1000;
    return '${s.toStringAsFixed(1)}s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final thinking = !widget.part.finished;
    final text = widget.part.text.trim();
    if (text.isEmpty && !thinking) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        decoration: BoxDecoration(
          color: scheme.primary.withValues(alpha: thinking ? 0.07 : 0.045),
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 9, 10, 9),
                child: Row(
                  children: [
                    if (thinking)
                      SizedBox(width: 26, child: TypingDots(size: 5, color: scheme.primary))
                    else
                      Icon(Icons.psychology_alt_rounded, size: 18, color: scheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      thinking ? t('思考中', 'Thinking') : t('已深度思考', 'Thought'),
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(color: scheme.primary),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _duration,
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    const Spacer(),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 250),
                      child: Icon(Icons.expand_more_rounded, size: 20, color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: !_expanded || text.isEmpty
                  ? const SizedBox(width: double.infinity)
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                      child: DefaultTextStyle.merge(
                        style: TextStyle(color: scheme.onSurfaceVariant),
                        child: Opacity(
                          opacity: 0.85,
                          child: MarkdownView(data: text, latex: false, fontScale: widget.fontScale * 0.92),
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
