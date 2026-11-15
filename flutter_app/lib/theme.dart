import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class MC {
  static const bg = Color(0xFF0A0C10);
  static const panel = Color(0xFF131821);
  static const panelAlt = Color(0xFF1A212D);
  static const border = Color(0xFF2A3340);
  static const accent = Color(0xFFFF6B35);
  static const accentDim = Color(0xFFB8512A);
  static const text = Color(0xFFE6EDF3);
  static const textDim = Color(0xFF8B98A5);
  static const good = Color(0xFF3FB950);
  static const warn = Color(0xFFF2CC60);
  static const bad = Color(0xFFF85149);

  static ThemeData theme() {
    final base = ThemeData.dark(useMaterial3: true);
    final textTheme = GoogleFonts.jetBrainsMonoTextTheme(base.textTheme).apply(
      bodyColor: text,
      displayColor: text,
    );
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: base.colorScheme.copyWith(
        primary: accent,
        secondary: accentDim,
        surface: panel,
      ),
      textTheme: textTheme,
      dividerColor: border,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: panelAlt,
        contentTextStyle: TextStyle(color: text, fontSize: 12),
        shape: RoundedRectangleBorder(
          side: BorderSide(color: border),
          borderRadius: BorderRadius.all(Radius.circular(4)),
        ),
      ),
      sliderTheme: const SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: border,
        thumbColor: accent,
        trackHeight: 3,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7),
        overlayShape: RoundSliderOverlayShape(overlayRadius: 14),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        isDense: true,
        labelStyle: TextStyle(color: textDim, fontSize: 11),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: border)),
        focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: accent)),
      ),
    );
  }
}
