import '../ai/message.dart';
import '../data/conversation.dart';

/// Compression is scheduled before the next reply, using the last completed
/// request's actual token usage. The newest user message stays after the new
/// checkpoint, so it is not swallowed into the summary.
class AutoCompressionPlan {
  const AutoCompressionPlan({required this.startIndex, required this.endIndex});

  final int startIndex;
  final int endIndex;

  static AutoCompressionPlan? forConversation(
    Conversation conversation,
    int contextLength, {
    int thresholdPercent = 98,
  }) {
    final nodes = conversation.nodes;
    if (contextLength <= 0 || nodes.length < 3 || nodes.last.role != Role.user) return null;

    final checkpoint = nodes.lastIndexWhere(
      (node) => node.current.parts.any((part) => part is TextPart && part.meta?['summary'] == true),
    );
    final lastAssistant = nodes.lastIndexWhere((node) => node.role == Role.assistant && node.current.usage != null);
    if (lastAssistant <= checkpoint) return null;
    final usage = nodes[lastAssistant].current.usage!;
    if (usage.isEmpty || usage.total * 100 < contextLength * thresholdPercent) return null;

    final start = checkpoint < 0 ? 0 : checkpoint;
    final end = nodes.length - 2;
    if (end <= start) return null;
    if (nodes
        .sublist(start, end + 1)
        .any((node) => node.current.parts.any((part) => part is ToolPart && !part.executed))) {
      return null;
    }
    return AutoCompressionPlan(startIndex: start, endIndex: end);
  }
}

/// Inserts a summary after the compressed prefix without deleting any message.
/// Returns the original conversation if the target node was removed meanwhile.
Conversation insertCompressionCheckpoint(Conversation conversation, String afterNodeId, String summary) {
  final end = conversation.nodes.indexWhere((node) => node.id == afterNodeId);
  if (end < 0 || end >= conversation.nodes.length - 1 || summary.trim().isEmpty) return conversation;
  final marker = ChatMessage(
    role: Role.user,
    parts: [
      TextPart(summary, meta: const {'summary': true}),
    ],
  );
  return conversation.copyWith(
    nodes: [
      ...conversation.nodes.take(end + 1),
      MessageNode(id: 'n-${marker.id}', messages: [marker]),
      ...conversation.nodes.skip(end + 1),
    ],
    updatedAt: DateTime.now(),
  );
}
