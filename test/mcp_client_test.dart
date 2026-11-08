import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/chat/chat_controller.dart';
import 'package:mewhub/core/net.dart';
import 'package:mewhub/data/assistant.dart';
import 'package:mewhub/data/models_misc.dart';
import 'package:mewhub/data/settings.dart';
import 'package:mewhub/tools/mcp.dart';
import 'package:mewhub/tools/tool.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

/// Tiny Streamable HTTP MCP server. Replies over SSE and sends a server
/// request with a colliding id first, like some real servers do.
class _FakeMcpServer {
  _FakeMcpServer._(this.server);
  final HttpServer server;
  final versions = <String?>[];
  final calls = <String>[];
  String session = 'session-1';
  bool expireNextCall = false;

  static Future<_FakeMcpServer> start() async {
    final s = _FakeMcpServer._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    s.server.listen(s._handle);
    return s;
  }

  String get url => 'http://127.0.0.1:${server.port}/mcp';

  Future<void> _handle(HttpRequest req) async {
    if (req.method == 'DELETE') {
      req.response.statusCode = 200;
      await req.response.close();
      return;
    }
    final body = jsonDecode(await utf8.decodeStream(req)) as Map<String, dynamic>;
    final method = body['method'] as String;
    versions.add(req.headers.value('mcp-protocol-version'));
    if (method != 'initialize' && req.headers.value('mcp-session-id') != session) {
      req.response.statusCode = 404;
      req.response.write('{"error":"unknown session"}');
      await req.response.close();
      return;
    }
    if (method.startsWith('notifications/')) {
      req.response.statusCode = 202;
      await req.response.close();
      return;
    }
    if (method == 'tools/call' && expireNextCall) {
      expireNextCall = false;
      session = 'session-2';
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    final id = body['id'];
    final Map<String, dynamic> result = switch (method) {
      'initialize' => {
        'protocolVersion': '2025-03-26',
        'serverInfo': {'name': 'fake'},
        'capabilities': <String, dynamic>{},
      },
      'tools/list' => {
        'tools': [
          {
            'name': 'echo',
            'description': 'Echo text',
            'inputSchema': {
              r'$schema': 'http://json-schema.org/draft-07/schema#',
              'type': 'object',
              'properties': {
                'text': {'type': 'string'},
              },
            },
          },
          {'name': 'ping'},
        ],
      },
      'tools/call' => () {
        final p = body['params'] as Map<String, dynamic>;
        calls.add(p['name'] as String);
        return {
          'content': [
            {'type': 'text', 'text': 'echo:${jsonEncode(p['arguments'])}'},
          ],
        };
      }(),
      _ => <String, dynamic>{},
    };
    if (method == 'initialize') req.response.headers.set('Mcp-Session-Id', session);
    req.response.headers.contentType = ContentType('text', 'event-stream');
    // A server-to-client request reusing our id must not be taken as the reply.
    req.response.write('data: ${jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': 'roots/list'})}\n\n');
    req.response.write('data: ${jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result})}\n\n');
    await req.response.close();
  }

  Future<void> close() => server.close(force: true);
}

Future<T> _real<T>(Future<T> Function() body) => HttpOverrides.runWithHttpOverrides(() async {
  Net.reconfigure();
  try {
    return await body();
  } finally {
    Net.reconfigure();
  }
}, _LoopbackHttpOverrides());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeMcpServer fake;

  setUp(() async {
    HttpOverrides.global = null;
    fake = await _FakeMcpServer.start();
  });
  tearDown(() => fake.close());

  test('connects over Streamable HTTP, negotiates the version and calls a tool', () async {
    await _real(() async {
      final mcp = McpManager();
      var notifications = 0;
      mcp.addListener(() => notifications++);
      final cfg = McpServerConfig(id: 'srv', name: 'Fake', url: fake.url);
      final client = await mcp.ensure(cfg);
      expect(client.status, McpStatus.connected);
      expect(client.tools.map((t) => t.name), ['echo', 'ping']);
      expect(notifications, greaterThan(0));
      // initialize has no version header; later requests use the agreed one.
      expect(fake.versions.first, isNull);
      expect(fake.versions.skip(1).toSet(), {'2025-03-26'});

      final r = await client.callTool('echo', {'text': 'hi'});
      expect(r.isError, isFalse);
      expect(r.text, 'echo:{"text":"hi"}');
      expect(identical(await mcp.ensure(cfg), client), isTrue);
      await mcp.closeAll();
      mcp.dispose();
    });
  });

  test('a call on an expired session reconnects once and succeeds', () async {
    await _real(() async {
      final mcp = McpManager();
      final client = await mcp.ensure(McpServerConfig(id: 'srv', name: 'Fake', url: fake.url));
      fake.expireNextCall = true;
      final r = await client.callTool('ping', const {});
      expect(r.text, 'echo:{}');
      expect(fake.calls, ['ping']);
      expect(client.status, McpStatus.connected);
      await mcp.closeAll();
      mcp.dispose();
    });
  });

  test('a failed server reports an error and reconnects after it comes back', () async {
    await _real(() async {
      final mcp = McpManager();
      final dead = McpServerConfig(id: 'dead', name: 'Dead', url: 'http://127.0.0.1:1/mcp');
      await expectLater(mcp.ensure(dead), throwsA(isA<ApiException>()));
      expect(mcp.client('dead')!.status, McpStatus.error);
      expect(mcp.client('dead')!.error, isNotEmpty);
      final fixed = await mcp.ensure(McpServerConfig(id: 'dead', name: 'Dead', url: fake.url));
      expect(fixed.status, McpStatus.connected);
      await mcp.disconnect('dead');
      expect(mcp.client('dead'), isNull);
      mcp.dispose();
    });
  });

  test('response matching skips server requests and accepts string ids and batches', () {
    expect(McpClient.matchResponse({'jsonrpc': '2.0', 'id': 3, 'method': 'roots/list'}, 3), isNull);
    expect(McpClient.matchResponse({'jsonrpc': '2.0', 'id': '3', 'result': {}}, 3), isNotNull);
    final batch = [
      {'jsonrpc': '2.0', 'method': 'notifications/progress'},
      {
        'jsonrpc': '2.0',
        'id': 4,
        'result': {'ok': true},
      },
    ];
    expect(McpClient.matchResponse(batch, 4)?['result'], {'ok': true});
    expect(McpClient.matchResponse(batch, 5), isNull);
  });

  test('tool results summarise non-text content and structured output', () {
    final r = McpClient.formatToolResult({
      'content': [
        {'type': 'text', 'text': 'line'},
        {'type': 'image', 'mimeType': 'image/png'},
      ],
      'isError': true,
    });
    expect(r.text, 'line\n[image image/png]');
    expect(r.isError, isTrue);
    expect(
      McpClient.formatToolResult({
        'structuredContent': {'n': 1},
      }).text,
      '{"n":1}',
    );
  });

  test('tool schemas and names are normalised for every provider', () {
    expect(normalizeToolSchema(const {}), {'type': 'object', 'properties': <String, dynamic>{}});
    final cleaned = normalizeToolSchema({
      r'$schema': 'x',
      'type': 'object',
      'properties': {
        'a': {'type': 'string'},
      },
      'required': <String>[],
    });
    expect(cleaned.containsKey(r'$schema'), isFalse);
    expect(cleaned.containsKey('required'), isFalse);
    final long = ChatController.mcpToolName('My Server', 'x' * 80);
    expect(long.length, 64);
    final taken = {long};
    final second = ChatController.uniqueToolName(long, taken);
    expect(second, isNot(long));
    expect(second.length, 64);
    expect(ChatController.mcpToolName('mt', 'read file'), 'mcp__mt__read_file');
  });

  test('servers enabled before 1.5 are attached to the current assistant once', () {
    final settings = AppSettings.initial();
    final current = settings.currentAssistantId;
    final json = settings.toJson()
      ..remove('mcpLinked')
      ..['mcpServers'] = [McpServerConfig(id: 'mt', name: 'mt', url: 'https://mcp.example').toJson()];
    final migrated = AppSettings.fromJson(json);
    expect(migrated.assistantById(current)!.mcpServerIds, {'mt'});
    // Once saved by 1.5, a user's choice to turn it off is respected.
    final off = migrated.copyWith(
      assistants: [for (final a in migrated.assistants) a.copyWith(mcpServerIds: const {})],
    );
    expect(AppSettings.fromJson(off.toJson()).assistantById(current)!.mcpServerIds, isEmpty);
    expect(
      linkOrphanMcpServers(
        [
          Assistant(id: 'a', mcpServerIds: const {'mt'}),
        ],
        [McpServerConfig(id: 'mt')],
        'a',
      ),
      hasLength(1),
    );
  });
}
