import '../ai/message.dart';
import '../ai/provider.dart';

/// Folds [StreamChunk]s into an ordered list of message parts.
class PartAccumulator {
  PartAccumulator([List<Part>? initial]) : parts = [...?initial];

  final List<Part> parts;
  TokenUsage usage = const TokenUsage();
  String? finishReason;
  final Map<String, int> _toolIndex = {};
  bool _reasoningOpen = false;

  void add(StreamChunk c) {
    switch (c) {
      case TextDelta(:final text):
        if (text.isEmpty) return;
        _closeReasoning();
        final last = parts.isEmpty ? null : parts.last;
        if (last is TextPart) {
          parts[parts.length - 1] = last.copyWith(text: last.text + text);
        } else {
          parts.add(TextPart(text));
        }
      case ReasoningDelta(:final text, :final meta):
        final last = parts.isEmpty ? null : parts.last;
        if (last is ReasoningPart && _reasoningOpen) {
          parts[parts.length - 1] = last.copyWith(text: last.text + text, meta: _mergeMeta(last.meta, meta));
        } else if (text.isEmpty && meta != null && last is ReasoningPart) {
          // Late signature for a block that already closed.
          parts[parts.length - 1] = last.copyWith(meta: _mergeMeta(last.meta, meta));
        } else if (text.isEmpty && meta != null && last is TextPart && meta.containsKey('thoughtSignature')) {
          // Gemini signature carried on a text part: keep it as a hidden reasoning part.
          parts.add(ReasoningPart('', startedAt: DateTime.now(), finishedAt: DateTime.now(), meta: meta));
        } else {
          parts.add(ReasoningPart(text, startedAt: DateTime.now(), meta: _mergeMeta(null, meta)));
          _reasoningOpen = true;
        }
      case ReasoningEnd(:final meta):
        final i = parts.lastIndexWhere((p) => p is ReasoningPart);
        if (i >= 0) {
          final r = parts[i] as ReasoningPart;
          parts[i] = r.copyWith(finishedAt: r.finishedAt ?? DateTime.now(), meta: _mergeMeta(r.meta, meta));
        } else if (meta != null && meta['enc'] != null) {
          // Encrypted reasoning with no visible summary still has to be replayed.
          parts.add(ReasoningPart('', startedAt: DateTime.now(), finishedAt: DateTime.now(), meta: meta));
        }
        _reasoningOpen = false;
      case ToolCallStart(:final callId, :final name, :final meta):
        _closeReasoning();
        if (_toolIndex.containsKey(callId)) return;
        _toolIndex[callId] = parts.length;
        parts.add(ToolPart(callId: callId, name: name, input: '', meta: meta));
      case ToolCallDelta(:final callId, :final argsDelta):
        final i = _toolIndex[callId];
        if (i == null) {
          _toolIndex[callId] = parts.length;
          parts.add(ToolPart(callId: callId, name: '', input: argsDelta));
          return;
        }
        final t = parts[i] as ToolPart;
        parts[i] = t.copyWith(input: t.input + argsDelta);
      case ServerToolChunk(:final part):
        _closeReasoning();
        final i = parts.indexWhere((p) => p is ServerToolPart && p.callId == part.callId && p.name == part.name);
        if (i < 0) {
          parts.add(
            ServerToolPart(
              callId: part.callId,
              name: part.name,
              input: part.input,
              output: part.output,
              done: part.done,
              startedAt: part.startedAt ?? (part.done ? null : DateTime.now()),
              finishedAt: part.finishedAt,
              meta: part.meta,
            ),
          );
        } else {
          final previous = parts[i] as ServerToolPart;
          final done = previous.done || part.done;
          final startedAt = previous.startedAt ?? part.startedAt ?? (done ? null : DateTime.now());
          parts[i] = ServerToolPart(
            callId: part.callId,
            name: part.name,
            input: part.input ?? previous.input,
            output: part.output ?? previous.output,
            done: done,
            startedAt: startedAt,
            finishedAt: previous.finishedAt ?? part.finishedAt ?? (done && startedAt != null ? DateTime.now() : null),
            meta: {...?previous.meta, ...?part.meta},
          );
        }
      case ImageChunk(:final dataUri, :final meta):
        _closeReasoning();
        parts.add(ImagePart(dataUri, meta: meta));
      case CitationChunk(:final citations):
        final i = parts.lastIndexWhere((p) => p is CitationsPart);
        if (i >= 0) {
          final existing = (parts[i] as CitationsPart).items;
          final urls = existing.map((e) => e.url).toSet();
          parts[i] = CitationsPart([...existing, ...citations.where((c) => urls.add(c.url))]);
        } else {
          final seen = <String>{};
          parts.add(CitationsPart(citations.where((c) => seen.add(c.url)).toList()));
        }
      case UsageChunk(usage: final u):
        usage = usage.merge(u);
      case FinishChunk(:final reason):
        finishReason = reason ?? finishReason;
        _closeReasoning();
    }
  }

  void _closeReasoning() {
    if (!_reasoningOpen) return;
    _reasoningOpen = false;
    final i = parts.lastIndexWhere((p) => p is ReasoningPart);
    if (i >= 0) {
      final r = parts[i] as ReasoningPart;
      if (r.finishedAt == null) parts[i] = r.copyWith(finishedAt: DateTime.now());
    }
  }

  void closeAll() => _closeReasoning();

  /// Tool calls emitted in the current round that have not run yet.
  List<ToolPart> get pendingTools => parts.whereType<ToolPart>().where((t) => !t.executed).toList();

  static Map<String, dynamic>? _mergeMeta(Map<String, dynamic>? a, Map<String, dynamic>? b) {
    if (b == null) return a;
    final out = {...?a};
    b.forEach((k, v) {
      if (k == 'details_append') {
        out['details'] = [...?(out['details'] as List?), ...(v as List)];
      } else if (k == 'signature' && v is String) {
        out[k] = '${out[k] ?? ''}$v';
      } else {
        out[k] = v;
      }
    });
    return out;
  }
}
