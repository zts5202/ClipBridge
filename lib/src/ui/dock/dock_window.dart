import 'dart:io';

import 'package:flutter/services.dart';

import 'dock_placement.dart';

/// Native popup host. Tests and Android never call into Win32.
class DockWindow {
  static const _channel = MethodChannel('app.clipbridge/platform');

  static Future<List<MonitorWorkArea>> monitors() async {
    if (!Platform.isWindows) return const [MonitorWorkArea.fallback];
    try {
      final raw = await _channel.invokeMethod<List<Object?>>('getMonitors');
      if (raw == null || raw.isEmpty) return const [MonitorWorkArea.fallback];
      return raw.whereType<Map>().map((item) {
        final map = item.map((key, value) => MapEntry('$key', value));
        return MonitorWorkArea(
          left: _asInt(map['left']),
          top: _asInt(map['top']),
          right: _asInt(map['right']),
          bottom: _asInt(map['bottom']),
          dpi: _asInt(map['dpi'], 96),
        );
      }).toList();
    } on MissingPluginException {
      return const [MonitorWorkArea.fallback];
    } on PlatformException {
      return const [MonitorWorkArea.fallback];
    }
  }

  static Future<void> setFrame(DockFrame frame, {required int radius, bool show = true}) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('setFrame', {
        'x': frame.x,
        'y': frame.y,
        'w': frame.width,
        'h': frame.height,
        'radius': radius,
        'show': show,
      });
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  static Future<void> allowActivate(bool allow) async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('allowActivate', {'allow': allow});
    } on MissingPluginException {
      return;
    } on PlatformException {
      return;
    }
  }

  static int _asInt(Object? value, [int fallback = 0]) {
    if (value is int) return value;
    if (value is num) return value.round();
    return fallback;
  }
}
