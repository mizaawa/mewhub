import '../ai/message.dart';
import '../ai/provider_config.dart';
import '../core/util.dart';

enum RegexScope { user, assistant }

class AssistantRegex {
  AssistantRegex({
    String? id,
    this.name = '',
    this.enabled = true,
    this.find = '',
    this.replace = '',
    this.scopes = const {RegexScope.assistant},
    this.visualOnly = false,
  }) : id = id ?? newId();

  final String id;
  final String name;
  final bool enabled;
  final String find;
  final String replace;
  final Set<RegexScope> scopes;
  final bool visualOnly;

  AssistantRegex copyWith({
    String? name,
    bool? enabled,
    String? find,
    String? replace,
    Set<RegexScope>? scopes,
    bool? visualOnly,
  }) => AssistantRegex(
    id: id,
    name: name ?? this.name,
    enabled: enabled ?? this.enabled,
    find: find ?? this.find,
    replace: replace ?? this.replace,
    scopes: scopes ?? this.scopes,
    visualOnly: visualOnly ?? this.visualOnly,
  );

  factory AssistantRegex.fromJson(Map<String, dynamic> j) => AssistantRegex(
    id: asStrOrNull(j['id']),
    name: asStr(j['name']),
    enabled: asBool(j['enabled'], true),
    find: asStr(j['find']),
    replace: asStr(j['replace']),
    scopes: enumSet(RegexScope.values, j['scopes']),
    visualOnly: asBool(j['visualOnly']),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'enabled': enabled,
    'find': find,
    'replace': replace,
    'scopes': scopes.map((e) => e.name).toList(),
    'visualOnly': visualOnly,
  };
}

final Map<String, RegExp?> _regexCache = {};

RegExp? _compile(String pattern) => _regexCache.putIfAbsent(pattern, () {
  try {
    return RegExp(pattern, multiLine: true);
  } catch (_) {
    return null;
  }
});

String applyRegexes(String text, List<AssistantRegex> regexes, RegexScope scope, {required bool visual}) {
  var out = text;
  for (final r in regexes) {
    if (!r.enabled || r.visualOnly != visual || !r.scopes.contains(scope) || r.find.isEmpty) continue;
    final re = _compile(r.find);
    if (re == null) continue;
    try {
      out = out.replaceAllMapped(re, (m) {
        return r.replace.replaceAllMapped(RegExp(r'\$(\d+)'), (g) {
          final i = int.parse(g.group(1)!);
          return i <= m.groupCount ? (m.group(i) ?? '') : g.group(0)!;
        });
      });
    } catch (_) {}
  }
  return out;
}

enum InjectPosition { beforeSystem, afterSystem, topOfChat, bottomOfChat, atDepth }

/// A lorebook (world info) entry, triggered by keywords in recent messages.
class LoreEntry {
  LoreEntry({
    String? id,
    this.name = '',
    this.enabled = true,
    this.keywords = const [],
    this.useRegex = false,
    this.caseSensitive = false,
    this.scanDepth = 4,
    this.constant = false,
    this.content = '',
    this.position = InjectPosition.afterSystem,
    this.depth = 4,
    this.priority = 0,
    this.role = Role.user,
  }) : id = id ?? newId();

  final String id;
  final String name;
  final bool enabled;
  final List<String> keywords;
  final bool useRegex;
  final bool caseSensitive;
  final int scanDepth;
  final bool constant;
  final String content;
  final InjectPosition position;
  final int depth;
  final int priority;
  final Role role;

  bool triggered(String context) {
    if (!enabled) return false;
    if (constant) return true;
    for (final k in keywords) {
      if (k.isEmpty) continue;
      if (useRegex) {
        try {
          if (RegExp(k, caseSensitive: caseSensitive).hasMatch(context)) return true;
        } catch (_) {}
      } else if (caseSensitive ? context.contains(k) : context.toLowerCase().contains(k.toLowerCase())) {
        return true;
      }
    }
    return false;
  }

  LoreEntry copyWith({
    String? name,
    bool? enabled,
    List<String>? keywords,
    bool? useRegex,
    bool? caseSensitive,
    int? scanDepth,
    bool? constant,
    String? content,
    InjectPosition? position,
    int? depth,
    int? priority,
    Role? role,
  }) => LoreEntry(
    id: id,
    name: name ?? this.name,
    enabled: enabled ?? this.enabled,
    keywords: keywords ?? this.keywords,
    useRegex: useRegex ?? this.useRegex,
    caseSensitive: caseSensitive ?? this.caseSensitive,
    scanDepth: scanDepth ?? this.scanDepth,
    constant: constant ?? this.constant,
    content: content ?? this.content,
    position: position ?? this.position,
    depth: depth ?? this.depth,
    priority: priority ?? this.priority,
    role: role ?? this.role,
  );

  factory LoreEntry.fromJson(Map<String, dynamic> j) => LoreEntry(
    id: asStrOrNull(j['id']),
    name: asStr(j['name']),
    enabled: asBool(j['enabled'], true),
    keywords: asList(j['keywords']).map((e) => e.toString()).toList(),
    useRegex: asBool(j['useRegex']),
    caseSensitive: asBool(j['caseSensitive']),
    scanDepth: asInt(j['scanDepth'], 4),
    constant: asBool(j['constant']),
    content: asStr(j['content']),
    position: enumByName(InjectPosition.values, j['position'], InjectPosition.afterSystem),
    depth: asInt(j['depth'], 4),
    priority: asInt(j['priority']),
    role: enumByName(Role.values, j['role'], Role.user),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'enabled': enabled,
    'keywords': keywords,
    'useRegex': useRegex,
    'caseSensitive': caseSensitive,
    'scanDepth': scanDepth,
    'constant': constant,
    'content': content,
    'position': position.name,
    'depth': depth,
    'priority': priority,
    'role': role.name,
  };
}

class Lorebook {
  Lorebook({String? id, this.name = '', this.description = '', this.enabled = true, this.entries = const []})
    : id = id ?? newId();

  final String id;
  final String name;
  final String description;
  final bool enabled;
  final List<LoreEntry> entries;

  Lorebook copyWith({String? name, String? description, bool? enabled, List<LoreEntry>? entries}) => Lorebook(
    id: id,
    name: name ?? this.name,
    description: description ?? this.description,
    enabled: enabled ?? this.enabled,
    entries: entries ?? this.entries,
  );

  factory Lorebook.fromJson(Map<String, dynamic> j) => Lorebook(
    id: asStrOrNull(j['id']),
    name: asStr(j['name']),
    description: asStr(j['description']),
    enabled: asBool(j['enabled'], true),
    entries: mapList(j['entries'], LoreEntry.fromJson),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'enabled': enabled,
    'entries': entries.map((e) => e.toJson()).toList(),
  };
}

/// A toggleable prompt snippet ("mode"), e.g. learning mode.
class ModeInjection {
  ModeInjection({
    String? id,
    this.name = '',
    this.content = '',
    this.position = InjectPosition.afterSystem,
    this.depth = 4,
    this.role = Role.user,
  }) : id = id ?? newId();

  final String id;
  final String name;
  final String content;
  final InjectPosition position;
  final int depth;
  final Role role;

  ModeInjection copyWith({String? name, String? content, InjectPosition? position, int? depth, Role? role}) =>
      ModeInjection(
        id: id,
        name: name ?? this.name,
        content: content ?? this.content,
        position: position ?? this.position,
        depth: depth ?? this.depth,
        role: role ?? this.role,
      );

  factory ModeInjection.fromJson(Map<String, dynamic> j) => ModeInjection(
    id: asStrOrNull(j['id']),
    name: asStr(j['name']),
    content: asStr(j['content']),
    position: enumByName(InjectPosition.values, j['position'], InjectPosition.afterSystem),
    depth: asInt(j['depth'], 4),
    role: enumByName(Role.values, j['role'], Role.user),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'content': content,
    'position': position.name,
    'depth': depth,
    'role': role.name,
  };
}

/// Local tools the model may call on-device.
enum LocalTool { timeInfo, clipboard, deviceInfo, calculator }

class Assistant {
  Assistant({
    String? id,
    this.name = '',
    this.avatar = '',
    this.systemPrompt = '',
    this.chatModelId,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.contextMessages = 0,
    this.stream = true,
    this.reasoning = ReasoningLevel.auto,
    this.messageTemplate = '{{message}}',
    this.presetMessages = const [],
    this.regexes = const [],
    this.headers = const [],
    this.bodies = const [],
    this.enableMemory = false,
    this.useGlobalMemory = false,
    this.enableRecentChats = false,
    this.enableWebSearch = false,
    this.localTools = const {LocalTool.timeInfo},
    this.mcpServerIds = const {},
    this.lorebookIds = const {},
    this.modeIds = const {},
    this.quickMessageIds = const {},
    this.background,
    this.backgroundOpacity = 0.35,
    this.tags = const [],
    this.toolApproval = false,
    this.greeting = '',
  }) : id = id ?? newId();

  final String id;
  final String name;

  /// Emoji or sandbox-relative image path. Empty = default glyph.
  final String avatar;
  final String systemPrompt;
  final String? chatModelId;
  final double? temperature;
  final double? topP;
  final int? maxTokens;

  /// Max history messages sent (0 = unlimited).
  final int contextMessages;
  final bool stream;
  final ReasoningLevel reasoning;
  final String messageTemplate;
  final List<ChatMessage> presetMessages;
  final List<AssistantRegex> regexes;
  final List<KeyValue> headers;
  final List<CustomBody> bodies;
  final bool enableMemory;
  final bool useGlobalMemory;
  final bool enableRecentChats;
  final bool enableWebSearch;
  final Set<LocalTool> localTools;
  final Set<String> mcpServerIds;
  final Set<String> lorebookIds;
  final Set<String> modeIds;
  final Set<String> quickMessageIds;
  final String? background;
  final double backgroundOpacity;
  final List<String> tags;

  /// Ask user before running any tool.
  final bool toolApproval;

  /// First assistant message shown in new chats (character card `first_mes`).
  final String greeting;

  bool get avatarIsImage => avatar.contains('/') || avatar.contains('.');

  Assistant copyWith({
    String? name,
    String? avatar,
    String? systemPrompt,
    Object? chatModelId = _keep,
    Object? temperature = _keep,
    Object? topP = _keep,
    Object? maxTokens = _keep,
    int? contextMessages,
    bool? stream,
    ReasoningLevel? reasoning,
    String? messageTemplate,
    List<ChatMessage>? presetMessages,
    List<AssistantRegex>? regexes,
    List<KeyValue>? headers,
    List<CustomBody>? bodies,
    bool? enableMemory,
    bool? useGlobalMemory,
    bool? enableRecentChats,
    bool? enableWebSearch,
    Set<LocalTool>? localTools,
    Set<String>? mcpServerIds,
    Set<String>? lorebookIds,
    Set<String>? modeIds,
    Set<String>? quickMessageIds,
    Object? background = _keep,
    double? backgroundOpacity,
    List<String>? tags,
    bool? toolApproval,
    String? greeting,
    String? id,
  }) => Assistant(
    id: id ?? this.id,
    name: name ?? this.name,
    avatar: avatar ?? this.avatar,
    systemPrompt: systemPrompt ?? this.systemPrompt,
    chatModelId: identical(chatModelId, _keep) ? this.chatModelId : chatModelId as String?,
    temperature: identical(temperature, _keep) ? this.temperature : temperature as double?,
    topP: identical(topP, _keep) ? this.topP : topP as double?,
    maxTokens: identical(maxTokens, _keep) ? this.maxTokens : maxTokens as int?,
    contextMessages: contextMessages ?? this.contextMessages,
    stream: stream ?? this.stream,
    reasoning: reasoning ?? this.reasoning,
    messageTemplate: messageTemplate ?? this.messageTemplate,
    presetMessages: presetMessages ?? this.presetMessages,
    regexes: regexes ?? this.regexes,
    headers: headers ?? this.headers,
    bodies: bodies ?? this.bodies,
    enableMemory: enableMemory ?? this.enableMemory,
    useGlobalMemory: useGlobalMemory ?? this.useGlobalMemory,
    enableRecentChats: enableRecentChats ?? this.enableRecentChats,
    enableWebSearch: enableWebSearch ?? this.enableWebSearch,
    localTools: localTools ?? this.localTools,
    mcpServerIds: mcpServerIds ?? this.mcpServerIds,
    lorebookIds: lorebookIds ?? this.lorebookIds,
    modeIds: modeIds ?? this.modeIds,
    quickMessageIds: quickMessageIds ?? this.quickMessageIds,
    background: identical(background, _keep) ? this.background : background as String?,
    backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
    tags: tags ?? this.tags,
    toolApproval: toolApproval ?? this.toolApproval,
    greeting: greeting ?? this.greeting,
  );

  factory Assistant.fromJson(Map<String, dynamic> j) => Assistant(
    id: asStrOrNull(j['id']),
    name: asStr(j['name']),
    avatar: asStr(j['avatar']),
    systemPrompt: asStr(j['systemPrompt']),
    chatModelId: asStrOrNull(j['chatModelId']),
    temperature: asDoubleOrNull(j['temperature']),
    topP: asDoubleOrNull(j['topP']),
    maxTokens: asIntOrNull(j['maxTokens']),
    contextMessages: asInt(j['contextMessages']),
    stream: asBool(j['stream'], true),
    reasoning: enumByName(ReasoningLevel.values, j['reasoning'], ReasoningLevel.auto),
    messageTemplate: asStr(j['messageTemplate'], '{{message}}'),
    presetMessages: mapList(j['presetMessages'], ChatMessage.fromJson),
    regexes: mapList(j['regexes'], AssistantRegex.fromJson),
    headers: mapList(j['headers'], KeyValue.fromJson),
    bodies: mapList(j['bodies'], CustomBody.fromJson),
    enableMemory: asBool(j['enableMemory']),
    useGlobalMemory: asBool(j['useGlobalMemory']),
    enableRecentChats: asBool(j['enableRecentChats']),
    enableWebSearch: asBool(j['enableWebSearch']),
    localTools: j['localTools'] == null ? {LocalTool.timeInfo} : enumSet(LocalTool.values, j['localTools']),
    mcpServerIds: asList(j['mcpServerIds']).map((e) => e.toString()).toSet(),
    lorebookIds: asList(j['lorebookIds']).map((e) => e.toString()).toSet(),
    modeIds: asList(j['modeIds']).map((e) => e.toString()).toSet(),
    quickMessageIds: asList(j['quickMessageIds']).map((e) => e.toString()).toSet(),
    background: asStrOrNull(j['background']),
    backgroundOpacity: asDouble(j['backgroundOpacity'], 0.35),
    tags: asList(j['tags']).map((e) => e.toString()).toList(),
    toolApproval: asBool(j['toolApproval']),
    greeting: asStr(j['greeting']),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'avatar': avatar,
    'systemPrompt': systemPrompt,
    'chatModelId': chatModelId,
    'temperature': temperature,
    'topP': topP,
    'maxTokens': maxTokens,
    'contextMessages': contextMessages,
    'stream': stream,
    'reasoning': reasoning.name,
    'messageTemplate': messageTemplate,
    'presetMessages': presetMessages.map((e) => e.toJson()).toList(),
    'regexes': regexes.map((e) => e.toJson()).toList(),
    'headers': headers.map((e) => e.toJson()).toList(),
    'bodies': bodies.map((e) => e.toJson()).toList(),
    'enableMemory': enableMemory,
    'useGlobalMemory': useGlobalMemory,
    'enableRecentChats': enableRecentChats,
    'enableWebSearch': enableWebSearch,
    'localTools': localTools.map((e) => e.name).toList(),
    'mcpServerIds': mcpServerIds.toList(),
    'lorebookIds': lorebookIds.toList(),
    'modeIds': modeIds.toList(),
    'quickMessageIds': quickMessageIds.toList(),
    'background': background,
    'backgroundOpacity': backgroundOpacity,
    'tags': tags,
    'toolApproval': toolApproval,
    'greeting': greeting,
  };
}

class QuickMessage {
  QuickMessage({String? id, this.title = '', this.content = ''}) : id = id ?? newId();
  final String id;
  final String title;
  final String content;

  factory QuickMessage.fromJson(Map<String, dynamic> j) =>
      QuickMessage(id: asStrOrNull(j['id']), title: asStr(j['title']), content: asStr(j['content']));
  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'content': content};
}

const _keep = Object();
