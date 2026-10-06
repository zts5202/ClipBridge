import 'dart:async';

import 'package:flutter/material.dart';

import '../../bridge_controller.dart';
import '../../core/models.dart';
import 'dock_panel.dart';
import 'dock_placement.dart';
import 'dock_theme.dart';
import 'dock_window.dart';

enum DockPreview { live, panel, settings, strip }

class WindowsDock extends StatefulWidget {
  const WindowsDock({
    super.key,
    required this.controller,
    this.preview = DockPreview.live,
  });

  final BridgeController controller;
  final DockPreview preview;

  @override
  State<WindowsDock> createState() => _WindowsDockState();
}

class _WindowsDockState extends State<WindowsDock> {
  final _boxKey = GlobalKey();
  bool _expanded = false;
  bool _pinned = false;
  bool _settings = false;
  String? _hint;
  String? _confirm;
  Completer<bool>? _confirmWait;
  PairPrompt? _prompt;
  int _pairLeft = 45;
  Timer? _expandTimer;
  Timer? _collapseTimer;
  Timer? _hintTimer;
  Timer? _pairTimer;
  StreamSubscription<String>? _toasts;
  StreamSubscription<String>? _drops;
  StreamSubscription<String>? _tray;
  StreamSubscription<void>? _monitorsSub;
  StreamSubscription<bool>? _nearSub;
  List<MonitorWorkArea> _monitors = const [MonitorWorkArea.fallback];
  bool _monitorsReady = false;
  bool _nativeNear = false;
  DockFrame? _applied;

  bool get _live => widget.preview == DockPreview.live;

  @override
  void initState() {
    super.initState();
    widget.controller.confirmSend = _confirmSend;
    widget.controller.addListener(_onController);
    _toasts = widget.controller.toasts.stream.listen(_showHint);
    _drops = widget.controller.clipboard.fileDrops.listen((path) {
      unawaited(widget.controller.sendDroppedFile(path));
    });
    _monitorsSub = widget.controller.clipboard.monitorChanges.listen((_) {
      unawaited(_loadMonitors());
    });
    _tray = widget.controller.clipboard.trayActions.listen((action) {
      if (action == 'show' || action == 'pin') {
        setState(() {
          _expanded = true;
          _pinned = true;
        });
      }
    });
    if (widget.preview == DockPreview.panel || widget.preview == DockPreview.settings) {
      _expanded = true;
      _pinned = true;
      _settings = widget.preview == DockPreview.settings;
    }
    if (_live) {
      _nearSub = widget.controller.clipboard.pointerNear.listen((near) {
        _nativeNear = near;
        if (near) {
          _onEnter();
        } else {
          _onExit();
        }
      });
      unawaited(_loadMonitors());
      if (widget.controller.settings.launchAtStartup) {
        unawaited(widget.controller.clipboard.setLaunchAtStartup(true));
      }
    }
  }

  Future<void> _loadMonitors() async {
    final monitors = await DockWindow.monitors();
    if (!mounted) return;
    setState(() {
      _monitors = monitors;
      _monitorsReady = true;
    });
    _scheduleFrame();
  }

  Future<bool> _confirmSend(String message) {
    final completer = Completer<bool>();
    setState(() {
      _confirm = message;
      _confirmWait = completer;
      _expanded = true;
      _pinned = true;
    });
    return completer.future;
  }

  void _finishConfirm(bool value) {
    final wait = _confirmWait;
    setState(() {
      _confirm = null;
      _confirmWait = null;
    });
    if (wait != null && !wait.isCompleted) wait.complete(value);
  }

  void _showHint(String message) {
    _hintTimer?.cancel();
    if (!mounted) return;
    setState(() => _hint = message);
    _hintTimer = Timer(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      setState(() => _hint = null);
    });
  }

  void _onController() {
    final prompt = widget.controller.pairPrompt;
    if (prompt == null) {
      _pairTimer?.cancel();
      _prompt = null;
    } else if (_prompt?.peerId != prompt.peerId) {
      _prompt = prompt;
      _expanded = true;
      _pinned = true;
      _pairLeft = prompt.deadline.difference(DateTime.now()).inSeconds.clamp(0, 45);
      _pairTimer?.cancel();
      _pairTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() => _pairLeft = (_pairLeft - 1).clamp(0, 45));
        if (_pairLeft == 0) {
          _pairTimer?.cancel();
          unawaited(widget.controller.rejectPair());
        }
      });
    }
    if (mounted) setState(() {});
    _scheduleFrame();
  }

  void _scheduleFrame() {
    if (!_live) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _pushFrame());
  }

  Future<void> _pushFrame() async {
    if (!mounted || !_live || !_monitorsReady) return;
    final box = _boxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final settings = widget.controller.settings;
    final dockRight = settings.dockEdge != 'left';
    final anchor = _applied;
    final anchorX = anchor == null ? _monitors.first.right - 1 : anchor.x + anchor.width ~/ 2;
    final anchorY = anchor == null
        ? (_monitors.first.top + _monitors.first.bottom) ~/ 2
        : anchor.y + anchor.height ~/ 2;
    final placed = clampDock(
      monitors: _monitors,
      dockRight: dockRight,
      fraction: settings.dockFraction,
      anchorX: anchorX,
      anchorY: anchorY,
    );
    final frame = placeDock(
      area: placed.area,
      dockRight: placed.dockRight,
      fraction: placed.fraction,
      logicalWidth: box.size.width,
      logicalHeight: box.size.height,
    );
    final radius = (_expanded ? 16 : 40) * (placed.area.scale);
    if (_same(_applied, frame)) return;
    _applied = frame;
    await DockWindow.setFrame(frame, radius: radius.round());
  }

  bool _same(DockFrame? previous, DockFrame next) {
    if (previous == null) return false;
    return previous.x == next.x &&
        previous.y == next.y &&
        previous.width == next.width &&
        previous.height == next.height;
  }

  void _onEnter() {
    _collapseTimer?.cancel();
    if (_expanded || _pinned) return;
    _expandTimer?.cancel();
    _expandTimer = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      setState(() => _expanded = true);
    });
  }

  void _onExit() {
    _expandTimer?.cancel();
    // The native poll stays true while the cursor is inside the 8px pad, even
    // after MouseRegion has already reported a leave. Collapsing here would
    // hide the panel while the pointer is still beside it.
    if (_nativeNear) return;
    if (_pinned || _prompt != null || _confirm != null) return;
    _collapseTimer?.cancel();
    _collapseTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted || _pinned) return;
      setState(() {
        _expanded = false;
        _settings = false;
      });
    });
  }

  void _togglePin() {
    setState(() {
      if (!_expanded) {
        _expanded = true;
        _pinned = true;
        return;
      }
      _pinned = !_pinned;
      if (!_pinned) _expanded = false;
    });
  }

  void _onDrag(DragUpdateDetails details) {
    final applied = _applied;
    if (applied == null || _monitors.isEmpty) return;
    final area = monitorForPoint(_monitors, applied.x, applied.y);
    final scale = area.scale;
    final screenX = applied.x + (details.globalPosition.dx * scale).round();
    final screenY = applied.y + (details.globalPosition.dy * scale).round();
    final monitor = monitorForPoint(_monitors, screenX, screenY);
    final dockRight = screenX >= (monitor.left + monitor.right) / 2;
    final fraction = monitor.height <= 1
        ? 0.5
        : ((screenY - monitor.top) / monitor.height).clamp(0.0, 1.0);
    widget.controller.updateSettings(
      widget.controller.settings.copyWith(
        dockEdge: dockRight ? 'right' : 'left',
        dockFraction: fraction,
      ),
    );
  }

  @override
  void dispose() {
    _expandTimer?.cancel();
    _collapseTimer?.cancel();
    _hintTimer?.cancel();
    _pairTimer?.cancel();
    _toasts?.cancel();
    _drops?.cancel();
    _tray?.cancel();
    _monitorsSub?.cancel();
    _nearSub?.cancel();
    widget.controller.removeListener(_onController);
    if (widget.controller.confirmSend != null) {
      widget.controller.confirmSend = null;
    }
    final wait = _confirmWait;
    if (wait != null && !wait.isCompleted) wait.complete(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final connected = controller.phase == LinkPhase.ready && controller.peerName != null;
    final showPanel = widget.preview == DockPreview.strip ? false : (_live ? _expanded : true);
    final showSettings = widget.preview == DockPreview.settings || (_settings && showPanel);
    final body = showPanel
        ? _panel(showSettings)
        : DockStrip(
            connected: connected,
            transferring: controller.isTransferring,
            hint: _hint,
            onTap: _togglePin,
            onDragUpdate: _live ? _onDrag : null,
          );
    final measured = NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        _scheduleFrame();
        return true;
      },
      child: SizeChangedLayoutNotifier(child: KeyedSubtree(key: _boxKey, child: body)),
    );
    final glass = dockSurface(Theme.of(context).brightness);
    if (!_live) {
      return Material(
        animationDuration: Duration.zero,
        color: glass,
        child: measured,
      );
    }
    _scheduleFrame();
    final dockRight = controller.settings.dockEdge != 'left';
    final edge = dockRight ? Alignment.centerRight : Alignment.centerLeft;
    // The view's constraints are tight to the current HWND. AnimatedSize
    // refuses to shrink-wrap a tight parent, which locked the collapsed strip
    // to the initial 360×680 window. UnconstrainedBox lets the strip and the
    // panel keep their own size; setFrame then hugs that size to the edge.
    return MouseRegion(
      onEnter: (_) => _onEnter(),
      onExit: (_) => _onExit(),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_expanded ? 16 : 12),
        child: Material(
          animationDuration: Duration.zero,
          color: glass,
          child: UnconstrainedBox(
            clipBehavior: Clip.none,
            alignment: edge,
            child: AnimatedSize(
              duration: const Duration(milliseconds: 240),
              curve: Curves.easeOutBack,
              alignment: edge,
              clipBehavior: Clip.none,
              onEnd: _scheduleFrame,
              child: measured,
            ),
          ),
        ),
      ),
    );
  }

  Widget _panel(bool settings) {
    final controller = widget.controller;
    return SizedBox(
      width: 320,
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        children: [
            if (_prompt != null)
              PairCard(
                prompt: _prompt!,
                secondsLeft: _pairLeft,
                onAccept: controller.acceptPair,
                onReject: controller.rejectPair,
              ),
            if (_confirm != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_confirm!, key: const Key('confirm-card')),
                    Row(
                      children: [
                        TextButton(onPressed: () => _finishConfirm(false), child: const Text('取消')),
                        FilledButton(onPressed: () => _finishConfirm(true), child: const Text('发送')),
                      ],
                    ),
                  ],
                ),
              ),
            if (_hint != null && _prompt == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  _hint!,
                  key: const Key('dock-hint'),
                  style: dockFace(fontSize: 12, color: Theme.of(context).colorScheme.onSurface),
                ),
              ),
            if (settings)
              DockSettingsPage(
                controller: controller,
                onTyping: (allow) => DockWindow.allowActivate(allow),
                onClose: () => setState(() => _settings = false),
              )
            else
              DockHome(
                controller: controller,
                onOpenSettings: () => setState(() => _settings = true),
                onDragUpdate: _live ? _onDrag : (_) {},
                onTyping: (allow) => DockWindow.allowActivate(allow),
              ),
        ],
      ),
    );
  }
}
