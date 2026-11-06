import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../ai/factory.dart';
import '../ai/message.dart';
import '../ai/provider.dart';
import '../ai/provider_config.dart';
import '../core/i18n.dart';
import '../core/net.dart';
import '../core/retry.dart';
import '../data/assistant.dart';
import '../data/conversation.dart';
import '../data/database.dart';
import '../data/models_misc.dart';
import '../data/settings.dart';
import '../state/settings_store.dart';
import '../tools/app_tools.dart';
import '../tools/local_tools.dart';
import '../tools/mcp.dart';
import '../tools/tool.dart';
import 'accumulator.dart';
import 'prompt_builder.dart';

/// Called by the UI to resolve a pending tool approval.
typedef ApprovalDecision = ({String callId, bool approved, String? reason});

/// Owns one open conversation: sending, streaming, tool loop, branches.
class ChatController extends ChangeNotifier {
  ChatController({
    required this.store,
    required this.db,
    required this.mcp,
    required Conversation conversation,
    this.onGenerationDone,
  }) : _conv = conversation;

  final SettingsStore store;
  final AppDatabase db;
  final McpManager mcp;
  final void Function(Conversation c, ChatMessage last)? onGenerationDone;

  Conversation _conv;
  Conversation get conversation => _conv;

  bool _generating = false;
  bool get generating => _generating;
  CancelToken? _cancel;
  String? lastError;

  /// Mode toggles chosen for this chat (in addition to the assistant's).
  Set<String> get modeIds => _conv.modeIds;

  final Map<String, Completer<ApprovalDecision>> _approvals = {};

  bool _disposed = false;
  Timer? _notifyTimer;
  DateTime _lastSave = DateTime.fromMillisecondsSinceEpoch(0);

  AppSettings get settings => store.value;
  Assistant get assistant => settings.assistantById(_conv.assistantId) ?? settings.currentAssistant;

  /// The level last picked in any chat wins over the assistant's stored one.
  ReasoningLevel get reasoning => settings.lastReasoning ?? assistant.reasoning;

  ({ProviderConfig provider, ModelConfig model})? get resolvedModel {
    final s = settings;
    return s.findModel(_conv.modelId) ?? s.findModel(assistant.chatModelId) ?? s.findModel(s.chatModelId);
  }

  // ------------------------------------------------------------------ public

  Future<void> send(List<Part> parts) async {
    if (_generating) return;
    if (parts.isEmpty) return;
    final user = ChatMessage(role: Role.user, parts: parts);
    _conv = _conv.upsertMessage('n-${user.id}', user).copyWith(updatedAt: DateTime.now(), suggestions: const []);
    notifyListeners();
    await _persist(force: true);
    await _generate();
  }

  /// Re-generates the assistant message at [nodeIndex] as a new branch.
  Future<void> regenerate(int nodeIndex) async {
    if (_generating) return;
    final node = _conv.nodes[nodeIndex];
    if (node.role == Role.user) {
      _conv = _conv.truncate(nodeIndex);
      notifyListeners();
      await _generate();
      return;
    }
    _conv = _conv.truncate(nodeIndex);
    notifyListeners();
    await _generate(targetNodeId: node.id);
  }

  /// Edits a user message: adds a new branch at that node and regenerates.
  Future<void> editAndResend(int nodeIndex, List<Part> parts) async {
    if (_generating) return;
    final node = _conv.nodes[nodeIndex];
    final edited = ChatMessage(role: node.role, parts: parts);
    final nodes = [..._conv.nodes.take(nodeIndex), node.upsert(edited)];
    _conv = _conv.copyWith(nodes: nodes, updatedAt: DateTime.now());
    notifyListeners();
    if (node.role == Role.user) {
      await _generate();
    } else {
      await _persist(force: true);
    }
  }

  /// Edits a message in place (no regeneration).
  Future<void> editInPlace(int nodeIndex, List<Part> parts) async {
    final node = _conv.nodes[nodeIndex];
    final updated = node.current.copyWith(parts: parts);
    final list = [..._conv.nodes];
    list[nodeIndex] = node.upsert(updated);
    _conv = _conv.copyWith(nodes: list);
    notifyListeners();
    await _persist(force: true);
  }

  Future<void> selectBranch(int nodeIndex, int branch) async {
    if (_generating) return;
    _conv = _conv.selectBranch(_conv.nodes[nodeIndex].id, branch);
    notifyListeners();
    await _persist(force: true);
  }

  Future<void> deleteNode(int nodeIndex) async {
    if (_generating) return;
    final list = [..._conv.nodes]..removeAt(nodeIndex);
    _conv = _conv.copyWith(nodes: list);
    notifyListeners();
    await _persist(force: true);
  }

  /// Removes only the visible branch at [nodeIndex]; drops the node if it was the last one.
  Future<void> deleteBranch(int nodeIndex) async {
    if (_generating) return;
    final node = _conv.nodes[nodeIndex];
    if (node.messages.length <= 1) return deleteNode(nodeIndex);
    final msgs = [...node.messages]..removeAt(node.selected);
    final list = [..._conv.nodes];
    list[nodeIndex] = node.copyWith(messages: msgs, selected: (node.selected - 1).clamp(0, msgs.length - 1));
    _conv = _conv.copyWith(nodes: list);
    notifyListeners();
    await _persist(force: true);
  }

  void stop() {
    _cancel?.cancel();
    for (final c in _approvals.values) {
      if (!c.isCompleted) c.complete((callId: '', approved: false, reason: 'stopped'));
    }
  }

  void resolveApproval(String callId, bool approved, {String? reason}) {
    final c = _approvals.remove(callId);
    if (c != null && !c.isCompleted) c.complete((callId: callId, approved: approved, reason: reason));
  }

  bool isAwaitingApproval(String callId) => _approvals.containsKey(callId);

  Future<void> setModel(String? modelId) async {
    _conv = _conv.copyWith(modelId: modelId);
    notifyListeners();
    if (_conv.nodes.isNotEmpty) await _persist(force: true);
  }

  Future<void> toggleMode(String id) async {
    final s = {..._conv.modeIds};
    if (!s.add(id)) s.remove(id);
    _conv = _conv.copyWith(modeIds: s);
    notifyListeners();
    if (_conv.nodes.isNotEmpty) await _persist(force: true);
  }

  Future<void> setTitle(String title) async {
    _conv = _conv.copyWith(title: title);
    notifyListeners();
    await _persist(force: true);
  }

  Future<void> setCustomSystemPrompt(String? p) async {
    _conv = _conv.copyWith(customSystemPrompt: (p == null || p.trim().isEmpty) ? null : p);
    notifyListeners();
    if (_conv.nodes.isNotEmpty) await _persist(force: true);
  }

  Future<void> setTranslation(int nodeIndex, String? text) async {
    final node = _conv.nodes[nodeIndex];
    final list = [..._conv.nodes];
    list[nodeIndex] = node.upsert(node.current.copyWith(translation: text));
    _conv = _conv.copyWith(nodes: list);
    notifyListeners();
    await _persist(force: true);
  }

  // ---------------------------------------------------------------- internal

  Future<List<AppTool>> _collectTools(ModelConfig model) async {
    final a = assistant;
    final s = settings;
    final tools = <AppTool>[
      ...buildLocalTools(a.localTools),
      if (a.enableWebSearch && !_useBuiltInSearch(model)) ...buildSearchTools(s),
      if (a.enableMemory) ...buildMemoryTools(db, assistantId: a.useGlobalMemory ? null : a.id),
    ];
    for (final id in a.mcpServerIds) {
      final cfg = s.mcpServers.where((m) => m.id == id && m.enabled).firstOrNull;
      if (cfg == null) continue;
      try {
        final client = await mcp.ensure(cfg);
        for (final t in client.tools) {
          if (cfg.disabledTools.contains(t.name)) continue;
          tools.add(
            AppTool(
              name: _mcpToolName(cfg.name, t.name),
              displayName: '${cfg.name} · ${t.name}',
              description: t.description,
              parameters: t.inputSchema,
              needsApproval: true,
              execute: (args) async {
                final r = await client.callTool(t.name, args);
                return r.isError ? jsonEncode({'error': r.text}) : r.text;
              },
            ),
          );
        }
      } catch (e) {
        debugPrint('MCP ${cfg.name} unavailable: $e');
      }
    }
    return tools;
  }

  static String _mcpToolName(String server, String tool) {
    final s = server.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]+'), '_');
    final n = 'mcp__${s}__$tool'.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return n.length > 64 ? n.substring(0, 64) : n;
  }

  bool _useBuiltInSearch(ModelConfig model) =>
      assistant.enableWebSearch && model.builtInTools.contains(BuiltInTool.search);

  Future<void> _generate({String? targetNodeId}) async {
    final resolved = resolvedModel;
    if (resolved == null) {
      lastError = t('请先在设置里添加供应商并选择模型', 'Add a provider and pick a model in Settings first');
      notifyListeners();
      return;
    }
    final (:provider, :model) = resolved;
    if (provider.keys.isEmpty &&
        !provider.trimmedBaseUrl.contains('127.0.0.1') &&
        !provider.trimmedBaseUrl.contains('localhost')) {
      lastError = t('「${provider.name}」还没有填写 API Key', '"${provider.name}" has no API key yet');
      notifyListeners();
      return;
    }
    _generating = true;
    lastError = null;
    _cancel = CancelToken();
    final cancel = _cancel!;
    final nodeId = targetNodeId ?? 'n-${DateTime.now().microsecondsSinceEpoch}';
    var msg = ChatMessage(role: Role.assistant, parts: const [], modelId: model.id, modelName: model.displayName);
    _conv = _conv.upsertMessage(nodeId, msg);
    notifyListeners();

    final a = assistant;
    final ai = providerFor(provider);
    final tools = model.tools ? await _collectTools(model) : <AppTool>[];
    final toolMap = {for (final t in tools) t.name: t};
    final memories = a.enableMemory
        ? (a.useGlobalMemory ? await db.memories(global: true) : await db.memories(assistantId: a.id))
        : <MemoryItem>[];
    final recent = a.enableRecentChats
        ? (await db.recent(a.id, excludeId: _conv.id, limit: 8)).map((e) => e.title).where((e) => e.isNotEmpty).toList()
        : <String>[];

    final acc = PartAccumulator();
    var totalUsage = const TokenUsage();
    try {
      for (var round = 0; round < 32; round++) {
        final history = [..._conv.currentMessages]..removeLast();
        final prompt = PromptBuilder.build(
          settings: settings,
          assistant: a,
          model: model,
          history: [
            ...history,
            msg.copyWith(parts: acc.parts),
          ],
          customSystemPrompt: _conv.customSystemPrompt,
          extraModeIds: _conv.modeIds,
          memories: memories,
          recentTitles: recent,
        );
        final params = GenerationParams(
          model: model,
          temperature: a.temperature,
          topP: a.topP,
          maxTokens: a.maxTokens,
          reasoning: reasoning,
          tools: tools.map((e) => e.spec).toList(),
          extraHeaders: a.headers,
          extraBodies: a.bodies,
          stream: a.stream,
          useBuiltInSearch: _useBuiltInSearch(model),
          sessionId: _conv.id,
        );
        acc.usage = const TokenUsage();
        await _streamWithRetry(ai, prompt, params, cancel, acc, (parts) {
          msg = msg.copyWith(parts: parts);
          _conv = _conv.upsertMessage(nodeId, msg);
          _scheduleNotify();
        });
        acc.closeAll();
        totalUsage = totalUsage + acc.usage;
        if (!acc.usage.isEmpty) {
          unawaited(db.recordUsage(model.id, model.displayName, acc.usage.input, acc.usage.output, acc.usage.cached));
        }
        final pending = acc.pendingTools;
        if (pending.isEmpty || cancel.isCancelled) break;
        await _runTools(pending, toolMap, acc, a, cancel, (parts) {
          msg = msg.copyWith(parts: parts);
          _conv = _conv.upsertMessage(nodeId, msg);
          _scheduleNotify();
        });
        if (cancel.isCancelled) break;
      }
    } on http.RequestAbortedException {
      // stopped by user
    } catch (e) {
      if (!cancel.isCancelled) lastError = e is ApiException ? e.toString() : '$e';
    } finally {
      acc.closeAll();
      msg = msg.copyWith(
        parts: acc.parts,
        usage: totalUsage.isEmpty ? null : totalUsage,
        finishedAt: DateTime.now(),
        error: lastError,
      );
      _conv = _conv.upsertMessage(nodeId, msg).copyWith(updatedAt: DateTime.now());
      _generating = false;
      _cancel = null;
      _notifyTimer?.cancel();
      if (!_disposed) notifyListeners();
      await _persist(force: true);
      if (lastError == null) onGenerationDone?.call(_conv, msg);
    }
  }

  Future<void> _streamWithRetry(
    AiProvider ai,
    List<ChatMessage> prompt,
    GenerationParams params,
    CancelToken cancel,
    PartAccumulator acc,
    void Function(List<Part>) onUpdate,
  ) async {
    final preferences = settings;
    await for (final chunk in retryStream(
      () => ai.stream(prompt, params, cancel: cancel),
      cancel: cancel,
      settings: preferences.network,
      enabled: preferences.autoRetry,
    )) {
      acc.add(chunk);
      onUpdate(List.unmodifiable(acc.parts));
    }
  }

  Future<void> _runTools(
    List<ToolPart> pending,
    Map<String, AppTool> toolMap,
    PartAccumulator acc,
    Assistant a,
    CancelToken cancel,
    void Function(List<Part>) onUpdate,
  ) async {
    for (final call in pending) {
      if (cancel.isCancelled) return;
      final idx = acc.parts.indexWhere((p) => p is ToolPart && p.callId == call.callId);
      final tool = toolMap[call.name];
      if (tool == null) {
        acc.parts[idx] = call.copyWith(output: jsonEncode({'error': 'Unknown tool ${call.name}'}), isError: true);
        onUpdate(List.unmodifiable(acc.parts));
        continue;
      }
      if (a.toolApproval || tool.needsApproval) {
        acc.parts[idx] = call.copyWith(approval: ToolApproval.pending);
        onUpdate(List.unmodifiable(acc.parts));
        _flushNotify();
        final c = Completer<ApprovalDecision>();
        _approvals[call.callId] = c;
        final d = await c.future;
        if (cancel.isCancelled) return;
        if (!d.approved) {
          acc.parts[idx] = call.copyWith(
            approval: ToolApproval.denied,
            output: jsonEncode({'error': 'User denied this tool call${d.reason == null ? '' : ': ${d.reason}'}'}),
            isError: true,
          );
          onUpdate(List.unmodifiable(acc.parts));
          continue;
        }
        acc.parts[idx] = call.copyWith(approval: ToolApproval.approved);
        onUpdate(List.unmodifiable(acc.parts));
      }
      final current = acc.parts[idx] as ToolPart;
      try {
        final out = await tool.execute(current.inputJson).timeout(const Duration(minutes: 3));
        acc.parts[idx] = current.copyWith(output: out);
      } catch (e) {
        acc.parts[idx] = current.copyWith(output: jsonEncode({'error': e.toString()}), isError: true);
      }
      onUpdate(List.unmodifiable(acc.parts));
    }
  }

  void _scheduleNotify() {
    if (_notifyTimer?.isActive ?? false) return;
    _notifyTimer = Timer(const Duration(milliseconds: 50), _flushNotify);
    if (DateTime.now().difference(_lastSave) > const Duration(seconds: 3)) {
      _lastSave = DateTime.now();
      unawaited(_persist());
    }
  }

  void _flushNotify() {
    _notifyTimer?.cancel();
    if (!_disposed) notifyListeners();
  }

  Future<void> _persist({bool force = false}) async {
    if (_conv.nodes.isEmpty) return;
    try {
      await db.saveConversation(_conv);
    } catch (e) {
      debugPrint('save failed: $e');
    }
  }

  /// Applies an external update (e.g. generated title) to this controller.
  void applyExternal(Conversation Function(Conversation c) fn) {
    _conv = fn(_conv);
    if (!_disposed) notifyListeners();
    unawaited(_persist(force: true));
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    _notifyTimer?.cancel();
    super.dispose();
  }
}
