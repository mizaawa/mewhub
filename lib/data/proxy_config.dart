import '../core/util.dart';

enum ProxyProtocol { http, socks5 }

class ProxyEndpoint {
  const ProxyEndpoint({
    required this.protocol,
    required this.host,
    required this.port,
    this.username = '',
    this.password = '',
  });

  final ProxyProtocol protocol;
  final String host;
  final int port;
  final String username;
  final String password;

  bool get hasCredentials => username.isNotEmpty || password.isNotEmpty;

  static ProxyEndpoint parse(String raw) {
    final value = raw.trim();
    if (value.isEmpty) throw const FormatException('Proxy address is empty');
    final withScheme = value.contains('://') ? value : 'http://$value';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) throw const FormatException('Enter a valid proxy URL or host:port');
    final protocol = switch (uri.scheme.toLowerCase()) {
      'http' => ProxyProtocol.http,
      'socks5' || 'socks5h' => ProxyProtocol.socks5,
      _ => throw const FormatException('Proxy URL must use http:// or socks5://'),
    };
    if ((uri.path.isNotEmpty && uri.path != '/') || uri.hasQuery || uri.hasFragment) {
      throw const FormatException('A proxy URL cannot include a path, query, or fragment');
    }
    final port = uri.hasPort
        ? uri.port
        : protocol == ProxyProtocol.socks5
        ? 1080
        : 80;
    if (port < 1 || port > 65535) throw const FormatException('Proxy port must be between 1 and 65535');
    final parts = uri.userInfo.split(':');
    return ProxyEndpoint(
      protocol: protocol,
      host: uri.host,
      port: port,
      username: parts.isEmpty ? '' : Uri.decodeComponent(parts.first),
      password: parts.length < 2 ? '' : Uri.decodeComponent(parts.sublist(1).join(':')),
    );
  }

  String get node {
    final host = this.host.contains(':') && !this.host.startsWith('[') ? '[${this.host}]' : this.host;
    return '$host:$port';
  }
}

class ProxyConfig {
  ProxyConfig({String? id, this.name = '', required this.url}) : id = id ?? newId();

  final String id;
  final String name;
  final String url;

  String get displayName {
    final trimmed = name.trim();
    if (trimmed.isNotEmpty) return trimmed;
    try {
      return ProxyEndpoint.parse(url).node;
    } catch (_) {
      return url.trim();
    }
  }

  String get displayAddress {
    try {
      return ProxyEndpoint.parse(url).node;
    } catch (_) {
      return url.trim();
    }
  }

  ProxyConfig copyWith({String? name, String? url}) =>
      ProxyConfig(id: id, name: name ?? this.name, url: url ?? this.url);

  factory ProxyConfig.fromJson(Map<String, dynamic> json) =>
      ProxyConfig(id: asStrOrNull(json['id']), name: asStr(json['name']), url: asStr(json['url']));

  Map<String, dynamic> toJson({bool withSecrets = true}) => {'id': id, 'name': name, 'url': withSecrets ? url : ''};
}
