import '../ai/message.dart';
import '../core/util.dart';

/// One position in the chat. Holds alternative versions (branches) of a
/// message; [selected] picks the visible one. Regenerate / edit add branches.
class MessageNode {
  MessageNode({String? id, required this.messages, this.selected = 0}) : id = id ?? newId();

  final String id;
  final List<ChatMessage> messages;
  final int selected;

  ChatMessage get current => messages[selected.clamp(0, messages.length - 1)];
  Role get role => messages.isEmpty ? Role.user : messages.first.role;

  MessageNode copyWith({List<ChatMessage>? messages, int? selected}) =>
      MessageNode(id: id, messages: messages ?? this.messages, selected: selected ?? this.selected);

  /// Replaces the message with the same id, or appends it as a new selected branch.
  MessageNode upsert(ChatMessage m) {
    final i = messages.indexWhere((e) => e.id == m.id);
    if (i >= 0) {
      final list = [...messages];
      list[i] = m;
      return copyWith(messages: list);
    }
    return copyWith(messages: [...messages, m], selected: messages.length);
  }

  factory MessageNode.fromJson(Map<String, dynamic> j) {
    final msgs = mapList(j['messages'], ChatMessage.fromJson);
    return MessageNode(
      id: asStrOrNull(j['id']),
      messages: msgs.isEmpty ? [ChatMessage.text(Role.user, '')] : msgs,
      selected: asInt(j['selected']).clamp(0, msgs.isEmpty ? 0 : msgs.length - 1),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'selected': selected,
    'messages': messages.map((e) => e.toJson()).toList(),
  };
}

class Conversation {
  Conversation({
    String? id,
    required this.assistantId,
    this.title = '',
    this.nodes = const [],
    this.suggestions = const [],
    this.pinned = false,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.customSystemPrompt,
    this.modelId,
    this.modeIds = const {},
    this.folder,
  }) : id = id ?? newId(),
       createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final String assistantId;
  final String title;
  final List<MessageNode> nodes;
  final List<String> suggestions;
  final bool pinned;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String? customSystemPrompt;

  /// Per-conversation model override.
  final String? modelId;
  final Set<String> modeIds;
  final String? folder;

  List<ChatMessage> get currentMessages => [for (final n in nodes) n.current];

  bool get isEmpty => nodes.isEmpty;

  TokenUsage get totalUsage {
    var u = const TokenUsage();
    for (final m in currentMessages) {
      if (m.usage != null) u = u + m.usage!;
    }
    return u;
  }

  Conversation copyWith({
    String? title,
    List<MessageNode>? nodes,
    List<String>? suggestions,
    bool? pinned,
    DateTime? updatedAt,
    Object? customSystemPrompt = _keep,
    Object? modelId = _keep,
    Set<String>? modeIds,
    Object? folder = _keep,
    String? assistantId,
    String? id,
    DateTime? createdAt,
  }) => Conversation(
    id: id ?? this.id,
    assistantId: assistantId ?? this.assistantId,
    title: title ?? this.title,
    nodes: nodes ?? this.nodes,
    suggestions: suggestions ?? this.suggestions,
    pinned: pinned ?? this.pinned,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    customSystemPrompt: identical(customSystemPrompt, _keep) ? this.customSystemPrompt : customSystemPrompt as String?,
    modelId: identical(modelId, _keep) ? this.modelId : modelId as String?,
    modeIds: modeIds ?? this.modeIds,
    folder: identical(folder, _keep) ? this.folder : folder as String?,
  );

  int indexOfMessage(String messageId) => nodes.indexWhere((n) => n.messages.any((m) => m.id == messageId));

  /// Writes [m] into node [nodeId] (creating it at the end if missing).
  Conversation upsertMessage(String nodeId, ChatMessage m) {
    final i = nodes.lastIndexWhere((n) => n.id == nodeId);
    if (i < 0) {
      return copyWith(
        nodes: [
          ...nodes,
          MessageNode(id: nodeId, messages: [m]),
        ],
      );
    }
    final list = [...nodes];
    list[i] = list[i].upsert(m);
    return copyWith(nodes: list);
  }

  Conversation selectBranch(String nodeId, int index) {
    final list = [
      for (final n in nodes) n.id == nodeId ? n.copyWith(selected: index.clamp(0, n.messages.length - 1)) : n,
    ];
    return copyWith(nodes: list);
  }

  /// Keeps nodes up to and including [nodeIndex] (or excluding when [inclusive] is false).
  Conversation truncate(int nodeIndex, {bool inclusive = true}) =>
      copyWith(nodes: nodes.sublist(0, (inclusive ? nodeIndex + 1 : nodeIndex).clamp(0, nodes.length)));

  /// Creates a new conversation from the visible messages up to [nodeIndex].
  Conversation fork(int nodeIndex) => Conversation(
    assistantId: assistantId,
    title: title.isEmpty ? '' : '$title (fork)',
    nodes: [
      for (final n in nodes.take(nodeIndex + 1)) MessageNode(messages: [n.current.cloneWithNewId()]),
    ],
    customSystemPrompt: customSystemPrompt,
    modelId: modelId,
    modeIds: modeIds,
  );

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
    id: asStrOrNull(j['id']),
    assistantId: asStr(j['assistantId']),
    title: asStr(j['title']),
    nodes: mapList(j['nodes'], MessageNode.fromJson),
    suggestions: asList(j['suggestions']).map((e) => e.toString()).toList(),
    pinned: asBool(j['pinned']),
    createdAt: dateFromMs(j['createdAt']),
    updatedAt: dateFromMs(j['updatedAt']),
    customSystemPrompt: asStrOrNull(j['customSystemPrompt']),
    modelId: asStrOrNull(j['modelId']),
    modeIds: asList(j['modeIds']).map((e) => e.toString()).toSet(),
    folder: asStrOrNull(j['folder']),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'assistantId': assistantId,
    'title': title,
    'nodes': nodes.map((e) => e.toJson()).toList(),
    'suggestions': suggestions,
    'pinned': pinned,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'customSystemPrompt': customSystemPrompt,
    'modelId': modelId,
    'modeIds': modeIds.toList(),
    'folder': folder,
  };
}

const _keep = Object();
