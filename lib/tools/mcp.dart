import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/net.dart';
import '../core/sse.dart';
import '../core/util.dart';
import '../data/models_misc.dart';

class McpTool {
  McpTool(this.name, this.description, this.inputSchema);
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;
}

enum McpStatus { idle, connecting, connected, error }

/// Minimal MCP client (protocol 2025-06-18) over Streamable HTTP, with a
/// fallback for the legacy HTTP+SSE transport.
class McpClient {
  McpClient(this.config, {this.onChanged});
  final McpServerConfig config;

  /// Called whenever [status], [error] or [tools] change.
  final VoidCallback? onChanged;

  static const protocolVersion = '2025-06-18';
  String? _sessionId;

  /// Version agreed in `initialize`; sent on every later request.
  String? _negotiatedVersion;
  int _nextId = 1;
  McpStatus status = McpStatus.idle;
  String? error;
  List<McpTool> tools = [];
  String serverName = '';
  Future<void>? _connecting;

  // legacy SSE transport state
  Uri? _sseEndpoint;
  StreamSubscription<SseEvent>? _sseSub;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
    'MCP-Protocol-Version': ?_negotiatedVersion,
    'Mcp-Session-Id': ?_sessionId,
    ...config.headers,
  };

  void _set(McpStatus s, [String? err]) {
    status = s;
    error = err;
    onChanged?.call();
  }

  /// Opens a session and lists tools. Concurrent callers share one attempt.
  Future<void> connect() => _connecting ??= _connect().whenComplete(() => _connecting = null);

  Future<void> _connect() async {
    _set(McpStatus.connecting);
    try {
      await _resetTransport();
      if (config.transport == McpTransport.sse) await _openSse();
      final init = await _request('initialize', {
        'protocolVersion': protocolVersion,
        'capabilities': <String, dynamic>{},
        'clientInfo': {'name': 'MewHub', 'version': '1.5.0'},
      });
      serverName = asStr(asMap(init['serverInfo'])['name'], config.name);
      final agreed = asStr(init['protocolVersion']).trim();
      _negotiatedVersion = agreed.isEmpty ? protocolVersion : agreed;
      await _notify('notifications/initialized');
      await refreshTools();
      _set(McpStatus.connected);
    } catch (e) {
      _set(McpStatus.error, _describe(e));
      rethrow;
    }
  }

  Future<void> refreshTools() async {
    final out = <McpTool>[];
    String? cursor;
    for (var i = 0; i < 20; i++) {
      final r = await _request('tools/list', {'cursor': ?cursor});
      for (final t in asList(r['tools'])) {
        final m = asMap(t);
        final name = asStr(m['name']).trim();
        if (name.isEmpty) continue;
        out.add(McpTool(name, asStr(m['description']), asMapOrNull(m['inputSchema']) ?? const {}));
      }
      cursor = asStrOrNull(r['nextCursor']);
      if (cursor == null || cursor.isEmpty) break;
    }
    tools = out;
    onChanged?.call();
  }

  /// Calls a tool; returns text content (images/resources are summarised).
  ///
  /// A server that forgot our session (restart, idle expiry) answers 404 or a
  /// session error; the call is retried once on a fresh session.
  Future<({String text, bool isError})> callTool(String name, Map<String, dynamic> args) async {
    Map<String, dynamic> r;
    try {
      r = await _request('tools/call', {'name': name, 'arguments': args}, timeout: const Duration(minutes: 3));
    } catch (e) {
      if (!_sessionLost(e)) rethrow;
      await connect();
      r = await _request('tools/call', {'name': name, 'arguments': args}, timeout: const Duration(minutes: 3));
    }
    return formatToolResult(r);
  }

  @visibleForTesting
  static ({String text, bool isError}) formatToolResult(Map<String, dynamic> r) {
    final buf = StringBuffer();
    for (final c in asList(r['content'])) {
      final m = asMap(c);
      switch (m['type']) {
        case 'text':
          buf.writeln(asStr(m['text']));
        case 'image':
          buf.writeln('[image ${asStr(m['mimeType'])}]');
        case 'audio':
          buf.writeln('[audio ${asStr(m['mimeType'])}]');
        case 'resource':
          final res = asMap(m['resource']);
          buf.writeln(asStr(res['text'], '[resource ${asStr(res['uri'])}]'));
        case 'resource_link':
          buf.writeln('[resource ${asStr(m['uri'])}]');
      }
    }
    if (buf.isEmpty && r['structuredContent'] != null) buf.write(jsonEncode(r['structuredContent']));
    return (text: buf.toString().trim(), isError: asBool(r['isError']));
  }

  Future<void> close() async {
    await _resetTransport();
    _set(McpStatus.idle);
  }

  Future<void> _resetTransport() async {
    await _sseSub?.cancel();
    _sseSub = null;
    _sseEndpoint = null;
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(ApiException('MCP connection closed'));
    }
    _pending.clear();
    if (_sessionId != null && config.transport == McpTransport.streamableHttp) {
      try {
        final res = await Net.send(
          'DELETE',
          Uri.parse(config.url),
          headers: _headers,
          timeout: const Duration(seconds: 5),
        );
        await res.stream.drain<void>();
      } catch (_) {}
    }
    _sessionId = null;
    _negotiatedVersion = null;
  }

  static bool _sessionLost(Object e) =>
      e is ApiException && (e.status == 404 || (e.status == 400 && e.message.toLowerCase().contains('session')));

  static String _describe(Object e) {
    if (e is ApiException) {
      return switch (e.status) {
        401 || 403 => 'HTTP ${e.status}: ${e.message} (check the Authorization header)',
        404 => 'HTTP 404: ${e.message} (check the URL and transport type)',
        _ => e.toString(),
      };
    }
    if (e is TimeoutException) return 'Timed out connecting to the server';
    return e.toString();
  }

  Future<void> _notify(String method) async {
    final body = jsonEncode({'jsonrpc': '2.0', 'method': method});
    final res = config.transport == McpTransport.sse
        ? await Net.send('POST', _sseEndpoint!, headers: _headers, body: body)
        : await Net.send('POST', Uri.parse(config.url), headers: _headers, body: body);
    await res.stream.drain<void>();
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, dynamic> params, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final id = _nextId++;
    final payload = jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    if (config.transport == McpTransport.sse) {
      final endpoint = _sseEndpoint;
      if (endpoint == null) throw ApiException('MCP SSE stream is not open');
      final c = Completer<Map<String, dynamic>>();
      _pending[id] = c;
      try {
        final res = await Net.send('POST', endpoint, headers: _headers, body: payload);
        await res.stream.drain<void>();
      } catch (e) {
        _pending.remove(id);
        rethrow;
      }
      return _unwrap(
        await c.future.timeout(
          timeout,
          onTimeout: () {
            _pending.remove(id);
            throw ApiException('MCP $method timed out');
          },
        ),
      );
    }
    final res = await Net.send('POST', Uri.parse(config.url), headers: _headers, body: payload);
    final sid = res.headers['mcp-session-id'];
    if (sid != null && sid.isNotEmpty) _sessionId = sid;
    final type = res.headers['content-type'] ?? '';
    if (type.contains('text/event-stream')) {
      await for (final ev in parseSse(res.stream).timeout(timeout)) {
        final reply = matchResponse(tryJsonDecode(ev.data), id);
        if (reply != null) return _unwrap(reply);
      }
      throw ApiException('MCP $method: stream ended without a response');
    }
    final text = await res.stream.bytesToString().timeout(timeout);
    final reply = matchResponse(tryJsonDecode(text), id);
    if (reply == null) throw ApiException('MCP $method: unexpected response ${truncate(text.trim(), 200)}');
    return _unwrap(reply);
  }

  /// Picks the JSON-RPC response for [id] from a message or batch. Server
  /// requests and notifications (they carry `method`) are never responses,
  /// even when their own id happens to collide with ours.
  @visibleForTesting
  static Map<String, dynamic>? matchResponse(Object? decoded, int id) {
    for (final item in decoded is List ? decoded : [decoded]) {
      final m = asMapOrNull(item);
      if (m == null || m.containsKey('method')) continue;
      if ('${m['id']}' == '$id') return m;
    }
    return null;
  }

  Map<String, dynamic> _unwrap(Map<String, dynamic> j) {
    if (j['error'] != null) {
      final e = asMap(j['error']);
      throw ApiException('MCP error ${e['code']}: ${asStr(e['message'])}');
    }
    return asMap(j['result']);
  }

  Future<void> _openSse() async {
    final req = http.AbortableRequest('GET', Uri.parse(config.url))
      ..headers.addAll({'Accept': 'text/event-stream', ...config.headers});
    // The event stream may stay quiet for a long time between calls.
    final res = await Net.sendRequest(req, timeout: const Duration(hours: 6));
    final ready = Completer<void>();
    void fail(Object e) {
      if (!ready.isCompleted) ready.completeError(e);
      for (final c in _pending.values) {
        if (!c.isCompleted) c.completeError(e);
      }
      _pending.clear();
      _sseEndpoint = null;
      if (status != McpStatus.idle) _set(McpStatus.error, _describe(e));
    }

    _sseSub = parseSse(res.stream).listen(
      (ev) {
        if (ev.event == 'endpoint') {
          _sseEndpoint = Uri.parse(config.url).resolve(ev.data.trim());
          if (!ready.isCompleted) ready.complete();
          return;
        }
        final j = asMapOrNull(tryJsonDecode(ev.data));
        if (j == null || j.containsKey('method')) return;
        final id = int.tryParse('${j['id']}');
        if (id != null) _pending.remove(id)?.complete(j);
      },
      onError: (Object e) => fail(e),
      onDone: () => fail(ApiException('MCP SSE stream closed')),
    );
    await ready.future.timeout(const Duration(seconds: 20));
  }
}

/// Keeps one live client per server and tells listeners when any changes.
class McpManager extends ChangeNotifier {
  final Map<String, McpClient> _clients = {};
  bool _disposed = false;

  McpClient? client(String serverId) => _clients[serverId];

  static bool _sameTarget(McpServerConfig a, McpServerConfig b) =>
      a.url == b.url && a.transport == b.transport && mapEquals(a.headers, b.headers);

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  /// Returns a connected client for [c], reconnecting after errors or when the
  /// URL, transport or headers changed. Concurrent callers share one attempt.
  Future<McpClient> ensure(McpServerConfig c) async {
    final existing = _clients[c.id];
    if (existing != null && _sameTarget(existing.config, c)) {
      if (existing.status == McpStatus.connected) return existing;
      if (existing.status == McpStatus.connecting) {
        await existing.connect();
        return existing;
      }
    }
    final client = McpClient(c, onChanged: _changed);
    _clients[c.id] = client;
    if (existing != null) unawaited(existing.close());
    _changed();
    await client.connect();
    return client;
  }

  /// Drops the client of a disabled or deleted server.
  Future<void> disconnect(String serverId) async {
    final c = _clients.remove(serverId);
    _changed();
    await c?.close();
  }

  Future<void> closeAll() async {
    final all = _clients.values.toList();
    _clients.clear();
    for (final c in all) {
      await c.close();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
