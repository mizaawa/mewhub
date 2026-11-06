import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/data/conversation.dart';
import 'package:mewhub/data/database.dart';
import 'package:mewhub/state/app_state.dart';
import 'package:mewhub/state/settings_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('folders keep chats organized and persist through settings', () async {
    final root = await Directory.systemTemp.createTemp('mewhub_folders');
    AppPaths.support = root;
    AppPaths.cache = root;
    FlutterSecureStorage.setMockInitialValues({});
    final store = await SettingsStore.load();
    final db = await AppDatabase.open('${root.path}/mewhub.db');
    final app = AppState(store: store, db: db);
    addTearDown(() async {
      app.dispose();
      await store.flush();
      store.dispose();
      await db.close();
      for (var attempt = 0; attempt < 10; attempt++) {
        try {
          await root.delete(recursive: true);
          break;
        } on FileSystemException {
          if (attempt == 9) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });

    final chat = Conversation(assistantId: store.value.currentAssistantId, title: 'Saved chat');
    await db.saveConversation(chat);
    await app.refreshList();
    expect(app.conversations.single.folder, isNull);

    final folder = app.createChatFolder(' Work ')!;
    expect(folder.name, 'Work');
    expect(app.createChatFolder('work'), isNull);
    await app.moveConversationToFolder(chat.id, folder.id);
    expect(app.conversations.single.folder, folder.id);
    expect(app.renameChatFolder(folder, 'Projects'), isTrue);
    expect(store.value.chatFolders.single.name, 'Projects');
    await store.flush();
    final reloaded = await SettingsStore.load();
    expect(reloaded.value.chatFolders.single.id, folder.id);
    reloaded.dispose();

    await app.deleteChatFolder(folder);
    expect(store.value.chatFolders, isEmpty);
    expect(app.conversations.single.folder, isNull);
    expect((await db.getConversation(chat.id))?.folder, isNull);
  });
}
