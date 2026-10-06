import '../core/models.dart';

/// Wi-Fi: the lexicographically smaller device id dials.
/// USB tethering: the PC dials, because a Public RNDIS profile drops inbound TCP.
bool shouldAutoDialPeer({
  required String localId,
  required String remoteId,
  required DeviceKind localKind,
  required bool peerOnUsbTether,
}) {
  if (peerOnUsbTether) return localKind == DeviceKind.pc;
  return localId.compareTo(remoteId) < 0;
}

enum DuplicateChoice { keepExisting, replaceExisting }

bool existingLinkHealthy({required bool closed, required int missedPings}) {
  return !closed && missedPings < 3;
}

DuplicateChoice decideDuplicate({required bool existingHealthy}) {
  if (existingHealthy) return DuplicateChoice.keepExisting;
  return DuplicateChoice.replaceExisting;
}

int nextBackoffSeconds(int current) {
  final base = current < 1 ? 1 : current;
  final doubled = base * 2;
  if (doubled > 30) return 30;
  return doubled;
}

String disconnectReasonLabel(String reason) {
  return switch (reason) {
    'timeout' => 'heartbeat timeout',
    'closed' => 'peer close',
    'duplicate' || 'replaced' => 'replaced by duplicate',
    'local' => 'local close',
    _ => reason,
  };
}

/// Tray/toast gate. The window status is updated separately and stays live.
class ConnectionNotices {
  DateTime? downSince;
  bool announcedDown = false;
  bool everUp = false;

  String? onConnected(DateTime now, String peerName) {
    final down = downSince;
    final announced = announcedDown;
    downSince = null;
    announcedDown = false;
    if (!everUp) {
      everUp = true;
      return '已连接 $peerName';
    }
    if (down == null) return null;
    if (announced || now.difference(down) >= const Duration(seconds: 10)) {
      return '已重新连接';
    }
    return null;
  }

  String? onDisconnected(DateTime now) {
    downSince ??= now;
    if (announcedDown) return null;
    if (now.difference(downSince!) >= const Duration(seconds: 10)) {
      announcedDown = true;
      return '已断开';
    }
    return null;
  }

  void cancelPending() {
    downSince = null;
    announcedDown = false;
  }
}
