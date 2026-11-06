import '../ai/provider_config.dart';

const zakoProviderId = 'p-zako';
const zakoBaseUrl = 'https://api.zayuapi.com';
const zakoWebsite = 'https://www.zayuapi.com';

/// Website icons bundled with the app; provenance is in assets/providers/SOURCES.json.
const providerIconAssets = {
  zakoProviderId: 'assets/providers/zako.png',
  'p-openai': 'assets/providers/openai.png',
  'p-anthropic': 'assets/providers/anthropic.png',
  'p-gemini': 'assets/providers/gemini.png',
  'p-deepseek': 'assets/providers/deepseek.png',
  'p-openrouter': 'assets/providers/openrouter.png',
  'p-siliconflow': 'assets/providers/siliconflow.png',
  'p-moonshot': 'assets/providers/moonshot.png',
  'p-dashscope': 'assets/providers/dashscope.png',
  'p-volc': 'assets/providers/volc.png',
  'p-zhipu': 'assets/providers/zhipu.png',
  'p-xai': 'assets/providers/xai.png',
};

extension ProviderBranding on ProviderConfig {
  bool get isZako => id == zakoProviderId;
  String? get iconAsset => builtIn ? providerIconAssets[id] : null;
}
