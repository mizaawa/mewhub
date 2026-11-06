import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ai/message.dart';
import '../chat/chat_controller.dart';
import '../chat/helpers.dart';
import '../data/conversation.dart';
import '../data/chat_folder.dart';
import '../data/database.dart';
import '../tools/mcp.dart';
import 'notifications.dart';
import 'settings_store.dart';

/// App-wide state: database, conversation list and the open chat.
class AppState extends ChangeNotifier {
  AppState({required this.store, required this.db});

  final SettingsStore store;
  final AppDatabase db;
  final McpManager mcp = McpManager();

  List<ConversationSummary> conversations = [];
  Set<String> favoriteIds = {};
  ChatController? _chat;
  ChatController get chat =>
      _chat ??= _newController(Conversation(assistantId: store.value.currentAssistantId, modelId: _lastModelId()));

  /// The model picked last, if it still exists, so new chats carry it over.
  String? _lastModelId() {
    final s = store.value;
    return s.findModel(s.lastChatModelId) == null ? null : s.lastChatModelId;
  }

  /// Bumped whenever the conversation list changes (drawer listens to it).
  final ValueNotifier<int> listRevision = ValueNotifier(0);

  Future<void> init() async {
    await refreshList();
    favoriteIds = await db.favoriteMessageIds();
  }

  ChatController _newController(Conversation c) =>
      ChatController(store: store, db: db, mcp: mcp, conversation: c, onGenerationDone: _afterGeneration);

  Future<void> refreshList() async {
    conversations = await db.listConversations();
    listRevision.value++;
    notifyListeners();
  }

  void newChat({String? assistantId}) {
    final id = assistantId ?? store.value.currentAssistantId;
    if (assistantId != null && assistantId != store.value.currentAssistantId) {
      store.update((s) => s.copyWith(currentAssistantId: assistantId));
    }
    final a = store.value.assistantById(id) ?? store.value.currentAssistant;
    final greeting = a.greeting.trim();
    final conv = Conversation(
      assistantId: a.id,
      modelId: _lastModelId(),
      nodes: greeting.isEmpty
          ? const []
          : [
              MessageNode(messages: [ChatMessage.text(Role.assistant, greeting)]),
            ],
    );
    _swap(_newController(conv));
  }

  Future<void> openConversation(String id) async {
    if (_chat?.conversation.id == id) return;
    final c = await db.getConversation(id);
    if (c == null) return;
    if (c.assistantId != store.value.currentAssistantId && store.value.assistantById(c.assistantId) != null) {
      store.update((s) => s.copyWith(currentAssistantId: c.assistantId));
    }
    _swap(_newController(c));
  }

  void openForked(Conversation c) {
    _swap(_newController(c));
    db.saveConversation(c).then((_) => refreshList());
  }

  void _swap(ChatController next) {
    final old = _chat;
    _chat = next;
    notifyListeners();
    // Let a running generation finish saving before disposing.
    if (old != null) {
      if (old.generating) {
        old.addListener(() {
          if (!old.generating) Future.microtask(old.dispose);
        });
      } else {
        old.dispose();
      }
    }
  }

  Future<void> deleteConversation(String id) async {
    await db.deleteConversation(id);
    if (_chat?.conversation.id == id) newChat();
    await refreshList();
  }

  Future<void> togglePin(String id, bool pinned) async {
    await db.setPinned(id, pinned);
    if (_chat?.conversation.id == id) _chat!.applyExternal((c) => c.copyWith(pinned: pinned));
    await refreshList();
  }

  Future<void> renameConversation(String id, String title) async {
    if (_chat?.conversation.id == id) {
      await _chat!.setTitle(title);
    } else {
      final c = await db.getConversation(id);
      if (c != null) await db.saveConversation(c.copyWith(title: title));
    }
    await refreshList();
  }

  ChatFolder? createChatFolder(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final assistantId = store.value.currentAssistantId;
    if (store.value.chatFolders.any(
      (f) => f.assistantId == assistantId && f.name.toLowerCase() == trimmed.toLowerCase(),
    )) {
      return null;
    }
    final folder = ChatFolder(assistantId: assistantId, name: trimmed);
    store.update((s) => s.copyWith(chatFolders: [...s.chatFolders, folder]));
    return folder;
  }

  bool renameChatFolder(ChatFolder folder, String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty ||
        store.value.chatFolders.any(
          (f) =>
              f.id != folder.id && f.assistantId == folder.assistantId && f.name.toLowerCase() == trimmed.toLowerCase(),
        )) {
      return false;
    }
    store.update(
      (s) =>
          s.copyWith(chatFolders: [for (final f in s.chatFolders) f.id == folder.id ? f.copyWith(name: trimmed) : f]),
    );
    return true;
  }

  Future<bool> deleteChatFolder(ChatFolder folder) async {
    if (_chat?.generating == true && _chat?.conversation.folder == folder.id) return false;
    for (final c in await db.allConversations().toList()) {
      if (c.folder == folder.id) await moveConversationToFolder(c.id, null, refresh: false);
    }
    store.update((s) => s.copyWith(chatFolders: s.chatFolders.where((f) => f.id != folder.id).toList()));
    await refreshList();
    return true;
  }

  Future<void> moveConversationToFolder(String conversationId, String? folderId, {bool refresh = true}) async {
    final c = await db.getConversation(conversationId);
    if (c == null) return;
    final changed = c.copyWith(folder: folderId);
    await db.saveConversation(changed);
    if (_chat?.conversation.id == conversationId) {
      _chat!.applyExternal((_) => changed);
    }
    if (refresh) await refreshList();
  }

  Future<void> toggleFavorite(Conversation c, ChatMessage m) async {
    if (favoriteIds.contains(m.id)) {
      await db.removeFavorite(m.id);
      favoriteIds.remove(m.id);
    } else {
      await db.addFavoriteMessage(c, m);
      favoriteIds.add(m.id);
    }
    notifyListeners();
  }

  Future<void> _afterGeneration(Conversation c, ChatMessage last) async {
    await refreshList();
    final s = store.value;
    if (s.display.notifyOnFinish) {
      unawaited(Notifier.showDone(c.title.isEmpty ? 'MewHub' : c.title, last.text));
    }
    final msgs = c.currentMessages;
    final userTurns = msgs.where((m) => m.role == Role.user).length;
    if (s.autoTitle && (c.title.isEmpty || userTurns == 2)) {
      try {
        final title = await AiHelpers.title(s, msgs, db: db);
        if (title != null && title.isNotEmpty) await _patch(c.id, (x) => x.copyWith(title: title));
      } catch (e) {
        debugPrint('title failed: $e');
      }
    }
    if (s.suggestions) {
      try {
        final sug = await AiHelpers.suggestions(s, msgs, db: db);
        await _patch(c.id, (x) => x.copyWith(suggestions: sug));
      } catch (e) {
        debugPrint('suggestions failed: $e');
      }
    }
  }

  Future<void> _patch(String id, Conversation Function(Conversation) fn) async {
    if (_chat?.conversation.id == id && !(_chat?.generating ?? false)) {
      _chat!.applyExternal(fn);
    } else {
      final c = await db.getConversation(id);
      if (c != null) await db.saveConversation(fn(c));
    }
    await refreshList();
  }

  @override
  void dispose() {
    _chat?.dispose();
    mcp.closeAll();
    super.dispose();
  }
}
