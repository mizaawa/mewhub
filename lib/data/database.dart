import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../ai/message.dart';
import '../core/paths.dart';
import 'conversation.dart';
import 'models_misc.dart';

class ConversationSummary {
  ConversationSummary({
    required this.id,
    required this.assistantId,
    required this.title,
    required this.pinned,
    required this.updatedAt,
    required this.preview,
    this.folder,
  });

  final String id;
  final String assistantId;
  final String title;
  final bool pinned;
  final DateTime updatedAt;
  final String preview;
  final String? folder;
}

class SearchHit {
  SearchHit(this.conversationId, this.title, this.snippet, this.updatedAt);
  final String conversationId;
  final String title;
  final String snippet;
  final DateTime updatedAt;
}

/// SQLite storage for conversations, memories and favorites.
/// The whole message tree is stored as a JSON blob per conversation; a
/// flattened `search_text` column powers full-text search with LIKE.
class AppDatabase {
  AppDatabase._(this._db);
  final Database _db;

  static Future<AppDatabase> open([String? path]) async {
    final db = await openDatabase(
      path ?? AppPaths.dbPath,
      version: 1,
      onCreate: (db, v) async {
        await db.execute('''CREATE TABLE conversations(
          id TEXT PRIMARY KEY,
          assistant_id TEXT NOT NULL,
          title TEXT NOT NULL DEFAULT '',
          pinned INTEGER NOT NULL DEFAULT 0,
          folder TEXT,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          preview TEXT NOT NULL DEFAULT '',
          search_text TEXT NOT NULL DEFAULT '',
          data TEXT NOT NULL)''');
        await db.execute('CREATE INDEX idx_conv_assistant ON conversations(assistant_id, updated_at DESC)');
        await db.execute('CREATE INDEX idx_conv_updated ON conversations(updated_at DESC)');
        await db.execute('''CREATE TABLE memories(
          id TEXT PRIMARY KEY,
          assistant_id TEXT,
          content TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL)''');
        await db.execute('''CREATE TABLE favorites(
          id TEXT PRIMARY KEY,
          conversation_id TEXT NOT NULL,
          message_id TEXT NOT NULL UNIQUE,
          snapshot TEXT NOT NULL,
          created_at INTEGER NOT NULL)''');
        await db.execute('''CREATE TABLE usage_stats(
          day TEXT NOT NULL,
          model_id TEXT NOT NULL,
          model_name TEXT NOT NULL DEFAULT '',
          requests INTEGER NOT NULL DEFAULT 0,
          input_tokens INTEGER NOT NULL DEFAULT 0,
          output_tokens INTEGER NOT NULL DEFAULT 0,
          cached_tokens INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY(day, model_id))''');
      },
    );
    return AppDatabase._(db);
  }

  Future<void> close() => _db.close();

  // ---------------- conversations ----------------

  Future<void> saveConversation(Conversation c) async {
    final msgs = c.currentMessages;
    final preview = msgs.isEmpty ? '' : msgs.last.text.replaceAll(RegExp(r'\s+'), ' ');
    final search = msgs.map((m) => m.text).join('\n');
    await _db.insert('conversations', {
      'id': c.id,
      'assistant_id': c.assistantId,
      'title': c.title,
      'pinned': c.pinned ? 1 : 0,
      'folder': c.folder,
      'created_at': c.createdAt.millisecondsSinceEpoch,
      'updated_at': c.updatedAt.millisecondsSinceEpoch,
      'preview': preview.length > 160 ? preview.substring(0, 160) : preview,
      'search_text': search,
      'data': jsonEncode(c.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Conversation?> getConversation(String id) async {
    final rows = await _db.query('conversations', columns: ['data'], where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Conversation.fromJson(jsonDecode(rows.first['data'] as String) as Map<String, dynamic>);
  }

  Future<List<ConversationSummary>> listConversations({String? assistantId, int limit = 500, int offset = 0}) async {
    final rows = await _db.query(
      'conversations',
      columns: ['id', 'assistant_id', 'title', 'pinned', 'updated_at', 'preview', 'folder'],
      where: assistantId == null ? null : 'assistant_id = ?',
      whereArgs: assistantId == null ? null : [assistantId],
      orderBy: 'pinned DESC, updated_at DESC',
      limit: limit,
      offset: offset,
    );
    return rows.map(_summary).toList();
  }

  ConversationSummary _summary(Map<String, Object?> r) => ConversationSummary(
    id: r['id'] as String,
    assistantId: r['assistant_id'] as String,
    title: r['title'] as String,
    pinned: (r['pinned'] as int) == 1,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
    preview: r['preview'] as String,
    folder: r['folder'] as String?,
  );

  Future<List<SearchHit>> search(String query, {int limit = 100}) async {
    final q = query.trim();
    if (q.isEmpty) return [];
    final like = '%${q.replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
    final rows = await _db.rawQuery(
      r"SELECT id, title, search_text, updated_at FROM conversations WHERE title LIKE ? ESCAPE '\' OR search_text LIKE ? ESCAPE '\' ORDER BY updated_at DESC LIMIT ?",
      [like, like, limit],
    );
    final lower = q.toLowerCase();
    return rows.map((r) {
      final text = r['search_text'] as String;
      final idx = text.toLowerCase().indexOf(lower);
      String snippet;
      if (idx < 0) {
        snippet = text.length > 80 ? text.substring(0, 80) : text;
      } else {
        final start = (idx - 30).clamp(0, text.length);
        final end = (idx + q.length + 50).clamp(0, text.length);
        snippet = '${start > 0 ? '…' : ''}${text.substring(start, end)}${end < text.length ? '…' : ''}';
      }
      return SearchHit(
        r['id'] as String,
        r['title'] as String,
        snippet.replaceAll(RegExp(r'\s+'), ' '),
        DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
      );
    }).toList();
  }

  Future<void> deleteConversation(String id) async {
    await _db.delete('conversations', where: 'id = ?', whereArgs: [id]);
    await _db.delete('favorites', where: 'conversation_id = ?', whereArgs: [id]);
  }

  Future<void> deleteConversationsOf(String assistantId) =>
      _db.delete('conversations', where: 'assistant_id = ? AND pinned = 0', whereArgs: [assistantId]);

  Future<void> setPinned(String id, bool pinned) =>
      _db.update('conversations', {'pinned': pinned ? 1 : 0}, where: 'id = ?', whereArgs: [id]);

  Future<int> conversationCount() async =>
      Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM conversations')) ?? 0;

  /// Recent conversation titles for the "recent chats" context feature.
  Future<List<ConversationSummary>> recent(String assistantId, {String? excludeId, int limit = 10}) async {
    final rows = await _db.query(
      'conversations',
      columns: ['id', 'assistant_id', 'title', 'pinned', 'updated_at', 'preview', 'folder'],
      where: excludeId == null ? 'assistant_id = ?' : 'assistant_id = ? AND id != ?',
      whereArgs: excludeId == null ? [assistantId] : [assistantId, excludeId],
      orderBy: 'updated_at DESC',
      limit: limit,
    );
    return rows.map(_summary).toList();
  }

  Stream<Conversation> allConversations() async* {
    const page = 50;
    var offset = 0;
    while (true) {
      final rows = await _db.query(
        'conversations',
        columns: ['data'],
        orderBy: 'created_at',
        limit: page,
        offset: offset,
      );
      if (rows.isEmpty) break;
      for (final r in rows) {
        yield Conversation.fromJson(jsonDecode(r['data'] as String) as Map<String, dynamic>);
      }
      offset += page;
    }
  }

  // ---------------- memories ----------------

  Future<List<MemoryItem>> memories({String? assistantId, bool global = false}) async {
    final rows = await _db.query(
      'memories',
      where: global ? 'assistant_id IS NULL' : 'assistant_id = ?',
      whereArgs: global ? null : [assistantId],
      orderBy: 'updated_at DESC',
    );
    return rows
        .map(
          (r) => MemoryItem(
            id: r['id'] as String,
            assistantId: r['assistant_id'] as String?,
            content: r['content'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
          ),
        )
        .toList();
  }

  Future<List<MemoryItem>> allMemories() async {
    final rows = await _db.query('memories', orderBy: 'updated_at DESC');
    return rows
        .map(
          (r) => MemoryItem(
            id: r['id'] as String,
            assistantId: r['assistant_id'] as String?,
            content: r['content'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
            updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
          ),
        )
        .toList();
  }

  Future<void> saveMemory(MemoryItem m) => _db.insert('memories', {
    'id': m.id,
    'assistant_id': m.assistantId,
    'content': m.content,
    'created_at': m.createdAt.millisecondsSinceEpoch,
    'updated_at': m.updatedAt.millisecondsSinceEpoch,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> deleteMemory(String id) => _db.delete('memories', where: 'id = ?', whereArgs: [id]);

  // ---------------- favorites ----------------

  Future<void> addFavorite(FavoriteItem f) => _db.insert('favorites', {
    'id': f.id,
    'conversation_id': f.conversationId,
    'message_id': f.messageId,
    'snapshot': f.snapshot,
    'created_at': f.createdAt.millisecondsSinceEpoch,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> addFavoriteMessage(Conversation c, ChatMessage m) => addFavorite(
    FavoriteItem(
      conversationId: c.id,
      messageId: m.id,
      snapshot: jsonEncode({'title': c.title, 'assistantId': c.assistantId, 'message': m.toJson()}),
    ),
  );

  Future<void> removeFavorite(String messageId) =>
      _db.delete('favorites', where: 'message_id = ?', whereArgs: [messageId]);

  Future<Set<String>> favoriteMessageIds() async {
    final rows = await _db.query('favorites', columns: ['message_id']);
    return rows.map((r) => r['message_id'] as String).toSet();
  }

  Future<List<FavoriteItem>> favorites() async {
    final rows = await _db.query('favorites', orderBy: 'created_at DESC');
    return rows
        .map(
          (r) => FavoriteItem(
            id: r['id'] as String,
            conversationId: r['conversation_id'] as String,
            messageId: r['message_id'] as String,
            snapshot: r['snapshot'] as String,
            createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
          ),
        )
        .toList();
  }

  // ---------------- usage stats ----------------

  Future<void> recordUsage(String modelId, String modelName, int input, int output, int cached) async {
    final now = DateTime.now();
    final day = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    await _db.rawInsert(
      'INSERT INTO usage_stats(day, model_id, model_name, requests, input_tokens, output_tokens, cached_tokens) '
      'VALUES(?, ?, ?, 1, ?, ?, ?) ON CONFLICT(day, model_id) DO UPDATE SET '
      'requests = requests + 1, input_tokens = input_tokens + excluded.input_tokens, '
      'output_tokens = output_tokens + excluded.output_tokens, cached_tokens = cached_tokens + excluded.cached_tokens, '
      'model_name = excluded.model_name',
      [day, modelId, modelName, input, output, cached],
    );
  }

  Future<List<Map<String, Object?>>> usageByDay({int days = 30}) {
    final from = DateTime.now().subtract(Duration(days: days));
    final d = '${from.year}-${from.month.toString().padLeft(2, '0')}-${from.day.toString().padLeft(2, '0')}';
    return _db.rawQuery(
      'SELECT day, SUM(requests) AS requests, SUM(input_tokens) AS input, SUM(output_tokens) AS output '
      'FROM usage_stats WHERE day >= ? GROUP BY day ORDER BY day',
      [d],
    );
  }

  Future<List<Map<String, Object?>>> usageByModel() => _db.rawQuery(
    'SELECT model_id, MAX(model_name) AS name, SUM(requests) AS requests, SUM(input_tokens) AS input, '
    'SUM(output_tokens) AS output, SUM(cached_tokens) AS cached FROM usage_stats GROUP BY model_id ORDER BY input + output DESC',
  );

  Future<List<Map<String, Object?>>> rawUsage() => _db.query('usage_stats');

  Future<void> importUsage(List<Map<String, dynamic>> rows) async {
    final batch = _db.batch();
    for (final r in rows) {
      batch.insert('usage_stats', r, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<void> wipe() async {
    for (final t in ['conversations', 'memories', 'favorites', 'usage_stats']) {
      await _db.delete(t);
    }
  }
}
