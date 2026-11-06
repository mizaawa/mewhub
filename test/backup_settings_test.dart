import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/data/backup.dart';
import 'package:mewhub/data/chat_folder.dart';
import 'package:mewhub/data/conversation.dart';
import 'package:mewhub/data/database.dart';
import 'package:mewhub/data/models_misc.dart';
import 'package:mewhub/data/proxy_config.dart';
import 'package:mewhub/data/settings.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('backup round trip includes chats, favorites, memories, usage and app files', () async {
    final root = await Directory.systemTemp.createTemp('mewhub_backup_test');
    addTearDown(() => root.delete(recursive: true));
    final source = Directory('${root.path}/source')..createSync();
    final destination = Directory('${root.path}/destination')..createSync();
    AppPaths.support = source;
    AppPaths.cache = root;
    final initial = AppSettings.initial();
    final settings = initial.copyWith(
      chatFolders: [ChatFolder(id: 'work', assistantId: initial.currentAssistantId, name: 'Work')],
      display: initial.display.copyWith(conversationSortByCreation: true),
    );
    final sourceDb = await AppDatabase.open('${source.path}/mewhub.db');
    final conversation = Conversation(
      id: 'chat-1',
      assistantId: settings.currentAssistantId,
      title: 'Saved conversation',
      folder: 'work',
      nodes: [
        MessageNode(messages: [ChatMessage.text(Role.user, 'Hello')]),
      ],
    );
    await sourceDb.saveConversation(conversation);
    await sourceDb.addFavorite(
      FavoriteItem(
        id: 'favorite-1',
        conversationId: conversation.id,
        messageId: conversation.nodes.single.current.id,
        snapshot: '{"title":"Saved conversation"}',
      ),
    );
    await sourceDb.saveMemory(MemoryItem(id: 'memory-1', content: 'Remember this'));
    await sourceDb.recordUsage('model-1', 'Model One', 120, 30, 40);
    await sourceDb.recordAppLaunch();
    final attachment = File('${AppPaths.files.path}/attachment.txt');
    await attachment.parent.create(recursive: true);
    await attachment.writeAsString('saved attachment');

    final bytes = await BackupService(sourceDb).build(settings);
    final archive = ZipDecoder().decodeBytes(bytes);
    expect(archive.findFile('favorites.json'), isNotNull);
    expect(archive.findFile('files/attachment.txt'), isNotNull);
    await sourceDb.close();

    AppPaths.support = destination;
    final destinationDb = await AppDatabase.open('${destination.path}/mewhub.db');
    final restored = await BackupService(destinationDb).restore(bytes, AppSettings.initial());
    expect(restored.currentAssistantId, settings.currentAssistantId);
    expect(restored.chatFolders.single.name, 'Work');
    expect(restored.display.conversationSortByCreation, isTrue);
    expect((await destinationDb.getConversation('chat-1'))?.folder, 'work');
    expect((await destinationDb.favorites()).single.id, 'favorite-1');
    expect((await destinationDb.allMemories()).single.content, 'Remember this');
    expect((await destinationDb.rawUsage()).single['input_tokens'], 120);
    expect((await destinationDb.rawAppLaunches()).single['launches'], 1);
    expect(await File('${AppPaths.files.path}/attachment.txt').readAsString(), 'saved attachment');
    await destinationDb.close();
  });

  test('sanitized backup excludes every credential and keeps local ones on restore', () {
    final initial = AppSettings.initial();
    final provider = initial.providers.firstWhere((item) => item.id == 'p-openai');
    final current = initial.copyWith(
      providers: [
        for (final item in initial.providers) item.id == provider.id ? item.copyWith(apiKey: 'provider-secret') : item,
      ],
      searchServices: [SearchServiceConfig(id: 'search-1', type: SearchServiceType.tavily, apiKey: 'search-secret')],
      mcpServers: [
        McpServerConfig(id: 'mcp-1', url: 'https://mcp.example', headers: {'Authorization': 'mcp-secret'}),
      ],
      webDav: initial.webDav.copyWith(url: 'https://dav.example', password: 'dav-secret'),
      proxies: [ProxyConfig(id: 'proxy-1', url: 'socks5://proxy-secret@host:1080')],
      defaultProxyId: 'proxy-1',
      proxy: 'legacy-secret',
    );

    final payload = jsonEncode(current.toJson(withSecrets: false));
    for (final secret in [
      'provider-secret',
      'search-secret',
      'mcp-secret',
      'dav-secret',
      'proxy-secret',
      'legacy-secret',
    ]) {
      expect(payload, isNot(contains(secret)), reason: '$secret leaked into a sanitized backup');
    }

    final restored = BackupService.preserveLocalSecrets(
      AppSettings.fromJson(jsonDecode(payload) as Map<String, dynamic>),
      current,
    );
    expect(restored.providers.firstWhere((item) => item.id == provider.id).apiKey, 'provider-secret');
    expect(restored.searchServices.single.apiKey, 'search-secret');
    expect(restored.mcpServers.single.headers['Authorization'], 'mcp-secret');
    expect(restored.webDav.password, 'dav-secret');
    expect(restored.proxies.single.url, 'socks5://proxy-secret@host:1080');
    expect(restored.proxy, 'legacy-secret');
  });

  test('restoring without secrets does not transfer credentials across IDs', () {
    final initial = AppSettings.initial();
    final current = initial.copyWith(
      searchServices: [SearchServiceConfig(id: 'old-search', type: SearchServiceType.tavily, apiKey: 'old-key')],
      mcpServers: [
        McpServerConfig(id: 'old-mcp', headers: {'Authorization': 'old-header'}),
      ],
      proxies: [ProxyConfig(id: 'old-proxy', url: 'socks5://old-host:1080')],
    );
    final restored = initial.copyWith(
      searchServices: [SearchServiceConfig(id: 'new-search', type: SearchServiceType.tavily)],
      mcpServers: [McpServerConfig(id: 'new-mcp')],
      proxies: [ProxyConfig(id: 'new-proxy', url: '')],
    );
    final merged = BackupService.preserveLocalSecrets(restored, current);
    expect(merged.searchServices.single.apiKey, isEmpty);
    expect(merged.mcpServers.single.headers, isEmpty);
    expect(merged.proxies.single.url, isEmpty);
  });
}
