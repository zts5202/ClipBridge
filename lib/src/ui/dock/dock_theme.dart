import 'package:flutter/material.dart';

const dockBlue = Color(0xFF0A84FF);
const dockGreen = Color(0xFF30D158);
const dockGray = Color(0xFF8E8E93);

/// Segoe UI Variable has Latin glyphs but not CJK. YaHei covers the Chinese
/// UI strings when the primary face has no glyph.
const dockFontFamily = 'Segoe UI Variable';
const dockFontFallback = <String>['Microsoft YaHei UI', 'Microsoft YaHei'];

/// iOS label / secondaryLabel, baked opaque so contrast does not depend on
/// what sits behind a translucent color.
const dockLabelLight = Color(0xFF000000);
const dockLabelDark = Color(0xFFFFFFFF);
const dockSecondaryLight = Color(0xFF87878C);
const dockSecondaryDark = Color(0xFF98989F);

Color dockLabel(Brightness brightness) =>
    brightness == Brightness.dark ? dockLabelDark : dockLabelLight;

Color dockSecondary(Brightness brightness) =>
    brightness == Brightness.dark ? dockSecondaryDark : dockSecondaryLight;

TextStyle dockFace({
  double? fontSize,
  FontWeight? fontWeight,
  Color? color,
  double? height,
  double? letterSpacing,
}) {
  return TextStyle(
    fontFamily: dockFontFamily,
    fontFamilyFallback: dockFontFallback,
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    height: height,
    letterSpacing: letterSpacing,
  );
}

ThemeData buildDockTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final label = dockLabel(brightness);
  final secondary = dockSecondary(brightness);
  final surface = dockSurface(brightness);
  final scheme = ColorScheme.fromSeed(
    seedColor: dockBlue,
    brightness: brightness,
  ).copyWith(
    primary: dockBlue,
    onPrimary: Colors.white,
    surface: surface,
    onSurface: label,
    onSurfaceVariant: secondary,
  );
  final face = dockFace();
  final button = dockFace(fontSize: 13, fontWeight: FontWeight.w600);
  final base = (dark
          ? Typography.material2021(platform: TargetPlatform.windows).white
          : Typography.material2021(platform: TargetPlatform.windows).black)
      .apply(
        bodyColor: label,
        displayColor: label,
        fontFamily: dockFontFamily,
        fontFamilyFallback: dockFontFallback,
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: dockFontFamily,
    fontFamilyFallback: dockFontFallback,
    scaffoldBackgroundColor: surface,
    splashFactory: InkSparkle.splashFactory,
    textTheme: base.copyWith(
      bodySmall: face.copyWith(fontSize: 12, color: secondary),
      labelSmall: face.copyWith(fontSize: 11, color: secondary),
    ),
    iconTheme: IconThemeData(color: label),
    listTileTheme: ListTileThemeData(
      textColor: label,
      iconColor: secondary,
      titleTextStyle: face.copyWith(fontSize: 14, color: label),
      subtitleTextStyle: face.copyWith(fontSize: 12, color: secondary),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: dockBlue,
        textStyle: button,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: dockBlue,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: button.copyWith(color: Colors.white),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: label,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        side: BorderSide(color: secondary),
        textStyle: button.copyWith(color: label),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: label),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: dark ? const Color(0xFF2C2C2E) : Colors.white,
      hintStyle: face.copyWith(color: secondary, fontSize: 13),
      labelStyle: face.copyWith(color: label),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: WidgetStateProperty.all(button),
      ),
    ),
  );
}

/// Opacity of the plate drawn over the DWM acrylic/mica backdrop.
/// Text is painted opaquely on top of this plate, so contrast stays.
const dockGlassOpacity = 0.82;

Color dockSurface(Brightness brightness) {
  final tint = brightness == Brightness.dark ? const Color(0xFF1C1C1E) : const Color(0xFFF7F7FA);
  return tint.withValues(alpha: dockGlassOpacity);
}
