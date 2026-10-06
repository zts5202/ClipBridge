class MonitorWorkArea {
  const MonitorWorkArea({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.dpi,
  });

  final int left;
  final int top;
  final int right;
  final int bottom;
  final int dpi;

  double get scale => dpi <= 0 ? 1 : dpi / 96.0;
  int get width => right - left;
  int get height => bottom - top;

  bool contains(int x, int y) => x >= left && x < right && y >= top && y < bottom;

  static const fallback = MonitorWorkArea(
    left: 0,
    top: 0,
    right: 1920,
    bottom: 1080,
    dpi: 96,
  );
}

class DockFrame {
  const DockFrame({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final int x;
  final int y;
  final int width;
  final int height;
}

/// Physical-pixel frame for a strip or panel snapped to a work-area edge.
DockFrame placeDock({
  required MonitorWorkArea area,
  required bool dockRight,
  required double fraction,
  required double logicalWidth,
  required double logicalHeight,
}) {
  final scale = area.scale;
  var width = (logicalWidth * scale).round();
  var height = (logicalHeight * scale).round();
  if (width < 1) width = 1;
  if (height < 1) height = 1;
  if (width > area.width) width = area.width;
  if (height > area.height) height = area.height;
  final x = dockRight ? area.right - width : area.left;
  final travel = area.height - height;
  final along = fraction.clamp(0.0, 1.0);
  final y = area.top + (travel * along).round();
  return DockFrame(x: x, y: y, width: width, height: height);
}

MonitorWorkArea monitorForPoint(List<MonitorWorkArea> monitors, int x, int y) {
  if (monitors.isEmpty) return MonitorWorkArea.fallback;
  for (final monitor in monitors) {
    if (monitor.contains(x, y)) return monitor;
  }
  return monitors.first;
}

/// Keep a saved anchor on a visible edge after the display layout changes.
({bool dockRight, double fraction, MonitorWorkArea area}) clampDock({
  required List<MonitorWorkArea> monitors,
  required bool dockRight,
  required double fraction,
  required int anchorX,
  required int anchorY,
}) {
  final area = monitorForPoint(monitors, anchorX, anchorY);
  return (dockRight: dockRight, fraction: fraction.clamp(0.0, 1.0), area: area);
}
