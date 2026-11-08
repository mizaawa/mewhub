import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/data/database.dart';
import 'package:mewhub/data/models_misc.dart';
import 'package:mewhub/tools/app_tools.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('private memory also sees and edits global memories; global scope stays separate', () async {
    final root = await Directory.systemTemp.createTemp('mewhub_memory_tools_');
    AppPaths.support = root;
    AppPaths.cache = root;
    final db = await AppDatabase.open('${root.path}/mewhub.db');
    addTearDown(() async {
      await db.close();
      await root.delete(recursive: true);
    });
    await db.saveMemory(MemoryItem(id: 'global00-memory', content: 'likes cats'));
    await db.saveMemory(MemoryItem(id: 'other000-memory', assistantId: 'other', content: 'other assistant'));

    final private = {for (final t in buildMemoryTools(db, assistantId: 'mine')) t.name: t};
    final saved = jsonDecode(await private['memory_save']!.execute({'content': 'prefers short answers'})) as Map;
    expect(saved['ok'], isTrue);
    final prompt = await memoriesForPrompt(db, assistantId: 'mine');
    expect(prompt.map((m) => m.content).toSet(), {'prefers short answers', 'likes cats'});

    final updated = await private['memory_update']!.execute({'id': 'global00', 'content': 'loves cats'});
    expect(jsonDecode(updated), {'ok': true});
    expect((await db.memories(global: true)).single.content, 'loves cats');
    final blank = await private['memory_update']!.execute({'id': 'global00', 'content': '  '});
    expect(jsonDecode(blank), {'error': 'empty'});
    expect(jsonDecode(await private['memory_delete']!.execute({'id': 'other000'})), {'error': 'not found'});
    expect(jsonDecode(await private['memory_delete']!.execute({'id': ''})), {'error': 'not found'});

    final global = await memoriesForPrompt(db, assistantId: null);
    expect(global.map((m) => m.content), ['loves cats']);
    final shared = {for (final t in buildMemoryTools(db, assistantId: null)) t.name: t};
    await shared['memory_delete']!.execute({'id': 'global00'});
    expect(await db.memories(global: true), isEmpty);
    expect((await db.allMemories()).map((m) => m.content).toSet(), {'prefers short answers', 'other assistant'});
  });
}
