import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ai/message.dart';
import '../../ai/provider_config.dart';
import '../../core/attachments.dart';
import '../../core/i18n.dart';
import '../../data/settings.dart';
import '../../tools/cartesian_plot.dart';
import '../theme.dart';
import '../widgets/cartesian_plot_view.dart';
import '../widgets/common.dart';
import '../widgets/image_viewer.dart';
import '../widgets/motion.dart';
import 'image_editor.dart';

/// Chat input area. Holds draft text + attachments and reports a send.
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.settings,
    required this.generating,
    required this.onSend,
    required this.onStop,
    required this.modelLabel,
    this.providerLabel = '',
    required this.onPickModel,
    required this.searchEnabled,
    required this.onToggleSearch,
    required this.reasoning,
    required this.onReasoning,
    required this.supportsReasoning,
    required this.supportsVision,
    required this.onCompress,
    this.controller,
    this.mcpLabel,
    this.mcpDot,
    this.mcpActive = false,
    this.onOpenMcp,
    this.extensionsLabel,
    this.extensionsActive = 0,
    this.onOpenExtensions,
    this.plotEnabled = false,
  });

  final AppSettings settings;
  final bool generating;
  final Future<void> Function(List<Part> parts) onSend;
  final VoidCallback onStop;
  final String modelLabel;
  final String providerLabel;
  final VoidCallback onPickModel;
  final bool searchEnabled;
  final VoidCallback onToggleSearch;
  final ReasoningLevel reasoning;
  final ValueChanged<ReasoningLevel> onReasoning;
  final bool supportsReasoning;
  final bool supportsVision;
  final VoidCallback onCompress;
  final TextEditingController? controller;

  /// Summary for the MCP entry ("2 on · 67 tools"). Null hides the entry.
  final String? mcpLabel;
  final Color? mcpDot;
  final bool mcpActive;
  final VoidCallback? onOpenMcp;

  /// Summary for the extensions entry. Null hides the entry.
  final String? extensionsLabel;
  final int extensionsActive;
  final VoidCallback? onOpenExtensions;
  final bool plotEnabled;

  @override
  State<Composer> createState() => ComposerState();
}

class ComposerState extends State<Composer> {
  late final TextEditingController _text = widget.controller ?? TextEditingController();
  final _focus = FocusNode();
  final List<Part> _attachments = [];
  bool _busy = false;
  bool _toolsOpen = false;

  @override
  void initState() {
    super.initState();
    _text.addListener(_onChanged);
    _focus.addListener(_onChanged);
    _attachments.addAll(Attachments.takeRecoveredChatPhotos());
    if (_attachments.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) toast(context, t('已恢复中断前尚未发送的照片', 'Recovered photos from your interrupted chat'));
      });
    }
  }

  void _onChanged() => setState(() {});

  /// Prefills the composer (used by edit / quick messages / suggestions).
  void setText(String s, {bool focus = true}) {
    _text.text = s;
    _text.selection = TextSelection.collapsed(offset: s.length);
    if (focus) _focus.requestFocus();
  }

  void addAttachments(List<Part> parts) => setState(() => _attachments.addAll(parts));

  @override
  void dispose() {
    _text.removeListener(_onChanged);
    if (widget.controller == null) _text.dispose();
    _focus.removeListener(_onChanged);
    _focus.dispose();
    super.dispose();
  }

  bool get _canSend => !_busy && (_text.text.trim().isNotEmpty || _attachments.isNotEmpty);

  Future<void> _send() async {
    if (widget.generating) {
      widget.onStop();
      return;
    }
    if (!_canSend) return;
    final text = _text.text.trim();
    final parts = <Part>[..._attachments];
    final d = widget.settings.display;
    if (text.isNotEmpty) {
      if (d.pasteLongTextAsFile && text.length > d.longTextThreshold) {
        parts.add(await Attachments.textAsFile(text));
      } else {
        parts.add(TextPart(text));
      }
    }
    _text.clear();
    setState(() {
      _attachments.clear();
      _toolsOpen = false;
    });
    if (d.haptics) unawaited(HapticFeedback.lightImpact());
    await widget.onSend(parts);
  }

  Future<void> _pick(Future<List<Part>> Function() picker) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final parts = await picker();
      if (mounted && parts.isNotEmpty) setState(() => _attachments.addAll(parts));
    } catch (e) {
      if (mounted) toast(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _takePhotoAndEdit() => _editPickedPhotos(() async {
    final photo = await Attachments.takePhoto();
    return photo == null ? const [] : [photo];
  });

  Future<void> _pickPhotosAndEdit() => _editPickedPhotos(Attachments.pickImages);

  Future<void> _editPickedPhotos(Future<List<ImagePart>> Function() picker) async {
    if (_busy) return;
    _focus.unfocus();
    setState(() {
      _busy = true;
      _toolsOpen = false;
    });
    var photos = <ImagePart>[];
    final kept = <String>[];
    try {
      photos = await picker();
      for (var i = 0; i < photos.length; i++) {
        if (!mounted) break;
        final edited = await Navigator.of(context).push<String>(
          MaterialPageRoute(
            // A dialog route: no edge back-swipe while a corner is dragged.
            fullscreenDialog: true,
            builder: (_) => ImageEditorPage(key: ValueKey('composer-photo-editor-$i'), imageUrl: photos[i].url),
          ),
        );
        if (edited == null) break;
        if (mounted) {
          setState(() => _attachments.add(ImagePart(edited)));
          kept.add(edited);
        } else {
          await Attachments.deleteStored(edited);
        }
      }
    } catch (e) {
      if (mounted) {
        final message = e is PlatformException && e.code == 'camera_access_denied'
            ? t(
                '相机权限被拒绝。请在系统设置的 MewHub 权限中允许相机，然后重试。',
                'Camera access was denied. Allow Camera in MewHub’s system settings, then try again.',
              )
            : '$e';
        toast(context, message, error: true);
      }
    } finally {
      try {
        for (final photo in photos) {
          await Attachments.deleteStored(photo.url);
        }
        if (!mounted) {
          for (final image in kept) {
            await Attachments.deleteStored(image);
          }
        }
      } catch (e) {
        debugPrint('Unable to remove temporary photo: $e');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  Future<void> _openFullEditor() async {
    _focus.unfocus();
    final send = await Navigator.of(context).push<bool>(
      PageRouteBuilder(
        opaque: false,
        barrierColor: Colors.black26,
        transitionDuration: const Duration(milliseconds: 380),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (context, a, b) => FullScreenEditor(
          controller: _text,
          fontScale: widget.settings.display.fontScale,
          canSend: !widget.generating,
        ),
        transitionsBuilder: (context, a, b, child) {
          final c = CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
          return FadeTransition(
            opacity: c,
            child: SlideTransition(
              position: Tween(begin: const Offset(0, 0.06), end: Offset.zero).animate(c),
              child: child,
            ),
          );
        },
      ),
    );
    if (!mounted) return;
    if (send == true) {
      await _send();
    } else {
      _focus.requestFocus();
    }
  }

  void _reasoningSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => ReasoningSheet(initial: widget.reasoning, onChanged: widget.onReasoning),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = widget.settings;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final focused = _focus.hasFocus;
    // The chat list runs behind the composer (as in RikkaHub): it fades out
    // over the input card and is solid only under its lower half and the
    // gesture bar, instead of a solid band that used to eat a third of the
    // screen.
    return CustomPaint(
      painter: _ComposerScrim(color: scheme.surface, solidHeight: bottom + 8 + 46),
      child: Padding(
        padding: EdgeInsets.fromLTRB(10, 6, 10, 8 + bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              child: _toolsOpen ? _toolsPanel(context) : const SizedBox(width: double.infinity),
            ),
            AnimatedContainer(
              key: const ValueKey('composer-input'),
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: focused ? scheme.primary.withValues(alpha: 0.45) : scheme.outlineVariant),
                boxShadow: [
                  BoxShadow(
                    color: scheme.shadow.withValues(alpha: focused ? 0.09 : 0.06),
                    blurRadius: 20,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSize(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    alignment: Alignment.topCenter,
                    child: _attachments.isEmpty ? const SizedBox(width: double.infinity) : _attachmentTray(context),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 2, 11, 0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _text,
                            focusNode: _focus,
                            minLines: 1,
                            maxLines: 7,
                            textInputAction: s.display.sendOnEnter ? TextInputAction.send : TextInputAction.newline,
                            onSubmitted: s.display.sendOnEnter ? (_) => _send() : null,
                            style: TextStyle(fontSize: 15.5 * s.display.fontScale, height: 1.45),
                            decoration: InputDecoration(
                              hintText: t('和 MewBot 说点什么…', 'Message MewBot…'),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              filled: false,
                              contentPadding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: _ExpandButton(onTap: _openFullEditor),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                    child: Row(
                      children: [
                        _RoundIcon(
                          icon: Icons.add_rounded,
                          onTap: () => setState(() => _toolsOpen = !_toolsOpen),
                          rotate: _toolsOpen,
                          tooltip: _toolsOpen ? t('收起工具', 'Close tools') : t('展开工具', 'Open tools'),
                        ),
                        const SizedBox(width: 2),
                        _RoundIcon(
                          icon: Icons.travel_explore_rounded,
                          active: widget.searchEnabled,
                          onTap: widget.onToggleSearch,
                          tooltip: t('联网搜索', 'Web search'),
                        ),
                        const SizedBox(width: 4),
                        // Model and reasoning live in the input's own action
                        // row now, so they no longer cost a separate line.
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                child: _ModelChip(
                                  model: widget.modelLabel,
                                  provider: widget.providerLabel,
                                  onTap: widget.onPickModel,
                                ),
                              ),
                              if (widget.supportsReasoning) ...[
                                const SizedBox(width: 6),
                                _ReasoningChip(level: widget.reasoning, onTap: _reasoningSheet),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        _SendButton(
                          generating: widget.generating,
                          enabled: widget.generating || _canSend,
                          busy: _busy,
                          onTap: _send,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Pending attachments, shown inside the input card above the text.
  Widget _attachmentTray(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 80,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
        itemCount: _attachments.length,
        separatorBuilder: (context, i) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final a = _attachments[i];
          final Widget content;
          if (a is ImagePart) {
            content = ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Image(image: imageProviderFor(a.url), width: 64, height: 64, fit: BoxFit.cover),
            );
          } else {
            final name = a is DocumentPart ? a.fileName : 'file';
            content = Container(
              width: 128,
              height: 64,
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(14)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.description_outlined, size: 18, color: scheme.primary),
                  const Spacer(),
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(height: 1.2),
                  ),
                ],
              ),
            );
          }
          return EntranceFx(
            index: i,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                content,
                Positioned(
                  right: -4,
                  top: -4,
                  child: Pressable(
                    onTap: () => setState(() => _attachments.removeAt(i)),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: scheme.inverseSurface,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.surfaceContainerLowest, width: 1.5),
                      ),
                      child: Icon(Icons.close_rounded, size: 12, color: scheme.onInverseSurface),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Collapses the panel, then opens one of the chat drawers.
  void _openDrawer(VoidCallback open) {
    _focus.unfocus();
    setState(() => _toolsOpen = false);
    open();
  }

  Future<void> _openPlot() async {
    _focus.unfocus();
    setState(() => _toolsOpen = false);
    final part = await Navigator.of(context).push<ImagePart>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => CartesianPlotPage(initialPlot: CartesianPlot.example(), allowAttach: true),
      ),
    );
    if (part == null) return;
    if (mounted) {
      setState(() => _attachments.add(part));
    } else {
      await Attachments.deleteStored(part.url);
    }
  }

  /// "+" panel: two drawer entries with live summaries above one row of
  /// compact actions, about the height of the old single tile row.
  Widget _toolsPanel(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = <Widget>[
      if (widget.onOpenMcp != null)
        _EntryCard(
          key: const ValueKey('composer-mcp-entry'),
          icon: Icons.extension_rounded,
          title: 'MCP',
          subtitle: widget.mcpLabel ?? '',
          active: widget.mcpActive,
          dot: widget.mcpDot,
          onTap: () => _openDrawer(widget.onOpenMcp!),
        ),
      if (widget.onOpenExtensions != null)
        _EntryCard(
          key: const ValueKey('composer-extensions-entry'),
          icon: Icons.auto_awesome_mosaic_outlined,
          title: t('扩展', 'Extensions'),
          subtitle: widget.extensionsLabel ?? '',
          active: widget.extensionsActive > 0,
          count: widget.extensionsActive,
          onTap: () => _openDrawer(widget.onOpenExtensions!),
        ),
    ];
    final actions = <Widget>[
      _ActionPill(
        key: const ValueKey('composer-action-photos'),
        icon: Icons.photo_library_outlined,
        label: t('相册', 'Photos'),
        enabled: widget.supportsVision,
        onTap: _pickPhotosAndEdit,
      ),
      _ActionPill(
        key: const ValueKey('composer-action-camera'),
        icon: Icons.photo_camera_outlined,
        label: t('拍照', 'Camera'),
        enabled: widget.supportsVision,
        onTap: _takePhotoAndEdit,
      ),
      _ActionPill(
        key: const ValueKey('composer-action-files'),
        icon: Icons.attach_file_rounded,
        label: t('文件', 'Files'),
        onTap: () => _pick(Attachments.pickFiles),
      ),
      _ActionPill(
        key: const ValueKey('composer-action-compress'),
        icon: Icons.compress_rounded,
        label: t('压缩', 'Compress'),
        onTap: widget.onCompress,
      ),
    ];
    List<Widget> spaced(List<Widget> items, double gap, int offset) => [
      for (var i = 0; i < items.length; i++) ...[
        if (i > 0) SizedBox(width: gap),
        Expanded(
          child: EntranceFx(index: offset + i, dy: 8, child: items[i]),
        ),
      ],
    ];
    return Container(
      key: const ValueKey('composer-tools-panel'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (entries.isNotEmpty) ...[Row(children: spaced(entries, 8, 0)), const SizedBox(height: 8)],
          Row(children: spaced(actions, 6, entries.length)),
          if (widget.plotEnabled) ...[
            const SizedBox(height: 8),
            _EntryCard(
              key: const ValueKey('composer-plot-entry'),
              icon: Icons.grid_on_rounded,
              title: t('平面直角坐标系', 'Cartesian plot'),
              subtitle: t('绘制函数和坐标点', 'Draw functions and points'),
              active: true,
              onTap: _openPlot,
            ),
          ],
        ],
      ),
    );
  }
}

/// Fades the conversation out behind the composer: clear at the top, then
/// solid for the bottom [solidHeight], so nothing shows through around the
/// lower half of the input card or under the gesture bar.
class _ComposerScrim extends CustomPainter {
  const _ComposerScrim({required this.color, required this.solidHeight});
  final Color color;
  final double solidHeight;

  static const _fade = 64.0;

  @override
  void paint(Canvas canvas, Size size) {
    final solidTop = (size.height - solidHeight).clamp(0.0, size.height);
    final fadeTop = math.max(0.0, solidTop - _fade);
    canvas.drawRect(
      Rect.fromLTRB(0, fadeTop, size.width, size.height),
      Paint()
        // Clamped: everything below solidTop takes the solid end colour.
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0), color.withValues(alpha: 0.9), color],
          stops: const [0, 0.6, 1],
        ).createShader(Rect.fromLTRB(0, fadeTop, size.width, math.max(solidTop, fadeTop + 1))),
    );
  }

  @override
  bool shouldRepaint(_ComposerScrim oldDelegate) =>
      oldDelegate.color != color || oldDelegate.solidHeight != solidHeight;
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.onTap, this.active = false, this.tooltip, this.rotate = false});
  final IconData icon;
  final VoidCallback onTap;
  final bool active;
  final String? tooltip;
  final bool rotate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final child = Pressable(
      onTap: onTap,
      scale: 0.88,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: active ? scheme.primary.withValues(alpha: 0.15) : Colors.transparent,
          // Round, like the model and reasoning pills next to it.
          borderRadius: BorderRadius.circular(18),
        ),
        child: AnimatedRotation(
          turns: rotate ? 0.125 : 0,
          duration: const Duration(milliseconds: 260),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
            child: Icon(icon, key: ValueKey(icon), size: 21, color: active ? scheme.primary : scheme.onSurfaceVariant),
          ),
        ),
      ),
    );
    return tooltip == null ? child : Tooltip(message: tooltip!, child: child);
  }
}

/// Current model, a compact pill in the input's action row. The provider is
/// added when there is room; very long ids scale down a little before they
/// are ellipsized (the app bar still shows the full name).
class _ModelChip extends StatelessWidget {
  const _ModelChip({required this.model, required this.provider, required this.onTap});
  final String model;
  final String provider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: t('切换模型', 'Switch model'),
      child: Pressable(
        onTap: onTap,
        scale: 0.95,
        child: Container(
          key: const ValueKey('composer-model-chip'),
          height: 32,
          padding: const EdgeInsets.fromLTRB(4, 0, 5, 0),
          decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(16)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AvatarView(value: '', fallback: model, size: 22),
              const SizedBox(width: 6),
              Flexible(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: LayoutBuilder(
                    key: ValueKey('$model|$provider'),
                    builder: (context, box) {
                      final style = tt.labelLarge?.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface);
                      final providerStyle = tt.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
                      double width(String text, TextStyle? style) {
                        final painter = TextPainter(
                          text: TextSpan(text: text, style: style),
                          maxLines: 1,
                          textDirection: TextDirection.ltr,
                          textScaler: MediaQuery.textScalerOf(context),
                        )..layout();
                        final w = painter.width;
                        painter.dispose();
                        return w;
                      }

                      final modelWidth = width(model, style);
                      final shrink = modelWidth > box.maxWidth;
                      final withProvider =
                          provider.isNotEmpty && modelWidth + width('  $provider', providerStyle) <= box.maxWidth;
                      return Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: model, style: shrink ? style?.copyWith(fontSize: 12.5) : style),
                            if (withProvider) TextSpan(text: '  $provider', style: providerStyle),
                          ],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 1),
              Icon(Icons.unfold_more_rounded, size: 15, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReasoningChip extends StatelessWidget {
  const _ReasoningChip({required this.level, required this.onTap});
  final ReasoningLevel level;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: t('思考强度', 'Reasoning effort'),
      child: Pressable(
        onTap: onTap,
        scale: 0.95,
        child: Container(
          height: 32,
          padding: const EdgeInsets.fromLTRB(7, 0, 10, 0),
          decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(16)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.psychology_alt_rounded, size: 16, color: scheme.primary),
              const SizedBox(width: 4),
              // The pill eases to the new label's width while the labels fade.
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    reasoningLabel(level),
                    key: ValueKey(level),
                    maxLines: 1,
                    style: Theme.of(context).textTheme.labelMedium
                        ?.copyWith(color: scheme.onSecondaryContainer, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String reasoningLabel(ReasoningLevel l) => switch (l) {
  ReasoningLevel.off => t('关闭', 'Off'),
  ReasoningLevel.auto => t('自动', 'Auto'),
  ReasoningLevel.low => t('轻度', 'Low'),
  ReasoningLevel.medium => t('中等', 'Medium'),
  ReasoningLevel.high => t('深度', 'High'),
  ReasoningLevel.xhigh => t('超深', 'XHigh'),
  ReasoningLevel.max => t('极限', 'Max'),
};

String _reasoningHint(ReasoningLevel l) => switch (l) {
  ReasoningLevel.off || ReasoningLevel.auto => t('交给模型自己决定想多久', 'Let the model decide how long to think'),
  ReasoningLevel.low => t('快速回答，少量思考', 'Quick answers, light thinking'),
  ReasoningLevel.medium => t('速度和质量的平衡', 'Balanced speed and quality'),
  ReasoningLevel.high => t('复杂问题，认真推理', 'Careful reasoning for hard problems'),
  ReasoningLevel.xhigh => t('长任务、难题，耗时更久', 'Long, hard tasks; takes longer'),
  ReasoningLevel.max => t('不计成本的最强推理', 'Strongest reasoning, no token limit'),
};

/// Six-stop slider for the reasoning level. Applies on every change so the
/// chip under the sheet updates live.
class ReasoningSheet extends StatefulWidget {
  const ReasoningSheet({super.key, required this.initial, required this.onChanged});
  final ReasoningLevel initial;
  final ValueChanged<ReasoningLevel> onChanged;

  @override
  State<ReasoningSheet> createState() => _ReasoningSheetState();
}

class _ReasoningSheetState extends State<ReasoningSheet> {
  static const _levels = ReasoningLevel.selectable;
  late int _i = _levels.indexOf(widget.initial).clamp(0, _levels.length - 1);

  void _set(int i) {
    if (i == _i) return;
    HapticFeedback.selectionClick();
    setState(() => _i = i);
    widget.onChanged(_levels[i]);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final level = _levels[_i];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(t('思考强度', 'Reasoning effort'), style: tt.titleMedium),
                const Spacer(),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                  child: Text(
                    reasoningLabel(level),
                    key: ValueKey(level),
                    style: tt.titleMedium?.copyWith(color: scheme.primary, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              layoutBuilder: (current, previous) =>
                  Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
              child: Text(
                _reasoningHint(level),
                key: ValueKey(level),
                style: tt.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 10),
            // Track ends sit at the centre of the first and last label cell.
            LayoutBuilder(
              builder: (context, box) => SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 6,
                  showValueIndicator: ShowValueIndicator.never,
                  activeTickMarkColor: scheme.onPrimary.withValues(alpha: 0.7),
                  inactiveTickMarkColor: scheme.primary.withValues(alpha: 0.35),
                ),
                child: Slider(
                  value: _i.toDouble(),
                  min: 0,
                  max: (_levels.length - 1).toDouble(),
                  divisions: _levels.length - 1,
                  padding: EdgeInsets.symmetric(horizontal: box.maxWidth / _levels.length / 2, vertical: 12),
                  onChanged: (v) => _set(v.round()),
                ),
              ),
            ),
            Row(
              children: [
                for (var i = 0; i < _levels.length; i++)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _set(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            _levels[i].displayName,
                            style: tt.labelMedium?.copyWith(
                              color: i == _i ? scheme.primary : scheme.onSurfaceVariant,
                              fontWeight: i == _i ? FontWeight.w800 : FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              t('模型不支持的档位会自动降到它支持的最高档', 'Levels a model does not support fall back to its highest one'),
              style: tt.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  const _SendButton({required this.generating, required this.enabled, required this.busy, required this.onTap});
  final bool generating;
  final bool enabled;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Widget icon;
    if (busy) {
      icon = const SizedBox(
        key: ValueKey('busy'),
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
      );
    } else if (generating) {
      icon = const Icon(Icons.stop_rounded, key: ValueKey('stop'), color: Colors.white, size: 22);
    } else {
      icon = const Icon(Icons.arrow_upward_rounded, key: ValueKey('send'), color: Colors.white, size: 22);
    }
    return Pressable(
      onTap: enabled ? onTap : null,
      scale: 0.86,
      // No overshooting curve here: lerping the shadow past 1 gives a negative blur.
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          gradient: enabled
              ? LinearGradient(
                  colors: [scheme.primary, Color.lerp(scheme.primary, MewThemeColors.of(context).accentGlow, 0.4)!],
                )
              : null,
          color: enabled ? null : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(generating ? 13 : 20),
          boxShadow: enabled
              ? [BoxShadow(color: scheme.primary.withValues(alpha: 0.35), blurRadius: 12, offset: const Offset(0, 4))]
              : null,
        ),
        child: Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (c, a) => RotationTransition(
              turns: Tween(begin: 0.75, end: 1.0).animate(a),
              child: ScaleTransition(scale: a, child: c),
            ),
            child: icon,
          ),
        ),
      ),
    );
  }
}

/// One of the two drawer entries at the top of the "+" panel.
class _EntryCard extends StatelessWidget {
  const _EntryCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.active = false,
    this.dot,
    this.count = 0,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool active;
  final Color? dot;
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Pressable(
      onTap: onTap,
      scale: 0.97,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        height: 54,
        padding: const EdgeInsets.fromLTRB(8, 7, 6, 7),
        decoration: BoxDecoration(
          color: active ? scheme.primary.withValues(alpha: 0.10) : scheme.secondaryContainer.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: active ? scheme.primary.withValues(alpha: 0.32) : Colors.transparent),
        ),
        child: Row(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: active ? scheme.primary : scheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(icon, size: 19, color: active ? scheme.onPrimary : scheme.primary),
                ),
                if (dot != null)
                  Positioned(
                    right: -2,
                    top: -2,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: dot,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.surfaceContainerLowest, width: 1.6),
                      ),
                    ),
                  )
                else if (count > 0)
                  Positioned(
                    right: -5,
                    top: -5,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 16),
                      height: 16,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: scheme.surfaceContainerLowest, width: 1.4),
                      ),
                      child: Text(
                        '$count',
                        style: tt.labelSmall?.copyWith(color: scheme.onPrimary, fontSize: 9.5, height: 1),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tt.labelLarge?.copyWith(fontWeight: FontWeight.w700, height: 1.15),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tt.labelSmall?.copyWith(color: scheme.onSurfaceVariant, height: 1.25),
                  ),
                ],
              ),
            ),
            Icon(Icons.keyboard_arrow_up_rounded, size: 18, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// Compact icon-over-label action used for photos, camera, files and compress.
class _ActionPill extends StatelessWidget {
  const _ActionPill({super.key, required this.icon, required this.label, required this.onTap, this.enabled = true});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Pressable(
        onTap: enabled ? onTap : null,
        scale: 0.94,
        child: Container(
          height: 50,
          decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(14)),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 19, color: scheme.primary),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(height: 1.1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small corner button in the input that opens the full-screen editor.
class _ExpandButton extends StatelessWidget {
  const _ExpandButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: t('全屏编辑', 'Full-screen editor'),
      child: Pressable(
        onTap: onTap,
        scale: 0.85,
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(color: scheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(10)),
          child: Icon(Icons.open_in_full_rounded, size: 15, color: scheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// Full-screen draft editor sharing the composer's controller. Pops `true`
/// when the user taps send, `false`/null when they just close it.
class FullScreenEditor extends StatefulWidget {
  const FullScreenEditor({super.key, required this.controller, this.fontScale = 1.0, this.canSend = true});
  final TextEditingController controller;
  final double fontScale;
  final bool canSend;

  @override
  State<FullScreenEditor> createState() => _FullScreenEditorState();
}

class _FullScreenEditorState extends State<FullScreenEditor> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final text = widget.controller.text;
    final lines = text.isEmpty ? 0 : '\n'.allMatches(text).length + 1;
    final canSend = widget.canSend && text.trim().isNotEmpty;
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(10, 8, 10, 10 + insets),
          child: Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: scheme.outlineVariant),
              boxShadow: [
                BoxShadow(color: scheme.shadow.withValues(alpha: 0.12), blurRadius: 30, offset: const Offset(0, 10)),
              ],
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 6, 8, 0),
                  child: Row(
                    children: [
                      IconButton(
                        tooltip: t('收起', 'Collapse'),
                        icon: const Icon(Icons.close_fullscreen_rounded, size: 20),
                        onPressed: () => Navigator.pop(context, false),
                      ),
                      const SizedBox(width: 2),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(t('全屏编辑', 'Editor'), style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                            Text(
                              t(
                                '$lines 行 · ${text.characters.length} 字',
                                '$lines lines · ${text.characters.length} chars',
                              ),
                              style: tt.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                      AnimatedOpacity(
                        duration: const Duration(milliseconds: 200),
                        opacity: text.isEmpty ? 0 : 1,
                        child: IconButton(
                          tooltip: t('清空', 'Clear'),
                          icon: Icon(Icons.backspace_outlined, size: 19, color: scheme.onSurfaceVariant),
                          onPressed: text.isEmpty ? null : widget.controller.clear,
                        ),
                      ),
                      const SizedBox(width: 4),
                      AnimatedScale(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutBack,
                        scale: canSend ? 1 : 0.92,
                        child: FilledButton.icon(
                          onPressed: canSend ? () => Navigator.pop(context, true) : null,
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            minimumSize: const Size(0, 38),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                          label: Text(t('发送', 'Send')),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Divider(height: 12, color: scheme.outlineVariant.withValues(alpha: 0.6)),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: TextField(
                      controller: widget.controller,
                      focusNode: _focus,
                      expands: true,
                      maxLines: null,
                      minLines: null,
                      keyboardType: TextInputType.multiline,
                      textAlignVertical: TextAlignVertical.top,
                      style: TextStyle(fontSize: 16.5 * widget.fontScale, height: 1.6),
                      decoration: InputDecoration(
                        hintText: t('慢慢写，想写多长都可以…', 'Take your time, write as much as you like…'),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
