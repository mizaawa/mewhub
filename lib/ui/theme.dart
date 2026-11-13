import 'package:animations/animations.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/accent_colors.dart';

/// MewHub palette: warm milk-white surfaces with a soft caramel / latte accent.
///
/// These are the colours as designed around Caramel. Every theme reads them
/// through [mewRetint], so surfaces, text and lines follow the chosen accent.
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

  static const accents = accentColors;

  static const accentNames = ['焦糖 Caramel', '樱花 Sakura', '抹茶 Matcha', '薰衣草 Lavender', '海盐 Sea salt', '蜂蜜 Honey'];
}

/// Moves a colour designed around Caramel to the same place around [accent]:
/// the hue turns with the accent and the saturation scales with the accent's,
/// while lightness and alpha stay, so contrast carries over. Caramel itself and
/// colourless white, black and greys come back unchanged.
Color mewRetint(Color designed, Color accent) {
  if (accent == MewColors.caramel) return designed;
  final source = HSLColor.fromColor(designed);
  if (source.saturation == 0) return designed;
  final from = HSLColor.fromColor(MewColors.caramel);
  final to = HSLColor.fromColor(accent);
  return source
      .withHue((source.hue + to.hue - from.hue) % 360)
      .withSaturation(clampDouble(source.saturation * to.saturation / from.saturation, 0, 1))
      .toColor();
}

/// MewHub colours drawn outside the Material [ColorScheme], tinted for the
/// accent exactly like the scheme's surfaces.
@immutable
class MewThemeColors extends ThemeExtension<MewThemeColors> {
  const MewThemeColors({
    required this.accentGlow,
    required this.accentPartner,
    required this.ambientWarm,
    required this.ambientCool,
    required this.codeSurface,
    required this.inlineCode,
    required this.toastSurface,
    required this.plotSeries,
  });

  factory MewThemeColors.forAccent(Color accent, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    Color tone(Color designed) => mewRetint(designed, accent);
    return MewThemeColors(
      accentGlow: tone(const Color(0xFFE7B98F)),
      accentPartner: tone(const Color(0xFF7E9C8B)),
      ambientWarm: tone(const Color(0xFFF2C9A8)),
      ambientCool: tone(const Color(0xFFE8D9F2)),
      codeSurface: tone(dark ? const Color(0xFF1C1915) : const Color(0xFFF7F2EB)),
      inlineCode: tone(dark ? const Color(0xFFF3D9C2) : const Color(0xFF8B4F28)),
      toastSurface: tone(dark ? const Color(0xFF332D26) : MewColors.cocoa),
      plotSeries: _plotSeriesFor(accent, dark),
    );
  }

  /// Light end of accent gradients: user bubbles, the send button, filled tiles.
  final Color accentGlow;

  /// A companion data colour that stays apart from the accent (token output share).
  final Color accentPartner;

  /// Soft washes drifting behind the chat and onboarding.
  final Color ambientWarm;
  final Color ambientCool;

  final Color codeSurface;
  final Color inlineCode;
  final Color toastSurface;

  /// Curve colours of the Cartesian plot, in the order functions take them.
  final List<Color> plotSeries;

  /// Colours of the surrounding theme; plain themes (tests, previews) get Caramel.
  static MewThemeColors of(BuildContext context) => resolve(Theme.of(context));

  static MewThemeColors resolve(ThemeData theme) =>
      theme.extension<MewThemeColors>() ?? MewThemeColors.forAccent(MewColors.caramel, theme.brightness);

  @override
  MewThemeColors copyWith({
    Color? accentGlow,
    Color? accentPartner,
    Color? ambientWarm,
    Color? ambientCool,
    Color? codeSurface,
    Color? inlineCode,
    Color? toastSurface,
    List<Color>? plotSeries,
  }) => MewThemeColors(
    accentGlow: accentGlow ?? this.accentGlow,
    accentPartner: accentPartner ?? this.accentPartner,
    ambientWarm: ambientWarm ?? this.ambientWarm,
    ambientCool: ambientCool ?? this.ambientCool,
    codeSurface: codeSurface ?? this.codeSurface,
    inlineCode: inlineCode ?? this.inlineCode,
    toastSurface: toastSurface ?? this.toastSurface,
    plotSeries: plotSeries ?? this.plotSeries,
  );

  @override
  MewThemeColors lerp(covariant ThemeExtension<MewThemeColors>? other, double t) {
    if (other is! MewThemeColors) return this;
    return MewThemeColors(
      accentGlow: Color.lerp(accentGlow, other.accentGlow, t)!,
      accentPartner: Color.lerp(accentPartner, other.accentPartner, t)!,
      ambientWarm: Color.lerp(ambientWarm, other.ambientWarm, t)!,
      ambientCool: Color.lerp(ambientCool, other.ambientCool, t)!,
      codeSurface: Color.lerp(codeSurface, other.codeSurface, t)!,
      inlineCode: Color.lerp(inlineCode, other.inlineCode, t)!,
      toastSurface: Color.lerp(toastSurface, other.toastSurface, t)!,
      plotSeries: [for (var i = 0; i < plotSeries.length; i++) Color.lerp(plotSeries[i], other.plotSeries[i], t)!],
    );
  }

  // Value equality, so rebuilding with the same accent does not restart the
  // app-wide theme animation.
  @override
  bool operator ==(Object other) =>
      other is MewThemeColors &&
      other.accentGlow == accentGlow &&
      other.accentPartner == accentPartner &&
      other.ambientWarm == ambientWarm &&
      other.ambientCool == ambientCool &&
      other.codeSurface == codeSurface &&
      other.inlineCode == inlineCode &&
      other.toastSurface == toastSurface &&
      listEquals(other.plotSeries, plotSeries);

  @override
  int get hashCode => Object.hash(
    accentGlow,
    accentPartner,
    ambientWarm,
    ambientCool,
    codeSurface,
    inlineCode,
    toastSurface,
    Object.hashAll(plotSeries),
  );
}

/// Plot curve colours per accent, light then dark. Slot 1 is the accent made
/// vivid enough to read as a line; the rest are a categorical palette ordered
/// so that neighbouring curves, and any two of the first three, stay apart
/// for protanopia, deuteranopia and full colour vision in both modes
/// (validated with the data-viz palette checks against the plot paper).
const _plotSeriesByAccent = <int, (List<Color>, List<Color>)>{
  0xFFB07D52: (
    [
      Color(0xFFA25A00),
      Color(0xFF1BAF7A),
      Color(0xFF2A78D6),
      Color(0xFFE34948),
      Color(0xFF6250D6),
      Color(0xFFEDA100),
      Color(0xFFE87BA4),
      Color(0xFF008300),
    ],
    [
      Color(0xFFC36E03),
      Color(0xFF199E70),
      Color(0xFF3987E5),
      Color(0xFFE66767),
      Color(0xFF9085E9),
      Color(0xFFC98500),
      Color(0xFFD55181),
      Color(0xFF008300),
    ],
  ),
  0xFFC48A9A: (
    [
      Color(0xFFB75576),
      Color(0xFF008300),
      Color(0xFF2A78D6),
      Color(0xFFEDA100),
      Color(0xFFE87BA4),
      Color(0xFF6250D6),
      Color(0xFFEB6834),
      Color(0xFF1BAF7A),
    ],
    [
      Color(0xFFC46181),
      Color(0xFF008300),
      Color(0xFF3987E5),
      Color(0xFFC98500),
      Color(0xFFD55181),
      Color(0xFF9085E9),
      Color(0xFFD95926),
      Color(0xFF199E70),
    ],
  ),
  0xFF7E9C8B: (
    [
      Color(0xFF3E9A6F),
      Color(0xFFEDA100),
      Color(0xFF2A78D6),
      Color(0xFF008300),
      Color(0xFFE87BA4),
      Color(0xFF6250D6),
      Color(0xFFEB6834),
      Color(0xFF1BAF7A),
    ],
    [
      Color(0xFF4CA77B),
      Color(0xFFC98500),
      Color(0xFF3987E5),
      Color(0xFF008300),
      Color(0xFFD55181),
      Color(0xFF9085E9),
      Color(0xFFD95926),
      Color(0xFF199E70),
    ],
  ),
  0xFF8A93B8: (
    [
      Color(0xFF6372C6),
      Color(0xFF008300),
      Color(0xFFE87BA4),
      Color(0xFFEDA100),
      Color(0xFF2A78D6),
      Color(0xFF1BAF7A),
      Color(0xFF6250D6),
      Color(0xFFE34948),
    ],
    [
      Color(0xFF6F7ED4),
      Color(0xFF008300),
      Color(0xFFD55181),
      Color(0xFFC98500),
      Color(0xFF3987E5),
      Color(0xFF199E70),
      Color(0xFF9085E9),
      Color(0xFFE66767),
    ],
  ),
  0xFF6F98AD: (
    [
      Color(0xFF0486B2),
      Color(0xFFEB6834),
      Color(0xFF6250D6),
      Color(0xFF1BAF7A),
      Color(0xFF2A78D6),
      Color(0xFFEDA100),
      Color(0xFFE87BA4),
      Color(0xFF008300),
    ],
    [
      Color(0xFF0486B2),
      Color(0xFFD95926),
      Color(0xFF9085E9),
      Color(0xFF199E70),
      Color(0xFF3987E5),
      Color(0xFFC98500),
      Color(0xFFD55181),
      Color(0xFF008300),
    ],
  ),
  0xFFB8956A: (
    [
      Color(0xFF885703),
      Color(0xFF1BAF7A),
      Color(0xFF2A78D6),
      Color(0xFFE34948),
      Color(0xFF6250D6),
      Color(0xFFEDA100),
      Color(0xFFE87BA4),
      Color(0xFF008300),
    ],
    [
      Color(0xFFB67703),
      Color(0xFF199E70),
      Color(0xFF3987E5),
      Color(0xFFE66767),
      Color(0xFF9085E9),
      Color(0xFFC98500),
      Color(0xFFD55181),
      Color(0xFF008300),
    ],
  ),
};

// The same validated hues in their reference order, for any other accent.
const _defaultPlotSeries = (
  [
    Color(0xFF2A78D6),
    Color(0xFFEB6834),
    Color(0xFF1BAF7A),
    Color(0xFFEDA100),
    Color(0xFFE87BA4),
    Color(0xFF008300),
    Color(0xFF6250D6),
    Color(0xFFE34948),
  ],
  [
    Color(0xFF3987E5),
    Color(0xFFD95926),
    Color(0xFF199E70),
    Color(0xFFC98500),
    Color(0xFFD55181),
    Color(0xFF008300),
    Color(0xFF9085E9),
    Color(0xFFE66767),
  ],
);

List<Color> _plotSeriesFor(Color accent, bool dark) {
  final (light, night) = _plotSeriesByAccent[accent.toARGB32()] ?? _defaultPlotSeries;
  return dark ? night : light;
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
  static ThemeData light(int accent) => _build(Brightness.light, accentColorAt(accent));
  static ThemeData dark(int accent) => _build(Brightness.dark, accentColorAt(accent));

  static ColorScheme _scheme(Brightness b, Color accent) {
    final dark = b == Brightness.dark;
    // The milk / latte neutrals are designed around Caramel; tint them for the
    // chosen accent so backgrounds, text and lines change along with it.
    Color tone(Color designed) => mewRetint(designed, accent);
    final night = tone(MewColors.nightBase);
    return ColorScheme.fromSeed(seedColor: accent, brightness: b).copyWith(
      primary: dark ? Color.lerp(accent, Colors.white, 0.18) : accent,
      onPrimary: Colors.white,
      surface: dark ? night : tone(MewColors.cream),
      onSurface: tone(dark ? const Color(0xFFF1EAE1) : MewColors.ink),
      onSurfaceVariant: tone(dark ? const Color(0xFFB5A99C) : MewColors.mute),
      surfaceContainerLowest: tone(dark ? const Color(0xFF110E0B) : Colors.white),
      surfaceContainerLow: tone(dark ? MewColors.nightSurface : MewColors.milk),
      surfaceContainer: tone(dark ? MewColors.nightSurface : MewColors.porcelain),
      surfaceContainerHigh: tone(dark ? MewColors.nightRaised : const Color(0xFFEFE7DC)),
      surfaceContainerHighest: tone(dark ? const Color(0xFF332D26) : MewColors.oat),
      outline: tone(dark ? const Color(0xFF5A5046) : const Color(0xFFD9CDBE)),
      outlineVariant: tone(dark ? MewColors.nightLine : const Color(0xFFEAE0D3)),
      secondaryContainer: dark ? Color.lerp(accent, night, 0.72) : Color.lerp(accent, Colors.white, 0.80),
      onSecondaryContainer: tone(dark ? const Color(0xFFF6EDE3) : MewColors.cocoa),
      primaryContainer: dark ? Color.lerp(accent, night, 0.6) : Color.lerp(accent, Colors.white, 0.72),
      onPrimaryContainer: dark ? Colors.white : tone(MewColors.cocoa),
      shadow: dark ? Colors.black : tone(const Color(0xFF7A5C3E)),
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
    final popupBg = mewRetint(dark ? MewColors.nightRaised : MewColors.cocoa, accent);
    return base.copyWith(
      extensions: [MewThemeColors.forAccent(accent, b)],
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
