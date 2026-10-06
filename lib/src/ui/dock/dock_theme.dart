import 'dart:io';

import 'package:flutter/material.dart';

const dockBlue = Color(0xFF0A84FF);
const dockGreen = Color(0xFF30D158);
const dockGray = Color(0xFF8E8E93);

ThemeData buildDockTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: dockBlue,
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: Platform.isWindows ? 'Segoe UI Variable' : null,
    scaffoldBackgroundColor: dark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7),
    splashFactory: InkSparkle.splashFactory,
    textTheme: (dark
            ? Typography.material2021(platform: TargetPlatform.windows).white
            : Typography.material2021(platform: TargetPlatform.windows).black)
        .apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: dockBlue,
        foregroundColor: Colors.white,
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 36),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: dark ? const Color(0xFF2C2C2E) : Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: WidgetStateProperty.all(
          const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    ),
  );
}

Color dockSurface(Brightness brightness) {
  // Opaque frosted fill. Flutter's swapchain does not composite per-pixel
  // alpha on a non-layered window, so a translucent color would paint over black.
  return brightness == Brightness.dark ? const Color(0xFF1C1C1E) : const Color(0xFFF7F7FA);
}
