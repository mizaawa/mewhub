import 'dart:async';
import 'dart:convert';

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
  McpClient(this.config);
  final McpServerConfig config;

  static const protocolVersion = '2025-06-18';
  String? _sessionId;
  int _nextId = 1;
  McpStatus status = McpStatus.idle;
  String? error;
  List<McpTool> tools = [];
  String serverName = '';

  // legacy SSE transport state
  Uri? _sseEndpoint;
  StreamSubscription<SseEvent>? _sseSub;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Accept': 'application/json, text/event-stream',
    'MCP-Protocol-Version': protocolVersion,
    'Mcp-Session-Id': ?_sessionId,
    ...config.headers,
  };

  Future<void> connect() async {
    status = McpStatus.connecting;
    error = null;
    try {
      if (config.transport == McpTransport.sse) await _openSse();
      final init = await _request('initialize', {
        'protocolVersion': protocolVersion,
        'capabilities': <String, dynamic>{},
        'clientInfo': {'name': 'MewHub', 'version': '1.0.0'},
      });
      serverName = asStr(asMap(init['serverInfo'])['name'], config.name);
      await _notify('notifications/initialized');
      await refreshTools();
      status = McpStatus.connected;
    } catch (e) {
      status = McpStatus.error;
      error = e.toString();
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
        out.add(
          McpTool(
            asStr(m['name']),
            asStr(m['description']),
            asMapOrNull(m['inputSchema']) ?? {'type': 'object', 'properties': <String, dynamic>{}},
          ),
        );
      }
      cursor = asStrOrNull(r['nextCursor']);
      if (cursor == null) break;
    }
    tools = out;
  }

  /// Calls a tool; returns text content (images/resources are summarised).
  Future<({String text, bool isError})> callTool(String name, Map<String, dynamic> args) async {
    final r = await _request('tools/call', {'name': name, 'arguments': args}, timeout: const Duration(minutes: 3));
    final buf = StringBuffer();
    for (final c in asList(r['content'])) {
      final m = asMap(c);
      switch (m['type']) {
        case 'text':
          buf.writeln(asStr(m['text']));
        case 'image':
          buf.writeln('[image ${asStr(m['mimeType'])}]');
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
    await _sseSub?.cancel();
    _sseSub = null;
    if (_sessionId != null && config.transport == McpTransport.streamableHttp) {
      try {
        await Net.send('DELETE', Uri.parse(config.url), headers: _headers, log: false);
      } catch (_) {}
    }
    _sessionId = null;
    status = McpStatus.idle;
  }

  Future<void> _notify(String method) async {
    final body = jsonEncode({'jsonrpc': '2.0', 'method': method});
    if (config.transport == McpTransport.sse) {
      await Net.send('POST', _sseEndpoint!, headers: _headers, body: body, log: false);
      return;
    }
    final res = await Net.send('POST', Uri.parse(config.url), headers: _headers, body: body);
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
      final c = Completer<Map<String, dynamic>>();
      _pending[id] = c;
      await Net.send('POST', _sseEndpoint!, headers: _headers, body: payload);
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
        final j = asMapOrNull(tryJsonDecode(ev.data));
        if (j != null && j['id'] == id) return _unwrap(j);
      }
      throw ApiException('MCP $method: stream ended without a response');
    }
    final text = await res.stream.bytesToString().timeout(timeout);
    return _unwrap(asMap(jsonDecode(text)));
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
    final res = await Net.sendRequest(req, log: false);
    final ready = Completer<void>();
    _sseSub = parseSse(res.stream).listen(
      (ev) {
        if (ev.event == 'endpoint') {
          _sseEndpoint = Uri.parse(config.url).resolve(ev.data.trim());
          if (!ready.isCompleted) ready.complete();
          return;
        }
        final j = asMapOrNull(tryJsonDecode(ev.data));
        final id = j?['id'];
        if (j != null && id is int) _pending.remove(id)?.complete(j);
      },
      onError: (Object e) {
        if (!ready.isCompleted) ready.completeError(e);
        for (final c in _pending.values) {
          c.completeError(e);
        }
        _pending.clear();
        status = McpStatus.error;
        error = e.toString();
      },
    );
    await ready.future.timeout(const Duration(seconds: 20));
  }
}

/// Keeps one live client per enabled server.
class McpManager {
  final Map<String, McpClient> _clients = {};

  McpClient? client(String serverId) => _clients[serverId];

  Future<McpClient> ensure(McpServerConfig c) async {
    final existing = _clients[c.id];
    if (existing != null &&
        existing.status == McpStatus.connected &&
        existing.config.url == c.url &&
        existing.config.transport == c.transport &&
        jsonEncode(existing.config.headers) == jsonEncode(c.headers)) {
      return existing;
    }
    await existing?.close();
    final client = McpClient(c);
    _clients[c.id] = client;
    await client.connect();
    return client;
  }

  Future<void> closeAll() async {
    for (final c in _clients.values) {
      await c.close();
    }
    _clients.clear();
  }
}
