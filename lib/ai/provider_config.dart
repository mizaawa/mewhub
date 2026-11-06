import '../core/util.dart';

/// Wire protocol spoken by a provider.
enum ProviderKind {
  openai('https://api.openai.com/v1'),
  anthropic('https://api.anthropic.com/v1'),
  google('https://generativelanguage.googleapis.com/v1beta');

  const ProviderKind(this.defaultBaseUrl);
  final String defaultBaseUrl;
}

enum ModelType { chat, image, embedding }

enum Modality { text, image }

enum ModelAbility { tool, reasoning }

enum BuiltInTool { search, urlContext }

enum ReasoningLevel {
  off(0, 'none'),
  auto(-1, 'auto'),
  low(1024, 'low'),
  medium(4096, 'medium'),
  high(16384, 'high'),
  xhigh(24576, 'xhigh'),
  max(32768, 'max');

  const ReasoningLevel(this.budget, this.effort);
  final int budget;
  final String effort;

  bool get enabled => this != off;

  /// Levels offered in the UI, weakest to strongest. [off] is internal only
  /// (background helpers such as title generation).
  static const selectable = [auto, low, medium, high, xhigh, max];

  /// Old settings may still hold [off]; the UI no longer offers it.
  static ReasoningLevel fromName(Object? name) {
    for (final l in values) {
      if (l.name == name) return l == off ? auto : l;
    }
    return auto;
  }
}

/// `reasoning.effort` / `reasoning_effort` for OpenAI-style models.
/// Older GPT models reject `xhigh` / `max`, so those step down to the
/// strongest level the model family is known to accept.
String openAiEffort(String modelId, ReasoningLevel level) {
  if (level != ReasoningLevel.xhigh && level != ReasoningLevel.max) return level.effort;
  final id = modelId.toLowerCase();
  if (id.contains('claude')) return anthropicEffort(modelId, level);
  final m = RegExp(r'gpt-(\d+)(?:\.(\d+))?').firstMatch(id);
  if (m == null) return 'high';
  final v = int.parse(m.group(1)!) * 100 + int.parse(m.group(2) ?? '0');
  final xhigh = v >= 502 || id.contains('codex-max');
  final max = v >= 506;
  if (level == ReasoningLevel.max && max) return 'max';
  return xhigh ? 'xhigh' : 'high';
}

/// `output_config.effort` for Claude. Opus 4.5 has neither `xhigh` nor `max`;
/// Opus / Sonnet 4.6 have `max` but not `xhigh`.
String anthropicEffort(String modelId, ReasoningLevel level) {
  final id = modelId.toLowerCase();
  if (RegExp(r'(opus|sonnet)-4-5').hasMatch(id)) {
    return level.index > ReasoningLevel.high.index ? 'high' : level.effort;
  }
  if (level == ReasoningLevel.xhigh && RegExp(r'(opus|sonnet)-4-6').hasMatch(id)) return 'high';
  return level.effort;
}

class KeyValue {
  const KeyValue(this.key, this.value);
  final String key;
  final String value;

  factory KeyValue.fromJson(Map<String, dynamic> j) => KeyValue(asStr(j['k']), asStr(j['v']));
  Map<String, dynamic> toJson() => {'k': key, 'v': value};
}

/// A custom JSON body override; [value] is raw JSON text (e.g. `{"top_k": 20}` or `0.5`).
class CustomBody {
  const CustomBody(this.key, this.value);
  final String key;
  final String value;

  /// The JSON value, or the raw text when it isn't valid JSON.
  /// A literal `null` yields Dart null, which removes the key.
  dynamic get parsed {
    final s = value.trim();
    if (s == 'null') return null;
    final v = tryJsonDecode(s);
    return v ?? value;
  }

  factory CustomBody.fromJson(Map<String, dynamic> j) => CustomBody(asStr(j['k']), asStr(j['v']));
  Map<String, dynamic> toJson() => {'k': key, 'v': value};
}

class ModelConfig {
  ModelConfig({
    String? id,
    required this.modelId,
    String? displayName,
    this.type = ModelType.chat,
    this.input = const {Modality.text},
    this.output = const {Modality.text},
    this.abilities = const {},
    this.builtInTools = const {},
    this.headers = const [],
    this.bodies = const [],
    this.contextLength = 128000,
  }) : id = id ?? newId(),
       displayName = (displayName == null || displayName.isEmpty) ? modelId : displayName;

  final String id;
  final String modelId;
  final String displayName;
  final ModelType type;
  final Set<Modality> input;
  final Set<Modality> output;
  final Set<ModelAbility> abilities;
  final Set<BuiltInTool> builtInTools;
  final List<KeyValue> headers;
  final List<CustomBody> bodies;
  final int contextLength;

  bool get vision => input.contains(Modality.image);
  bool get tools => abilities.contains(ModelAbility.tool);
  bool get reasoning => abilities.contains(ModelAbility.reasoning);
  bool get imageOutput => output.contains(Modality.image);

  ModelConfig copyWith({
    String? modelId,
    String? displayName,
    ModelType? type,
    Set<Modality>? input,
    Set<Modality>? output,
    Set<ModelAbility>? abilities,
    Set<BuiltInTool>? builtInTools,
    List<KeyValue>? headers,
    List<CustomBody>? bodies,
    int? contextLength,
  }) => ModelConfig(
    id: id,
    modelId: modelId ?? this.modelId,
    displayName: displayName ?? this.displayName,
    type: type ?? this.type,
    input: input ?? this.input,
    output: output ?? this.output,
    abilities: abilities ?? this.abilities,
    builtInTools: builtInTools ?? this.builtInTools,
    headers: headers ?? this.headers,
    bodies: bodies ?? this.bodies,
    contextLength: contextLength ?? this.contextLength,
  );

  factory ModelConfig.fromJson(Map<String, dynamic> j) => ModelConfig(
    id: asStrOrNull(j['id']),
    modelId: asStr(j['modelId']),
    displayName: asStrOrNull(j['displayName']),
    type: enumByName(ModelType.values, j['type'], ModelType.chat),
    input: j['input'] == null ? {Modality.text} : enumSet(Modality.values, j['input']),
    output: j['output'] == null ? {Modality.text} : enumSet(Modality.values, j['output']),
    abilities: enumSet(ModelAbility.values, j['abilities']),
    builtInTools: enumSet(BuiltInTool.values, j['builtInTools']),
    headers: mapList(j['headers'], KeyValue.fromJson),
    bodies: mapList(j['bodies'], CustomBody.fromJson),
    contextLength: asInt(j['contextLength'], 128000),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'modelId': modelId,
    'displayName': displayName,
    'type': type.name,
    'input': input.map((e) => e.name).toList(),
    'output': output.map((e) => e.name).toList(),
    'abilities': abilities.map((e) => e.name).toList(),
    'builtInTools': builtInTools.map((e) => e.name).toList(),
    'headers': headers.map((e) => e.toJson()).toList(),
    'bodies': bodies.map((e) => e.toJson()).toList(),
    'contextLength': contextLength,
  };
}

class ProviderConfig {
  ProviderConfig({
    String? id,
    required this.kind,
    required this.name,
    this.enabled = true,
    this.apiKey = '',
    required this.baseUrl,
    this.models = const [],
    this.headers = const [],
    this.useResponsesApi = false,
    this.chatPath = '/chat/completions',
    this.responsesPath = '/responses',
    this.includeHistoryReasoning = true,
    this.promptCaching = false,
    this.vertex = false,
    this.balanceUrl = '',
    this.balancePath = '',
    this.builtIn = false,
  }) : id = id ?? newId();

  final String id;
  final ProviderKind kind;
  final String name;
  final bool enabled;

  /// May contain multiple keys separated by commas / newlines; a key is
  /// picked round-robin per request.
  final String apiKey;
  final String baseUrl;
  final List<ModelConfig> models;
  final List<KeyValue> headers;

  // OpenAI-compatible
  final bool useResponsesApi;
  final String chatPath;
  final String responsesPath;
  final bool includeHistoryReasoning;

  // Anthropic
  final bool promptCaching;

  // Google
  final bool vertex;

  /// Optional balance query: GET [balanceUrl] (supports `{{baseUrl}}`), read value at
  /// dot path [balancePath] (e.g. `data.total_balance`).
  final String balanceUrl;
  final String balancePath;

  final bool builtIn;

  List<String> get keys => apiKey.split(RegExp(r'[\s,]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  String get protocolLabel => switch (kind) {
    ProviderKind.openai => useResponsesApi ? 'OpenAI Responses' : 'OpenAI Chat',
    ProviderKind.anthropic => 'Anthropic Messages',
    ProviderKind.google => vertex ? 'Vertex AI' : 'Google Gemini',
  };

  String get trimmedBaseUrl => baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

  ModelConfig? findModel(String id) {
    for (final m in models) {
      if (m.id == id) return m;
    }
    return null;
  }

  ProviderConfig copyWith({
    ProviderKind? kind,
    String? name,
    bool? enabled,
    String? apiKey,
    String? baseUrl,
    List<ModelConfig>? models,
    List<KeyValue>? headers,
    bool? useResponsesApi,
    String? chatPath,
    String? responsesPath,
    bool? includeHistoryReasoning,
    bool? promptCaching,
    bool? vertex,
    String? balanceUrl,
    String? balancePath,
    String? id,
  }) => ProviderConfig(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    name: name ?? this.name,
    enabled: enabled ?? this.enabled,
    apiKey: apiKey ?? this.apiKey,
    baseUrl: baseUrl ?? this.baseUrl,
    models: models ?? this.models,
    headers: headers ?? this.headers,
    useResponsesApi: useResponsesApi ?? this.useResponsesApi,
    chatPath: chatPath ?? this.chatPath,
    responsesPath: responsesPath ?? this.responsesPath,
    includeHistoryReasoning: includeHistoryReasoning ?? this.includeHistoryReasoning,
    promptCaching: promptCaching ?? this.promptCaching,
    vertex: vertex ?? this.vertex,
    balanceUrl: balanceUrl ?? this.balanceUrl,
    balancePath: balancePath ?? this.balancePath,
    builtIn: builtIn,
  );

  factory ProviderConfig.fromJson(Map<String, dynamic> j) => ProviderConfig(
    id: asStrOrNull(j['id']),
    kind: enumByName(ProviderKind.values, j['kind'], ProviderKind.openai),
    name: asStr(j['name'], 'Provider'),
    enabled: asBool(j['enabled'], true),
    apiKey: asStr(j['apiKey']),
    baseUrl: asStr(j['baseUrl']),
    models: mapList(j['models'], ModelConfig.fromJson),
    headers: mapList(j['headers'], KeyValue.fromJson),
    useResponsesApi: asBool(j['useResponsesApi']),
    chatPath: asStr(j['chatPath'], '/chat/completions'),
    responsesPath: asStr(j['responsesPath'], '/responses'),
    includeHistoryReasoning: asBool(j['includeHistoryReasoning'], true),
    promptCaching: asBool(j['promptCaching']),
    vertex: asBool(j['vertex']),
    balanceUrl: asStr(j['balanceUrl']),
    balancePath: asStr(j['balancePath']),
    builtIn: asBool(j['builtIn']),
  );

  /// [withSecrets] = false strips the API key (for share codes without keys).
  Map<String, dynamic> toJson({bool withSecrets = true, bool withModels = true}) => {
    'id': id,
    'kind': kind.name,
    'name': name,
    'enabled': enabled,
    'apiKey': withSecrets ? apiKey : '',
    'baseUrl': baseUrl,
    if (withModels) 'models': models.map((e) => e.toJson()).toList(),
    'headers': headers.map((e) => e.toJson()).toList(),
    'useResponsesApi': useResponsesApi,
    'chatPath': chatPath,
    'responsesPath': responsesPath,
    'includeHistoryReasoning': includeHistoryReasoning,
    'promptCaching': promptCaching,
    'vertex': vertex,
    'balanceUrl': balanceUrl,
    'balancePath': balancePath,
    'builtIn': builtIn,
  };
}
