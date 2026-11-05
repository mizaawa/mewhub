import 'dart:ui' as ui;

enum AppLang { system, zh, en }

class I18n {
  static bool isZh = true;

  static void apply(AppLang lang) {
    isZh = switch (lang) {
      AppLang.zh => true,
      AppLang.en => false,
      AppLang.system => ui.PlatformDispatcher.instance.locale.languageCode == 'zh',
    };
  }

  static String get localeName => isZh ? '简体中文' : 'English';
}

/// Inline bilingual string. Chinese first, English second.
String t(String zh, String en) => I18n.isZh ? zh : en;
