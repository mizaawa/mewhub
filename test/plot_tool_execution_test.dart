import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/ai/provider_config.dart';
import 'package:mewhub/chat/chat_controller.dart';
import 'package:mewhub/core/net.dart';
import 'package:mewhub/core/paths.dart';
import 'package:mewhub/data/assistant.dart';
import 'package:mewhub/data/conversation.dart';
import 'package:mewhub/state/settings_store.dart';
import 'package:mewhub/tools/mcp.dart';

import 'chat_edit_resend_test.dart' show MemoryDatabase;

class _LoopbackHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('invalid plot arguments persist an error ToolPart and feed the error back to the model', () async {
    final temp = await Directory.systemTemp.createTemp('mewhub_plot_execution');
    AppPaths.support = temp;
    AppPaths.cache = temp;
    FlutterSecureStorage.setMockInitialValues({});
    final store = await SettingsStore.load();
    final db = MemoryDatabase();
    final mcp = McpManager();
    final requests = <Map<String, dynamic>>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add(jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>);
      request.response.headers.contentType = ContentType('text', 'event-stream');
      final delta = requests.length == 1
          ? <String, dynamic>{
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'invalid-plot',
                  'type': 'function',
                  'function': {
                    'name': 'plot_cartesian',
                    'arguments': jsonEncode({
                      'functions': ['unknown(x)'],
                    }),
                  },
                },
              ],
            }
          : <String, dynamic>{'content': 'The expression is invalid.'};
      request.response.write(
        'data: ${jsonEncode({
          'choices': [
            {'delta': delta, 'finish_reason': requests.length == 1 ? 'tool_calls' : 'stop'},
          ],
        })}\n\ndata: [DONE]\n\n',
      );
      await request.response.close();
    });
    final model = ModelConfig(id: 'plot-model', modelId: 'fixture', abilities: {ModelAbility.tool});
    store.update(
      (s) => s.copyWith(
        providers: [
          ProviderConfig(
            id: 'plot-provider',
            name: 'Plot fixture',
            kind: ProviderKind.openai,
            baseUrl: 'http://127.0.0.1:${server.port}/v1',
            models: [model],
          ),
        ],
        chatModelId: model.id,
        autoRetry: false,
        autoCompress: false,
        assistants: [
          s.currentAssistant.copyWith(
            enableMemory: false,
            enableRecentChats: false,
            enableWebSearch: false,
            localTools: {LocalTool.cartesianPlot},
            toolApproval: false,
          ),
        ],
      ),
    );
    final chat = ChatController(
      store: store,
      db: db,
      mcp: mcp,
      conversation: Conversation(assistantId: store.value.currentAssistantId),
    );
    try {
      await HttpOverrides.runWithHttpOverrides(() async {
        Net.reconfigure();
        await chat.send([const TextPart('Plot a function')]);
      }, _LoopbackHttpOverrides());

      expect(chat.lastError, isNull);
      expect(requests, hasLength(2));
      // The plot tool brings its guidance for LaTeX replies into the system prompt.
      final system = (requests.first['messages'] as List<dynamic>).cast<Map<String, dynamic>>().first;
      expect(system['role'], 'system');
      expect(system['content'], allOf(contains('<math_graphs>'), contains('LaTeX')));
      final saved = db.rows[chat.conversation.id]!;
      final restored = Conversation.fromJson(jsonDecode(jsonEncode(saved.toJson())) as Map<String, dynamic>);
      final part = restored.currentMessages.last.parts.whereType<ToolPart>().single;
      expect(part.name, 'plot_cartesian');
      expect(part.executed, isTrue);
      expect(part.isError, isTrue);
      expect(jsonDecode(part.output!)['error'], contains('Unknown function'));
      final messages = requests.last['messages'] as List<dynamic>;
      final toolReply = messages.cast<Map<String, dynamic>>().singleWhere((message) => message['role'] == 'tool');
      expect(toolReply['tool_call_id'], 'invalid-plot');
      expect(jsonDecode(toolReply['content'] as String)['error'], contains('Unknown function'));
    } finally {
      chat.dispose();
      mcp.dispose();
      await server.close(force: true);
      Net.reconfigure();
      await store.flush();
      store.dispose();
      // Writes that finish after the reply can still land in the sandbox
      // while it is removed; retry instead of failing on "Directory not empty".
      for (var attempt = 0; attempt < 10; attempt++) {
        try {
          await temp.delete(recursive: true);
          break;
        } on FileSystemException {
          if (attempt == 9) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }
  });
}
