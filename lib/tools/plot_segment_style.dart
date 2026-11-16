/// Supported line patterns for named-point segments in both plot tools.
enum PlotLineStyle {
  solid('solid'),
  dashed('dashed'),
  dotted('dotted'),
  dashDot('dash_dot');

  const PlotLineStyle(this.jsonName);
  final String jsonName;

  static PlotLineStyle parse(Object? value, {bool legacyDashed = false}) {
    if (value == null) return legacyDashed ? dashed : solid;
    for (final style in values) {
      if (style.jsonName == value) return style;
    }
    throw const FormatException('style must be solid, dashed, dotted or dash_dot.');
  }
}

/// A finite, theme-independent palette exposed to drawing models.
enum PlotLineColor {
  theme('default'),
  red('red'),
  orange('orange'),
  green('green'),
  teal('teal'),
  blue('blue'),
  purple('purple'),
  pink('pink'),
  gray('gray'),
  black('black');

  const PlotLineColor(this.jsonName);
  final String jsonName;

  static PlotLineColor parse(Object? value) {
    if (value == null) return theme;
    for (final color in values) {
      if (color.jsonName == value) return color;
    }
    throw const FormatException('color must be default, red, orange, green, teal, blue, purple, pink, gray or black.');
  }
}
