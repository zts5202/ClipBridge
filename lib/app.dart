import 'package:flutter/material.dart';

import 'src/bridge_controller.dart';
import 'src/ui/shell.dart';
import 'src/ui/theme.dart';

class ClipBridgeApp extends StatelessWidget {
  const ClipBridgeApp({super.key, required this.controller});

  final BridgeController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClipBridge',
      debugShowCheckedModeBanner: false,
      theme: buildClipTheme(Brightness.light),
      darkTheme: buildClipTheme(Brightness.dark),
      home: ClipShell(controller: controller),
    );
  }
}
