import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/i18n.dart';
import '../../data/settings.dart';
import '../../state/settings_store.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/motion.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<SettingsStore>();
    final s = store.value;
    final scheme = Theme.of(context).colorScheme;
    final enabledProviders = s.providers.where((p) => p.enabled).length;
    final models = s.allModels().length;

    Widget nav(IconData icon, String title, String route, {String? subtitle, Color? color}) => ListTile(
      leading: IconBadge(icon, color: color),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => Navigator.of(context).pushNamed(route),
    );

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(title: Text(t('设置', 'Settings'))),
          SliverToBoxAdapter(
            child: EntranceFx(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: _HeroCard(providers: enabledProviders, models: models, assistants: s.assistants.length),
              ),
            ),
          ),
          SliverList.list(
            children: [
              SettingsGroup(
                index: 1,
                title: t('外观', 'Appearance'),
                children: [
                  ListTile(
                    leading: const IconBadge(Icons.contrast_rounded),
                    title: Text(t('主题模式', 'Theme')),
                    trailing: SegmentedButton<ThemeModePref>(
                      showSelectedIcon: false,
                      style: const ButtonStyle(visualDensity: VisualDensity.compact),
                      segments: [
                        ButtonSegment(
                          value: ThemeModePref.system,
                          icon: const Icon(Icons.brightness_auto_rounded, size: 18),
                        ),
                        ButtonSegment(value: ThemeModePref.light, icon: const Icon(Icons.light_mode_rounded, size: 18)),
                        ButtonSegment(value: ThemeModePref.dark, icon: const Icon(Icons.dark_mode_rounded, size: 18)),
                      ],
                      selected: {s.themeMode},
                      onSelectionChanged: (v) => store.update((x) => x.copyWith(themeMode: v.first)),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                    child: Row(
                      children: [
                        const IconBadge(Icons.palette_outlined),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              for (var i = 0; i < MewColors.accents.length; i++)
                                Tooltip(
                                  message: MewColors.accentNames[i],
                                  child: Pressable(
                                    onTap: () => store.update((x) => x.copyWith(accentIndex: i)),
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 260),
                                      width: 32,
                                      height: 32,
                                      decoration: BoxDecoration(
                                        color: MewColors.accents[i],
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: s.accentIndex == i ? scheme.onSurface : Colors.transparent,
                                          width: 2.5,
                                        ),
                                      ),
                                      child: s.accentIndex == i
                                          ? const Icon(Icons.check_rounded, size: 18, color: Colors.white)
                                          : null,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  ListTile(
                    leading: const IconBadge(Icons.language_rounded),
                    title: Text(t('语言', 'Language')),
                    trailing: DropdownButton<AppLang>(
                      value: s.language,
                      underline: const SizedBox.shrink(),
                      borderRadius: BorderRadius.circular(14),
                      items: [
                        DropdownMenuItem(value: AppLang.system, child: Text(t('跟随系统', 'System'))),
                        const DropdownMenuItem(value: AppLang.zh, child: Text('简体中文')),
                        const DropdownMenuItem(value: AppLang.en, child: Text('English')),
                      ],
                      onChanged: (v) => store.update((x) => x.copyWith(language: v)),
                    ),
                  ),
                  nav(Icons.chat_bubble_outline_rounded, t('聊天显示', 'Chat display'), '/settings/display'),
                ],
              ),
              SettingsGroup(
                index: 2,
                title: t('模型与服务', 'Models & services'),
                children: [
                  nav(
                    Icons.hub_outlined,
                    t('供应商', 'Providers'),
                    '/providers',
                    subtitle: t('已启用 $enabledProviders 个 · $models 个模型', '$enabledProviders enabled · $models models'),
                  ),
                  nav(Icons.auto_awesome_outlined, t('默认模型', 'Default models'), '/settings/models'),
                  nav(
                    Icons.face_retouching_natural_outlined,
                    t('助手', 'Assistants'),
                    '/assistants',
                    subtitle: t('${s.assistants.length} 个助手', '${s.assistants.length} assistants'),
                  ),
                  nav(
                    Icons.travel_explore_rounded,
                    t('联网搜索', 'Web search'),
                    '/settings/search',
                    subtitle: s.currentSearch?.label,
                  ),
                  nav(
                    Icons.extension_outlined,
                    'MCP',
                    '/settings/mcp',
                    subtitle: t('${s.mcpServers.length} 个服务器', '${s.mcpServers.length} servers'),
                  ),
                  nav(Icons.record_voice_over_outlined, t('语音朗读', 'Text to speech'), '/settings/tts'),
                ],
              ),
              SettingsGroup(
                index: 3,
                title: t('扩展', 'Extensions'),
                children: [
                  nav(Icons.menu_book_outlined, t('世界书 / 模式', 'Lorebooks & modes'), '/settings/prompts'),
                  nav(Icons.short_text_rounded, t('快捷短语', 'Quick messages'), '/settings/quick'),
                  nav(Icons.psychology_outlined, t('记忆', 'Memories'), '/settings/memory'),
                ],
              ),
              SettingsGroup(
                index: 4,
                title: t('数据', 'Data'),
                children: [
                  nav(Icons.cloud_sync_outlined, t('备份与恢复', 'Backup & restore'), '/settings/backup'),
                  nav(Icons.insights_outlined, t('用量统计', 'Usage stats'), '/settings/stats'),
                  nav(Icons.wifi_tethering_rounded, t('网络', 'Network'), '/settings/network'),
                  nav(Icons.receipt_long_outlined, t('请求日志', 'Request logs'), '/settings/logs'),
                ],
              ),
              SettingsGroup(
                index: 5,
                children: [nav(Icons.info_outline_rounded, t('关于 MewHub', 'About MewHub'), '/settings/about')],
              ),
              const SizedBox(height: 32),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.providers, required this.models, required this.assistants});
  final int providers;
  final int models;
  final int assistants;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget stat(String n, String label) => Expanded(
      child: Column(
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: double.tryParse(n) ?? 0),
            duration: const Duration(milliseconds: 900),
            curve: Curves.easeOutCubic,
            builder: (context, v, _) => Text(
              v.round().toString(),
              style: Theme.of(context).textTheme.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w800, color: Colors.white),
            ),
          ),
          Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Colors.white70)),
        ],
      ),
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          colors: [scheme.primary, Color.lerp(scheme.primary, const Color(0xFFE9C3A0), 0.55)!],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(color: scheme.primary.withValues(alpha: 0.28), blurRadius: 24, offset: const Offset(0, 10)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('🐱', style: TextStyle(fontSize: 26)),
              const SizedBox(width: 10),
              Text(
                'MewHub',
                style: Theme.of(context).textTheme.titleLarge
                    ?.copyWith(color: Colors.white, fontWeight: FontWeight.w800, letterSpacing: -0.3),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              stat('$providers', t('供应商', 'Providers')),
              stat('$models', t('模型', 'Models')),
              stat('$assistants', t('助手', 'Assistants')),
            ],
          ),
        ],
      ),
    );
  }
}
