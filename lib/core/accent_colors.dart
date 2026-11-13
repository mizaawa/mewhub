import 'dart:ui';

/// Theme accents offered in Display settings, in the order their index is stored.
/// Kept outside the UI layer so system surfaces such as notifications can use them.
const accentColors = <Color>[
  Color(0xFFB07D52),
  Color(0xFFC48A9A),
  Color(0xFF7E9C8B),
  Color(0xFF8A93B8),
  Color(0xFF6F98AD),
  Color(0xFFB8956A),
];

/// The accent stored as [index], wrapping the same way the theme does.
Color accentColorAt(int index) => accentColors[index % accentColors.length];
