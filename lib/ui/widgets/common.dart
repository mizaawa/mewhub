import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ai/model_registry.dart';
import '../../core/i18n.dart';
import '../../core/paths.dart';
import 'motion.dart';

OverlayEntry? _toastEntry;

/// Brief notice shown as a pill under the status bar, clear of the composer
/// and its buttons. Only one is visible at a time; it has its own close button
/// and lets touches through everywhere else.
void toast(BuildContext context, String msg, {bool error = false}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;
  _toastEntry?.remove();
  late final OverlayEntry entry;
  void close() {
    if (identical(_toastEntry, entry)) _toastEntry = null;
    if (entry.mounted) entry.remove();
  }

  entry = OverlayEntry(
    builder: (_) => _Toast(
      message: msg,
      error: error,
      duration: Duration(milliseconds: error ? 4000 : 2200),
      onClosed: close,
    ),
  );
  _toastEntry = entry;
  overlay.insert(entry);
}

class _Toast extends StatefulWidget {
  const _Toast({required this.message, required this.error, required this.duration, required this.onClosed});
  final String message;
  final bool error;
  final Duration duration;
  final VoidCallback onClosed;

  @override
  State<_Toast> createState() => _ToastState();
}

class _ToastState extends State<_Toast> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    reverseDuration: const Duration(milliseconds: 200),
  )..forward();
  late final Animation<double> _curve = CurvedAnimation(
    parent: _c,
    curve: Curves.easeOutBack,
    reverseCurve: Curves.easeInCubic,
  );
  bool _closing = false;
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.duration, _dismiss);
  }

  Future<void> _dismiss() async {
    if (_closing || !mounted) return;
    _closing = true;
    await _c.reverse();
    widget.onClosed();
  }

  @override
  void dispose() {
    _timer.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF332D26) : const Color(0xFF4A3B30);
    final fg = Colors.white.withValues(alpha: 0.95);
    final accent = widget.error ? const Color(0xFFFFA8A0) : Color.lerp(scheme.primary, Colors.white, 0.45)!;
    return Positioned(
      left: 0,
      right: 0,
      top: MediaQuery.paddingOf(context).top + kToolbarHeight + 6,
      child: Center(
        child: FadeTransition(
          opacity: _c,
          child: AnimatedBuilder(
            animation: _curve,
            builder: (context, child) => Transform.translate(
              offset: Offset(0, -14 * (1 - _curve.value)),
              child: Transform.scale(scale: 0.92 + 0.08 * _curve.value, child: child),
            ),
            child: Dismissible(
              key: const ValueKey('toast'),
              direction: DismissDirection.up,
              onDismissed: (_) => widget.onClosed(),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width - 40),
                  padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
                  decoration: BoxDecoration(
                    color: bg,
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.18),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        widget.error ? Icons.error_outline_rounded : Icons.check_circle_rounded,
                        color: accent,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          widget.message,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(color: fg, height: 1.3),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Semantics(
                        button: true,
                        label: t('关闭提示', 'Dismiss'),
                        child: InkResponse(
                          onTap: _dismiss,
                          radius: 18,
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.12),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(Icons.close_rounded, size: 16, color: fg),
                          ),
                        ),
                      ),
                    ],
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

Future<void> copyText(BuildContext context, String text) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) toast(context, t('已复制', 'Copied'));
}

Future<bool> confirm(
  BuildContext context,
  String title, {
  String? message,
  String? ok,
  bool destructive = false,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: message == null ? null : Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(t('取消', 'Cancel'))),
        FilledButton(
          style: destructive
              ? FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError)
              : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(ok ?? t('确定', 'OK')),
        ),
      ],
    ),
  );
  return r ?? false;
}

Future<String?> promptText(
  BuildContext context,
  String title, {
  String initial = '',
  String? hint,
  int maxLines = 1,
  String? ok,
}) async {
  final c = TextEditingController(text: initial);
  final r = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        maxLines: maxLines,
        minLines: 1,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: maxLines == 1 ? (v) => Navigator.pop(ctx, v) : null,
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t('取消', 'Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(ok ?? t('确定', 'OK'))),
      ],
    ),
  );
  c.dispose();
  return r;
}

/// Section title + rounded group of tiles used across settings pages.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, this.title, required this.children, this.index = 0, this.footer});
  final String? title;
  final List<Widget> children;
  final int index;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      items.add(children[i]);
      if (i < children.length - 1) items.add(const Divider(indent: 56, height: 1));
    }
    final labelStyle = Theme.of(context).textTheme.labelLarge
        ?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700);
    final footStyle = Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return EntranceFx(
      index: index,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(title!, style: labelStyle),
              ),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(children: items),
            ),
            if (footer != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                child: Text(footer!, style: footStyle),
              ),
          ],
        ),
      ),
    );
  }
}

class IconBadge extends StatelessWidget {
  const IconBadge(this.icon, {super.key, this.color});
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(color: c.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(11)),
      child: Icon(icon, size: 19, color: c),
    );
  }
}

/// Emoji / image / monogram avatar.
class AvatarView extends StatelessWidget {
  const AvatarView({super.key, required this.value, this.fallback = '', this.size = 36});
  final String value;
  final String fallback;
  final double size;

  bool get _isImage => value.contains('/') || value.endsWith('.png') || value.endsWith('.jpg');

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget inner;
    if (value.isNotEmpty && _isImage) {
      inner = Image.file(
        File(AppPaths.resolve(value)),
        fit: BoxFit.cover,
        width: size,
        height: size,
        errorBuilder: (context, error, stack) => _mono(context),
      );
    } else if (value.isNotEmpty) {
      inner = Center(
        child: Text(value, style: TextStyle(fontSize: size * 0.52)),
      );
    } else {
      inner = _mono(context);
    }
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(size * 0.34),
        border: Border.all(color: scheme.outlineVariant, width: 0.8),
      ),
      child: inner,
    );
  }

  Widget _mono(BuildContext context) {
    final family = ModelRegistry.family(fallback);
    final String label;
    if (family.isNotEmpty) {
      label = family.substring(0, 1);
    } else if (fallback.isEmpty) {
      label = '?';
    } else {
      label = fallback.characters.first.toUpperCase();
    }
    final color = Theme.of(context).colorScheme.onSecondaryContainer;
    return Center(
      child: Text(
        label,
        style: TextStyle(fontSize: size * 0.42, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.subtitle, this.action});
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Center(
      child: EntranceFx(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(24)),
                child: Icon(icon, size: 34, color: scheme.primary),
              ),
              const SizedBox(height: 16),
              Text(title, style: tt.titleMedium, textAlign: TextAlign.center),
              if (subtitle != null) ...[
                const SizedBox(height: 6),
                Text(
                  subtitle!,
                  style: tt.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ],
              if (action != null) ...[const SizedBox(height: 18), action!],
            ],
          ),
        ),
      ),
    );
  }
}
