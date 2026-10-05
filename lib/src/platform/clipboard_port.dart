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
  Future<void> notify(String title, String body);
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
  Future<void> trayUpdate({required String tooltip, required bool paused});
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
  Future<void> notify(String title, String body) async {
    notifications.add('$title $body');
  }

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
  Future<void> trayUpdate({required String tooltip, required bool paused}) async {}

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
      }
      return null;
    });
  }

  static const _channel = MethodChannel('app.clipbridge/platform');
  final _shares = StreamController<ShareItem>.broadcast();
  final _tray = StreamController<String>.broadcast();

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
  Future<void> notify(String title, String body) async {
    await _invoke<void>('notify', {'title': title, 'body': body});
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
  Future<void> trayUpdate({
    required String tooltip,
    required bool paused,
  }) async {
    await _invoke<void>('trayUpdate', {'tooltip': tooltip, 'paused': paused});
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
