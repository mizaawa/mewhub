import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/i18n.dart';
import 'markdown_view.dart';

/// Reveals streamed text the way it is written: a few graphemes per frame,
/// catching up faster when the model runs ahead, with a soft caret while the
/// reply is still arriving.
///
/// The buffer that has already settled is rendered as its own [MarkdownView],
/// so only the tail is re-parsed while the caret advances.
class StreamingReveal extends StatefulWidget {
  const StreamingReveal({
    super.key,
    required this.text,
    required this.streaming,
    this.latex = true,
    this.codeWrap = false,
    this.lineNumbers = false,
    this.fontScale = 1.0,
    this.fontFamily,
  });

  final String text;
  final bool streaming;
  final bool latex;
  final bool codeWrap;
  final bool lineNumbers;
  final double fontScale;
  final String? fontFamily;

  @override
  State<StreamingReveal> createState() => StreamingRevealState();
}

class StreamingRevealState extends State<StreamingReveal> with SingleTickerProviderStateMixin {
  static const _maxInterval = Duration(milliseconds: 16);
  static const _charsPerFrame = 6.0;

  /// Settled text shorter than this stays in the live tail, so short replies
  /// are not split into two markdown blocks.
  static const _settledFloor = 480;

  late final Ticker _ticker;
  int _shown = 0;
  Duration _last = Duration.zero;

  /// Characters that will never change again; rendered outside the live tail.
  int _settled = 0;

  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    // Text that is not streaming is already complete: show it at once.
    _shown = widget.streaming ? 0 : widget.text.length;
    if (widget.streaming && _shown < widget.text.length) _ticker.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion (and every non-streaming bubble) shows the whole text at
    // once; the reveal only exists for text that is genuinely still arriving.
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce != _reduceMotion) {
      _reduceMotion = reduce;
      if (reduce) {
        _ticker.stop();
        _shown = widget.text.length;
      }
    }
    if (_reduceMotion && _shown < widget.text.length) {
      _shown = widget.text.length;
      _ticker.stop();
    }
  }

  @override
  void didUpdateWidget(StreamingReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    final total = widget.text.length;
    if (!widget.streaming || _reduceMotion) {
      _ticker.stop();
      // The finished reply is parsed as one block, exactly like reloading it.
      _settled = 0;
      if (_shown < total) setState(() => _shown = total);
      return;
    }
    if (total < _shown) {
      // The text was replaced (new branch or a provider reset): start over.
      setState(() => _shown = total);
      return;
    }
    if (_shown < total && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final backlog = widget.text.length - _shown;
    if (backlog <= 0) {
      _ticker.stop();
      if (mounted) setState(() {});
      return;
    }
    final dt = _last == Duration.zero ? _maxInterval.inMicroseconds / 1000 : (elapsed - _last).inMicroseconds / 1000;
    _last = elapsed;
    // A steady cadence near the model's own speed, speeding up when the buffer
    // runs far ahead so the caret never lags behind a finished reply.
    final pace = 0.35 + math.min(1.6, backlog / 90);
    final step = math.max(1, math.min(backlog, (dt / 16 * _charsPerFrame * pace).round()));
    final next = math.min(widget.text.length, _shown + step);
    if (!mounted) return;
    setState(() => _shown = next);
    if (next >= widget.text.length) _ticker.stop();
  }

  /// Last paragraph break outside a fenced code block, leaving the tail whole.
  int _settleBoundary() {
    final text = widget.text;
    var fenced = false;
    var boundary = 0;
    for (var i = 0; i < text.length; i++) {
      final n = text.codeUnitAt(i);
      if (i == 0 || text.codeUnitAt(i - 1) == 0x0A) {
        if (text.startsWith('```', i) || text.startsWith('~~~', i)) fenced = !fenced;
      }
      if (fenced) continue;
      if (n == 0x0A && i + 1 < text.length && text.codeUnitAt(i + 1) == 0x0A) boundary = i + 2;
    }
    return boundary;
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.text.length;
    final shown = widget.text.length <= _shown ? total : _shown;
    final live = widget.streaming && shown < total;
    if (!live) _settled = 0;
    if (live && shown - _settled > _settledFloor) {
      final boundary = _settleBoundary();
      // Only ever move forward, so a settled paragraph is parsed once and the
      // live tail stays short even for very long replies.
      if (boundary > _settled) _settled = boundary;
    }
    if (shown < _settled) _settled = 0;
    final settled = widget.text.substring(0, _settled.clamp(0, shown));
    final tail = widget.text.substring(_settled.clamp(0, shown), shown);
    Widget markdown(String data) => MarkdownView(
      data: data,
      latex: widget.latex,
      codeWrap: widget.codeWrap,
      lineNumbers: widget.lineNumbers,
      fontScale: widget.fontScale,
      fontFamily: widget.fontFamily,
    );
    final children = <Widget>[];
    if (settled.isNotEmpty) children.add(markdown(settled));
    if (tail.isNotEmpty) children.add(markdown(tail));
    if (live) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: _Caret(color: Theme.of(context).colorScheme.primary),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children);
  }
}

/// A quiet breathing bar under the text while it is still growing.
///
/// It sits outside the text's layout, so settling widgets do not wait on it.
class _Caret extends StatefulWidget {
  const _Caret({required this.color});
  final Color color;

  @override
  State<_Caret> createState() => _CaretState();
}

class _CaretState extends State<_Caret> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduce = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      label: t('正在输出', 'Streaming'),
      child: reduce
          ? Container(
              width: 18,
              height: 3,
              margin: const EdgeInsets.only(left: 1),
              decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(3)),
            )
          : AnimatedBuilder(
              animation: _c,
              builder: (context, _) => Container(
                width: 18,
                height: 3,
                margin: const EdgeInsets.only(left: 1),
                decoration: BoxDecoration(
                  color: widget.color.withValues(alpha: 0.25 + 0.45 * Curves.easeInOut.transform(_c.value)),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
    );
  }
}
