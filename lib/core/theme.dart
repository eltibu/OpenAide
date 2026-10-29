import 'package:flutter/material.dart';

/// A calm, warm look in the style of the Claude Android app: ivory paper in
/// light mode, warm charcoal in dark mode, one terracotta accent.
class NexusColors extends ThemeExtension<NexusColors> {
  const NexusColors({
    required this.userBubble,
    required this.composer,
    required this.composerBorder,
    required this.muted,
  });

  final Color userBubble;
  final Color composer;
  final Color composerBorder;
  final Color muted;

  static const accent = Color(0xFFC96442);

  @override
  NexusColors copyWith({
    Color? userBubble,
    Color? composer,
    Color? composerBorder,
    Color? muted,
  }) => NexusColors(
    userBubble: userBubble ?? this.userBubble,
    composer: composer ?? this.composer,
    composerBorder: composerBorder ?? this.composerBorder,
    muted: muted ?? this.muted,
  );

  @override
  NexusColors lerp(NexusColors? other, double t) {
    if (other == null) return this;
    return NexusColors(
      userBubble: Color.lerp(userBubble, other.userBubble, t)!,
      composer: Color.lerp(composer, other.composer, t)!,
      composerBorder: Color.lerp(composerBorder, other.composerBorder, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
    );
  }
}

extension NexusTheme on BuildContext {
  NexusColors get nexus => Theme.of(this).extension<NexusColors>()!;
}

/// [oled] is the web's OLED Dark: true black behind everything, so the
/// screen's pixels are off.
ThemeData nexusTheme(Brightness brightness, {bool oled = false}) {
  final dark = brightness == Brightness.dark;
  final background = oled
      ? Colors.black
      : dark
      ? const Color(0xFF262624)
      : const Color(0xFFFAF9F5);
  final surface = oled
      ? const Color(0xFF161616)
      : dark
      ? const Color(0xFF30302E)
      : Colors.white;
  final text = dark ? const Color(0xFFF5F4EE) : const Color(0xFF1F1E1D);
  final muted = dark ? const Color(0xFFA6A39A) : const Color(0xFF73726C);
  final scheme =
      ColorScheme.fromSeed(
        seedColor: NexusColors.accent,
        brightness: brightness,
      ).copyWith(
        primary: NexusColors.accent,
        onPrimary: Colors.white,
        surface: background,
        onSurface: text,
        onSurfaceVariant: muted,
        surfaceContainerLowest: background,
        surfaceContainerLow: surface,
        surfaceContainer: surface,
        surfaceContainerHigh: dark
            ? const Color(0xFF3A3936)
            : const Color(0xFFF0EEE6),
        surfaceContainerHighest: dark
            ? const Color(0xFF3F3E3A)
            : const Color(0xFFE8E6DC),
        outlineVariant: dark
            ? const Color(0xFF45443F)
            : const Color(0xFFE3E0D5),
      );
  final base = ThemeData(
    colorScheme: scheme,
    brightness: brightness,
    useMaterial3: true,
  );
  return base.copyWith(
    scaffoldBackgroundColor: background,
    appBarTheme: AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: text,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: base.textTheme.titleMedium?.copyWith(
        color: text,
        fontWeight: FontWeight.w600,
      ),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
    ),
    dividerTheme: DividerThemeData(color: scheme.outlineVariant),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    // Chips sized to the text they hold: small type, snug padding, so
    // rows of them fit a phone screen.
    chipTheme: base.chipTheme.copyWith(
      labelStyle: base.textTheme.labelMedium,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      labelPadding: const EdgeInsets.symmetric(horizontal: 6),
      side: BorderSide(color: scheme.outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    extensions: [
      NexusColors(
        userBubble: dark ? const Color(0xFF141413) : const Color(0xFFF0EEE6),
        composer: surface,
        composerBorder: dark
            ? const Color(0xFF45443F)
            : const Color(0xFFE3E0D5),
        muted: muted,
      ),
    ],
  );
}
