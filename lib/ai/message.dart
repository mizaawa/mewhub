import 'dart:convert';

import '../core/util.dart';

enum Role { system, user, assistant, tool }

enum ToolApproval { auto, pending, approved, denied }

/// One piece of a message. Persisted as JSON with a `type` discriminator.
sealed class Part {
  const Part();

  Map<String, dynamic> toJson();

  static Part? fromJson(Map<String, dynamic> j) {
    final meta = asMapOrNull(j['meta']);
    switch (j['type']) {
      case 'text':
        return TextPart(asStr(j['text']), meta: meta);
      case 'image':
        return ImagePart(asStr(j['url']), meta: meta);
      case 'document':
        return DocumentPart(
          path: asStr(j['path']),
          fileName: asStr(j['fileName']),
          mime: asStr(j['mime'], 'text/plain'),
          extractedText: asStrOrNull(j['text']),
          meta: meta,
        );
      case 'reasoning':
        return ReasoningPart(
          asStr(j['text']),
          startedAt: dateFromMsOrNull(j['startedAt']),
          finishedAt: dateFromMsOrNull(j['finishedAt']),
          meta: meta,
        );
      case 'tool':
        return ToolPart(
          callId: asStr(j['callId']),
          name: asStr(j['name']),
          input: asStr(j['input']),
          output: asStrOrNull(j['output']),
          isError: asBool(j['isError']),
          approval: enumByName(ToolApproval.values, j['approval'], ToolApproval.auto),
          meta: meta,
        );
      case 'server_tool':
        return ServerToolPart(
          callId: asStr(j['callId']),
          name: asStr(j['name']),
          input: j['input'],
          output: j['output'],
          done: asBool(j['done'], true),
          startedAt: dateFromMsOrNull(j['startedAt']),
          finishedAt: dateFromMsOrNull(j['finishedAt']),
          meta: meta,
        );
      case 'citations':
        return CitationsPart(mapList(j['items'], Citation.fromJson));
    }
    return null;
  }
}

class TextPart extends Part {
  const TextPart(this.text, {this.meta});
  final String text;
  final Map<String, dynamic>? meta;

  TextPart copyWith({String? text, Map<String, dynamic>? meta}) => TextPart(text ?? this.text, meta: meta ?? this.meta);

  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text, if (meta != null) 'meta': meta};
}

/// [url] is a sandbox-relative file path, an http(s) URL, or a data URI.
class ImagePart extends Part {
  const ImagePart(this.url, {this.meta});
  final String url;
  final Map<String, dynamic>? meta;

  @override
  Map<String, dynamic> toJson() => {'type': 'image', 'url': url, if (meta != null) 'meta': meta};
}

class DocumentPart extends Part {
  const DocumentPart({required this.path, required this.fileName, required this.mime, this.extractedText, this.meta});
  final String path;
  final String fileName;
  final String mime;
  final String? extractedText;
  final Map<String, dynamic>? meta;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'document',
    'path': path,
    'fileName': fileName,
    'mime': mime,
    if (extractedText != null) 'text': extractedText,
    if (meta != null) 'meta': meta,
  };
}

/// Provider metadata keys used in [ReasoningPart.meta]:
/// - `signature` (Anthropic thinking signature)
/// - `redacted` (Anthropic redacted_thinking data)
/// - `rid` / `enc` (OpenAI Responses reasoning item id / encrypted_content)
/// - `thoughtSignature` (Gemini)
class ReasoningPart extends Part {
  const ReasoningPart(this.text, {this.startedAt, this.finishedAt, this.meta});
  final String text;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final Map<String, dynamic>? meta;

  bool get finished => finishedAt != null;

  ReasoningPart copyWith({String? text, DateTime? finishedAt, Map<String, dynamic>? meta}) => ReasoningPart(
    text ?? this.text,
    startedAt: startedAt,
    finishedAt: finishedAt ?? this.finishedAt,
    meta: meta ?? this.meta,
  );

  @override
  Map<String, dynamic> toJson() => {
    'type': 'reasoning',
    'text': text,
    if (startedAt != null) 'startedAt': startedAt!.millisecondsSinceEpoch,
    if (finishedAt != null) 'finishedAt': finishedAt!.millisecondsSinceEpoch,
    if (meta != null) 'meta': meta,
  };
}

/// A client-side function call and (once executed) its result.
class ToolPart extends Part {
  const ToolPart({
    required this.callId,
    required this.name,
    required this.input,
    this.output,
    this.isError = false,
    this.approval = ToolApproval.auto,
    this.meta,
  });
  final String callId;
  final String name;
  final String input;
  final String? output;
  final bool isError;
  final ToolApproval approval;
  final Map<String, dynamic>? meta;

  bool get executed => output != null;
  bool get pending => !executed && approval == ToolApproval.pending;

  Map<String, dynamic> get inputJson => asMap(tryJsonDecode(input.isEmpty ? '{}' : input));

  ToolPart copyWith({
    String? name,
    String? input,
    String? output,
    bool? isError,
    ToolApproval? approval,
    Map<String, dynamic>? meta,
  }) => ToolPart(
    callId: callId,
    name: name ?? this.name,
    input: input ?? this.input,
    output: output ?? this.output,
    isError: isError ?? this.isError,
    approval: approval ?? this.approval,
    meta: meta ?? this.meta,
  );

  @override
  Map<String, dynamic> toJson() => {
    'type': 'tool',
    'callId': callId,
    'name': name,
    'input': input,
    if (output != null) 'output': output,
    if (isError) 'isError': true,
    'approval': approval.name,
    if (meta != null) 'meta': meta,
  };
}

/// A tool executed by the provider (e.g. built-in web search). Display + replay only.
class ServerToolPart extends Part {
  const ServerToolPart({
    required this.callId,
    required this.name,
    this.input,
    this.output,
    this.done = true,
    this.startedAt,
    this.finishedAt,
    this.meta,
  });
  final String callId;
  final String name;
  final dynamic input;
  final dynamic output;
  final bool done;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final Map<String, dynamic>? meta;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'server_tool',
    'callId': callId,
    'name': name,
    if (input != null) 'input': input,
    if (output != null) 'output': output,
    'done': done,
    if (startedAt != null) 'startedAt': startedAt!.millisecondsSinceEpoch,
    if (finishedAt != null) 'finishedAt': finishedAt!.millisecondsSinceEpoch,
    if (meta != null) 'meta': meta,
  };
}

class Citation {
  const Citation({required this.title, required this.url, this.snippet = ''});
  final String title;
  final String url;
  final String snippet;

  factory Citation.fromJson(Map<String, dynamic> j) =>
      Citation(title: asStr(j['title']), url: asStr(j['url']), snippet: asStr(j['snippet']));

  Map<String, dynamic> toJson() => {'title': title, 'url': url, if (snippet.isNotEmpty) 'snippet': snippet};
}

class CitationsPart extends Part {
  const CitationsPart(this.items);
  final List<Citation> items;

  @override
  Map<String, dynamic> toJson() => {'type': 'citations', 'items': items.map((e) => e.toJson()).toList()};
}

class TokenUsage {
  const TokenUsage({this.input = 0, this.output = 0, this.cached = 0, this.reasoning = 0});
  final int input;
  final int output;
  final int cached;
  final int reasoning;

  int get total => input + output;
  bool get isEmpty => input == 0 && output == 0;

  /// Streaming usage chunks may be partial; keep the max seen for each field.
  TokenUsage merge(TokenUsage o) => TokenUsage(
    input: o.input > input ? o.input : input,
    output: o.output > output ? o.output : output,
    cached: o.cached > cached ? o.cached : cached,
    reasoning: o.reasoning > reasoning ? o.reasoning : reasoning,
  );

  TokenUsage operator +(TokenUsage o) => TokenUsage(
    input: input + o.input,
    output: output + o.output,
    cached: cached + o.cached,
    reasoning: reasoning + o.reasoning,
  );

  factory TokenUsage.fromJson(Map<String, dynamic> j) => TokenUsage(
    input: asInt(j['in']),
    output: asInt(j['out']),
    cached: asInt(j['cached']),
    reasoning: asInt(j['reasoning']),
  );

  Map<String, dynamic> toJson() => {'in': input, 'out': output, 'cached': cached, 'reasoning': reasoning};
}

class ChatMessage {
  ChatMessage({
    String? id,
    required this.role,
    required this.parts,
    DateTime? createdAt,
    this.modelId,
    this.modelName,
    this.usage,
    this.finishedAt,
    this.error,
    this.translation,
    this.interrupted = false,
  }) : id = id ?? newId(),
       createdAt = createdAt ?? DateTime.now();

  final String id;
  final Role role;
  final List<Part> parts;
  final DateTime createdAt;

  /// Internal model id (not the API model name).
  final String? modelId;
  final String? modelName;
  final TokenUsage? usage;
  final DateTime? finishedAt;
  final String? error;
  final String? translation;

  /// True when the user stopped the stream: the visible text is kept as
  /// history, but the turn was cut short.
  final bool interrupted;

  factory ChatMessage.text(Role role, String text) => ChatMessage(role: role, parts: [TextPart(text)]);

  String get text => parts.whereType<TextPart>().map((e) => e.text).join('\n');

  String get reasoningText => parts.whereType<ReasoningPart>().map((e) => e.text).join('\n');

  bool get hasToolCalls => parts.any((p) => p is ToolPart);

  List<ToolPart> get toolCalls => parts.whereType<ToolPart>().toList();

  bool get isEmpty => parts.every(
    (p) => switch (p) {
      TextPart(:final text) => text.trim().isEmpty,
      ReasoningPart() => true,
      _ => false,
    },
  );

  ChatMessage copyWith({
    List<Part>? parts,
    String? modelId,
    String? modelName,
    TokenUsage? usage,
    DateTime? finishedAt,
    Object? error = _keep,
    Object? translation = _keep,
    DateTime? createdAt,
    bool? interrupted,
  }) => ChatMessage(
    id: id,
    role: role,
    parts: parts ?? this.parts,
    createdAt: createdAt ?? this.createdAt,
    modelId: modelId ?? this.modelId,
    modelName: modelName ?? this.modelName,
    usage: usage ?? this.usage,
    finishedAt: finishedAt ?? this.finishedAt,
    error: identical(error, _keep) ? this.error : error as String?,
    translation: identical(translation, _keep) ? this.translation : translation as String?,
    interrupted: interrupted ?? this.interrupted,
  );

  /// A fresh copy with a new id, used for forking / preset messages.
  ChatMessage cloneWithNewId() => ChatMessage(
    role: role,
    parts: parts,
    createdAt: DateTime.now(),
    modelId: modelId,
    modelName: modelName,
    usage: usage,
    finishedAt: finishedAt,
    interrupted: interrupted,
  );

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
    id: asStrOrNull(j['id']),
    role: enumByName(Role.values, j['role'], Role.user),
    parts: asList(j['parts'])
        .whereType<Map<dynamic, dynamic>>()
        .map((e) => Part.fromJson(asMap(e)))
        .whereType<Part>()
        .toList(),
    createdAt: dateFromMs(j['createdAt']),
    modelId: asStrOrNull(j['modelId']),
    modelName: asStrOrNull(j['modelName']),
    usage: j['usage'] is Map ? TokenUsage.fromJson(asMap(j['usage'])) : null,
    finishedAt: dateFromMsOrNull(j['finishedAt']),
    error: asStrOrNull(j['error']),
    translation: asStrOrNull(j['translation']),
    interrupted: asBool(j['interrupted']),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role.name,
    'parts': parts.map((e) => e.toJson()).toList(),
    'createdAt': createdAt.millisecondsSinceEpoch,
    if (modelId != null) 'modelId': modelId,
    if (modelName != null) 'modelName': modelName,
    if (usage != null) 'usage': usage!.toJson(),
    if (finishedAt != null) 'finishedAt': finishedAt!.millisecondsSinceEpoch,
    if (error != null) 'error': error,
    if (translation != null) 'translation': translation,
    if (interrupted) 'interrupted': true,
  };

  String encode() => jsonEncode(toJson());
}

const _keep = Object();
