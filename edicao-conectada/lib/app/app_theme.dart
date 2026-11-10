import 'package:flutter/material.dart';
import 'dart:math' as math;

abstract final class AppTheme {
  static const forest = Color(0xFF173D2B);
  static const leaf = Color(0xFF37845A);
  static const canvas = Color(0xFFF5F7F3);
  // Compatibility names used by screens from the earlier visual theme.
  static const primary = forest;
  static const background = canvas;
  static const textPrimary = forest;
  static const textSecondary = Color(0xFF6B7280);

  /// Keeps dialogs inside the usable screen width on phones and tablets.
  static double dialogWidth(BuildContext context, {double maxWidth = 480}) {
    final available = MediaQuery.sizeOf(context).width - 80;
    return math.max(0, math.min(maxWidth, available));
  }

  static EdgeInsets pagePadding(BuildContext context) =>
      EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 16 : 24);

  static ThemeData get light {
    final scheme =
        ColorScheme.fromSeed(seedColor: leaf, brightness: Brightness.light)
            .copyWith(primary: forest, secondary: leaf, surface: Colors.white);
    final baseText = Typography.material2021().black;
    final textTheme = baseText.copyWith(
      displayLarge: baseText.displayLarge?.copyWith(fontSize: 48, height: 1.15),
      displayMedium:
          baseText.displayMedium?.copyWith(fontSize: 40, height: 1.18),
      displaySmall: baseText.displaySmall?.copyWith(fontSize: 34, height: 1.2),
      headlineLarge:
          baseText.headlineLarge?.copyWith(fontSize: 32, height: 1.2),
      headlineMedium:
          baseText.headlineMedium?.copyWith(fontSize: 28, height: 1.22),
      headlineSmall:
          baseText.headlineSmall?.copyWith(fontSize: 24, height: 1.25),
      titleLarge: baseText.titleLarge?.copyWith(fontSize: 22, height: 1.25),
      titleMedium: baseText.titleMedium?.copyWith(fontSize: 16, height: 1.3),
      titleSmall: baseText.titleSmall?.copyWith(fontSize: 14, height: 1.3),
      bodyLarge: baseText.bodyLarge?.copyWith(fontSize: 16, height: 1.45),
      bodyMedium: baseText.bodyMedium?.copyWith(fontSize: 14, height: 1.45),
      bodySmall: baseText.bodySmall?.copyWith(fontSize: 12, height: 1.4),
      labelLarge: baseText.labelLarge?.copyWith(fontSize: 14, height: 1.3),
      labelMedium: baseText.labelMedium?.copyWith(fontSize: 13, height: 1.3),
      labelSmall: baseText.labelSmall?.copyWith(fontSize: 12, height: 1.3),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: canvas,
      appBarTheme:
          const AppBarTheme(backgroundColor: canvas, foregroundColor: forest),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        errorMaxLines: 3,
        helperMaxLines: 3,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none),
      ),
      dialogTheme: const DialogThemeData(
        insetPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        titleTextStyle: TextStyle(
          color: forest,
          fontSize: 20,
          height: 1.25,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
