import 'package:flutter/material.dart';

/// Visual design: ledger-ink blue with a haldi (turmeric) accent on a cool,
/// paper-white ground. Money colours stay semantic: red = they owe / money out,
/// green = received / money in.
class AppColors {
  static const ink = Color(0xFF1F4E79); // primary – ledger ink
  static const haldi = Color(0xFFD9822B); // accent
  static const due = Color(0xFFC62828); // येणे / out
  static const paid = Color(0xFF2E7D32); // जमा / in
  static const sale = Color(0xFFC0392B);
  static const receipt = Color(0xFF2E7D32);
  static const expense = Color(0xFFD9822B);
  static const purchase = Color(0xFF1F4E79);
  static const neutral = Color(0xFF5B6B7F);
}

class AppTheme {
  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness b) {
    final dark = b == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.ink,
      brightness: b,
      primary: dark ? const Color(0xFF9EC3EA) : AppColors.ink,
      secondary: AppColors.haldi,
      surface: dark ? const Color(0xFF0F1318) : const Color(0xFFF2F4F8),
    );
    final radius = BorderRadius.circular(18);
    final cardColor = dark ? const Color(0xFF1A2029) : Colors.white;
    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: scheme,
      fontFamily: 'NotoSansDevanagari',
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkRipple.splashFactory,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0.5,
        surfaceTintColor: Colors.transparent,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: 'NotoSansDevanagari',
          fontSize: 21,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.2,
          color: scheme.onSurface,
        ),
      ),
      cardTheme: CardThemeData(
        color: cardColor,
        // light: paper cards lifted by a soft shadow; dark: a hairline edge
        elevation: dark ? 0 : 1.5,
        shadowColor: const Color(0xFF1F4E79).withValues(alpha: 0.18),
        margin: const EdgeInsets.symmetric(vertical: 5),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: dark ? BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.35)) : BorderSide.none),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: cardColor,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: scheme.outlineVariant)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: scheme.outlineVariant.withValues(alpha: dark ? 0.6 : 0.9))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: scheme.primary, width: 1.8)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 50),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          textStyle: const TextStyle(fontFamily: 'NotoSansDevanagari', fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          backgroundColor: cardColor,
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.8)),
        ),
      ),
      chipTheme: ChipThemeData(
        // pills
        shape: const StadiumBorder(),
        side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.8)),
        backgroundColor: cardColor,
        selectedColor: scheme.primaryContainer,
        labelStyle: TextStyle(fontFamily: 'NotoSansDevanagari', color: scheme.onSurface),
      ),
      listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.symmetric(horizontal: 16)),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant.withValues(alpha: 0.5), thickness: 1, space: 1),
      navigationBarTheme: NavigationBarThemeData(
        height: 70,
        backgroundColor: cardColor,
        surfaceTintColor: Colors.transparent,
        elevation: 8,
        shadowColor: Colors.black.withValues(alpha: 0.35),
        indicatorColor: scheme.primaryContainer,
        // the tab you are on reads bolder, in the ink colour
        labelTextStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontFamily: 'NotoSansDevanagari',
            fontSize: 12.5,
            fontWeight: s.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w500,
            color: s.contains(WidgetState.selected) ? scheme.primary : scheme.onSurfaceVariant)),
        iconTheme: WidgetStateProperty.resolveWith(
            (s) => IconThemeData(color: s.contains(WidgetState.selected) ? scheme.primary : scheme.onSurfaceVariant)),
      ),
      navigationRailTheme: NavigationRailThemeData(backgroundColor: cardColor, indicatorColor: scheme.primaryContainer),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 3,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cardColor,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cardColor,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)))),
      ),
    );
  }
}
