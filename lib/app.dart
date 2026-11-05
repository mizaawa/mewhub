import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'core/i18n.dart';
import 'data/settings.dart';
import 'state/settings_store.dart';
import 'ui/assistant/assistants_page.dart';
import 'ui/chat/chat_page.dart';
import 'ui/onboarding.dart';
import 'ui/pages/extensions_pages.dart';
import 'ui/pages/misc_settings.dart';
import 'ui/pages/tools_pages.dart';
import 'ui/settings/providers_page.dart';
import 'ui/settings/settings_page.dart';
import 'ui/theme.dart';

class MewHubApp extends StatefulWidget {
  const MewHubApp({super.key});

  @override
  State<MewHubApp> createState() => _MewHubAppState();
}

class _MewHubAppState extends State<MewHubApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Persist settings when the app goes to background (iOS may kill it).
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
      context.read<SettingsStore>().flush();
    }
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    final store = context.read<SettingsStore>();
    if (store.value.language == AppLang.system) store.update((s) => s);
  }

  static final Map<String, WidgetBuilder> _routes = {
    '/settings': (_) => const SettingsPage(),
    '/providers': (_) => const ProvidersPage(),
    '/assistants': (_) => const AssistantsPage(),
    '/settings/models': (_) => const DefaultModelsPage(),
    '/settings/display': (_) => const DisplaySettingsPage(),
    '/settings/search': (_) => const SearchSettingsPage(),
    '/settings/tts': (_) => const TtsSettingsPage(),
    '/settings/network': (_) => const NetworkSettingsPage(),
    '/settings/logs': (_) => const RequestLogsPage(),
    '/settings/mcp': (_) => const McpPage(),
    '/settings/prompts': (_) => const PromptsPage(),
    '/settings/quick': (_) => const QuickMessagesPage(),
    '/settings/memory': (_) => const MemoryPage(),
    '/settings/backup': (_) => const BackupPage(),
    '/settings/stats': (_) => const StatsPage(),
    '/settings/about': (_) => const AboutPage(),
    '/translator': (_) => const TranslatorPage(),
    '/imagegen': (_) => const ImageGenPage(),
    '/favorites': (_) => const FavoritesPage(),
    '/search': (_) => const SearchPage(),
  };

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SettingsStore>().value;
    return MaterialApp(
      title: 'MewHub',
      debugShowCheckedModeBanner: false,
      theme: MewTheme.light(s.accentIndex),
      darkTheme: MewTheme.dark(s.accentIndex),
      themeMode: switch (s.themeMode) {
        ThemeModePref.system => ThemeMode.system,
        ThemeModePref.light => ThemeMode.light,
        ThemeModePref.dark => ThemeMode.dark,
      },
      themeAnimationDuration: const Duration(milliseconds: 450),
      themeAnimationCurve: Curves.easeOutCubic,
      locale: switch (s.language) {
        AppLang.zh => const Locale('zh', 'CN'),
        AppLang.en => const Locale('en'),
        AppLang.system => null,
      },
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      // Rebuild every page when the language changes, since strings come from t().
      key: ValueKey('lang-${I18n.isZh}'),
      home: s.onboarded ? const ChatPage() : const OnboardingPage(),
      routes: _routes,
    );
  }
}
