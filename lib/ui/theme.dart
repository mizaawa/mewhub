import 'package:animations/animations.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// MewHub palette: warm milk-white surfaces with a soft caramel / latte accent.
class MewColors {
  static const cream = Color(0xFFFBF7F1);
  static const milk = Color(0xFFFFFDF9);
  static const porcelain = Color(0xFFF4EEE5);
  static const oat = Color(0xFFEAE1D4);
  static const latte = Color(0xFFC9A27E);
  static const caramel = Color(0xFFB07D52);
  static const cocoa = Color(0xFF4A3B30);
  static const ink = Color(0xFF2B2420);
  static const mute = Color(0xFF8C7E72);

  static const nightBase = Color(0xFF16130F);
  static const nightSurface = Color(0xFF201C17);
  static const nightRaised = Color(0xFF2A251F);
  static const nightLine = Color(0xFF3A332B);

  static const accents = <Color>[
    Color(0xFFB07D52),
    Color(0xFFC48A9A),
    Color(0xFF7E9C8B),
    Color(0xFF8A93B8),
    Color(0xFF6F98AD),
    Color(0xFFB8956A),
  ];

  static const accentNames = ['焦糖 Caramel', '樱花 Sakura', '抹茶 Matcha', '薰衣草 Lavender', '海盐 Sea salt', '蜂蜜 Honey'];
}

/// System bars keep the app canvas visible behind gesture and three-button
/// navigation on Android. In particular, SystemUiOverlayStyle.light/dark both
/// hard-code a black navigation bar, which leaves a black strip below pages.
SystemUiOverlayStyle mewSystemUiOverlayStyle(Brightness brightness) => SystemUiOverlayStyle(
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarDividerColor: Colors.transparent,
  systemNavigationBarIconBrightness: brightness == Brightness.dark ? Brightness.light : Brightness.dark,
  systemNavigationBarContrastEnforced: false,
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: brightness == Brightness.dark ? Brightness.light : Brightness.dark,
  statusBarBrightness: brightness == Brightness.dark ? Brightness.dark : Brightness.light,
  systemStatusBarContrastEnforced: false,
);

class MewTheme {
  static ThemeData light(int accent) => _build(Brightness.light, MewColors.accents[accent % MewColors.accents.length]);
  static ThemeData dark(int accent) => _build(Brightness.dark, MewColors.accents[accent % MewColors.accents.length]);

  static ColorScheme _scheme(Brightness b, Color accent) {
    final dark = b == Brightness.dark;
    return ColorScheme.fromSeed(seedColor: accent, brightness: b).copyWith(
      primary: dark ? Color.lerp(accent, Colors.white, 0.18) : accent,
      onPrimary: Colors.white,
      surface: dark ? MewColors.nightBase : MewColors.cream,
      onSurface: dark ? const Color(0xFFF1EAE1) : MewColors.ink,
      onSurfaceVariant: dark ? const Color(0xFFB5A99C) : MewColors.mute,
      surfaceContainerLowest: dark ? const Color(0xFF110E0B) : Colors.white,
      surfaceContainerLow: dark ? MewColors.nightSurface : MewColors.milk,
      surfaceContainer: dark ? MewColors.nightSurface : MewColors.porcelain,
      surfaceContainerHigh: dark ? MewColors.nightRaised : const Color(0xFFEFE7DC),
      surfaceContainerHighest: dark ? const Color(0xFF332D26) : MewColors.oat,
      outline: dark ? const Color(0xFF5A5046) : const Color(0xFFD9CDBE),
      outlineVariant: dark ? MewColors.nightLine : const Color(0xFFEAE0D3),
      secondaryContainer: dark ? Color.lerp(accent, MewColors.nightBase, 0.72) : Color.lerp(accent, Colors.white, 0.80),
      onSecondaryContainer: dark ? const Color(0xFFF6EDE3) : MewColors.cocoa,
      primaryContainer: dark ? Color.lerp(accent, MewColors.nightBase, 0.6) : Color.lerp(accent, Colors.white, 0.72),
      onPrimaryContainer: dark ? Colors.white : MewColors.cocoa,
      shadow: dark ? Colors.black : const Color(0xFF7A5C3E),
    );
  }

  static ThemeData _build(Brightness b, Color accent) {
    final dark = b == Brightness.dark;
    final scheme = _scheme(b, accent);
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: b,
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      // Press feedback tinted with the accent instead of Material's neutral
      // grey, so ripples and highlights belong to the milk / caramel palette.
      splashColor: scheme.primary.withValues(alpha: dark ? 0.18 : 0.12),
      highlightColor: scheme.primary.withValues(alpha: dark ? 0.12 : 0.08),
      hoverColor: scheme.primary.withValues(alpha: 0.05),
      focusColor: scheme.primary.withValues(alpha: 0.10),
    );
    final text = base.textTheme.apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);
    final r14 = BorderRadius.circular(14);
    final popupBg = dark ? MewColors.nightRaised : MewColors.cocoa;
    return base.copyWith(
      textTheme: text.copyWith(
        titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        bodyLarge: text.bodyLarge?.copyWith(height: 1.55),
        bodyMedium: text.bodyMedium?.copyWith(height: 1.5),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: SharedAxisPageTransitionsBuilder(transitionType: SharedAxisTransitionType.horizontal),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, fontSize: 20),
        systemOverlayStyle: mewSystemUiOverlayStyle(b),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, thickness: 0.6, space: 1),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: r14),
        iconColor: scheme.onSurfaceVariant,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: r14,
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: r14,
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: r14,
          borderSide: BorderSide(color: scheme.primary, width: 1.4),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: r14),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: r14),
          side: BorderSide(color: scheme.outline),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        elevation: 6,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: popupBg,
        contentTextStyle: const TextStyle(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: r14),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      drawerTheme: DrawerThemeData(backgroundColor: scheme.surface, surfaceTintColor: Colors.transparent),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(color: popupBg, borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}
