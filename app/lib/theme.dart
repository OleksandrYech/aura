import 'package:flutter/material.dart';

/// Токены дизайн-системы AURA (tokens.json).
class AuraColors {
  const AuraColors({
    required this.ink,
    required this.cream,
    required this.beige,
    required this.warmSand,
    required this.lavender,
    required this.thistle,
    required this.grayPurple,
    required this.lightGray,
  });

  final Color ink, cream, beige, warmSand, lavender, thistle, grayPurple, lightGray;

  static const light = AuraColors(
    ink: Color(0xFF403B55),
    cream: Color(0xFFFFFFF0),
    beige: Color(0xFFF5F5DC),
    warmSand: Color(0xFFE6D7B9),
    lavender: Color(0xFFE6E6FA),
    thistle: Color(0xFFD8BFD8),
    grayPurple: Color(0xFFBDB5D5),
    lightGray: Color(0xFFD3D3D3),
  );

  static const dark = AuraColors(
    ink: Color(0xFFF1ECFA),
    cream: Color(0xFF1C1824),
    beige: Color(0xFF241F2E),
    warmSand: Color(0xFF2E2838),
    lavender: Color(0xFF4B4566),
    thistle: Color(0xFF5C5270),
    grayPurple: Color(0xFF6B6485),
    lightGray: Color(0xFF3A3444),
  );

  static AuraColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}

const radiusMd = 16.0;
const radiusLg = 24.0;

/// Переключатель темы для всего приложения.
final themeMode = ValueNotifier(ThemeMode.light);

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? AuraColors.dark : AuraColors.light;
  final base = ThemeData(brightness: brightness, fontFamily: 'Ubuntu');
  final field = OutlineInputBorder(
    borderRadius: BorderRadius.circular(radiusMd),
    borderSide: BorderSide(color: c.lightGray),
  );
  return base.copyWith(
    scaffoldBackgroundColor: c.cream,
    colorScheme: ColorScheme.fromSeed(
      seedColor: c.lavender,
      brightness: brightness,
      primary: c.ink,
      onPrimary: c.cream,
      surface: c.cream,
      onSurface: c.ink,
      error: c.ink,
    ),
    textTheme: base.textTheme.apply(bodyColor: c.ink, displayColor: c.ink).copyWith(
          // Title / Headers — Comfortaa, Body / Caption — Ubuntu.
          headlineSmall: TextStyle(fontFamily: 'Comfortaa', fontSize: 24, fontWeight: FontWeight.w700, height: 1.3, color: c.ink),
          titleMedium: TextStyle(fontFamily: 'Comfortaa', fontSize: 16, fontWeight: FontWeight.w700, height: 1.5, color: c.ink),
          bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: c.ink),
          bodySmall: TextStyle(fontSize: 13, fontWeight: FontWeight.w300, height: 1.4, color: c.ink),
        ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.beige,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: field,
      enabledBorder: field,
      focusedBorder: field.copyWith(borderSide: BorderSide(color: c.grayPurple, width: 1.5)),
      errorBorder: field.copyWith(borderSide: BorderSide(color: c.grayPurple)),
      hintStyle: TextStyle(color: c.ink.withValues(alpha: 0.45)),
      labelStyle: TextStyle(color: c.ink.withValues(alpha: 0.6)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.lavender,
        foregroundColor: c.ink,
        minimumSize: const Size.fromHeight(48),
        textStyle: const TextStyle(fontFamily: 'Ubuntu', fontSize: 15, fontWeight: FontWeight.w500),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radiusMd)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStatePropertyAll(c.cream),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.grayPurple : c.lightGray),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    dividerColor: c.lightGray,
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.cream,
      indicatorColor: c.lavender,
      labelTextStyle: WidgetStatePropertyAll(TextStyle(fontSize: 11, color: c.ink)),
      iconTheme: WidgetStatePropertyAll(IconThemeData(color: c.ink)),
    ),
  );
}
