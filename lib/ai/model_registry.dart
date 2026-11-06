import 'provider_config.dart';

/// Guesses capabilities from a model id, so models fetched from `/models`
/// get sensible defaults. Users can always override per model.
class ModelRegistry {
  static final _reasoning = [
    RegExp(r'\bo[1-9](-|$|\b)'),
    RegExp(r'gpt-5'),
    RegExp(r'gpt-6'),
    RegExp(r'gpt-oss'),
    RegExp(r'claude-(3-7|sonnet-4|opus-4|haiku-4|4|[5-9])'),
    RegExp(r'claude-(sonnet|opus|haiku)-[4-9]'),
    RegExp(r'gemini-(2\.5|[3-9])'),
    RegExp(r'deepseek-(r1|reasoner|v3\.[1-9]|v[4-9])'),
    RegExp(r'qwq|qwen3|qwen-plus|qwen-max'),
    RegExp(r'glm-(4\.[5-9]|[5-9])'),
    RegExp(r'kimi-k2|k2-thinking|kimi-k[3-9]'),
    RegExp(r'grok-(3-mini|4|[5-9])'),
    RegExp(r'thinking|reason'),
    RegExp(r'minimax-m[1-9]'),
    RegExp(r'doubao-.*(thinking|seed-1\.[6-9])'),
  ];

  static final _vision = [
    RegExp(r'gpt-4o|gpt-4\.1|gpt-4-turbo|gpt-4-vision|gpt-5|gpt-6|\bo[3-9]\b|o4-mini'),
    RegExp(r'claude-(3|sonnet|opus|haiku|4|[5-9])'),
    RegExp(r'gemini'),
    RegExp(r'gemma-3'),
    RegExp(r'vision|-vl|vl-|qvq|omni'),
    RegExp(r'grok-(2-vision|4|[5-9])'),
    RegExp(r'llava|pixtral|mistral-(medium|small)-3'),
    RegExp(r'glm-4(\.[5-9])?v|glm-[5-9]v'),
    RegExp(r'kimi-k2\.[5-9]|kimi-latest|moonshot-v1-.*-vision'),
    RegExp(r'doubao-.*(vision|seed)'),
    RegExp(r'llama-4'),
  ];

  static final _noTools = [
    RegExp(r'embedding|embed|whisper|tts|dall-e|gpt-image|imagen|rerank|moderation'),
    RegExp(r'deepseek-r1(?!-0528)'),
    RegExp(r'\bo1-(mini|preview)'),
    RegExp(r'-image(-|$)|image-preview|nano-banana'),
  ];

  static final _imageOut = [
    RegExp(r'gemini-.*image|nano-banana'),
    RegExp(r'gpt-image|dall-e|imagen|flux|stable-diffusion|sdxl|seedream|kolors|cogview|wanx|qwen-image'),
  ];

  static final _imageOnlyModels = [
    RegExp(r'gpt-image|dall-e|imagen|flux|stable-diffusion|sdxl|seedream|kolors|cogview|wanx|qwen-image'),
  ];

  static final _embedding = [RegExp(r'embedding|embed|bge-|m3e|text-similarity')];

  static bool _any(List<RegExp> rs, String id) => rs.any((r) => r.hasMatch(id));

  static ModelConfig guess(String modelId, {String? displayName}) {
    final id = modelId.toLowerCase();
    if (_any(_embedding, id)) {
      return ModelConfig(modelId: modelId, displayName: displayName, type: ModelType.embedding);
    }
    if (_any(_imageOnlyModels, id)) {
      return ModelConfig(
        modelId: modelId,
        displayName: displayName,
        type: ModelType.image,
        input: {Modality.text, Modality.image},
        output: {Modality.image},
      );
    }
    final abilities = <ModelAbility>{};
    if (!_any(_noTools, id)) abilities.add(ModelAbility.tool);
    if (_any(_reasoning, id)) abilities.add(ModelAbility.reasoning);
    final input = {Modality.text, if (_any(_vision, id)) Modality.image};
    final output = {Modality.text, if (_any(_imageOut, id)) Modality.image};
    return ModelConfig(
      modelId: modelId,
      displayName: displayName,
      input: input,
      output: output,
      abilities: abilities,
      contextLength: _context(id),
    );
  }

  static int _context(String id) {
    if (id.contains('gemini')) return 1048576;
    if (id.contains('gpt-4.1') || id.contains('gpt-5') || id.contains('gpt-6')) return 272000;
    if (id.contains('claude')) return 200000;
    if (id.contains('deepseek')) return 128000;
    return 128000;
  }

  /// Returns a short label for the model family, used to pick avatar glyphs.
  static String family(String modelId) {
    final id = modelId.toLowerCase();
    const map = {
      'claude': 'Claude',
      'gpt': 'OpenAI',
      'o1': 'OpenAI',
      'o3': 'OpenAI',
      'o4': 'OpenAI',
      'gemini': 'Gemini',
      'gemma': 'Gemini',
      'deepseek': 'DeepSeek',
      'qwen': 'Qwen',
      'qwq': 'Qwen',
      'glm': 'GLM',
      'kimi': 'Kimi',
      'moonshot': 'Kimi',
      'grok': 'Grok',
      'llama': 'Llama',
      'mistral': 'Mistral',
      'doubao': 'Doubao',
      'minimax': 'MiniMax',
      'hunyuan': 'Hunyuan',
      'ernie': 'ERNIE',
      'step': 'Step',
    };
    for (final e in map.entries) {
      if (id.contains(e.key)) return e.value;
    }
    return '';
  }
}
