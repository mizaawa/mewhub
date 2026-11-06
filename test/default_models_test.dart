import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mewhub/ai/message.dart';
import 'package:mewhub/ai/model_registry.dart';
import 'package:mewhub/ai/provider_config.dart';
import 'package:mewhub/chat/helpers.dart';
import 'package:mewhub/data/defaults.dart';
import 'package:mewhub/data/settings.dart';

void main() {
  test('compression model setting can be saved and cleared', () {
    final settings = AppSettings.initial().copyWith(compressModelId: 'compression-model');
    expect(AppSettings.fromJson(settings.toJson()).compressModelId, 'compression-model');
    expect(settings.copyWith(compressModelId: null).compressModelId, isNull);
  });

  test('compression uses its selected model instead of the current chat model', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestBody = Completer<Map<String, dynamic>>();
    server.listen((request) async {
      requestBody.complete(jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>);
      request.response.headers.contentType = ContentType('text', 'event-stream');
      request.response.write('data: {"choices":[{"delta":{"content":"summary"},"finish_reason":"stop"}]}\n\n');
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });
    try {
      final provider = ProviderConfig(
        kind: ProviderKind.openai,
        name: 'Local test provider',
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: 'test',
        models: [
          ModelConfig(id: 'current-model', modelId: 'chat-model'),
          ModelConfig(id: 'compression-model', modelId: 'summary-model'),
        ],
      );
      final settings = AppSettings.initial().copyWith(
        providers: [provider],
        chatModelId: 'current-model',
        compressModelId: 'compression-model',
      );
      final output = await AiHelpers.compress(settings, 'current-model', [ChatMessage.text(Role.user, 'hello')]);
      expect(output, 'summary');
      expect((await requestBody.future)['model'], 'summary-model');
    } finally {
      await server.close(force: true);
    }
  });

  test('GPT context defaults use 272000 tokens', () {
    final models = defaultProviders().firstWhere((provider) => provider.id == 'p-openai').models;
    expect(models.firstWhere((model) => model.modelId == 'gpt-5.1').contextLength, 272000);
    expect(models.firstWhere((model) => model.modelId == 'gpt-5-mini').contextLength, 272000);
    expect(ModelRegistry.guess('gpt-5.1').contextLength, 272000);
  });
}
