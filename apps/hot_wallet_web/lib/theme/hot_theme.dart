import 'package:flutter/material.dart';

/// Design tokens and Material 3 theme for the Watch-Only Hot Wallet Web App.
///
/// Uses a Warm Charcoal dark surface with Red-Orange primary accents,
/// Amber/Gold balance highlights, and Slate-Green staking reward cards.
class HotTheme {
  HotTheme._();

  // Surfaces
  static const Color background = Color(0xFF120C09);
  static const Color surface = Color(0xFF1C1410);
  static const Color surfaceElevated = Color(0xFF261B16);
  static const Color borderSubtle = Color(0xFF3A2820);

  // Brand & Primary Actions (Red-Orange)
  static const Color primary = Color(0xFFF9572B);
  static const Color primaryHover = Color(0xFFE0481F);
  static const Color primaryBorder = Color(0xFF8C3219);
  static const Color primarySurface = Color(0xFF2C1610);
  static const Color onPrimary = Color(0xFFFFFFFF);

  // Specialized Cards
  static const Color balanceCardBg = Color(0xFF23170E);
  static const Color balanceCardBorder = Color(0xFF5C3B1E);
  static const Color balanceAccent = Color(0xFFF59E0B);

  static const Color stakingCardBg = Color(0xFF141F1B);
  static const Color stakingCardBorder = Color(0xFF243B33);
  static const Color stakingButtonBg = Color(0xFF5E7485);

  // Semantic (separated from Red-Orange brand primary)
  static const Color success = Color(0xFF22C55E);
  static const Color successSurface = Color(0xFF10261A);
  static const Color warning = Color(0xFFFBBF24);
  static const Color warningSurface = Color(0xFF2B1F0B);
  static const Color danger = Color(0xFFDC2626);
  static const Color dangerSurface = Color(0xFF2E1111);
  static const Color info = Color(0xFF38BDF8);

  // Text
  static const Color textPrimary = Color(0xFFFAF5F0);
  static const Color textSecondary = Color(0xFFA89990);
  static const Color textMuted = Color(0xFF786860);

  static ThemeData buildThemeData() {
    const colorScheme = ColorScheme.dark(
      primary: primary,
      onPrimary: onPrimary,
      primaryContainer: primarySurface,
      onPrimaryContainer: textPrimary,
      secondary: balanceAccent,
      onSecondary: Color(0xFF120C09),
      surface: surface,
      onSurface: textPrimary,
      surfaceContainerHighest: surfaceElevated,
      error: danger,
      onError: onPrimary,
      outline: borderSubtle,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: background,
      canvasColor: background,
      appBarTheme: const AppBarTheme(
        backgroundColor: surface,
        foregroundColor: textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: borderSubtle, width: 1),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: borderSubtle),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surfaceElevated,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: borderSubtle,
        thickness: 1,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: onPrimary,
          minimumSize: const Size(44, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          backgroundColor: surface,
          minimumSize: const Size(44, 46),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          side: const BorderSide(color: primaryBorder, width: 1.2),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: balanceAccent,
          minimumSize: const Size(44, 44),
          textStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceElevated,
        labelStyle: const TextStyle(color: textSecondary),
        hintStyle: const TextStyle(color: textMuted),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: borderSubtle),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: borderSubtle),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primary, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: danger),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceElevated,
        contentTextStyle: const TextStyle(color: textPrimary, fontSize: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: borderSubtle),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
