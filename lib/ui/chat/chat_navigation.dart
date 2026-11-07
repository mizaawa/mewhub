import 'package:flutter/material.dart';

import '../../core/i18n.dart';
import '../widgets/motion.dart';

/// Shares the old jump button's position above the composer.
class ChatNavigation extends StatefulWidget {
  const ChatNavigation({
    super.key,
    required this.visible,
    required this.onTop,
    required this.onPrevious,
    required this.onNext,
    required this.onBottom,
  });

  final bool visible;
  final VoidCallback onTop;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onBottom;

  @override
  State<ChatNavigation> createState() => _ChatNavigationState();
}

class _ChatNavigationState extends State<ChatNavigation> with SingleTickerProviderStateMixin {
  late final _visibility = AnimationController(
    vsync: this,
    // Half of the old 220 ms expansion, without resizing the button column.
    duration: const Duration(milliseconds: 110),
    reverseDuration: const Duration(milliseconds: 90),
  );

  void _syncVisibility() {
    if (MediaQuery.disableAnimationsOf(context)) {
      _visibility.value = widget.visible ? 1 : 0;
    } else if (widget.visible) {
      _visibility.forward();
    } else {
      _visibility.reverse();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncVisibility();
  }

  @override
  void didUpdateWidget(ChatNavigation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible != oldWidget.visible) _syncVisibility();
  }

  @override
  void dispose() {
    _visibility.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final buttons = [
      (t('到最顶部', 'First message'), Icons.keyboard_double_arrow_up_rounded, widget.onTop),
      (t('上一条我的消息', 'Previous user message'), Icons.keyboard_arrow_up_rounded, widget.onPrevious),
      (t('下一条我的消息', 'Next user message'), Icons.keyboard_arrow_down_rounded, widget.onNext),
      (t('到最底部', 'Latest message'), Icons.keyboard_double_arrow_down_rounded, widget.onBottom),
    ];
    return AnimatedBuilder(
      animation: _visibility,
      builder: (context, _) {
        if (_visibility.isDismissed && !widget.visible) return const SizedBox.shrink();
        return IgnorePointer(
          ignoring: !widget.visible,
          child: ExcludeSemantics(
            excluding: !widget.visible,
            child: Column(
              key: const ValueKey('chat-navigation'),
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < buttons.length; i++) ...[
                  if (i != 0) const SizedBox(height: 4),
                  _reveal(
                    i,
                    _JumpButton(
                      key: ValueKey(buttons[i].$2),
                      tooltip: buttons[i].$1,
                      icon: buttons[i].$2,
                      onPressed: buttons[i].$3,
                      scheme: scheme,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _reveal(int index, Widget child) {
    final progress = Interval(index * 0.07, 1, curve: Curves.easeOutCubic).transform(_visibility.value);
    return Opacity(
      opacity: progress,
      child: Transform.translate(
        offset: Offset(8 * (1 - progress), 0),
        child: Transform.scale(scale: 0.92 + 0.08 * progress, child: child),
      ),
    );
  }
}

class _JumpButton extends StatefulWidget {
  const _JumpButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    required this.scheme,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final ColorScheme scheme;

  @override
  State<_JumpButton> createState() => _JumpButtonState();
}

class _JumpButtonState extends State<_JumpButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final scheme = widget.scheme;
    final color = scheme.surfaceContainerHigh.withValues(alpha: 0.94);
    final foreground = scheme.onSurfaceVariant.withValues(alpha: enabled ? 0.9 : 0.28);
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.tooltip,
      child: Tooltip(
        message: widget.tooltip,
        child: SizedBox(
          width: 48,
          height: 48,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: widget.onPressed,
              borderRadius: BorderRadius.circular(12),
              onHighlightChanged: (pressed) => setState(() => _pressed = pressed),
              child: Center(
                child: AnimatedScale(
                  scale: _pressed && enabled ? 0.9 : 1,
                  duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 80),
                  curve: Curves.easeOutCubic,
                  child: Container(
                    key: ValueKey('jump-tile-${widget.icon.codePoint}'),
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: [
                        BoxShadow(
                          color: scheme.shadow.withValues(alpha: 0.1),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: Icon(widget.icon, size: 16, color: foreground),
                  ),
                ),
              ),
            ),
          ),
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
