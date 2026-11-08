import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/data/conversation.dart';
import 'package:mewhub/data/database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('message search scopes by assistant and sorts relevance/newest/oldest', () async {
    final root = await Directory.systemTemp.createTemp('mewhub_conversation_search_');
    AppPaths.support = root;
    AppPaths.cache = root;
    final db = await AppDatabase.open('${root.path}/mewhub.db');
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });

    final base = DateTime(2026, 11, 8, 12);
    final oldTitleMatch = Conversation(
      assistantId: 'assistant-a',
      title: 'Maple plans',
      nodes: [
        MessageNode(messages: [ChatMessage.text(Role.user, 'ordinary request')]),
      ],
      createdAt: base,
      updatedAt: base,
    );
    final newBodyMatch = Conversation(
      assistantId: 'assistant-a',
      title: 'New session',
      nodes: [
        MessageNode(messages: [ChatMessage.text(Role.user, 'please find maple tree')]),
      ],
      createdAt: base.add(const Duration(hours: 1)),
      updatedAt: base.add(const Duration(hours: 1)),
    );
    final otherAssistantMatch = Conversation(
      assistantId: 'assistant-b',
      title: 'Maple elsewhere',
      nodes: [
        MessageNode(messages: [ChatMessage.text(Role.user, 'maple')]),
      ],
      createdAt: base.add(const Duration(hours: 2)),
      updatedAt: base.add(const Duration(hours: 2)),
    );
    for (final conversation in [oldTitleMatch, newBodyMatch, otherAssistantMatch]) {
      await db.saveConversation(conversation);
    }

    final currentAssistant = await db.search('maple', assistantId: 'assistant-a');
    expect(currentAssistant.map((hit) => hit.conversationId), [oldTitleMatch.id, newBodyMatch.id]);

    final all = await db.search('maple');
    expect(all, hasLength(3));
    expect(all.take(2).map((hit) => hit.title), ['Maple elsewhere', 'Maple plans']);
    expect(all.last.conversationId, newBodyMatch.id, reason: 'title matches rank before body-only matches');

    final newest = await db.search('maple', sort: ConversationSearchSort.newest);
    expect(newest.first.conversationId, otherAssistantMatch.id);
    final oldest = await db.search('maple', sort: ConversationSearchSort.oldest);
    expect(oldest.first.conversationId, oldTitleMatch.id);
    expect(currentAssistant.last.snippet.toLowerCase(), contains('maple'));
  });
}
