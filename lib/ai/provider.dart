import '../core/net.dart';
import 'message.dart';
import 'provider_config.dart';

/// Normalised streaming events produced by every protocol adapter.
sealed class StreamChunk {
  const StreamChunk();
}

class TextDelta extends StreamChunk {
  const TextDelta(this.text);
  final String text;
}

class ReasoningDelta extends StreamChunk {
  const ReasoningDelta(this.text, {this.meta});
  final String text;

  /// Merged into the current reasoning part's metadata (signature, ids...).
  final Map<String, dynamic>? meta;
}

/// Ends the current reasoning block so the next reasoning text opens a new one.
class ReasoningEnd extends StreamChunk {
  const ReasoningEnd({this.meta});
  final Map<String, dynamic>? meta;
}

class ToolCallStart extends StreamChunk {
  const ToolCallStart(this.callId, this.name, {this.meta});
  final String callId;
  final String name;
  final Map<String, dynamic>? meta;
}

class ToolCallDelta extends StreamChunk {
  const ToolCallDelta(this.callId, this.argsDelta);
  final String callId;
  final String argsDelta;
}

class ServerToolChunk extends StreamChunk {
  const ServerToolChunk(this.part);
  final ServerToolPart part;
}

class ImageChunk extends StreamChunk {
  const ImageChunk(this.dataUri, {this.meta});
  final String dataUri;
  final Map<String, dynamic>? meta;
}

class CitationChunk extends StreamChunk {
  const CitationChunk(this.citations);
  final List<Citation> citations;
}

class UsageChunk extends StreamChunk {
  const UsageChunk(this.usage);
  final TokenUsage usage;
}

class FinishChunk extends StreamChunk {
  const FinishChunk(this.reason);
  final String? reason;
}

/// JSON-schema tool definition sent to the model.
class ToolSpec {
  const ToolSpec({required this.name, required this.description, required this.parameters});
  final String name;
  final String description;
  final Map<String, dynamic> parameters;
}

class GenerationParams {
  const GenerationParams({
    required this.model,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.reasoning = ReasoningLevel.auto,
    this.tools = const [],
    this.extraHeaders = const [],
    this.extraBodies = const [],
    this.stream = true,
    this.useBuiltInSearch = false,
    this.sessionId,
  });

  final ModelConfig model;
  final double? temperature;
  final double? topP;
  final int? maxTokens;
  final ReasoningLevel reasoning;
  final List<ToolSpec> tools;
  final List<KeyValue> extraHeaders;
  final List<CustomBody> extraBodies;
  final bool stream;
  final bool useBuiltInSearch;
  final String? sessionId;
}

class RemoteModel {
  const RemoteModel(this.id, [this.name]);
  final String id;
  final String? name;
}

abstract class AiProvider {
  AiProvider(this.config);
  final ProviderConfig config;

  /// [messages] may start with one system message.
  Stream<StreamChunk> stream(List<ChatMessage> messages, GenerationParams params, {CancelToken? cancel});

  Future<List<RemoteModel>> listModels();

  /// Text-to-image for dedicated image models. Returns data URIs or URLs.
  Future<List<String>> generateImage(ModelConfig model, String prompt, {int n = 1, String size = '1024x1024'}) {
    throw UnsupportedError('Image generation not supported by ${config.protocolLabel}');
  }

  // Round-robin over multiple keys.
  static final Map<String, int> _keyCursor = {};

  String nextKey() {
    final keys = config.keys;
    if (keys.isEmpty) return '';
    final i = (_keyCursor[config.id] ?? 0) % keys.length;
    _keyCursor[config.id] = i + 1;
    return keys[i];
  }

  Map<String, String> mergeHeaders(Map<String, String> base, GenerationParams? p) {
    final h = Map<String, String>.from(base);
    for (final kv in config.headers) {
      if (kv.key.isNotEmpty) h[kv.key] = kv.value;
    }
    if (p != null) {
      for (final kv in [...p.model.headers, ...p.extraHeaders]) {
        if (kv.key.isNotEmpty) h[kv.key] = kv.value;
      }
    }
    return h;
  }

  /// Applies custom body overrides. Dotted keys (`a.b`) set nested values;
  /// a value of `null` removes the key.
  Map<String, dynamic> mergeBody(Map<String, dynamic> body, GenerationParams p) {
    for (final b in [...p.model.bodies, ...p.extraBodies]) {
      if (b.key.trim().isEmpty) continue;
      final path = b.key.trim().split('.');
      Map<String, dynamic> cur = body;
      for (var i = 0; i < path.length - 1; i++) {
        final next = cur[path[i]];
        if (next is Map<String, dynamic>) {
          cur = next;
        } else {
          final m = <String, dynamic>{};
          cur[path[i]] = m;
          cur = m;
        }
      }
      final v = b.parsed;
      if (v == null) {
        cur.remove(path.last);
      } else {
        cur[path.last] = v;
      }
    }
    return body;
  }
}
