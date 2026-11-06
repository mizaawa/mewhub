import 'dart:convert';

import '../../core/net.dart';
import '../../core/sse.dart';
import '../../core/util.dart';
import '../encoding.dart';
import '../message.dart';
import '../provider.dart';
import '../provider_config.dart';
import 'openai_common.dart' show documentAsText;

/// Google Gemini API (`generativelanguage.googleapis.com/v1beta`).
class GoogleProvider extends AiProvider {
  GoogleProvider(super.config);

  Map<String, String> _headers(GenerationParams? p) =>
      mergeHeaders({'Content-Type': 'application/json', 'x-goog-api-key': nextKey()}, p);

  @override
  Future<List<RemoteModel>> listModels() async {
    final out = <RemoteModel>[];
    String? token;
    for (var page = 0; page < 10; page++) {
      final q = <String, String>{'pageSize': '1000'};
      if (token != null) q['pageToken'] = token;
      final uri = Uri.parse('${config.trimmedBaseUrl}/models').replace(queryParameters: q);
      final j = asMap(
        await Net.json(
          'GET',
          uri,
          headers: _headers(null),
          timeout: const Duration(seconds: 30),
          providerId: config.id,
        ),
      );
      for (final e in asList(j['models'])) {
        final m = asMap(e);
        final methods = asList(m['supportedGenerationMethods']);
        if (methods.isNotEmpty && !methods.contains('generateContent') && !methods.contains('predict')) continue;
        final name = asStr(m['name']).replaceFirst('models/', '');
        out.add(RemoteModel(name, asStrOrNull(m['displayName'])));
      }
      token = asStrOrNull(j['nextPageToken']);
      if (token == null || token.isEmpty) break;
    }
    return out;
  }

  @override
  Future<List<String>> generateImage(ModelConfig model, String prompt, {int n = 1, String size = '1024x1024'}) async {
    if (model.modelId.startsWith('imagen')) {
      final j = asMap(
        await Net.json(
          'POST',
          Uri.parse('${config.trimmedBaseUrl}/models/${model.modelId}:predict'),
          headers: _headers(null),
          body: {
            'instances': [
              {'prompt': prompt},
            ],
            'parameters': {'sampleCount': n},
          },
          timeout: const Duration(minutes: 5),
          providerId: config.id,
        ),
      );
      final out = <String>[];
      for (final p in asList(j['predictions'])) {
        final m = asMap(p);
        final b64 = asStrOrNull(m['bytesBase64Encoded']);
        if (b64 != null) out.add('data:${asStr(m['mimeType'], 'image/png')};base64,$b64');
      }
      if (out.isEmpty) throw ApiException('No image returned');
      return out;
    }
    final out = <String>[];
    await for (final c in stream([
      ChatMessage.text(Role.user, prompt),
    ], GenerationParams(model: model, stream: false))) {
      if (c is ImageChunk) out.add(c.dataUri);
    }
    if (out.isEmpty) throw ApiException('No image returned');
    return out;
  }

  @override
  Stream<StreamChunk> stream(List<ChatMessage> messages, GenerationParams p, {CancelToken? cancel}) async* {
    final method = p.stream ? 'streamGenerateContent?alt=sse' : 'generateContent';
    final url = Uri.parse('${config.trimmedBaseUrl}/models/${p.model.modelId}:$method');
    final body = mergeBody(await _buildBody(messages, p), p);
    if (!p.stream) {
      final j = asMap(
        await Net.json('POST', url, headers: _headers(p), body: body, cancel: cancel, providerId: config.id),
      );
      yield* _parseResponse(j, _CallIds());
      return;
    }
    final res = await Net.send(
      'POST',
      url,
      headers: _headers(p),
      body: jsonEncode(body),
      cancel: cancel,
      providerId: config.id,
    );
    final ids = _CallIds();
    await for (final ev in parseSse(res.stream)) {
      final j = asMapOrNull(tryJsonDecode(ev.data));
      if (j == null) continue;
      if (j['error'] != null) throw ApiException(asStr(asMap(j['error'])['message'], 'Gemini stream error'));
      yield* _parseResponse(j, ids);
    }
  }

  Stream<StreamChunk> _parseResponse(Map<String, dynamic> j, _CallIds ids) async* {
    for (final c in asList(j['candidates'])) {
      final cand = asMap(c);
      for (final rawPart in asList(asMap(cand['content'])['parts'])) {
        final part = asMap(rawPart);
        final sig = asStrOrNull(part['thoughtSignature']);
        if (part['functionCall'] != null) {
          final fc = asMap(part['functionCall']);
          final id = asStrOrNull(fc['id']) ?? ids.next();
          yield ToolCallStart(id, asStr(fc['name']), meta: {'thoughtSignature': ?sig});
          yield ToolCallDelta(id, jsonEncode(fc['args'] ?? {}));
        } else if (part['inlineData'] != null) {
          final d = asMap(part['inlineData']);
          if (asBool(part['thought'])) continue;
          yield ImageChunk(
            'data:${asStr(d['mimeType'], 'image/png')};base64,${asStr(d['data'])}',
            meta: {'thoughtSignature': ?sig},
          );
        } else if (part['text'] != null) {
          final text = asStr(part['text']);
          if (asBool(part['thought'])) {
            yield ReasoningDelta(text, meta: {'thoughtSignature': ?sig});
          } else {
            if (sig != null) yield ReasoningDelta('', meta: {'thoughtSignature': sig});
            yield TextDelta(text);
          }
        } else if (sig != null) {
          yield ReasoningDelta('', meta: {'thoughtSignature': sig});
        }
      }
      final g = asMapOrNull(cand['groundingMetadata']);
      if (g != null) {
        final cites = <Citation>[];
        for (final ch in asList(g['groundingChunks'])) {
          final web = asMap(asMap(ch)['web']);
          final u = asStrOrNull(web['uri']);
          if (u != null) cites.add(Citation(title: asStr(web['title'], u), url: u));
        }
        if (cites.isNotEmpty) yield CitationChunk(cites);
      }
      final finish = asStrOrNull(cand['finishReason']);
      if (finish != null) yield FinishChunk(finish);
    }
    final u = asMapOrNull(j['usageMetadata']);
    if (u != null) {
      yield UsageChunk(
        TokenUsage(
          input: asInt(u['promptTokenCount']),
          output: asInt(u['candidatesTokenCount']) + asInt(u['thoughtsTokenCount']),
          cached: asInt(u['cachedContentTokenCount']),
          reasoning: asInt(u['thoughtsTokenCount']),
        ),
      );
    }
    final block = asMapOrNull(j['promptFeedback']);
    if (block != null && block['blockReason'] != null) {
      throw ApiException('Blocked: ${block['blockReason']}');
    }
  }

  Future<Map<String, dynamic>> _buildBody(List<ChatMessage> messages, GenerationParams p) async {
    final body = <String, dynamic>{'contents': await _buildContents(messages, p.model)};
    final system = messages.where((m) => m.role == Role.system).map((m) => m.text).join('\n\n');
    if (system.isNotEmpty) {
      body['systemInstruction'] = {
        'parts': [
          {'text': system},
        ],
      };
    }
    final gen = <String, dynamic>{};
    if (p.temperature != null) gen['temperature'] = p.temperature;
    if (p.topP != null) gen['topP'] = p.topP;
    if (p.maxTokens != null) gen['maxOutputTokens'] = p.maxTokens;
    if (p.model.imageOutput) gen['responseModalities'] = ['TEXT', 'IMAGE'];
    if (p.model.reasoning) gen['thinkingConfig'] = _thinking(p);
    if (gen.isNotEmpty) body['generationConfig'] = gen;

    final tools = <Map<String, dynamic>>[];
    // Gemini < 3 rejects google_search combined with function calling.
    final searchOnly = p.useBuiltInSearch && !RegExp(r'gemini-[3-9]').hasMatch(p.model.modelId.toLowerCase());
    if (p.model.tools && p.tools.isNotEmpty && !searchOnly) {
      tools.add({
        'functionDeclarations': [
          for (final t in p.tools) {'name': t.name, 'description': t.description, 'parametersJsonSchema': t.parameters},
        ],
      });
    }
    if (p.useBuiltInSearch) {
      tools.add({'google_search': <String, dynamic>{}});
    }
    if (p.model.builtInTools.contains(BuiltInTool.urlContext)) {
      tools.add({'url_context': <String, dynamic>{}});
    }
    if (tools.isNotEmpty) body['tools'] = tools;
    body['safetySettings'] = [
      for (final c in const [
        'HARM_CATEGORY_HARASSMENT',
        'HARM_CATEGORY_HATE_SPEECH',
        'HARM_CATEGORY_SEXUALLY_EXPLICIT',
        'HARM_CATEGORY_DANGEROUS_CONTENT',
      ])
        {'category': c, 'threshold': 'BLOCK_ONLY_HIGH'},
    ];
    return body;
  }

  Map<String, dynamic> _thinking(GenerationParams p) {
    final id = p.model.modelId.toLowerCase();
    final gemini3 = RegExp(r'gemini-[3-9]').hasMatch(id);
    final level = p.reasoning;
    if (!level.enabled) {
      // Gemini 2.5 Pro cannot fully disable thinking; 128 is its minimum budget.
      if (gemini3) return {'thinkingLevel': 'minimal', 'includeThoughts': false};
      if (id.contains('pro')) return {'thinkingBudget': 128, 'includeThoughts': false};
      return {'thinkingBudget': 0, 'includeThoughts': false};
    }
    if (level == ReasoningLevel.auto) {
      return gemini3 ? {'includeThoughts': true} : {'thinkingBudget': -1, 'includeThoughts': true};
    }
    if (gemini3) {
      final l = switch (level) {
        ReasoningLevel.low => 'low',
        ReasoningLevel.medium => 'medium',
        _ => 'high',
      };
      return {'thinkingLevel': l, 'includeThoughts': true};
    }
    return {'thinkingBudget': level.budget, 'includeThoughts': true};
  }

  Future<List<Map<String, dynamic>>> _buildContents(List<ChatMessage> messages, ModelConfig model) async {
    final out = <Map<String, dynamic>>[];
    void push(String role, List<Map<String, dynamic>> parts) {
      if (parts.isEmpty) return;
      if (out.isNotEmpty && out.last['role'] == role) {
        (out.last['parts'] as List).addAll(parts);
      } else {
        out.add({'role': role, 'parts': parts});
      }
    }

    for (final m in messages) {
      if (m.role == Role.system) continue;
      if (m.role == Role.user) {
        final parts = <Map<String, dynamic>>[];
        for (final part in m.parts) {
          switch (part) {
            case TextPart(:final text):
              if (text.isNotEmpty) parts.add({'text': text});
            case ImagePart(:final url):
              if (!model.vision) continue;
              final enc = await MediaEncoder.encodeImage(url, providerId: config.id);
              if (enc != null) {
                parts.add({
                  'inlineData': {'mimeType': enc.mime, 'data': enc.base64},
                });
              }
            case DocumentPart():
              parts.add({'text': documentAsText(part)});
            default:
              break;
          }
        }
        push('user', parts);
        continue;
      }
      if (m.role != Role.assistant) continue;
      var modelParts = <Map<String, dynamic>>[];
      var responses = <Map<String, dynamic>>[];
      String? pendingSig;
      void flushRound() {
        push('model', modelParts);
        push('user', responses);
        modelParts = [];
        responses = [];
      }

      for (final part in m.parts) {
        switch (part) {
          case ReasoningPart():
            final s = part.meta?['thoughtSignature'];
            if (s is String && s.isNotEmpty) pendingSig = s;
          case TextPart():
            if (responses.isNotEmpty) flushRound();
            if (part.text.isEmpty && pendingSig == null) continue;
            modelParts.add({'text': part.text, 'thoughtSignature': ?pendingSig});
            pendingSig = null;
          case ImagePart(:final url):
            final enc = await MediaEncoder.encodeImage(url, providerId: config.id);
            if (enc == null) continue;
            if (responses.isNotEmpty) flushRound();
            final s = part.meta?['thoughtSignature'];
            modelParts.add({
              'inlineData': {'mimeType': enc.mime, 'data': enc.base64},
              if (s is String) 'thoughtSignature': s,
            });
          case ToolPart():
            if (!part.executed) continue;
            final s = part.meta?['thoughtSignature'] ?? pendingSig;
            pendingSig = null;
            modelParts.add({
              'functionCall': {'name': part.name, 'args': part.inputJson},
              if (s is String) 'thoughtSignature': s,
            });
            final parsed = tryJsonDecode(part.output ?? '');
            responses.add({
              'functionResponse': {
                'name': part.name,
                'response': parsed is Map ? parsed : {'result': part.output ?? ''},
              },
            });
          default:
            break;
        }
      }
      flushRound();
    }
    return out;
  }
}

class _CallIds {
  int _n = 0;
  String next() => 'gcall_${_n++}_${newId().substring(0, 6)}';
}
