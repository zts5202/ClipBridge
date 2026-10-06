import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/models.dart';

abstract class ClipboardPort {
  Future<String?> getText();
  Future<void> setText(String text);
  Future<Uint8List?> getImagePng();
  Future<void> setImagePng(Uint8List png);
  Future<int> getSequence();
  Future<PasteResult> tryPaste();
  Future<void> notify(String title, String body, {bool sound = false});
  Future<String?> publishFile({
    required String path,
    required String name,
    required String mime,
    required bool gallery,
  });
  Future<void> reveal(String pathOrUri);
  Future<void> startPresence(String text);
  Future<void> updatePresence(String text);
  Future<void> stopPresence();
  Future<ShareItem?> takePendingShare();
  Stream<ShareItem> get shares;
  Stream<String> get trayActions;
  Stream<String> get fileDrops;
  Stream<void> get monitorChanges;
  Stream<bool> get pointerNear;
  Future<void> trayUpdate({
    required String tooltip,
    required bool paused,
    bool autoSync = false,
    bool launchAtStartup = false,
    bool notificationSound = false,
  });
  Future<void> setLaunchAtStartup(bool enabled);
  Future<void> showWindow();
  Future<void> hideWindow();
  Future<void> quitApp();
}

class MemoryClipboard implements ClipboardPort {
  String? text;
  Uint8List? png;
  int sequence = 1;
  final List<String> notifications = [];
  final List<String> published = [];
  PasteResult pasteResult = const PasteResult(ok: true, reason: '');
  final _shares = StreamController<ShareItem>.broadcast();
  final _tray = StreamController<String>.broadcast();
  final _drops = StreamController<String>.broadcast();
  final _monitors = StreamController<void>.broadcast();
  final _near = StreamController<bool>.broadcast();
  bool syncedNotificationSound = false;

  @override
  Future<String?> getText() async => text;

  @override
  Future<void> setText(String value) async {
    text = value;
    sequence += 1;
  }

  @override
  Future<Uint8List?> getImagePng() async => png;

  @override
  Future<void> setImagePng(Uint8List value) async {
    png = Uint8List.fromList(value);
    sequence += 1;
  }

  @override
  Future<int> getSequence() async => sequence;

  @override
  Future<PasteResult> tryPaste() async => pasteResult;

  @override
  Future<void> notify(String title, String body, {bool sound = false}) async {
    notifications.add('$title $body');
  }

  void emitNear(bool near) => _near.add(near);

  @override
  Future<String?> publishFile({
    required String path,
    required String name,
    required String mime,
    required bool gallery,
  }) async {
    published.add(path);
    return path;
  }

  @override
  Future<void> reveal(String pathOrUri) async {}

  @override
  Future<void> startPresence(String text) async {}

  @override
  Future<void> updatePresence(String text) async {}

  @override
  Future<void> stopPresence() async {}

  @override
  Future<ShareItem?> takePendingShare() async => null;

  @override
  Stream<ShareItem> get shares => _shares.stream;

  @override
  Stream<String> get trayActions => _tray.stream;

  @override
  Stream<String> get fileDrops => _drops.stream;

  @override
  Stream<void> get monitorChanges => _monitors.stream;

  @override
  Stream<bool> get pointerNear => _near.stream;

  @override
  Future<void> trayUpdate({
    required String tooltip,
    required bool paused,
    bool autoSync = false,
    bool launchAtStartup = false,
    bool notificationSound = false,
  }) async {
    syncedNotificationSound = notificationSound;
  }

  @override
  Future<void> setLaunchAtStartup(bool enabled) async {}

  @override
  Future<void> showWindow() async {}

  @override
  Future<void> hideWindow() async {}

  @override
  Future<void> quitApp() async {}

  void emitShare(ShareItem item) => _shares.add(item);

  void emitTray(String action) => _tray.add(action);
}

class PlatformClipboard implements ClipboardPort {
  PlatformClipboard() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onShare') {
        final item = _shareFrom(call.arguments);
        if (item != null) _shares.add(item);
      } else if (call.method == 'onTray') {
        final action = call.arguments;
        if (action is String) _tray.add(action);
      } else if (call.method == 'onFileDrop') {
        final path = call.arguments;
        if (path is String && path.isNotEmpty) _drops.add(path);
      } else if (call.method == 'onMonitorsChanged') {
        _monitors.add(null);
      } else if (call.method == 'onPointerNear') {
        if (call.arguments is bool) _near.add(call.arguments as bool);
      }
      return null;
    });
  }

  static const _channel = MethodChannel('app.clipbridge/platform');
  final _shares = StreamController<ShareItem>.broadcast();
  final _tray = StreamController<String>.broadcast();
  final _drops = StreamController<String>.broadcast();
  final _monitors = StreamController<void>.broadcast();
  final _near = StreamController<bool>.broadcast();

  Future<T?> _invoke<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<String?> getText() => _invoke<String>('getClipboardText');

  @override
  Future<void> setText(String text) async {
    await _invoke<void>('setClipboardText', {'text': text});
  }

  @override
  Future<Uint8List?> getImagePng() async {
    final value = await _invoke<Uint8List>('getClipboardPng');
    return value;
  }

  @override
  Future<void> setImagePng(Uint8List png) async {
    await _invoke<void>('setClipboardPng', {'bytes': png});
  }

  @override
  Future<int> getSequence() async => await _invoke<int>('getClipboardSequence') ?? 0;

  @override
  Future<PasteResult> tryPaste() async {
    final value = await _invoke<Map<Object?, Object?>>('pasteCtrlV');
    if (value == null) {
      return const PasteResult(ok: false, reason: 'unsupported');
    }
    return PasteResult(
      ok: value['ok'] == true,
      reason: value['reason'] as String? ?? '',
    );
  }

  @override
  Future<void> notify(String title, String body, {bool sound = false}) async {
    await _invoke<void>('notify', {'title': title, 'body': body, 'sound': sound});
  }

  @override
  Future<String?> publishFile({
    required String path,
    required String name,
    required String mime,
    required bool gallery,
  }) {
    return _invoke<String>('publishFile', {
      'path': path,
      'name': name,
      'mime': mime,
      'gallery': gallery,
    });
  }

  @override
  Future<void> reveal(String pathOrUri) async {
    await _invoke<void>('revealPath', {'path': pathOrUri});
  }

  @override
  Future<void> startPresence(String text) async {
    await _invoke<void>('startService', {'text': text});
  }

  @override
  Future<void> updatePresence(String text) async {
    await _invoke<void>('updateService', {'text': text});
  }

  @override
  Future<void> stopPresence() async {
    await _invoke<void>('stopService');
  }

  @override
  Future<ShareItem?> takePendingShare() async {
    final value = await _invoke<Map<Object?, Object?>>('takePendingShare');
    return _shareFrom(value);
  }

  ShareItem? _shareFrom(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.map((key, value) => MapEntry(key.toString(), value));
    final item = ShareItem(
      text: map['text'] as String?,
      path: map['path'] as String?,
      name: map['name'] as String?,
      mime: map['mime'] as String?,
    );
    return item.isEmpty ? null : item;
  }

  @override
  Stream<ShareItem> get shares => _shares.stream;

  @override
  Stream<String> get trayActions => _tray.stream;

  @override
  Stream<String> get fileDrops => _drops.stream;

  @override
  Stream<void> get monitorChanges => _monitors.stream;

  @override
  Stream<bool> get pointerNear => _near.stream;

  @override
  Future<void> trayUpdate({
    required String tooltip,
    required bool paused,
    bool autoSync = false,
    bool launchAtStartup = false,
    bool notificationSound = false,
  }) async {
    await _invoke<void>('trayUpdate', {
      'tooltip': tooltip,
      'paused': paused,
      'autoSync': autoSync,
      'launchAtStartup': launchAtStartup,
      'notificationSound': notificationSound,
    });
  }

  @override
  Future<void> setLaunchAtStartup(bool enabled) async {
    await _invoke<void>('setLaunchAtStartup', {'enabled': enabled});
  }

  @override
  Future<void> showWindow() async {
    await _invoke<void>('showWindow');
  }

  @override
  Future<void> hideWindow() async {
    await _invoke<void>('hideWindow');
  }

  @override
  Future<void> quitApp() async {
    await _invoke<void>('quit');
  }
}

ClipboardPort createPlatformClipboard() {
  if (Platform.isAndroid || Platform.isWindows) return PlatformClipboard();
  return MemoryClipboard();
}
