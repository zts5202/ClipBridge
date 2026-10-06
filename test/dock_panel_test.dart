import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:clipbridge/src/bridge_controller.dart';
import 'package:clipbridge/src/core/models.dart';
import 'package:clipbridge/src/platform/clipboard_port.dart';
import 'package:clipbridge/src/ui/dock/dock_theme.dart';
import 'package:clipbridge/src/ui/dock/windows_dock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

bool _previewFontReady = false;

Future<void> _loadFont(String family, String path) async {
  final file = File(path);
  if (!file.existsSync()) return;
  final loader = FontLoader(family);
  loader.addFont(Future<ByteData>.value(ByteData.sublistView(file.readAsBytesSync())));
  await loader.load();
}

Future<void> ensurePreviewFont() async {
  if (_previewFontReady) return;
  // Noto Sans SC covers Latin and CJK. It is loaded under the same family the
  // dock asks for, and it is not listed in pubspec assets, so it stays out of
  // the installer. Droid Sans Fallback was CJK-only, which turned "14" and
  // "ClipBridge" into boxes, and buttons never inherited that family.
  const noto = 'test/fonts/NotoSansSC-Regular.otf';
  if (File(noto).existsSync()) {
    await _loadFont(dockFontFamily, noto);
    _previewFontReady = true;
  }
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final iconCandidates = [
    if (flutterRoot != null) '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    '/home/ubuntu/sdk/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ];
  for (final path in iconCandidates) {
    if (!File(path).existsSync()) continue;
    await _loadFont('MaterialIcons', path);
    break;
  }
}

Future<({Directory root, BridgeController controller})> loadController({
  List<TransferRecord> history = const [],
  List<TrustedPeer> peers = const [],
}) async {
  final root = await Directory.systemTemp.createTemp('cb_dock_');
  Directory('${root.path}/inbox').createSync(recursive: true);
  if (history.isNotEmpty) {
    await File('${root.path}/history.json').writeAsString(
      jsonEncode({'items': history.map((item) => item.toJson()).toList()}),
    );
  }
  if (peers.isNotEmpty) {
    await File('${root.path}/peers.json').writeAsString(
      jsonEncode({'peers': peers.map((item) => item.toJson()).toList()}),
    );
  }
  final controller = await BridgeController.create(
    BridgeLaunch(
      storageDir: root,
      inboxDir: Directory('${root.path}/inbox'),
      kind: DeviceKind.pc,
      clipboard: MemoryClipboard(),
      startNetworking: false,
    ),
  );
  return (root: root, controller: controller);
}

TransferRecord record(String title, {DateTime? at}) {
  return TransferRecord(
    id: title,
    direction: TransferDirection.incoming,
    kind: PayloadKind.text,
    title: title,
    size: 4,
    status: TransferStatus.success,
    progress: 1,
    createdAt: at ?? DateTime.utc(2026, 10, 6, 12),
    textBody: title,
  );
}

Future<void> pumpDock(
  WidgetTester tester,
  BridgeController controller, {
  DockPreview preview = DockPreview.panel,
  Brightness brightness = Brightness.light,
}) async {
  await tester.binding.setSurfaceSize(const Size(480, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  if ((Platform.environment['CLIPBRIDGE_PREVIEW_DIR'] ?? '').isNotEmpty) {
    await tester.runAsync(ensurePreviewFont);
  }
  final theme = buildDockTheme(brightness);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      themeAnimationDuration: Duration.zero,
      home: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: Center(
          child: RepaintBoundary(
            key: const Key('dock-preview'),
            child: WindowsDock(controller: controller, preview: preview),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  // ListTile animates its label color for 200ms. Capture and assertions need
  // the settled color, not the previous theme's near-black text.
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> savePreview(WidgetTester tester, String name) async {
  final dir = Platform.environment['CLIPBRIDGE_PREVIEW_DIR'];
  if (dir == null || dir.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('dock-preview')),
  );
  final image = boundary.toImageSync(pixelRatio: 2);
  final bytes = await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.png));
  image.dispose();
  final file = File('$dir/$name.png');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  testWidgets('未配对时显示引导和重新搜索', (tester) async {
    final loaded = await tester.runAsync(loadController);
    addTearDown(() async {
      await loaded!.controller.shutdown();
      if (loaded.root.existsSync()) await loaded.root.delete(recursive: true);
    });
    final controller = loaded!.controller;
    await pumpDock(tester, controller);
    expect(find.byKey(const Key('unpaired-guide')), findsOneWidget);
    expect(find.text('在手机上打开剪贴坞，确认配对'), findsOneWidget);
    expect(find.text('未连接'), findsOneWidget);
    expect(find.byKey(const Key('dock-rescan')), findsOneWidget);
    await savePreview(tester, 'guide_light');
    await pumpDock(tester, controller, brightness: Brightness.dark);
    await savePreview(tester, 'guide_dark');
  });

  testWidgets('已连接时显示对端名称', (tester) async {
    final loaded = await tester.runAsync(loadController);
    addTearDown(() async {
      await loaded!.controller.shutdown();
      if (loaded.root.existsSync()) await loaded.root.delete(recursive: true);
    });
    final controller = loaded!.controller;
    controller.debugPreview(phase: LinkPhase.ready, peerName: '小米 14');
    await pumpDock(tester, controller);
    expect(find.text('已连接 · 小米 14'), findsOneWidget);
    expect(find.byKey(const Key('unpaired-guide')), findsNothing);
    await savePreview(tester, 'panel_light');
    await pumpDock(tester, controller, brightness: Brightness.dark);
    await savePreview(tester, 'panel_dark');
    await pumpDock(tester, controller, preview: DockPreview.strip);
    await savePreview(tester, 'strip_light');
    await pumpDock(tester, controller, preview: DockPreview.strip, brightness: Brightness.dark);
    await savePreview(tester, 'strip_dark');
  });

  testWidgets('接收模式切换立即写回设置', (tester) async {
    final loaded = await tester.runAsync(loadController);
    addTearDown(() async {
      await loaded!.controller.shutdown();
      if (loaded.root.existsSync()) await loaded.root.delete(recursive: true);
    });
    final controller = loaded!.controller;
    await pumpDock(tester, controller);
    expect(controller.settings.receiveMode, ReceiveMode.clipboard);
    await tester.ensureVisible(find.byKey(const Key('mode-paste')));
    await tester.tap(find.byKey(const Key('mode-paste')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(controller.settings.receiveMode, ReceiveMode.paste);
    await tester.ensureVisible(find.byKey(const Key('mode-clipboard')));
    await tester.tap(find.byKey(const Key('mode-clipboard')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(controller.settings.receiveMode, ReceiveMode.clipboard);
  });

  testWidgets('最近记录只显示 5 条', (tester) async {
    final history = [
      for (var i = 1; i <= 6; i++)
        record('记录$i', at: DateTime.utc(2026, 10, 6, 12, i)),
    ];
    final loaded = await tester.runAsync(() => loadController(history: history));
    addTearDown(() async {
      await loaded!.controller.shutdown();
      if (loaded.root.existsSync()) await loaded.root.delete(recursive: true);
    });
    await pumpDock(tester, loaded!.controller);
    for (var i = 1; i <= 5; i++) {
      expect(find.text('记录$i'), findsOneWidget);
    }
    expect(find.text('记录6'), findsNothing);
  });

  testWidgets('设置页可以管理设备、上限、贴边和开机自启', (tester) async {
    final loaded = await tester.runAsync(
      () => loadController(
        peers: [
          TrustedPeer(
            id: 'peer-1',
            name: '小米 14',
            kind: DeviceKind.phone,
            publicKeyB64: 'abc',
            fingerprint: '00112233445566778899aabb',
            lastSeenMs: 0,
          ),
        ],
      ),
    );
    addTearDown(() async {
      await loaded!.controller.shutdown();
      if (loaded.root.existsSync()) await loaded.root.delete(recursive: true);
    });
    final controller = loaded!.controller;
    await pumpDock(tester, controller, preview: DockPreview.settings);
    expect(find.byKey(const Key('dock-settings')), findsOneWidget);
    expect(find.text('忘记'), findsOneWidget);
    expect(find.text('开机自启'), findsOneWidget);
    expect(find.text('提示音'), findsOneWidget);
    expect(controller.settings.notificationSound, isFalse);
    expect(find.text('自动重连'), findsOneWidget);
    expect(find.byKey(const Key('file-limit')), findsOneWidget);
    expect(find.text('左侧'), findsOneWidget);
    expect(find.text('右侧'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('edge-left')));
    await tester.tap(find.byKey(const Key('edge-left')));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(controller.settings.dockEdge, 'left');
    await savePreview(tester, 'settings_light');
    await pumpDock(tester, controller, preview: DockPreview.settings, brightness: Brightness.dark);
    await savePreview(tester, 'settings_dark');
  });

  testWidgets('深色主题下关键文字足够亮，并带中文回退字体', (tester) async {
    final loaded = await tester.runAsync(
      () => loadController(
        peers: [
          TrustedPeer(
            id: 'peer-1',
            name: '小米 14',
            kind: DeviceKind.phone,
            publicKeyB64: 'abc',
            fingerprint: '00112233445566778899aabb',
            lastSeenMs: 0,
          ),
        ],
      ),
    );
    addTearDown(() async {
      await loaded!.controller.shutdown();
      if (loaded.root.existsSync()) await loaded.root.delete(recursive: true);
    });
    final controller = loaded!.controller;
    controller.debugPreview(phase: LinkPhase.ready, peerName: '小米 14');
    await pumpDock(tester, controller, brightness: Brightness.dark);
    expectBright(tester, '已连接 · 小米 14');
    expectBright(tester, '还没有传输记录');
    expectBright(tester, '断开');
    expectBright(tester, '发送当前剪贴板');
    expectBright(tester, '仅剪贴板');
    await pumpDock(tester, controller, brightness: Brightness.light);
    await pumpDock(tester, controller, brightness: Brightness.dark);
    expectBright(tester, '已连接 · 小米 14');
    expectBright(tester, '断开');
    expectBright(tester, '发送文件');
    await pumpDock(tester, controller, preview: DockPreview.settings, brightness: Brightness.dark);
    expectBright(tester, '小米 14');
    expectBright(tester, '自动重连');
    expectBright(tester, '保存名称');
    expectBright(tester, '单次大小上限（MB）');
    expectBright(tester, '尚未获得局域网地址');
    expectBright(tester, '提示音');
  });

  testWidgets('靠近滑出，离开收回，钉住除外，且不断开会话', (tester) async {
    final loaded = await tester.runAsync(loadController);
    addTearDown(() async {
      await loaded!.controller.shutdown();
      if (loaded.root.existsSync()) await loaded.root.delete(recursive: true);
    });
    final controller = loaded!.controller;
    final clip = controller.clipboard as MemoryClipboard;
    final phase = controller.phase;
    await pumpDock(tester, controller, preview: DockPreview.live);
    expect(find.byKey(const Key('dock-dot')), findsOneWidget);
    expect(find.byKey(const Key('dock-status')), findsNothing);

    clip.emitNear(true);
    await tester.pump(const Duration(milliseconds: 149));
    expect(find.byKey(const Key('dock-status')), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('dock-status')), findsOneWidget);
    expect(find.text('断开'), findsNothing);
    expect(controller.phase, phase);

    clip.emitNear(false);
    await tester.pump(const Duration(milliseconds: 599));
    expect(find.byKey(const Key('dock-status')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('dock-dot')), findsOneWidget);
    expect(controller.phase, phase);

    clip.emitTray('pin');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const Key('dock-status')), findsOneWidget);
    clip.emitNear(false);
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.byKey(const Key('dock-status')), findsOneWidget);
    expect(controller.phase, phase);
  });

  test('提示音默认关闭，旧配置没有该字段时仍关闭', () async {
    expect(AppSettings.fromJson(<String, Object?>{}, DeviceKind.pc).notificationSound, isFalse);
    final loaded = await loadController();
    addTearDown(() async {
      await loaded.controller.shutdown();
      if (loaded.root.existsSync()) await loaded.root.delete(recursive: true);
    });
    expect(loaded.controller.settings.notificationSound, isFalse);
    expect(dockGlassOpacity, inInclusiveRange(0.75, 0.85));
    expect(dockSurface(Brightness.light).a, closeTo(dockGlassOpacity, 0.001));
    expect(dockSurface(Brightness.dark).a, closeTo(dockGlassOpacity, 0.001));
    await loaded.controller.updateSettings(
      loaded.controller.settings.copyWith(notificationSound: true),
    );
    expect(loaded.controller.settings.notificationSound, isTrue);
    final clip = loaded.controller.clipboard as MemoryClipboard;
    expect(clip.syncedNotificationSound, isTrue);
    final saved = jsonDecode(File('${loaded.root.path}/settings.json').readAsStringSync());
    expect(saved['notificationSound'], isTrue);
  });
}

double _channel(double value) {
  return value <= 0.04045 ? value / 12.92 : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
}

double _luminance(Color color) {
  return 0.2126 * _channel(color.r) + 0.7152 * _channel(color.g) + 0.0722 * _channel(color.b);
}

void expectBright(WidgetTester tester, String text) {
  final finder = find.text(text);
  expect(finder, findsWidgets);
  final render = finder.evaluate().first.renderObject;
  final TextStyle? style;
  final Color? color;
  if (render is RenderParagraph) {
    final span = render.text;
    style = span is TextSpan ? span.style : null;
    color = style?.color;
  } else {
    final editable = tester.widget<EditableText>(finder);
    style = editable.style;
    color = editable.style.color;
  }
  expect(color, isNotNull, reason: '$text 没有颜色');
  final luminance = _luminance(color!);
  expect(
    luminance,
    greaterThan(0.2),
    reason: '$text 在深色底上太暗 luminance=$luminance color=$color',
  );
  expect(style?.fontFamily, dockFontFamily, reason: text);
  expect(style?.fontFamilyFallback, contains('Microsoft YaHei UI'), reason: text);
  expect(style?.fontFamilyFallback, contains('Microsoft YaHei'), reason: text);
}