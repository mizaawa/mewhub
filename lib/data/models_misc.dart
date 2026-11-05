import '../core/util.dart';

/// A long-term memory item. [assistantId] null = global memory.
class MemoryItem {
  MemoryItem({String? id, this.assistantId, required this.content, DateTime? createdAt, DateTime? updatedAt})
    : id = id ?? newId(),
      createdAt = createdAt ?? DateTime.now(),
      updatedAt = updatedAt ?? DateTime.now();

  final String id;
  final String? assistantId;
  final String content;
  final DateTime createdAt;
  final DateTime updatedAt;

  MemoryItem copyWith({String? content}) => MemoryItem(
    id: id,
    assistantId: assistantId,
    content: content ?? this.content,
    createdAt: createdAt,
    updatedAt: DateTime.now(),
  );
}

class FavoriteItem {
  FavoriteItem({
    String? id,
    required this.conversationId,
    required this.messageId,
    required this.snapshot,
    DateTime? createdAt,
  }) : id = id ?? newId(),
       createdAt = createdAt ?? DateTime.now();

  final String id;
  final String conversationId;
  final String messageId;

  /// JSON of the message at the time it was favorited.
  final String snapshot;
  final DateTime createdAt;
}

enum SearchServiceType { tavily, exa, brave, bing, serper, jina, zhipu, bocha, perplexity, searxng, linkup }

class SearchServiceConfig {
  SearchServiceConfig({String? id, required this.type, this.apiKey = '', this.url = '', this.maxResults = 5})
    : id = id ?? newId();

  final String id;
  final SearchServiceType type;
  final String apiKey;

  /// Base URL for self-hosted services (SearXNG) or custom endpoints.
  final String url;
  final int maxResults;

  String get label => switch (type) {
    SearchServiceType.tavily => 'Tavily',
    SearchServiceType.exa => 'Exa',
    SearchServiceType.brave => 'Brave',
    SearchServiceType.bing => 'Bing (scrape)',
    SearchServiceType.serper => 'Serper (Google)',
    SearchServiceType.jina => 'Jina',
    SearchServiceType.zhipu => 'Zhipu',
    SearchServiceType.bocha => 'Bocha',
    SearchServiceType.perplexity => 'Perplexity',
    SearchServiceType.searxng => 'SearXNG',
    SearchServiceType.linkup => 'LinkUp',
  };

  bool get needsKey => type != SearchServiceType.bing && type != SearchServiceType.searxng;

  SearchServiceConfig copyWith({SearchServiceType? type, String? apiKey, String? url, int? maxResults}) =>
      SearchServiceConfig(
        id: id,
        type: type ?? this.type,
        apiKey: apiKey ?? this.apiKey,
        url: url ?? this.url,
        maxResults: maxResults ?? this.maxResults,
      );

  factory SearchServiceConfig.fromJson(Map<String, dynamic> j) => SearchServiceConfig(
    id: asStrOrNull(j['id']),
    type: enumByName(SearchServiceType.values, j['type'], SearchServiceType.bing),
    apiKey: asStr(j['apiKey']),
    url: asStr(j['url']),
    maxResults: asInt(j['maxResults'], 5),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'apiKey': apiKey,
    'url': url,
    'maxResults': maxResults,
  };
}

enum McpTransport { streamableHttp, sse }

class McpServerConfig {
  McpServerConfig({
    String? id,
    this.name = '',
    this.url = '',
    this.transport = McpTransport.streamableHttp,
    this.enabled = true,
    this.headers = const {},
    this.disabledTools = const {},
  }) : id = id ?? newId();

  final String id;
  final String name;
  final String url;
  final McpTransport transport;
  final bool enabled;
  final Map<String, String> headers;
  final Set<String> disabledTools;

  McpServerConfig copyWith({
    String? name,
    String? url,
    McpTransport? transport,
    bool? enabled,
    Map<String, String>? headers,
    Set<String>? disabledTools,
  }) => McpServerConfig(
    id: id,
    name: name ?? this.name,
    url: url ?? this.url,
    transport: transport ?? this.transport,
    enabled: enabled ?? this.enabled,
    headers: headers ?? this.headers,
    disabledTools: disabledTools ?? this.disabledTools,
  );

  factory McpServerConfig.fromJson(Map<String, dynamic> j) => McpServerConfig(
    id: asStrOrNull(j['id']),
    name: asStr(j['name']),
    url: asStr(j['url']),
    transport: enumByName(McpTransport.values, j['transport'], McpTransport.streamableHttp),
    enabled: asBool(j['enabled'], true),
    headers: asMap(j['headers']).map((k, v) => MapEntry(k, v.toString())),
    disabledTools: asList(j['disabledTools']).map((e) => e.toString()).toSet(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url,
    'transport': transport.name,
    'enabled': enabled,
    'headers': headers,
    'disabledTools': disabledTools.toList(),
  };
}

class WebDavConfig {
  const WebDavConfig({this.url = '', this.username = '', this.password = '', this.path = 'mewhub_backups'});
  final String url;
  final String username;
  final String password;
  final String path;

  bool get configured => url.isNotEmpty;

  WebDavConfig copyWith({String? url, String? username, String? password, String? path}) => WebDavConfig(
    url: url ?? this.url,
    username: username ?? this.username,
    password: password ?? this.password,
    path: path ?? this.path,
  );

  factory WebDavConfig.fromJson(Map<String, dynamic> j) => WebDavConfig(
    url: asStr(j['url']),
    username: asStr(j['username']),
    password: asStr(j['password']),
    path: asStr(j['path'], 'mewhub_backups'),
  );

  Map<String, dynamic> toJson() => {'url': url, 'username': username, 'password': password, 'path': path};
}
