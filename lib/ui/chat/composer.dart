import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../ai/message.dart';
import '../../ai/provider_config.dart';
import '../../core/attachments.dart';
import '../../core/i18n.dart';
import '../../data/settings.dart';
import '../widgets/common.dart';
import '../widgets/image_viewer.dart';
import '../widgets/motion.dart';

/// Chat input area. Holds draft text + attachments and reports a send.
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.settings,
    required this.generating,
    required this.onSend,
    required this.onStop,
    required this.modelLabel,
    required this.onPickModel,
    required this.searchEnabled,
    required this.onToggleSearch,
    required this.reasoning,
    required this.onReasoning,
    required this.supportsReasoning,
    required this.supportsVision,
    required this.activeModes,
    required this.onToggleMode,
    required this.onQuickMessage,
    required this.onCompress,
    this.controller,
  });

  final AppSettings settings;
  final bool generating;
  final Future<void> Function(List<Part> parts) onSend;
  final VoidCallback onStop;
  final String modelLabel;
  final VoidCallback onPickModel;
  final bool searchEnabled;
  final VoidCallback onToggleSearch;
  final ReasoningLevel reasoning;
  final ValueChanged<ReasoningLevel> onReasoning;
  final bool supportsReasoning;
  final bool supportsVision;
  final Set<String> activeModes;
  final ValueChanged<String> onToggleMode;
  final ValueChanged<String> onQuickMessage;
  final VoidCallback onCompress;
  final TextEditingController? controller;

  @override
  State<Composer> createState() => ComposerState();
}

class ComposerState extends State<Composer> {
  late final TextEditingController _text = widget.controller ?? TextEditingController();
  final _focus = FocusNode();
  final List<Part> _attachments = [];
  bool _busy = false;
  bool _toolsOpen = false;
  final SpeechToText _stt = SpeechToText();
  bool _listening = false;
  String _sttBase = '';

  @override
  void initState() {
    super.initState();
    _text.addListener(_onChanged);
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
    _focus.dispose();
    _stt.cancel();
    super.dispose();
  }

  bool get _canSend => !_busy && (_text.text.trim().isNotEmpty || _attachments.isNotEmpty);

  Future<void> _send() async {
    if (widget.generating) {
      widget.onStop();
      return;
    }
    if (!_canSend) return;
    if (_listening) await _stopListening();
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
    setState(() => _busy = true);
    try {
      final parts = await picker();
      if (parts.isNotEmpty) setState(() => _attachments.addAll(parts));
    } catch (e) {
      if (mounted) toast(context, '$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleListening() async {
    if (_listening) return _stopListening();
    try {
      final ok = await _stt.initialize(
        onStatus: (s) {
          if ((s == 'done' || s == 'notListening') && mounted) setState(() => _listening = false);
        },
        onError: (e) {
          if (mounted) {
            setState(() => _listening = false);
            toast(context, e.errorMsg, error: true);
          }
        },
      );
      if (!ok) {
        if (mounted) toast(context, t('语音识别不可用或未授权', 'Speech recognition unavailable or not permitted'), error: true);
        return;
      }
      _sttBase = _text.text.isEmpty ? '' : '${_text.text} ';
      setState(() => _listening = true);
      await _stt.listen(
        onResult: (r) => setText('$_sttBase${r.recognizedWords}', focus: false),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          listenMode: ListenMode.dictation,
          autoPunctuation: true,
          pauseFor: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _listening = false);
        toast(context, '$e', error: true);
      }
    }
  }

  Future<void> _stopListening() async {
    await _stt.stop();
    if (mounted) setState(() => _listening = false);
  }

  void _reasoningSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        String label(ReasoningLevel l) => switch (l) {
          ReasoningLevel.off => t('关闭', 'Off'),
          ReasoningLevel.auto => t('自动', 'Auto'),
          ReasoningLevel.low => t('轻度', 'Low'),
          ReasoningLevel.medium => t('中等', 'Medium'),
          ReasoningLevel.high => t('深度', 'High'),
          ReasoningLevel.max => t('极限', 'Max'),
        };
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(t('思考强度', 'Reasoning effort'), style: Theme.of(ctx).textTheme.titleMedium),
              ),
              for (final l in ReasoningLevel.values)
                ListTile(
                  leading: Icon(
                    l == widget.reasoning ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  ),
                  title: Text(label(l)),
                  subtitle: l.budget > 0 ? Text('≈ ${l.budget} tokens') : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    widget.onReasoning(l);
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = widget.settings;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(10, 6, 10, 8 + bottom),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [scheme.surface.withValues(alpha: 0), scheme.surface.withValues(alpha: 0.92), scheme.surface],
          stops: const [0, 0.25, 1],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            child: _attachments.isEmpty ? const SizedBox(width: double.infinity) : _attachmentTray(context),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            child: _toolsOpen ? _toolsPanel(context) : const SizedBox(width: double.infinity),
          ),
          Container(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(
                color: _focus.hasFocus ? scheme.primary.withValues(alpha: 0.45) : scheme.outlineVariant,
              ),
              boxShadow: [
                BoxShadow(color: scheme.shadow.withValues(alpha: 0.07), blurRadius: 24, offset: const Offset(0, 8)),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
                  child: TextField(
                    controller: _text,
                    focusNode: _focus,
                    minLines: 1,
                    maxLines: 7,
                    textInputAction: s.display.sendOnEnter ? TextInputAction.send : TextInputAction.newline,
                    onSubmitted: s.display.sendOnEnter ? (_) => _send() : null,
                    style: TextStyle(fontSize: 15.5 * s.display.fontScale, height: 1.45),
                    decoration: InputDecoration(
                      hintText: _listening ? t('正在聆听…', 'Listening…') : t('和 Mew 说点什么…', 'Message Mew…'),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                  child: Row(
                    children: [
                      _RoundIcon(
                        icon: _toolsOpen ? Icons.close_rounded : Icons.add_rounded,
                        onTap: () => setState(() => _toolsOpen = !_toolsOpen),
                        rotate: _toolsOpen,
                      ),
                      const SizedBox(width: 2),
                      _Pill(icon: Icons.auto_awesome_rounded, label: widget.modelLabel, onTap: widget.onPickModel),
                      const SizedBox(width: 4),
                      _RoundIcon(
                        icon: Icons.travel_explore_rounded,
                        active: widget.searchEnabled,
                        onTap: widget.onToggleSearch,
                        tooltip: t('联网搜索', 'Web search'),
                      ),
                      if (widget.supportsReasoning)
                        _RoundIcon(
                          icon: Icons.psychology_alt_rounded,
                          active: widget.reasoning != ReasoningLevel.off,
                          onTap: _reasoningSheet,
                          tooltip: t('思考强度', 'Reasoning'),
                        ),
                      const Spacer(),
                      if (!widget.generating && _text.text.isEmpty && _attachments.isEmpty)
                        _RoundIcon(
                          icon: _listening ? Icons.graphic_eq_rounded : Icons.mic_none_rounded,
                          active: _listening,
                          onTap: _toggleListening,
                          tooltip: t('语音输入', 'Voice input'),
                        ),
                      const SizedBox(width: 4),
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
    );
  }

  Widget _attachmentTray(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 82,
      margin: const EdgeInsets.only(bottom: 8),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: _attachments.length,
        separatorBuilder: (context, i) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final a = _attachments[i];
          final Widget content;
          if (a is ImagePart) {
            content = ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image(image: imageProviderFor(a.url), width: 82, height: 82, fit: BoxFit.cover),
            );
          } else {
            final name = a is DocumentPart ? a.fileName : 'file';
            content = Container(
              width: 140,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.description_outlined, color: scheme.primary),
                  const Spacer(),
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
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
                      decoration: BoxDecoration(color: scheme.inverseSurface, shape: BoxShape.circle),
                      child: Icon(Icons.close_rounded, size: 13, color: scheme.onInverseSurface),
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

  Widget _toolsPanel(BuildContext context) {
    final s = widget.settings;
    final tiles = <Widget>[
      _ToolTile(
        icon: Icons.photo_library_outlined,
        label: t('相册', 'Photos'),
        enabled: widget.supportsVision,
        onTap: () => _pick(() async => await Attachments.pickImages()),
      ),
      _ToolTile(
        icon: Icons.photo_camera_outlined,
        label: t('拍照', 'Camera'),
        enabled: widget.supportsVision,
        onTap: () => _pick(() async {
          final p = await Attachments.takePhoto();
          return p == null ? <Part>[] : <Part>[p];
        }),
      ),
      _ToolTile(icon: Icons.attach_file_rounded, label: t('文件', 'Files'), onTap: () => _pick(Attachments.pickFiles)),
      _ToolTile(icon: Icons.compress_rounded, label: t('压缩上下文', 'Compress'), onTap: widget.onCompress),
    ];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (var i = 0; i < tiles.length; i++)
                Expanded(
                  child: EntranceFx(index: i, child: tiles[i]),
                ),
            ],
          ),
          if (s.modes.isNotEmpty || s.quickMessages.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  for (final m in s.modes)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: FilterChip(
                        label: Text(m.name),
                        selected: widget.activeModes.contains(m.id),
                        onSelected: (_) => widget.onToggleMode(m.id),
                      ),
                    ),
                  for (final q in s.quickMessages)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ActionChip(
                        avatar: const Icon(Icons.bolt_rounded, size: 16),
                        label: Text(q.title.isEmpty ? q.content : q.title, overflow: TextOverflow.ellipsis),
                        onPressed: () => widget.onQuickMessage(q.content),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
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
          borderRadius: BorderRadius.circular(13),
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

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Flexible(
      child: Pressable(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 170),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(13)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: scheme.primary),
              const SizedBox(width: 5),
              Flexible(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: Text(
                    label,
                    key: ValueKey(label),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(color: scheme.onSecondaryContainer),
                  ),
                ),
              ),
              Icon(Icons.expand_more_rounded, size: 15, color: scheme.onSecondaryContainer),
            ],
          ),
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
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutBack,
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          gradient: enabled
              ? LinearGradient(colors: [scheme.primary, Color.lerp(scheme.primary, const Color(0xFFE7B98F), 0.4)!])
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

class _ToolTile extends StatelessWidget {
  const _ToolTile({required this.icon, required this.label, required this.onTap, this.enabled = true});
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(17)),
              child: Icon(icon, color: scheme.primary),
            ),
            const SizedBox(height: 6),
            Text(label, style: Theme.of(context).textTheme.labelSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}
