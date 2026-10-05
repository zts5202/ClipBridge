import 'dart:io';

import 'package:flutter/material.dart';

import 'app.dart';
import 'src/bridge_controller.dart';
import 'src/core/models.dart';
import 'src/platform/clipboard_port.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final kind = Platform.isAndroid ? DeviceKind.phone : DeviceKind.pc;
  final controller = await BridgeController.create(
    BridgeLaunch(
      kind: kind,
      clipboard: createPlatformClipboard(),
    ),
  );
  runApp(ClipBridgeApp(controller: controller));
}
