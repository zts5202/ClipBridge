import 'package:clipbridge/src/core/models.dart';
import 'package:clipbridge/src/discovery/tether_probe.dart';
import 'package:flutter_test/flutter_test.dart';

DiscoveredPeer _peer(String id, String host) {
  return DiscoveredPeer(
    id: id,
    name: id,
    kind: DeviceKind.phone,
    tcpPort: 47822,
    fingerprint: 'aa',
    publicKeyB64: 'aa',
    host: host,
    lastSeen: DateTime.utc(2026),
  );
}

void main() {
  test('probe hosts are the tether gateway candidates', () {
    expect(tetherProbeHosts(['192.168.42.30']), ['192.168.42.129', '192.168.42.1']);
    expect(tetherProbeHosts(['192.168.42.129']), ['192.168.42.1']);
    expect(tetherProbeHosts(['192.168.42.1']), ['192.168.42.129']);
    expect(
      tetherProbeHosts(['192.168.49.8', '192.168.1.20']),
      ['192.168.49.129', '192.168.49.1'],
    );
    expect(tetherProbeHosts(['192.168.41.9', '192.168.50.1', '10.0.0.8']), isEmpty);
    expect(isAndroidUsbTetherAddress('192.168.43.129'), isTrue);
    expect(isAndroidUsbTetherAddress('192.168.1.1'), isFalse);
  });

  test('tcp probes try port 47822 on each host before the next port', () {
    final targets = tetherTcpTargets(['192.168.42.20']);
    expect(targets.first.host, '192.168.42.129');
    expect(targets.first.port, 47822);
    expect(targets[1].host, '192.168.42.1');
    expect(targets[1].port, 47822);
    expect(targets[2].port, 47823);
    expect(targets.length, 2 * (47841 - 47822 + 1));
    expect(tetherTcpTargets(['10.1.1.1']), isEmpty);
  });

  test('pc dials a new tether phone with pairing, and a trusted one only if auto reconnect is on', () {
    final phone = _peer('phone', '192.168.42.129');
    final wifi = _peer('wifi', '192.168.1.8');
    final locals = ['192.168.42.20'];

    final fresh = planTetherDial(
      kind: DeviceKind.pc,
      suppress: false,
      busy: false,
      autoReconnect: true,
      localAddresses: locals,
      discovered: [wifi, phone],
      isTrusted: (_) => false,
      isCoolingDown: (_) => false,
    );
    expect(fresh.peer?.id, 'phone');
    expect(fresh.intent, 'manual');

    final trusted = planTetherDial(
      kind: DeviceKind.pc,
      suppress: false,
      busy: false,
      autoReconnect: true,
      localAddresses: locals,
      discovered: [phone],
      isTrusted: (id) => id == 'phone',
      isCoolingDown: (_) => false,
    );
    expect(trusted.intent, 'auto');

    final autoOff = planTetherDial(
      kind: DeviceKind.pc,
      suppress: false,
      busy: false,
      autoReconnect: false,
      localAddresses: locals,
      discovered: [phone],
      isTrusted: (_) => true,
      isCoolingDown: (_) => false,
    );
    expect(autoOff.shouldDial, isFalse);

    final cooling = planTetherDial(
      kind: DeviceKind.pc,
      suppress: false,
      busy: false,
      autoReconnect: true,
      localAddresses: locals,
      discovered: [phone],
      isTrusted: (_) => false,
      isCoolingDown: (id) => id == 'phone',
    );
    expect(cooling.shouldDial, isFalse);

    final phoneSide = planTetherDial(
      kind: DeviceKind.phone,
      suppress: false,
      busy: false,
      autoReconnect: true,
      localAddresses: ['192.168.42.129'],
      discovered: [_peer('pc', '192.168.42.20')],
      isTrusted: (_) => false,
      isCoolingDown: (_) => false,
    );
    expect(phoneSide.shouldDial, isFalse);

    expect(sharesUsbTetherSubnet('192.168.42.129', locals), isTrue);
    expect(sharesUsbTetherSubnet('127.0.0.1', locals), isFalse);
  });
}
