import 'package:clipbridge/src/ui/dock/dock_placement.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dock snaps to the work-area edge and stays on screen', () {
    const area = MonitorWorkArea(left: 100, top: 40, right: 2020, bottom: 1120, dpi: 144);
    final right = placeDock(
      area: area,
      dockRight: true,
      fraction: 0.5,
      logicalWidth: 320,
      logicalHeight: 400,
    );
    expect(right.x + right.width, area.right);
    expect(right.y, greaterThanOrEqualTo(area.top));
    expect(right.y + right.height, lessThanOrEqualTo(area.bottom));

    final left = placeDock(
      area: area,
      dockRight: false,
      fraction: 2,
      logicalWidth: 22,
      logicalHeight: 4000,
      );
    expect(left.x, area.left);
    expect(left.height, area.height);
    expect(left.y, area.top);
  });

  test('a saved anchor moves onto a visible monitor', () {
    const primary = MonitorWorkArea(left: 0, top: 0, right: 1920, bottom: 1080, dpi: 96);
    const secondary = MonitorWorkArea(left: 1920, top: 0, right: 3200, bottom: 1080, dpi: 120);
    final placed = clampDock(
      monitors: const [primary, secondary],
      dockRight: true,
      fraction: 1.4,
      anchorX: 2000,
      anchorY: 100,
    );
    expect(placed.area.left, 1920);
    expect(placed.fraction, 1);
    expect(placed.dockRight, isTrue);
  });
}