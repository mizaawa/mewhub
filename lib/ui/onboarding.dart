import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ai/factory.dart';
import '../ai/model_registry.dart';
import '../ai/provider_config.dart';
import '../core/i18n.dart';
import '../state/settings_store.dart';
import 'widgets/common.dart';
import 'widgets/motion.dart';

/// First-run flow: welcome → connect a provider (optional) → chat.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _pages = PageController();
  int _page = 0;
  String _templateId = 'p-openai';
  final _key = TextEditingController();
  final _url = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _pages.dispose();
    _key.dispose();
    _url.dispose();
    super.dispose();
  }

  void _finish() => context.read<SettingsStore>().update((s) => s.copyWith(onboarded: true));

  void _next() {
    _pages.nextPage(duration: const Duration(milliseconds: 520), curve: Curves.easeOutCubic);
  }

  Future<void> _connect() async {
    final store = context.read<SettingsStore>();
    final tpl = store.value.providers.firstWhere((p) => p.id == _templateId);
    if (_key.text.trim().isEmpty && !tpl.baseUrl.contains('127.0.0.1')) {
      toast(context, t('请填写 API Key', 'Enter your API key'), error: true);
      return;
    }
    setState(() => _busy = true);
    var p = tpl.copyWith(
      apiKey: _key.text.trim(),
      baseUrl: _url.text.trim().isEmpty ? tpl.baseUrl : _url.text.trim(),
      enabled: true,
    );
    try {
      final remote = await providerFor(p).listModels();
      if (remote.isNotEmpty) {
        final existing = p.models.map((m) => m.modelId).toSet();
        final chatLike = remote.where((r) => ModelRegistry.guess(r.id).type == ModelType.chat).take(40);
        p = p.copyWith(
          models: [
            ...p.models.where((m) => remote.any((r) => r.id == m.modelId) || remote.length < 3),
            for (final r in chatLike)
              if (!existing.contains(r.id)) ModelRegistry.guess(r.id, displayName: r.name),
          ],
        );
      }
    } catch (e) {
      if (mounted) toast(context, t('无法获取模型列表，已使用预设模型：$e', 'Could not list models, using presets: $e'), error: true);
    }
    store.upsertProvider(p);
    final first = p.models.where((m) => m.type == ModelType.chat).firstOrNull;
    if (first != null) store.update((s) => s.copyWith(chatModelId: s.chatModelId ?? first.id));
    if (mounted) setState(() => _busy = false);
    _finish();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: AmbientBackground(
        intensity: 1.6,
        child: SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: _finish, child: Text(t('跳过', 'Skip'))),
              ),
              Expanded(
                child: PageView(
                  controller: _pages,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (i) => setState(() => _page = i),
                  children: [_welcome(context), _connectPage(context)],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < 2; i++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: _page == i ? 22 : 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: _page == i ? scheme.primary : scheme.outline,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _welcome(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final features = [
      (Icons.hub_outlined, t('OpenAI / Claude / Gemini 及任意兼容接口', 'OpenAI, Claude, Gemini & any compatible API')),
      (Icons.psychology_alt_outlined, t('深度思考、联网搜索、MCP 工具', 'Reasoning, web search & MCP tools')),
      (Icons.lock_outline_rounded, t('数据只留在你的设备上', 'Your data stays on your device')),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 1200),
            curve: Curves.elasticOut,
            builder: (context, v, child) => Transform.scale(scale: 0.4 + 0.6 * v, child: child),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(34),
                boxShadow: [
                  BoxShadow(color: scheme.primary.withValues(alpha: 0.35), blurRadius: 40, offset: const Offset(0, 14)),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(34),
                child: Image.asset('assets/images/icon.png', width: 120, height: 120),
              ),
            ),
          ),
          const SizedBox(height: 28),
          EntranceFx(
            index: 2,
            child: Text(
              'MewHub',
              style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -1),
            ),
          ),
          const SizedBox(height: 8),
          EntranceFx(
            index: 3,
            child: Text(
              t('温柔又聪明的 AI 聊天客户端', 'A gentle, clever AI chat client'),
              style: Theme.of(context).textTheme.titleMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 36),
          for (var i = 0; i < features.length; i++)
            EntranceFx(
              index: 4 + i,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Row(
                  children: [
                    IconBadge(features[i].$1),
                    const SizedBox(width: 14),
                    Expanded(child: Text(features[i].$2, style: Theme.of(context).textTheme.bodyLarge)),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 28),
          EntranceFx(
            index: 8,
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _next, child: Text(t('开始', 'Get started'))),
            ),
          ),
        ],
      ),
    );
  }

  Widget _connectPage(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final templates = store.value.providers.where((p) => p.builtIn).toList();
    final tpl = templates.firstWhere((p) => p.id == _templateId, orElse: () => templates.first);
    final isLocal = tpl.baseUrl.contains('127.0.0.1');
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      children: [
        const SizedBox(height: 8),
        EntranceFx(
          child: Text(
            t('连接一个模型服务', 'Connect a model service'),
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
        ),
        const SizedBox(height: 6),
        EntranceFx(
          index: 1,
          child: Text(
            t('之后可以在 设置 → 供应商 添加更多，或导入第三方配置。', 'Add more later in Settings → Providers, or import configs.'),
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
        const SizedBox(height: 20),
        EntranceFx(
          index: 2,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in templates)
                ChoiceChip(
                  label: Text(p.name),
                  selected: p.id == tpl.id,
                  onSelected: (_) => setState(() {
                    _templateId = p.id;
                    _url.text = '';
                  }),
                ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        EntranceFx(
          index: 3,
          child: TextField(
            controller: _url,
            autocorrect: false,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(labelText: 'Base URL', hintText: tpl.baseUrl),
          ),
        ),
        const SizedBox(height: 12),
        if (!isLocal)
          EntranceFx(
            index: 4,
            child: TextField(
              controller: _key,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(labelText: 'API Key', hintText: 'sk-...'),
            ),
          ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(Icons.lock_outline_rounded, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                t('Key 加密保存在系统钥匙串中，只发送给上面的地址。', 'Keys are kept in the system keychain and only sent to the URL above.'),
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: _busy ? null : _connect,
            child: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : Text(t('连接并开始聊天', 'Connect & start chatting')),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: TextButton(onPressed: _finish, child: Text(t('稍后再说', 'Later'))),
        ),
      ],
    );
  }
}
