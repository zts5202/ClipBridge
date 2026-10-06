import 'dart:convert';
import 'dart:io';
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

const _previewFontFamily = 'ClipPreview';
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
  const candidates = [
    '/usr/share/fonts/truetype/droid/DroidSansFallbackFull.ttf',
    '/usr/share/fonts/truetype/wqy/wqy-microhei.ttc',
  ];
  for (final path in candidates) {
    if (!File(path).existsSync()) continue;
    await _loadFont(_previewFontFamily, path);
    _previewFontReady = true;
    break;
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
  var theme = buildDockTheme(brightness);
  if (_previewFontReady) {
    theme = theme.copyWith(
      textTheme: theme.textTheme.apply(fontFamily: _previewFontFamily),
      primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: _previewFontFamily),
    );
  }
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
    expect(find.text('在手机上打开 ClipBridge，确认配对'), findsOneWidget);
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
}