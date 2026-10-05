import 'dart:io';

import 'package:clipbridge/app.dart';
import 'package:clipbridge/src/bridge_controller.dart';
import 'package:clipbridge/src/core/models.dart';
import 'package:clipbridge/src/platform/clipboard_port.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('首页显示未连接和发送入口', (tester) async {
    final created = await tester.runAsync(() async {
      final root = await Directory.systemTemp.createTemp('cb_ui_');
      final controller = await BridgeController.create(
        BridgeLaunch(
          storageDir: root,
          inboxDir: Directory('${root.path}/inbox')..createSync(recursive: true),
          kind: DeviceKind.pc,
          clipboard: MemoryClipboard(),
          startNetworking: false,
        ),
      );
      return (root: root, controller: controller);
    });
    final root = created!.root;
    final controller = created.controller;
    addTearDown(() async {
      await controller.shutdown();
      if (root.existsSync()) await root.delete(recursive: true);
    });

    await tester.pumpWidget(ClipBridgeApp(controller: controller));
    await tester.pump();
    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('发送文字'), findsOneWidget);
    expect(find.text('电脑接收方式'), findsOneWidget);
    expect(find.text('图片'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
  });
}
