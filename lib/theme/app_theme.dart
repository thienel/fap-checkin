import 'package:flutter/material.dart';

abstract final class AppColors {
  static const primary = Color(0xFF155D68);
  static const primaryDark = Color(0xFF103F49);
  static const canvas = Color(0xFFF6F8F9);
  static const surface = Colors.white;
  static const surfaceMuted = Color(0xFFF0F4F5);
  static const border = Color(0xFFDCE4E7);
  static const text = Color(0xFF1B3038);
  static const textMuted = Color(0xFF5F737C);
  static const success = Color(0xFF176B50);
  static const successSurface = Color(0xFFEAF6F0);
  static const warning = Color(0xFF8B610B);
  static const warningSurface = Color(0xFFFFF5DC);
  static const error = Color(0xFFB13D3A);
  static const errorSurface = Color(0xFFFCEDEC);
  static const info = Color(0xFF286B90);
  static const infoSurface = Color(0xFFEAF3F8);
}

abstract final class AppSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
}

abstract final class AppRadii {
  static const control = 8.0;
  static const panel = 12.0;
}

abstract final class AppMotion {
  static const quick = Duration(milliseconds: 160);
}

ThemeData buildAppTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: AppColors.primary).copyWith(
    primary: AppColors.primary,
    onPrimary: Colors.white,
    surface: AppColors.surface,
    error: AppColors.error,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme);
  final controlShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppRadii.control),
  );
  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppRadii.control),
    borderSide: const BorderSide(color: AppColors.border),
  );

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.canvas,
    focusColor: AppColors.infoSurface,
    hoverColor: AppColors.surfaceMuted,
    textTheme: base.textTheme.copyWith(
      headlineMedium: const TextStyle(
        fontSize: 27,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        color: AppColors.text,
      ),
      titleLarge: const TextStyle(
        fontSize: 19,
        fontWeight: FontWeight.w700,
        color: AppColors.text,
      ),
      titleMedium: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w700,
        color: AppColors.text,
      ),
      bodyMedium: const TextStyle(fontSize: 14, color: AppColors.text),
      bodySmall: const TextStyle(fontSize: 12, color: AppColors.textMuted),
    ),
    cardTheme: CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.panel),
        side: const BorderSide(color: AppColors.border),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(
        borderSide: const BorderSide(color: AppColors.primary, width: 1.6),
      ),
      errorBorder: inputBorder.copyWith(
        borderSide: const BorderSide(color: AppColors.error),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 42),
        shape: controlShape,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 42),
        shape: controlShape,
        side: const BorderSide(color: AppColors.border),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 40),
        shape: controlShape,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(40, 40),
        shape: controlShape,
      ),
    ),
    dataTableTheme: DataTableThemeData(
      headingRowColor: const WidgetStatePropertyAll(AppColors.surfaceMuted),
      dataRowColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return AppColors.infoSurface;
        }
        if (states.contains(WidgetState.hovered)) {
          return AppColors.surfaceMuted;
        }
        return null;
      }),
      dataRowMinHeight: 48,
      dataRowMaxHeight: 60,
      headingRowHeight: 44,
      columnSpacing: 20,
      horizontalMargin: 16,
      dividerThickness: 0.6,
    ),
    dividerTheme: const DividerThemeData(color: AppColors.border, thickness: 1),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.panel),
      ),
      titleTextStyle: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: AppColors.text,
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: AppColors.primaryDark,
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      textStyle: const TextStyle(color: Colors.white, fontSize: 12),
    ),
  );
}
