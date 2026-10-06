import 'dart:io';

import 'package:flutter/material.dart';

import 'src/bridge_controller.dart';
import 'src/ui/dock/dock_theme.dart';
import 'src/ui/dock/windows_dock.dart';
import 'src/ui/shell.dart';
import 'src/ui/theme.dart';

class ClipBridgeApp extends StatelessWidget {
  const ClipBridgeApp({super.key, required this.controller});

  final BridgeController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '剪贴坞',
      debugShowCheckedModeBanner: false,
      theme: Platform.isWindows ? buildDockTheme(Brightness.light) : buildClipTheme(Brightness.light),
      darkTheme: Platform.isWindows ? buildDockTheme(Brightness.dark) : buildClipTheme(Brightness.dark),
      home: Platform.isWindows
          ? WindowsDock(controller: controller)
          : ClipShell(controller: controller),
    );
  }
}
