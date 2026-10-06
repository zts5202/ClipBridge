import 'package:clipbridge/src/core/models.dart';
import 'package:clipbridge/src/session/link_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('smaller device id initiates, except the PC on USB tethering', () {
    expect(
      shouldAutoDialPeer(
        localId: 'aaa',
        remoteId: 'bbb',
        localKind: DeviceKind.phone,
        peerOnUsbTether: false,
      ),
      isTrue,
    );
    expect(
      shouldAutoDialPeer(
        localId: 'bbb',
        remoteId: 'aaa',
        localKind: DeviceKind.pc,
        peerOnUsbTether: false,
      ),
      isFalse,
    );
    expect(
      shouldAutoDialPeer(
        localId: 'bbb',
        remoteId: 'aaa',
        localKind: DeviceKind.pc,
        peerOnUsbTether: true,
      ),
      isTrue,
    );
    expect(
      shouldAutoDialPeer(
        localId: 'aaa',
        remoteId: 'bbb',
        localKind: DeviceKind.phone,
        peerOnUsbTether: true,
      ),
      isFalse,
    );
  });

  test('a healthy session is kept when a duplicate arrives', () {
    expect(
      decideDuplicate(
        existingHealthy: existingLinkHealthy(closed: false, missedPings: 0),
      ),
      DuplicateChoice.keepExisting,
    );
    expect(
      decideDuplicate(
        existingHealthy: existingLinkHealthy(closed: false, missedPings: 2),
      ),
      DuplicateChoice.keepExisting,
    );
    expect(
      decideDuplicate(
        existingHealthy: existingLinkHealthy(closed: false, missedPings: 3),
      ),
      DuplicateChoice.replaceExisting,
    );
    expect(
      decideDuplicate(
        existingHealthy: existingLinkHealthy(closed: true, missedPings: 0),
      ),
      DuplicateChoice.replaceExisting,
    );
  });

  test('reconnect backoff doubles up to 30 seconds', () {
    var delay = 1;
    expect(delay, 1);
    delay = nextBackoffSeconds(delay);
    expect(delay, 2);
    delay = nextBackoffSeconds(delay);
    expect(delay, 4);
    delay = nextBackoffSeconds(16);
    expect(delay, 30);
    expect(nextBackoffSeconds(30), 30);
    expect(disconnectReasonLabel('timeout'), 'heartbeat timeout');
    expect(disconnectReasonLabel('closed'), 'peer close');
    expect(disconnectReasonLabel('duplicate'), 'replaced by duplicate');
  });

  test('connect and disconnect notices wait 10 seconds', () {
    final notices = ConnectionNotices();
    final t0 = DateTime.utc(2026, 10, 6, 12);
    expect(notices.onConnected(t0, '我的手机'), '已连接 我的手机');

    expect(notices.onDisconnected(t0.add(const Duration(minutes: 5))), isNull);
    expect(
      notices.onConnected(t0.add(const Duration(minutes: 5, seconds: 3)), '我的手机'),
      isNull,
    );

    final down = t0.add(const Duration(minutes: 10));
    expect(notices.onDisconnected(down), isNull);
    expect(notices.onDisconnected(down.add(const Duration(seconds: 10))), '已断开');
    expect(
      notices.onConnected(down.add(const Duration(seconds: 12)), '我的手机'),
      '已重新连接',
    );
    expect(notices.onConnected(down.add(const Duration(seconds: 20)), '我的手机'), isNull);
  });
}