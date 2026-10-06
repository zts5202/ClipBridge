import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/log.dart';
import '../core/models.dart';
import 'tether_probe.dart';

class DirectTarget {
  const DirectTarget(this.address, this.port);

  final InternetAddress address;
  final int port;
}

class DiscoveryAnnouncement {
  DiscoveryAnnouncement({
    required this.id,
    required this.name,
    required this.kind,
    required this.tcpPort,
    required this.fingerprint,
    required this.publicKeyB64,
  });

  final String id;
  String name;
  final DeviceKind kind;
  int tcpPort;
  final String fingerprint;
  final String publicKeyB64;

  Uint8List encode() {
    final json = jsonEncode({
      'v': 1,
      'id': id,
      'name': name,
      'kind': kind.wire,
      'port': tcpPort,
      'fp': fingerprint,
      'pk': publicKeyB64,
    });
    return Uint8List.fromList(utf8.encode('CB1$json'));
  }
}

class DiscoveryService {
  DiscoveryService({this.bindPort = 47821});

  final int bindPort;
  final List<DirectTarget> directTargets = [];
  List<String> tetherLocals = const [];
  RawDatagramSocket? _socket;
  Timer? _announceTimer;
  Timer? _expireTimer;
  DiscoveryAnnouncement? _me;
  final Map<String, DiscoveredPeer> _peers = {};
  void Function(List<DiscoveredPeer> peers)? onChanged;

  int get port => _socket?.port ?? bindPort;
  List<DiscoveredPeer> get peers => _peers.values.toList(growable: false);

  Future<void> start(DiscoveryAnnouncement me) async {
    _me = me;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      bindPort,
      reuseAddress: true,
    );
    socket.broadcastEnabled = true;
    _socket = socket;
    socket.listen((event) {
      if (event == RawSocketEvent.read) {
        final datagram = socket.receive();
        if (datagram == null) return;
        _onDatagram(datagram);
      }
    });
    _announceTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => announceNow(),
    );
    _expireTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _expire(),
    );
    announceNow();
  }

  void updateSelf({String? name, int? tcpPort}) {
    final me = _me;
    if (me == null) return;
    if (name != null) me.name = name;
    if (tcpPort != null) me.tcpPort = tcpPort;
    announceNow();
  }

  void announceNow() {
    final me = _me;
    final socket = _socket;
    if (me == null || socket == null) return;
    final packet = me.encode();
    _safeSend(socket, packet, InternetAddress('255.255.255.255'), port);
    unawaited(_sendSubnetBroadcasts(socket, packet));
    for (final target in directTargets) {
      _safeSend(socket, packet, target.address, target.port);
    }
    for (final host in tetherProbeHosts(tetherLocals)) {
      final address = InternetAddress.tryParse(host);
      if (address == null) continue;
      _safeSend(socket, packet, address, port);
    }
  }

  Future<void> _sendSubnetBroadcasts(
    RawDatagramSocket socket,
    Uint8List packet,
  ) async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final iface in interfaces) {
        for (final address in iface.addresses) {
          if (address.isLoopback) continue;
          final parts = address.address.split('.');
          if (parts.length != 4) continue;
          final broadcast = InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255');
          _safeSend(socket, packet, broadcast, port);
        }
      }
    } catch (error) {
      cbLog('enumerate interfaces failed: $error');
    }
  }

  void _safeSend(
    RawDatagramSocket socket,
    Uint8List packet,
    InternetAddress address,
    int port,
  ) {
    try {
      socket.send(packet, address, port);
    } catch (error) {
      cbLog('udp send $address:$port failed: $error');
    }
  }

  void _onDatagram(Datagram datagram) {
    final me = _me;
    if (me == null) return;
    final peer = _parse(datagram.data, datagram.address.address);
    if (peer == null || peer.id == me.id) return;
    _peers[peer.id] = peer;
    onChanged?.call(peers);
    final socket = _socket;
    if (socket != null) {
      _safeSend(socket, me.encode(), datagram.address, datagram.port);
    }
  }

  void _expire() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 9));
    final before = _peers.length;
    _peers.removeWhere((_, peer) => peer.lastSeen.isBefore(cutoff));
    if (_peers.length != before) onChanged?.call(peers);
  }

  DiscoveredPeer? _parse(Uint8List data, String host) {
    try {
      final text = utf8.decode(data);
      if (!text.startsWith('CB1')) return null;
      final decoded = jsonDecode(text.substring(3));
      if (decoded is! Map) return null;
      final map = decoded.map((key, value) => MapEntry(key.toString(), value));
      if (map['v'] != 1) return null;
      final id = map['id'];
      final name = map['name'];
      final kind = map['kind'];
      final port = map['port'];
      final fp = map['fp'];
      final pk = map['pk'];
      if (id is! String ||
          name is! String ||
          kind is! String ||
          port is! int ||
          fp is! String ||
          pk is! String) {
        return null;
      }
      if (id.isEmpty || name.isEmpty || port <= 0 || port > 65535) return null;
      return DiscoveredPeer(
        id: id,
        name: name,
        kind: DeviceKindLabel.parse(kind),
        tcpPort: port,
        fingerprint: fp,
        publicKeyB64: pk,
        host: host,
        lastSeen: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _expireTimer?.cancel();
    _socket?.close();
    _socket = null;
    _peers.clear();
  }
}

Future<List<String>> localIpv4Addresses() async {
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
    includeLinkLocal: false,
  );
  final addresses = <String>[];
  for (final iface in interfaces) {
    for (final address in iface.addresses) {
      if (!address.isLoopback) addresses.add(address.address);
    }
  }
  return addresses;
}
