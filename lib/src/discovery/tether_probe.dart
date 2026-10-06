import '../core/models.dart';

/// Android USB tethering uses the 192.168.42.0/24–192.168.49.0/24 pools.
/// The phone is usually .129 (older builds) or .1 (newer IpServer).
const List<int> tetherProbeLastOctets = [129, 1];

const int tetherTcpPortStart = 47822;
const int tetherTcpPortEnd = 47841;

class TetherTcpTarget {
  const TetherTcpTarget(this.host, this.port);

  final String host;
  final int port;
}

class TetherDialPlan {
  const TetherDialPlan.none() : peer = null, intent = null;

  TetherDialPlan.dial(this.peer, this.intent);

  final DiscoveredPeer? peer;
  final String? intent;

  bool get shouldDial => peer != null && intent != null;
}

bool isAndroidUsbTetherAddress(String ip) {
  final parts = _ipv4(ip);
  if (parts == null) return false;
  return parts[0] == 192 && parts[1] == 168 && parts[2] >= 42 && parts[2] <= 49;
}

/// Likely phone addresses on each local USB-tether /24, excluding this host.
List<String> tetherProbeHosts(Iterable<String> localAddresses) {
  final hosts = <String>[];
  final seen = <String>{};
  for (final local in localAddresses) {
    final parts = _ipv4(local);
    if (parts == null || !isAndroidUsbTetherAddress(local)) continue;
    final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
    for (final last in tetherProbeLastOctets) {
      final host = '$prefix.$last';
      if (host == local || !seen.add(host)) continue;
      hosts.add(host);
    }
  }
  return hosts;
}

/// One TCP attempt per tick. Port 47822 is tried on every candidate before 47823.
List<TetherTcpTarget> tetherTcpTargets(Iterable<String> localAddresses) {
  final hosts = tetherProbeHosts(localAddresses);
  final targets = <TetherTcpTarget>[];
  for (var port = tetherTcpPortStart; port <= tetherTcpPortEnd; port++) {
    for (final host in hosts) {
      targets.add(TetherTcpTarget(host, port));
    }
  }
  return targets;
}

bool sharesUsbTetherSubnet(String host, Iterable<String> localAddresses) {
  final peer = _ipv4(host);
  if (peer == null || !isAndroidUsbTetherAddress(host)) return false;
  for (final local in localAddresses) {
    final parts = _ipv4(local);
    if (parts == null) continue;
    if (parts[0] == peer[0] && parts[1] == peer[1] && parts[2] == peer[2]) {
      return true;
    }
  }
  return false;
}

/// PC-only. The phone does not scan the client range: packets it sends are
/// inbound to Windows and a Public RNDIS profile drops them.
TetherDialPlan planTetherDial({
  required DeviceKind kind,
  required bool suppress,
  required bool busy,
  required bool autoReconnect,
  required List<String> localAddresses,
  required List<DiscoveredPeer> discovered,
  required bool Function(String id) isTrusted,
  required bool Function(String id) isCoolingDown,
}) {
  if (kind != DeviceKind.pc || suppress || busy) return const TetherDialPlan.none();
  if (!localAddresses.any(isAndroidUsbTetherAddress)) return const TetherDialPlan.none();
  for (final peer in discovered) {
    if (!sharesUsbTetherSubnet(peer.host, localAddresses)) continue;
    if (isCoolingDown(peer.id)) continue;
    if (isTrusted(peer.id)) {
      if (!autoReconnect) continue;
      return TetherDialPlan.dial(peer, 'auto');
    }
    return TetherDialPlan.dial(peer, 'manual');
  }
  return const TetherDialPlan.none();
}

List<int>? _ipv4(String ip) {
  final parts = ip.split('.');
  if (parts.length != 4) return null;
  final numbers = <int>[];
  for (final part in parts) {
    final value = int.tryParse(part);
    if (value == null || value < 0 || value > 255) return null;
    numbers.add(value);
  }
  return numbers;
}
