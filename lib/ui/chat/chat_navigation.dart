import 'package:flutter/material.dart';

import '../../core/i18n.dart';
import '../widgets/motion.dart';

/// Shares the old jump button's position above the composer.
class ChatNavigation extends StatelessWidget {
  const ChatNavigation({
    super.key,
    required this.expanded,
    required this.onExpand,
    required this.onTop,
    required this.onPrevious,
    required this.onNext,
    required this.onBottom,
  });

  final bool expanded;
  final VoidCallback onExpand;
  final VoidCallback onTop;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onBottom;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh.withValues(alpha: 0.94),
      elevation: 2,
      shadowColor: scheme.shadow.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: AnimatedSize(
        duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        alignment: Alignment.bottomCenter,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: expanded
              ? [
                  IconButton(
                    tooltip: t('到最顶部', 'First message'),
                    onPressed: onTop,
                    icon: const Icon(Icons.keyboard_double_arrow_up_rounded),
                  ),
                  IconButton(
                    tooltip: t('上一条我的消息', 'Previous user message'),
                    onPressed: onPrevious,
                    icon: const Icon(Icons.keyboard_arrow_up_rounded),
                  ),
                  IconButton(
                    tooltip: t('下一条我的消息', 'Next user message'),
                    onPressed: onNext,
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  ),
                  IconButton(
                    tooltip: t('到最底部', 'Latest message'),
                    onPressed: onBottom,
                    icon: const Icon(Icons.keyboard_double_arrow_down_rounded),
                  ),
                ]
              : [
                  IconButton(
                    tooltip: t('展开消息导航', 'Expand message navigation'),
                    onPressed: onExpand,
                    icon: const Icon(Icons.unfold_more_rounded),
                  ),
                ],
        ),
      ),
    );
  }
}

class StreamingBelow extends StatelessWidget {
  const StreamingBelow({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = t('下方正在生成，点击查看', 'Generating below. Tap to follow');
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: label,
      button: true,
      child: Tooltip(
        message: label,
        child: Material(
          color: scheme.surfaceContainerHigh.withValues(alpha: 0.94),
          elevation: 2,
          borderRadius: BorderRadius.circular(24),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
              child: ExcludeSemantics(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (MediaQuery.disableAnimationsOf(context))
                      Icon(Icons.more_horiz_rounded, size: 22, color: scheme.primary)
                    else
                      TypingDots(size: 5, color: scheme.primary),
                    const SizedBox(width: 6),
                    Icon(Icons.arrow_downward_rounded, size: 15, color: scheme.primary),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
