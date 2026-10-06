import 'dart:async';

import 'package:flutter/material.dart';

import '../bridge_controller.dart';
import '../core/models.dart';
import 'devices_page.dart';
import 'history_page.dart';
import 'home_page.dart';
import 'settings_page.dart';

class ClipShell extends StatefulWidget {
  const ClipShell({super.key, required this.controller});

  final BridgeController controller;

  @override
  State<ClipShell> createState() => _ClipShellState();
}

class _ClipShellState extends State<ClipShell> with WidgetsBindingObserver {
  int _index = 0;
  String? _shownPairId;
  StreamSubscription<String>? _toasts;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.confirmSend = _confirmSend;
    widget.controller.addListener(_onController);
    _toasts = widget.controller.toasts.stream.listen((message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.controller.bumpDiscovery();
    }
  }

  Future<bool> _confirmSend(String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认发送'),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('发送')),
        ],
      ),
    );
    return result ?? false;
  }

  void _onController() {
    if (mounted) setState(() {});
    final prompt = widget.controller.pairPrompt;
    if (prompt == null) {
      _shownPairId = null;
      return;
    }
    if (_shownPairId == prompt.peerId || !mounted) return;
    _shownPairId = prompt.peerId;
    _showPairing(prompt);
  }

  Future<void> _showPairing(PairPrompt prompt) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _PairDialog(prompt: prompt),
    );
    if (!mounted) return;
    if (result == true) {
      await widget.controller.acceptPair();
    } else {
      await widget.controller.rejectPair();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onController);
    _toasts?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomePage(
        controller: widget.controller,
        onOpenDevices: () => setState(() => _index = 1),
      ),
      DevicesPage(controller: widget.controller),
      HistoryPage(controller: widget.controller),
      SettingsPage(controller: widget.controller),
    ];
    final wide = MediaQuery.sizeOf(context).width >= 960;
    final titles = ['剪贴坞', '设备', '记录', '设置'];
    return Scaffold(
      appBar: AppBar(title: Text(titles[_index])),
      body: wide
          ? Row(
              children: [
                NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: (value) => setState(() => _index = value),
                  labelType: NavigationRailLabelType.all,
                  destinations: const [
                    NavigationRailDestination(icon: Icon(Icons.home_outlined), label: Text('首页')),
                    NavigationRailDestination(icon: Icon(Icons.devices_rounded), label: Text('设备')),
                    NavigationRailDestination(icon: Icon(Icons.history_rounded), label: Text('记录')),
                    NavigationRailDestination(icon: Icon(Icons.settings_outlined), label: Text('设置')),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: pages[_index]),
              ],
            )
          : pages[_index],
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (value) => setState(() => _index = value),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.home_outlined), label: '首页'),
                NavigationDestination(icon: Icon(Icons.devices_rounded), label: '设备'),
                NavigationDestination(icon: Icon(Icons.history_rounded), label: '记录'),
                NavigationDestination(icon: Icon(Icons.settings_outlined), label: '设置'),
              ],
            ),
    );
  }
}

class _PairDialog extends StatefulWidget {
  const _PairDialog({required this.prompt});

  final PairPrompt prompt;

  @override
  State<_PairDialog> createState() => _PairDialogState();
}

class _PairDialogState extends State<_PairDialog> {
  late int _left;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _left = widget.prompt.deadline.difference(DateTime.now()).inSeconds.clamp(0, 45);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _left = (_left - 1).clamp(0, 45));
      if (_left == 0) Navigator.of(context).pop(false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prompt = widget.prompt;
    return AlertDialog(
      title: const Text('确认新设备'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${prompt.name}（${prompt.kind.label}）请求配对'),
          const SizedBox(height: 8),
          Text('指纹 ${formatFingerprint(prompt.fingerprint)}'),
          const SizedBox(height: 12),
          Text('验证码', style: Theme.of(context).textTheme.labelLarge),
          Text(prompt.sas, style: Theme.of(context).textTheme.displaySmall),
          const SizedBox(height: 8),
          Text('请与另一台设备上的验证码核对，两端都点同意后才会建立加密会话。$_left 秒后自动拒绝。'),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('拒绝')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('同意')),
      ],
    );
  }
}
