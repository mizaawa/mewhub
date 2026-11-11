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
import 'auto_compression.dart';
import 'helpers.dart';
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
    this.onGenerationStarted,
    this.onGenerationSettled,
  }) : _conv = conversation;

  final SettingsStore store;
  final AppDatabase db;
  final McpManager mcp;
  final void Function(Conversation c, ChatMessage last)? onGenerationDone;
  final Future<void> Function(Conversation c)? onGenerationStarted;
  final Future<void> Function(Conversation c)? onGenerationSettled;

  Conversation _conv;
  Conversation get conversation => _conv;

  bool _generating = false;
  bool get generating => _generating;
  CancelToken? _cancel;
  Completer<void>? _idle;
  Future<void> get whenIdle => _idle?.future ?? Future<void>.value();
  String? lastError;

  /// Set when the user pressed stop, so the partial reply is kept as history
  /// instead of being discarded.
  bool _stoppedByUser = false;

  /// Bumped for every generation. A stream whose epoch is stale has been
  /// superseded (edit, regenerate, new turn) and must not write back into the
  /// conversation, or it would resurrect or overwrite a newer turn.
  int _epoch = 0;

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
  ///
  /// An edit always wins over a reply that is still streaming: the stream is
  /// cancelled and allowed to settle first, so the edit cannot be swallowed by
  /// the `_generating` guard and its result cannot be overwritten afterwards.
  /// The node is re-located by [messageId] after waiting, because the
  /// conversation may have grown while the editor was open.
  Future<void> editAndResend(String messageId, List<Part> parts) async {
    await _interrupt();
    final index = _conv.indexOfMessage(messageId);
    if (index < 0) return;
    final node = _conv.nodes[index];
    final edited = ChatMessage(id: messageId, role: node.current.role, parts: parts, createdAt: node.current.createdAt);
    final nodes = [..._conv.nodes.take(index), node.upsert(edited)];
    _conv = _conv.copyWith(nodes: nodes, updatedAt: DateTime.now());
    notifyListeners();
    if (node.role == Role.user) {
      await _generate();
    } else {
      await _persist(force: true);
    }
  }

  /// Edits a message in place (no regeneration).
  Future<void> editInPlace(String messageId, List<Part> parts) async {
    await _interrupt();
    final index = _conv.indexOfMessage(messageId);
    if (index < 0) return;
    final node = _conv.nodes[index];
    final updated = node.current.copyWith(parts: parts, interrupted: false);
    final list = [..._conv.nodes];
    list[index] = node.upsert(updated);
    _conv = _conv.copyWith(nodes: list);
    notifyListeners();
    await _persist(force: true);
  }

  /// Cancels any in-flight generation and waits until it has settled, so the
  /// conversation is stable before the caller mutates it.
  Future<void> _interrupt() async {
    if (!_generating) return;
    _cancel?.cancel();
    await whenIdle;
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
    if (!_generating) return;
    // Remember that this was an explicit stop: the text received so far stays
    // on screen and stays in the context sent to the model.
    _stoppedByUser = true;
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
    final servers = [
      for (final m in s.mcpServers)
        if (m.enabled && a.mcpServerIds.contains(m.id)) m,
    ];
    // Connect in parallel so one slow server cannot hold up the reply for long.
    final clients = await Future.wait([
      for (final cfg in servers)
        mcp.ensure(cfg).then<McpClient?>((c) => c).timeout(const Duration(seconds: 20)).catchError((Object e) {
          debugPrint('MCP ${cfg.name} unavailable: $e');
          return null;
        }),
    ]);
    final names = {for (final t in tools) t.name};
    for (var i = 0; i < servers.length; i++) {
      final cfg = servers[i];
      final client = clients[i];
      if (client == null) continue;
      for (final t in client.tools) {
        if (cfg.disabledTools.contains(t.name)) continue;
        final name = uniqueToolName(mcpToolName(cfg.name, t.name), names);
        names.add(name);
        tools.add(
          AppTool(
            name: name,
            displayName: '${cfg.name} · ${t.name}',
            description: t.description.trim().isEmpty ? 'Tool "${t.name}" from MCP server ${cfg.name}' : t.description,
            parameters: normalizeToolSchema(t.inputSchema),
            needsApproval: true,
            execute: (args) async {
              // Resolve the live client: the server may have reconnected since.
              final current = settings.mcpServers.where((m) => m.id == cfg.id).firstOrNull ?? cfg;
              final live = await mcp.ensure(current);
              final r = await live.callTool(t.name, args);
              return r.isError ? jsonEncode({'error': r.text}) : r.text;
            },
          ),
        );
      }
    }
    return tools;
  }

  /// `mcp__<server>__<tool>`, restricted to the characters every provider accepts.
  @visibleForTesting
  static String mcpToolName(String server, String tool) {
    final s = server.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]+'), '_');
    final n = 'mcp__${s}__$tool'.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return n.length > 64 ? n.substring(0, 64) : n;
  }

  /// Providers reject duplicate function names; long names can collide after truncation.
  @visibleForTesting
  static String uniqueToolName(String name, Set<String> taken) {
    if (!taken.contains(name)) return name;
    for (var i = 2; ; i++) {
      final suffix = '_$i';
      final base = name.length + suffix.length > 64 ? name.substring(0, 64 - suffix.length) : name;
      if (!taken.contains('$base$suffix')) return '$base$suffix';
    }
  }

  bool _useBuiltInSearch(ModelConfig model) =>
      assistant.enableWebSearch && model.builtInTools.contains(BuiltInTool.search);

  Future<void> _generate({String? targetNodeId}) async {
    if (_disposed || _generating) return;
    _generating = true;
    _epoch++;
    final epoch = _epoch;
    _stoppedByUser = false;
    lastError = null;
    final cancel = _cancel = CancelToken();
    final idle = _idle = Completer<void>();
    notifyListeners();
    try {
      await _persist(force: true);
      try {
        await onGenerationStarted?.call(_conv);
      } catch (e) {
        debugPrint('Unable to start background generation: $e');
      }
      if (!cancel.isCancelled && !_disposed) await _generateResponse(targetNodeId: targetNodeId, epoch: epoch);
    } catch (e) {
      if (!cancel.isCancelled) lastError = '$e';
    } finally {
      await _persist(force: true);
      _generating = false;
      _cancel = null;
      try {
        await onGenerationSettled?.call(_conv);
      } catch (e) {
        debugPrint('Background generation release failed: $e');
      }
      _notifyTimer?.cancel();
      if (!_disposed) notifyListeners();
      idle.complete();
    }
  }

  Future<void> _generateResponse({String? targetNodeId, required int epoch}) async {
    bool live() => epoch == _epoch && !_disposed;
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
    final autoCompression = settings.autoCompress && targetNodeId == null
        ? AutoCompressionPlan.forConversation(
            _conv,
            model.contextLength,
            thresholdPercent: settings.autoCompressThreshold,
          )
        : null;
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
        ? await memoriesForPrompt(db, assistantId: a.useGlobalMemory ? null : a.id)
        : <MemoryItem>[];
    final recent = a.enableRecentChats
        ? (await db.recent(a.id, excludeId: _conv.id, limit: 8)).map((e) => e.title).where((e) => e.isNotEmpty).toList()
        : <String>[];

    final acc = PartAccumulator();
    var totalUsage = const TokenUsage();
    try {
      if (autoCompression != null && !cancel.isCancelled) {
        try {
          await _autoCompress(autoCompression, model.id, cancel);
        } catch (e) {
          debugPrint('Automatic context compression failed: $e');
        }
      }
      for (var round = 0; round < 32; round++) {
        if (cancel.isCancelled) break;
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
          if (!live()) return;
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
          if (!live()) return;
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
      // A superseded stream (edit, regenerate, new turn) must not write back:
      // its node may already have been replaced by a newer generation.
      if (live()) {
        // A stopped turn keeps whatever arrived: the text stays on screen and
        // in the next prompt, only its `interrupted` flag marks it cut short.
        // If nothing arrived yet there is nothing to keep, so the placeholder
        // is dropped instead of leaving an empty bubble in history.
        final stopped = _stoppedByUser && cancel.isCancelled;
        final empty = acc.parts.every((p) => p is ReasoningPart || (p is TextPart && p.text.trim().isEmpty));
        if (stopped && empty) {
          _conv = _conv.copyWith(nodes: [..._conv.nodes.where((n) => n.id != nodeId)]);
        } else {
          msg = msg.copyWith(
            parts: acc.parts,
            usage: totalUsage.isEmpty ? null : totalUsage,
            finishedAt: DateTime.now(),
            error: stopped ? null : lastError,
            interrupted: stopped,
          );
          _conv = _conv.upsertMessage(nodeId, msg).copyWith(updatedAt: DateTime.now());
        }
        await _persist(force: true);
        if (lastError == null && !cancel.isCancelled) onGenerationDone?.call(_conv, msg);
      }
    }
  }

  Future<void> _autoCompress(AutoCompressionPlan plan, String modelId, CancelToken cancel) async {
    final nodes = _conv.nodes;
    final endNodeId = nodes[plan.endIndex].id;
    final history = [for (final node in nodes.sublist(plan.startIndex, plan.endIndex + 1)) node.current];
    final summary = await AiHelpers.compress(settings, modelId, history, cancel: cancel, db: db);
    if (cancel.isCancelled || summary.trim().isEmpty) return;

    final updated = insertCompressionCheckpoint(_conv, endNodeId, summary);
    if (identical(updated, _conv)) return;
    _conv = updated;
    if (!_disposed) notifyListeners();
    await _persist(force: true);
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
