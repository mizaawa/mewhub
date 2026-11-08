import 'dart:convert';

import '../core/util.dart';
import '../data/database.dart';
import '../data/models_misc.dart';
import '../data/settings.dart';
import 'search.dart';
import 'tool.dart';

List<AppTool> buildSearchTools(AppSettings s) {
  final svc = s.currentSearch;
  if (svc == null) return [];
  final jinaKey = s.searchServices.where((e) => e.type == SearchServiceType.jina).map((e) => e.apiKey).firstOrNull;
  return [
    AppTool(
      name: 'search_web',
      displayName: 'Web search',
      description:
          '''Search the web for current or specific information. Use focused keywords; run several searches if needed.
Today is ${formatDate(DateTime.now())}. Prefer primary sources and check dates before stating current facts.
Cite sources inline as [n](url) using the result index.''',
      parameters: objectSchema({'query': strProp('Search keywords')}, required: ['query']),
      execute: (args) async {
        final q = asStr(args['query']).trim();
        if (q.isEmpty) return jsonEncode({'error': 'empty query'});
        final r = await SearchService.search(svc, q);
        return jsonEncode({
          'query': q,
          'retrievedAt': DateTime.now().toIso8601String(),
          'answer': ?r.answer,
          'items': [
            for (var i = 0; i < r.items.length; i++) {'index': i + 1, ...r.items[i].toJson()},
          ],
        });
      },
    ),
    AppTool(
      name: 'scrape_web',
      displayName: 'Read page',
      description: 'Fetch the readable content of a specific URL when search snippets are not enough.',
      parameters: objectSchema({'url': strProp('Absolute http(s) URL')}, required: ['url']),
      execute: (args) async {
        final url = asStr(args['url']).trim();
        final u = Uri.tryParse(url);
        if (u == null || !(u.scheme == 'http' || u.scheme == 'https')) {
          return jsonEncode({'error': 'invalid url'});
        }
        return SearchService.scrape(url, jinaKey: jinaKey);
      },
    ),
  ];
}

List<AppTool> buildMemoryTools(AppDatabase db, {required String? assistantId}) {
  // An assistant with private memory still sees the global (shared) ones.
  Future<List<MemoryItem>> visible() async => assistantId == null
      ? await db.memories(global: true)
      : [...await db.memories(assistantId: assistantId), ...await db.memories(global: true)];

  Future<MemoryItem?> find(Object? id) async {
    final short = asStr(id).trim();
    if (short.isEmpty) return null;
    return (await visible()).where((e) => e.id.startsWith(short)).firstOrNull;
  }

  return [
    AppTool(
      name: 'memory_save',
      displayName: 'Save memory',
      description: 'Save a durable fact about the user (preferences, background, long-term goals) for future chats. Do not store secrets or one-off details.',
      parameters: objectSchema({'content': strProp('The fact, one concise sentence')}, required: ['content']),
      execute: (args) async {
        final content = asStr(args['content']).trim();
        if (content.isEmpty) return jsonEncode({'error': 'empty'});
        final m = MemoryItem(assistantId: assistantId, content: content);
        await db.saveMemory(m);
        return jsonEncode({'ok': true, 'id': m.id.substring(0, 8)});
      },
    ),
    AppTool(
      name: 'memory_update',
      displayName: 'Update memory',
      description: 'Update an existing memory by its short id shown in <memories>.',
      parameters: objectSchema(
        {'id': strProp('Short memory id'), 'content': strProp('New content')},
        required: ['id', 'content'],
      ),
      execute: (args) async {
        final content = asStr(args['content']).trim();
        if (content.isEmpty) return jsonEncode({'error': 'empty'});
        final m = await find(args['id']);
        if (m == null) return jsonEncode({'error': 'not found'});
        await db.saveMemory(m.copyWith(content: content));
        return jsonEncode({'ok': true});
      },
    ),
    AppTool(
      name: 'memory_delete',
      displayName: 'Delete memory',
      description: 'Delete an outdated or wrong memory by its short id.',
      parameters: objectSchema({'id': strProp('Short memory id')}, required: ['id']),
      execute: (args) async {
        final m = await find(args['id']);
        if (m == null) return jsonEncode({'error': 'not found'});
        await db.deleteMemory(m.id);
        return jsonEncode({'ok': true});
      },
    ),
  ];
}

/// Memories injected into the prompt for [assistantId] (null = global scope).
Future<List<MemoryItem>> memoriesForPrompt(AppDatabase db, {required String? assistantId}) async => assistantId == null
    ? await db.memories(global: true)
    : [...await db.memories(assistantId: assistantId), ...await db.memories(global: true)];
