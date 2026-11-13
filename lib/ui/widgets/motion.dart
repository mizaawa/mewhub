import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// Shrinks slightly while pressed, springs back on release.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.96,
    this.haptic = true,
  });
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  final bool haptic;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 110),
    reverseDuration: const Duration(milliseconds: 260),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _c.forward() : null,
      onTapUp: enabled ? (_) => _c.reverse() : null,
      onTapCancel: enabled ? () => _c.reverse() : null,
      onTap: widget.onTap == null
          ? null
          : () {
              if (widget.haptic) HapticFeedback.selectionClick();
              widget.onTap!();
            },
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              HapticFeedback.mediumImpact();
              widget.onLongPress!();
            },
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) =>
            Transform.scale(scale: 1 - (1 - widget.scale) * Curves.easeOut.transform(_c.value), child: child),
        child: widget.child,
      ),
    );
  }
}

/// Fades + slides children in, staggered by [index].
class EntranceFx extends StatelessWidget {
  const EntranceFx({super.key, required this.child, this.index = 0, this.dy = 14, this.baseDelayMs = 0});
  final Widget child;
  final int index;
  final double dy;
  final int baseDelayMs;

  @override
  Widget build(BuildContext context) {
    final delay = baseDelayMs + (index.clamp(0, 12) * 40);
    return TweenAnimationBuilder<double>(
      key: ValueKey('entrance-$index'),
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 420 + delay),
      curve: Interval(delay / (420 + delay), 1, curve: Curves.easeOutCubic),
      builder: (context, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, (1 - v) * dy), child: child),
      ),
      child: child,
    );
  }
}

/// Slow drifting blobs of warm color behind content.
class AmbientBackground extends StatefulWidget {
  const AmbientBackground({super.key, required this.child, this.intensity = 1.0});
  final Widget child;
  final double intensity;

  @override
  State<AmbientBackground> createState() => _AmbientBackgroundState();
}

class _AmbientBackgroundState extends State<AmbientBackground> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 28))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mew = MewThemeColors.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final reduce = MediaQuery.of(context).disableAnimations;
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: scheme.surface),
        if (!reduce)
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) => CustomPaint(
                painter: _BlobPainter(
                  t: _c.value,
                  colors: [
                    scheme.primary.withValues(alpha: (dark ? 0.10 : 0.13) * widget.intensity),
                    mew.ambientWarm.withValues(alpha: (dark ? 0.05 : 0.22) * widget.intensity),
                    mew.ambientCool.withValues(alpha: (dark ? 0.05 : 0.20) * widget.intensity),
                  ],
                ),
              ),
            ),
          ),
        widget.child,
      ],
    );
  }
}

class _BlobPainter extends CustomPainter {
  _BlobPainter({required this.t, required this.colors});
  final double t;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    final a = t * 2 * math.pi;
    final centers = [
      Offset(size.width * (0.2 + 0.12 * math.sin(a)), size.height * (0.15 + 0.06 * math.cos(a * 0.8))),
      Offset(size.width * (0.85 + 0.08 * math.cos(a * 1.1)), size.height * (0.35 + 0.08 * math.sin(a * 0.9))),
      Offset(size.width * (0.4 + 0.15 * math.cos(a * 0.7)), size.height * (0.85 + 0.05 * math.sin(a * 1.3))),
    ];
    final radius = size.shortestSide * 0.75;
    for (var i = 0; i < centers.length; i++) {
      final paint = Paint()
        ..shader = RadialGradient(colors: [colors[i], colors[i].withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: centers[i], radius: radius));
      canvas.drawCircle(centers[i], radius, paint);
    }
  }

  @override
  bool shouldRepaint(_BlobPainter old) => old.t != t || !listEquals(old.colors, colors);
}

/// Three softly bouncing dots shown while the model is thinking.
class TypingDots extends StatefulWidget {
  const TypingDots({super.key, this.color, this.size = 7});
  final Color? color;
  final double size;

  @override
  State<TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<TypingDots> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          final phase = (_c.value - i * 0.16) % 1.0;
          final v = math.sin(phase * math.pi).clamp(0.0, 1.0);
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: widget.size * 0.28),
            child: Transform.translate(
              offset: Offset(0, -v * widget.size * 0.7),
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.35 + 0.65 * v),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}
