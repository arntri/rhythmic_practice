import 'package:flutter/material.dart';

/// The app's calm lavender design system (UX overhaul). One place for the
/// palette + theme so the home, practice, and caregiver screens stay consistent.
class AppColors {
  /// Lavender seed the Material colour scheme is generated from.
  static const seed = Color(0xFF7E6BB3);

  /// Soft full-screen background gradient (top → bottom).
  static const bgTop = Color(0xFFF6F3FC);
  static const bgBottom = Color(0xFFE7DEF7);

  /// Deeper lavender for primary emphasis (the "tap to start" affordance).
  static const accent = Color(0xFF6A4FB0);

  /// Readable text on the calm lavender background.
  static const onCalm = Color(0xFF3A335A);

  /// The calm background as a reusable gradient.
  static const calmGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [bgTop, bgBottom],
  );
}

/// The light, lavender Material 3 theme used app-wide.
ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: AppColors.seed,
    brightness: Brightness.light,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bgTop,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
    ),
  );
}
