import '../ai/provider_config.dart';
import '../core/i18n.dart';
import '../core/util.dart';
import 'assistant.dart';
import 'defaults.dart';
import 'models_misc.dart';
import 'network_settings.dart';
import 'proxy_config.dart';

enum ThemeModePref { system, light, dark }

enum ChatFont { system, serif, mono }

class DisplaySettings {
  const DisplaySettings({
    this.userName = '',
    this.userAvatar = '',
    this.showUserAvatar = true,
    this.showModelName = true,
    this.showTokenUsage = true,
    this.showTimestamps = false,
    this.showThinking = true,
    this.autoCollapseThinking = true,
    this.fontScale = 1.0,
    this.chatFont = ChatFont.system,
    this.sendOnEnter = false,
    this.haptics = true,
    this.autoScroll = true,
    this.latex = true,
    this.codeWrap = false,
    this.codeLineNumbers = false,
    this.bubbleAssistant = false,
    this.showMessageJumper = true,
    this.notifyOnFinish = false,
    this.autoPlayTts = false,
    this.pasteLongTextAsFile = false,
    this.longTextThreshold = 2000,
  });

  final String userName;
  final String userAvatar;
  final bool showUserAvatar;
  final bool showModelName;
  final bool showTokenUsage;
  final bool showTimestamps;
  final bool showThinking;
  final bool autoCollapseThinking;
  final double fontScale;
  final ChatFont chatFont;
  final bool sendOnEnter;
  final bool haptics;
  final bool autoScroll;
  final bool latex;
  final bool codeWrap;
  final bool codeLineNumbers;
  final bool bubbleAssistant;
  final bool showMessageJumper;
  final bool notifyOnFinish;
  final bool autoPlayTts;
  final bool pasteLongTextAsFile;
  final int longTextThreshold;

  DisplaySettings copyWith({
    String? userName,
    String? userAvatar,
    bool? showUserAvatar,
    bool? showModelName,
    bool? showTokenUsage,
    bool? showTimestamps,
    bool? showThinking,
    bool? autoCollapseThinking,
    double? fontScale,
    ChatFont? chatFont,
    bool? sendOnEnter,
    bool? haptics,
    bool? autoScroll,
    bool? latex,
    bool? codeWrap,
    bool? codeLineNumbers,
    bool? bubbleAssistant,
    bool? showMessageJumper,
    bool? notifyOnFinish,
    bool? autoPlayTts,
    bool? pasteLongTextAsFile,
    int? longTextThreshold,
  }) => DisplaySettings(
    userName: userName ?? this.userName,
    userAvatar: userAvatar ?? this.userAvatar,
    showUserAvatar: showUserAvatar ?? this.showUserAvatar,
    showModelName: showModelName ?? this.showModelName,
    showTokenUsage: showTokenUsage ?? this.showTokenUsage,
    showTimestamps: showTimestamps ?? this.showTimestamps,
    showThinking: showThinking ?? this.showThinking,
    autoCollapseThinking: autoCollapseThinking ?? this.autoCollapseThinking,
    fontScale: fontScale ?? this.fontScale,
    chatFont: chatFont ?? this.chatFont,
    sendOnEnter: sendOnEnter ?? this.sendOnEnter,
    haptics: haptics ?? this.haptics,
    autoScroll: autoScroll ?? this.autoScroll,
    latex: latex ?? this.latex,
    codeWrap: codeWrap ?? this.codeWrap,
    codeLineNumbers: codeLineNumbers ?? this.codeLineNumbers,
    bubbleAssistant: bubbleAssistant ?? this.bubbleAssistant,
    showMessageJumper: showMessageJumper ?? this.showMessageJumper,
    notifyOnFinish: notifyOnFinish ?? this.notifyOnFinish,
    autoPlayTts: autoPlayTts ?? this.autoPlayTts,
    pasteLongTextAsFile: pasteLongTextAsFile ?? this.pasteLongTextAsFile,
    longTextThreshold: longTextThreshold ?? this.longTextThreshold,
  );

  factory DisplaySettings.fromJson(Map<String, dynamic> j) => DisplaySettings(
    userName: asStr(j['userName']),
    userAvatar: asStr(j['userAvatar']),
    showUserAvatar: asBool(j['showUserAvatar'], true),
    showModelName: asBool(j['showModelName'], true),
    showTokenUsage: asBool(j['showTokenUsage'], true),
    showTimestamps: asBool(j['showTimestamps']),
    showThinking: asBool(j['showThinking'], true),
    autoCollapseThinking: asBool(j['autoCollapseThinking'], true),
    fontScale: asDouble(j['fontScale'], 1.0),
    chatFont: enumByName(ChatFont.values, j['chatFont'], ChatFont.system),
    sendOnEnter: asBool(j['sendOnEnter']),
    haptics: asBool(j['haptics'], true),
    autoScroll: asBool(j['autoScroll'], true),
    latex: asBool(j['latex'], true),
    codeWrap: asBool(j['codeWrap']),
    codeLineNumbers: asBool(j['codeLineNumbers']),
    bubbleAssistant: asBool(j['bubbleAssistant']),
    showMessageJumper: asBool(j['showMessageJumper'], true),
    notifyOnFinish: asBool(j['notifyOnFinish']),
    autoPlayTts: asBool(j['autoPlayTts']),
    pasteLongTextAsFile: asBool(j['pasteLongTextAsFile']),
    longTextThreshold: asInt(j['longTextThreshold'], 2000),
  );

  Map<String, dynamic> toJson() => {
    'userName': userName,
    'userAvatar': userAvatar,
    'showUserAvatar': showUserAvatar,
    'showModelName': showModelName,
    'showTokenUsage': showTokenUsage,
    'showTimestamps': showTimestamps,
    'showThinking': showThinking,
    'autoCollapseThinking': autoCollapseThinking,
    'fontScale': fontScale,
    'chatFont': chatFont.name,
    'sendOnEnter': sendOnEnter,
    'haptics': haptics,
    'autoScroll': autoScroll,
    'latex': latex,
    'codeWrap': codeWrap,
    'codeLineNumbers': codeLineNumbers,
    'bubbleAssistant': bubbleAssistant,
    'showMessageJumper': showMessageJumper,
    'notifyOnFinish': notifyOnFinish,
    'autoPlayTts': autoPlayTts,
    'pasteLongTextAsFile': pasteLongTextAsFile,
    'longTextThreshold': longTextThreshold,
  };
}

class TtsSettings {
  const TtsSettings({this.rate = 0.5, this.pitch = 1.0, this.language = '', this.onlyQuoted = false});
  final double rate;
  final double pitch;
  final String language;
  final bool onlyQuoted;

  TtsSettings copyWith({double? rate, double? pitch, String? language, bool? onlyQuoted}) => TtsSettings(
    rate: rate ?? this.rate,
    pitch: pitch ?? this.pitch,
    language: language ?? this.language,
    onlyQuoted: onlyQuoted ?? this.onlyQuoted,
  );

  factory TtsSettings.fromJson(Map<String, dynamic> j) => TtsSettings(
    rate: asDouble(j['rate'], 0.5),
    pitch: asDouble(j['pitch'], 1.0),
    language: asStr(j['language']),
    onlyQuoted: asBool(j['onlyQuoted']),
  );

  Map<String, dynamic> toJson() => {'rate': rate, 'pitch': pitch, 'language': language, 'onlyQuoted': onlyQuoted};
}

class AppSettings {
  AppSettings({
    this.themeMode = ThemeModePref.system,
    this.language = AppLang.system,
    this.accentIndex = 0,
    this.providers = const [],
    this.assistants = const [],
    required this.currentAssistantId,
    this.chatModelId,
    this.titleModelId,
    this.translateModelId,
    this.suggestionModelId,
    this.ocrModelId,
    this.imageModelId,
    this.titlePrompt = defaultTitlePrompt,
    this.suggestionPrompt = defaultSuggestionPrompt,
    this.translatePrompt = defaultTranslatePrompt,
    this.ocrPrompt = defaultOcrPrompt,
    this.compressPrompt = defaultCompressPrompt,
    this.autoTitle = true,
    this.suggestions = true,
    this.favoriteModelIds = const [],
    this.searchServices = const [],
    this.searchServiceIndex = 0,
    this.mcpServers = const [],
    this.lorebooks = const [],
    this.modes = const [],
    this.quickMessages = const [],
    this.display = const DisplaySettings(),
    this.tts = const TtsSettings(),
    this.webDav = const WebDavConfig(),
    this.proxies = const [],
    this.defaultProxyId = '',
    this.userAgent = '',
    this.proxy = '',
    this.autoRetry = true,
    this.network = const NetworkSettings(),
    this.translateTarget = 'zh-CN',
    this.onboarded = false,
    this.lastBackupAt,
    this.lastChatModelId,
    this.lastReasoning,
  });

  final ThemeModePref themeMode;
  final AppLang language;
  final int accentIndex;
  final List<ProviderConfig> providers;
  final List<Assistant> assistants;
  final String currentAssistantId;
  final String? chatModelId;
  final String? titleModelId;
  final String? translateModelId;
  final String? suggestionModelId;
  final String? ocrModelId;
  final String? imageModelId;
  final String titlePrompt;
  final String suggestionPrompt;
  final String translatePrompt;
  final String ocrPrompt;
  final String compressPrompt;
  final bool autoTitle;
  final bool suggestions;
  final List<String> favoriteModelIds;
  final List<SearchServiceConfig> searchServices;
  final int searchServiceIndex;
  final List<McpServerConfig> mcpServers;
  final List<Lorebook> lorebooks;
  final List<ModeInjection> modes;
  final List<QuickMessage> quickMessages;
  final DisplaySettings display;
  final TtsSettings tts;
  final WebDavConfig webDav;
  final List<ProxyConfig> proxies;
  final String defaultProxyId;
  final String userAgent;
  final String proxy;
  final bool autoRetry;
  final NetworkSettings network;
  final String translateTarget;
  final bool onboarded;
  final DateTime? lastBackupAt;

  /// Model and reasoning level last picked in a chat. New chats start with
  /// them; picking a default in settings or on an assistant clears them.
  final String? lastChatModelId;
  final ReasoningLevel? lastReasoning;

  Assistant get currentAssistant =>
      assistants.firstWhere((a) => a.id == currentAssistantId, orElse: () => assistants.first);

  Assistant? assistantById(String id) {
    for (final a in assistants) {
      if (a.id == id) return a;
    }
    return null;
  }

  SearchServiceConfig? get currentSearch =>
      searchServices.isEmpty ? null : searchServices[searchServiceIndex.clamp(0, searchServices.length - 1)];

  /// Finds a model across all enabled providers.
  ({ProviderConfig provider, ModelConfig model})? findModel(String? id) {
    if (id == null) return null;
    for (final p in providers) {
      for (final m in p.models) {
        if (m.id == id) return (provider: p, model: m);
      }
    }
    return null;
  }

  Iterable<({ProviderConfig provider, ModelConfig model})> allModels({ModelType? type, bool enabledOnly = true}) sync* {
    for (final p in providers) {
      if (enabledOnly && !p.enabled) continue;
      for (final m in p.models) {
        if (type == null || m.type == type) yield (provider: p, model: m);
      }
    }
  }

  AppSettings copyWith({
    ThemeModePref? themeMode,
    AppLang? language,
    int? accentIndex,
    List<ProviderConfig>? providers,
    List<Assistant>? assistants,
    String? currentAssistantId,
    Object? chatModelId = _keep,
    Object? titleModelId = _keep,
    Object? translateModelId = _keep,
    Object? suggestionModelId = _keep,
    Object? ocrModelId = _keep,
    Object? imageModelId = _keep,
    String? titlePrompt,
    String? suggestionPrompt,
    String? translatePrompt,
    String? ocrPrompt,
    String? compressPrompt,
    bool? autoTitle,
    bool? suggestions,
    List<String>? favoriteModelIds,
    List<SearchServiceConfig>? searchServices,
    int? searchServiceIndex,
    List<McpServerConfig>? mcpServers,
    List<Lorebook>? lorebooks,
    List<ModeInjection>? modes,
    List<QuickMessage>? quickMessages,
    DisplaySettings? display,
    TtsSettings? tts,
    WebDavConfig? webDav,
    List<ProxyConfig>? proxies,
    String? defaultProxyId,
    String? userAgent,
    String? proxy,
    bool? autoRetry,
    NetworkSettings? network,
    String? translateTarget,
    bool? onboarded,
    DateTime? lastBackupAt,
    Object? lastChatModelId = _keep,
    Object? lastReasoning = _keep,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    language: language ?? this.language,
    accentIndex: accentIndex ?? this.accentIndex,
    providers: providers ?? this.providers,
    assistants: assistants ?? this.assistants,
    currentAssistantId: currentAssistantId ?? this.currentAssistantId,
    chatModelId: identical(chatModelId, _keep) ? this.chatModelId : chatModelId as String?,
    titleModelId: identical(titleModelId, _keep) ? this.titleModelId : titleModelId as String?,
    translateModelId: identical(translateModelId, _keep) ? this.translateModelId : translateModelId as String?,
    suggestionModelId: identical(suggestionModelId, _keep) ? this.suggestionModelId : suggestionModelId as String?,
    ocrModelId: identical(ocrModelId, _keep) ? this.ocrModelId : ocrModelId as String?,
    imageModelId: identical(imageModelId, _keep) ? this.imageModelId : imageModelId as String?,
    titlePrompt: titlePrompt ?? this.titlePrompt,
    suggestionPrompt: suggestionPrompt ?? this.suggestionPrompt,
    translatePrompt: translatePrompt ?? this.translatePrompt,
    ocrPrompt: ocrPrompt ?? this.ocrPrompt,
    compressPrompt: compressPrompt ?? this.compressPrompt,
    autoTitle: autoTitle ?? this.autoTitle,
    suggestions: suggestions ?? this.suggestions,
    favoriteModelIds: favoriteModelIds ?? this.favoriteModelIds,
    searchServices: searchServices ?? this.searchServices,
    searchServiceIndex: searchServiceIndex ?? this.searchServiceIndex,
    mcpServers: mcpServers ?? this.mcpServers,
    lorebooks: lorebooks ?? this.lorebooks,
    modes: modes ?? this.modes,
    quickMessages: quickMessages ?? this.quickMessages,
    display: display ?? this.display,
    tts: tts ?? this.tts,
    webDav: webDav ?? this.webDav,
    proxies: proxies ?? this.proxies,
    defaultProxyId: defaultProxyId ?? this.defaultProxyId,
    userAgent: userAgent ?? this.userAgent,
    proxy: proxy ?? this.proxy,
    autoRetry: autoRetry ?? this.autoRetry,
    network: network ?? this.network,
    translateTarget: translateTarget ?? this.translateTarget,
    onboarded: onboarded ?? this.onboarded,
    lastBackupAt: lastBackupAt ?? this.lastBackupAt,
    lastChatModelId: identical(lastChatModelId, _keep) ? this.lastChatModelId : lastChatModelId as String?,
    lastReasoning: identical(lastReasoning, _keep) ? this.lastReasoning : lastReasoning as ReasoningLevel?,
  );

  factory AppSettings.fromJson(Map<String, dynamic> j) {
    final assistants = mapList(j['assistants'], Assistant.fromJson);
    final loadedAssistants = assistants.isEmpty ? defaultAssistants() : assistants;
    final list = [
      for (final assistant in loadedAssistants)
        if (assistant.id == defaultAssistantId && assistant.avatar == '🐱')
          assistant.copyWith(avatar: defaultAssistantAvatar)
        else
          assistant,
    ];
    final cur = asStr(j['currentAssistantId']);
    return AppSettings(
      themeMode: enumByName(ThemeModePref.values, j['themeMode'], ThemeModePref.system),
      language: enumByName(AppLang.values, j['language'], AppLang.system),
      accentIndex: asInt(j['accentIndex']),
      providers: normalizeProviders(
        j['providers'] == null ? defaultProviders() : mapList(j['providers'], ProviderConfig.fromJson),
      ),
      assistants: list,
      currentAssistantId: list.any((a) => a.id == cur) ? cur : list.first.id,
      chatModelId: asStrOrNull(j['chatModelId']),
      titleModelId: asStrOrNull(j['titleModelId']),
      translateModelId: asStrOrNull(j['translateModelId']),
      suggestionModelId: asStrOrNull(j['suggestionModelId']),
      ocrModelId: asStrOrNull(j['ocrModelId']),
      imageModelId: asStrOrNull(j['imageModelId']),
      titlePrompt: asStr(j['titlePrompt'], defaultTitlePrompt),
      suggestionPrompt: asStr(j['suggestionPrompt'], defaultSuggestionPrompt),
      translatePrompt: asStr(j['translatePrompt'], defaultTranslatePrompt),
      ocrPrompt: asStr(j['ocrPrompt'], defaultOcrPrompt),
      compressPrompt: asStr(j['compressPrompt'], defaultCompressPrompt),
      autoTitle: asBool(j['autoTitle'], true),
      suggestions: asBool(j['suggestions'], true),
      favoriteModelIds: asList(j['favoriteModelIds']).map((e) => e.toString()).toList(),
      searchServices: j['searchServices'] == null
          ? [SearchServiceConfig(type: SearchServiceType.bing)]
          : mapList(j['searchServices'], SearchServiceConfig.fromJson),
      searchServiceIndex: asInt(j['searchServiceIndex']),
      mcpServers: mapList(j['mcpServers'], McpServerConfig.fromJson),
      lorebooks: mapList(j['lorebooks'], Lorebook.fromJson),
      modes: j['modes'] == null ? defaultModes() : mapList(j['modes'], ModeInjection.fromJson),
      quickMessages: mapList(j['quickMessages'], QuickMessage.fromJson),
      display: DisplaySettings.fromJson(asMap(j['display'])),
      tts: TtsSettings.fromJson(asMap(j['tts'])),
      webDav: WebDavConfig.fromJson(asMap(j['webDav'])),
      proxies: mapList(j['proxies'], ProxyConfig.fromJson),
      defaultProxyId: asStr(j['defaultProxyId']),
      userAgent: asStr(j['userAgent']),
      proxy: asStr(j['proxy']),
      autoRetry: asBool(j['autoRetry'], true),
      network: NetworkSettings.fromJson(asMap(j['network'])),
      translateTarget: asStr(j['translateTarget'], 'zh-CN'),
      onboarded: asBool(j['onboarded']),
      lastBackupAt: dateFromMsOrNull(j['lastBackupAt']),
      lastChatModelId: asStrOrNull(j['lastChatModelId']),
      lastReasoning: j['lastReasoning'] == null ? null : ReasoningLevel.fromName(j['lastReasoning']),
    );
  }

  factory AppSettings.initial() => AppSettings.fromJson(const {});

  /// [withSecrets] = false omits API keys and passwords (e.g. for sharing).
  Map<String, dynamic> toJson({bool withSecrets = true}) => {
    'themeMode': themeMode.name,
    'language': language.name,
    'accentIndex': accentIndex,
    'providers': providers.map((e) => e.toJson(withSecrets: withSecrets)).toList(),
    'assistants': assistants.map((e) => e.toJson()).toList(),
    'currentAssistantId': currentAssistantId,
    'chatModelId': chatModelId,
    'titleModelId': titleModelId,
    'translateModelId': translateModelId,
    'suggestionModelId': suggestionModelId,
    'ocrModelId': ocrModelId,
    'imageModelId': imageModelId,
    'titlePrompt': titlePrompt,
    'suggestionPrompt': suggestionPrompt,
    'translatePrompt': translatePrompt,
    'ocrPrompt': ocrPrompt,
    'compressPrompt': compressPrompt,
    'autoTitle': autoTitle,
    'suggestions': suggestions,
    'favoriteModelIds': favoriteModelIds,
    'searchServices': searchServices.map((e) => e.toJson()).toList(),
    'searchServiceIndex': searchServiceIndex,
    'mcpServers': mcpServers.map((e) => e.toJson()).toList(),
    'lorebooks': lorebooks.map((e) => e.toJson()).toList(),
    'modes': modes.map((e) => e.toJson()).toList(),
    'quickMessages': quickMessages.map((e) => e.toJson()).toList(),
    'display': display.toJson(),
    'tts': tts.toJson(),
    'webDav': withSecrets ? webDav.toJson() : webDav.copyWith(password: '').toJson(),
    'proxies': proxies.map((e) => e.toJson(withSecrets: withSecrets)).toList(),
    'defaultProxyId': defaultProxyId,
    'userAgent': userAgent,
    'proxy': withSecrets ? proxy : '',
    'autoRetry': autoRetry,
    'network': network.toJson(),
    'translateTarget': translateTarget,
    'onboarded': onboarded,
    'lastBackupAt': lastBackupAt?.millisecondsSinceEpoch,
    'lastChatModelId': lastChatModelId,
    'lastReasoning': lastReasoning?.name,
  };
}

const _keep = Object();
