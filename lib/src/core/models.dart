import 'dart:convert';
import 'dart:typed_data';

enum DeviceKind { phone, pc }

enum ReceiveMode { clipboard, paste }

enum LinkPhase { stopped, discovering, connecting, pairing, ready, error }

enum TransferDirection { outgoing, incoming }

enum PayloadKind { text, image, file }

enum TransferStatus { active, success, failed }

extension DeviceKindLabel on DeviceKind {
  String get wire => this == DeviceKind.phone ? 'phone' : 'pc';
  String get label => this == DeviceKind.phone ? '手机' : '电脑';

  static DeviceKind parse(String value) =>
      value == 'phone' ? DeviceKind.phone : DeviceKind.pc;
}

class AppSettings {
  const AppSettings({
    required this.deviceName,
    required this.autoReconnect,
    required this.autoSyncClipboard,
    required this.receiveMode,
    required this.maxFileBytes,
    required this.confirmBeforeSend,
    required this.paused,
    this.dockEdge = 'right',
    this.dockFraction = 0.5,
    this.launchAtStartup = false,
    this.notificationSound = false,
  });

  final String deviceName;
  final bool autoReconnect;
  final bool autoSyncClipboard;
  final ReceiveMode receiveMode;
  final int maxFileBytes;
  final bool confirmBeforeSend;
  final bool paused;
  final String dockEdge;
  final double dockFraction;
  final bool launchAtStartup;

  /// Windows balloon / Android alert sound. Off unless the user opts in.
  final bool notificationSound;

  static const int defaultMaxFileBytes = 200 * 1024 * 1024;

  factory AppSettings.initial(DeviceKind kind) {
    return AppSettings(
      deviceName: kind == DeviceKind.phone ? '我的手机' : '我的电脑',
      autoReconnect: true,
      autoSyncClipboard: false,
      receiveMode: ReceiveMode.clipboard,
      maxFileBytes: defaultMaxFileBytes,
      confirmBeforeSend: false,
      paused: false,
      dockEdge: 'right',
      dockFraction: 0.5,
      launchAtStartup: false,
    );
  }

  AppSettings copyWith({
    String? deviceName,
    bool? autoReconnect,
    bool? autoSyncClipboard,
    ReceiveMode? receiveMode,
    int? maxFileBytes,
    bool? confirmBeforeSend,
    bool? paused,
    String? dockEdge,
    double? dockFraction,
    bool? launchAtStartup,
    bool? notificationSound,
  }) {
    return AppSettings(
      deviceName: deviceName ?? this.deviceName,
      autoReconnect: autoReconnect ?? this.autoReconnect,
      autoSyncClipboard: autoSyncClipboard ?? this.autoSyncClipboard,
      receiveMode: receiveMode ?? this.receiveMode,
      maxFileBytes: maxFileBytes ?? this.maxFileBytes,
      confirmBeforeSend: confirmBeforeSend ?? this.confirmBeforeSend,
      paused: paused ?? this.paused,
      dockEdge: dockEdge ?? this.dockEdge,
      dockFraction: dockFraction ?? this.dockFraction,
      launchAtStartup: launchAtStartup ?? this.launchAtStartup,
      notificationSound: notificationSound ?? this.notificationSound,
    );
  }

  Map<String, Object?> toJson() => {
    'deviceName': deviceName,
    'autoReconnect': autoReconnect,
    'autoSyncClipboard': autoSyncClipboard,
    'receiveMode': receiveMode.name,
    'maxFileBytes': maxFileBytes,
    'confirmBeforeSend': confirmBeforeSend,
    'paused': paused,
    'dockEdge': dockEdge == 'left' ? 'left' : 'right',
    'dockFraction': dockFraction,
    'launchAtStartup': launchAtStartup,
    'notificationSound': notificationSound,
  };

  factory AppSettings.fromJson(Map<String, Object?> json, DeviceKind kind) {
    final initial = AppSettings.initial(kind);
    final mode = json['receiveMode'] == 'paste'
        ? ReceiveMode.paste
        : ReceiveMode.clipboard;
    final maxBytes = json['maxFileBytes'];
    return AppSettings(
      deviceName: (json['deviceName'] as String?)?.trim().isNotEmpty == true
          ? (json['deviceName'] as String).trim()
          : initial.deviceName,
      autoReconnect: json['autoReconnect'] as bool? ?? initial.autoReconnect,
      autoSyncClipboard:
          json['autoSyncClipboard'] as bool? ?? initial.autoSyncClipboard,
      receiveMode: mode,
      maxFileBytes: maxBytes is int && maxBytes > 0
          ? maxBytes
          : initial.maxFileBytes,
      confirmBeforeSend:
          json['confirmBeforeSend'] as bool? ?? initial.confirmBeforeSend,
      paused: json['paused'] as bool? ?? false,
      dockEdge: json['dockEdge'] == 'left' ? 'left' : 'right',
      dockFraction: json['dockFraction'] is num
          ? (json['dockFraction'] as num).toDouble().clamp(0.0, 1.0)
          : 0.5,
      launchAtStartup: json['launchAtStartup'] as bool? ?? false,
      notificationSound: json['notificationSound'] as bool? ?? false,
    );
  }

  int get maxFileMb => (maxFileBytes / (1024 * 1024)).round();
}

class TrustedPeer {
  const TrustedPeer({
    required this.id,
    required this.name,
    required this.kind,
    required this.publicKeyB64,
    required this.fingerprint,
    required this.lastSeenMs,
    this.lastHost,
    this.lastPort,
  });

  final String id;
  final String name;
  final DeviceKind kind;
  final String publicKeyB64;
  final String fingerprint;
  final int lastSeenMs;
  final String? lastHost;
  final int? lastPort;

  TrustedPeer copyWith({
    String? name,
    int? lastSeenMs,
    String? lastHost,
    int? lastPort,
  }) {
    return TrustedPeer(
      id: id,
      name: name ?? this.name,
      kind: kind,
      publicKeyB64: publicKeyB64,
      fingerprint: fingerprint,
      lastSeenMs: lastSeenMs ?? this.lastSeenMs,
      lastHost: lastHost ?? this.lastHost,
      lastPort: lastPort ?? this.lastPort,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'kind': kind.wire,
    'pub': publicKeyB64,
    'fp': fingerprint,
    'lastSeenMs': lastSeenMs,
    'lastHost': lastHost,
    'lastPort': lastPort,
  };

  factory TrustedPeer.fromJson(Map<String, Object?> json) {
    return TrustedPeer(
      id: json['id']! as String,
      name: json['name']! as String,
      kind: DeviceKindLabel.parse(json['kind'] as String? ?? 'pc'),
      publicKeyB64: json['pub']! as String,
      fingerprint: json['fp']! as String,
      lastSeenMs: json['lastSeenMs'] as int? ?? 0,
      lastHost: json['lastHost'] as String?,
      lastPort: json['lastPort'] as int?,
    );
  }
}

class DiscoveredPeer {
  const DiscoveredPeer({
    required this.id,
    required this.name,
    required this.kind,
    required this.tcpPort,
    required this.fingerprint,
    required this.publicKeyB64,
    required this.host,
    required this.lastSeen,
  });

  final String id;
  final String name;
  final DeviceKind kind;
  final int tcpPort;
  final String fingerprint;
  final String publicKeyB64;
  final String host;
  final DateTime lastSeen;
}

class TransferRecord {
  const TransferRecord({
    required this.id,
    required this.direction,
    required this.kind,
    required this.title,
    required this.size,
    required this.status,
    required this.progress,
    required this.createdAt,
    this.error,
    this.savedPath,
    this.publishedUri,
    this.sourcePath,
    this.textBody,
    this.mime,
  });

  final String id;
  final TransferDirection direction;
  final PayloadKind kind;
  final String title;
  final int size;
  final TransferStatus status;
  final double progress;
  final DateTime createdAt;
  final String? error;
  final String? savedPath;
  final String? publishedUri;
  final String? sourcePath;
  final String? textBody;
  final String? mime;

  bool get canRetry =>
      direction == TransferDirection.outgoing &&
      status == TransferStatus.failed &&
      ((textBody != null && textBody!.isNotEmpty) ||
          (sourcePath != null && sourcePath!.isNotEmpty));

  TransferRecord copyWith({
    TransferStatus? status,
    double? progress,
    String? error,
    String? savedPath,
    String? publishedUri,
    String? sourcePath,
    String? title,
  }) {
    return TransferRecord(
      id: id,
      direction: direction,
      kind: kind,
      title: title ?? this.title,
      size: size,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      createdAt: createdAt,
      error: error,
      savedPath: savedPath ?? this.savedPath,
      publishedUri: publishedUri ?? this.publishedUri,
      sourcePath: sourcePath ?? this.sourcePath,
      textBody: textBody,
      mime: mime,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'direction': direction.name,
    'kind': kind.name,
    'title': title,
    'size': size,
    'status': status.name,
    'progress': progress,
    'createdAt': createdAt.toIso8601String(),
    'error': error,
    'savedPath': savedPath,
    'publishedUri': publishedUri,
    'sourcePath': sourcePath,
    'textBody': textBody,
    'mime': mime,
  };

  factory TransferRecord.fromJson(Map<String, Object?> json) {
    return TransferRecord(
      id: json['id']! as String,
      direction: json['direction'] == 'incoming'
          ? TransferDirection.incoming
          : TransferDirection.outgoing,
      kind: PayloadKind.values.byName(json['kind']! as String),
      title: json['title']! as String,
      size: json['size'] as int? ?? 0,
      status: TransferStatus.values.byName(
        json['status'] as String? ?? 'failed',
      ),
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      error: json['error'] as String?,
      savedPath: json['savedPath'] as String?,
      publishedUri: json['publishedUri'] as String?,
      sourcePath: json['sourcePath'] as String?,
      textBody: json['textBody'] as String?,
      mime: json['mime'] as String?,
    );
  }
}

class PairPrompt {
  const PairPrompt({
    required this.peerId,
    required this.name,
    required this.kind,
    required this.fingerprint,
    required this.sas,
    required this.deadline,
  });

  final String peerId;
  final String name;
  final DeviceKind kind;
  final String fingerprint;
  final String sas;
  final DateTime deadline;
}

class ShareItem {
  const ShareItem({this.text, this.path, this.name, this.mime});

  final String? text;
  final String? path;
  final String? name;
  final String? mime;

  bool get isEmpty =>
      (text == null || text!.isEmpty) && (path == null || path!.isEmpty);
}

class PasteResult {
  const PasteResult({required this.ok, required this.reason});

  final bool ok;
  final String reason;
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String formatTime(DateTime time) {
  final local = time.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

String formatFingerprint(String hex) {
  final clean = hex.toUpperCase();
  if (clean.length < 12) return clean;
  return '${clean.substring(0, 4)}-${clean.substring(4, 8)}-${clean.substring(8, 12)}';
}

String safeFileName(String name) {
  final base = name.split(RegExp(r'[\\/]')).last.trim();
  final cleaned = base.replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_');
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return '未命名文件';
  return cleaned.length > 120 ? cleaned.substring(cleaned.length - 120) : cleaned;
}

({String host, int? port})? parseHostPort(String input) {
  final raw = input.trim();
  if (raw.isEmpty) return null;
  if (raw.startsWith('[')) {
    final end = raw.indexOf(']');
    if (end <= 1) return null;
    final host = raw.substring(1, end);
    if (end + 1 < raw.length && raw[end + 1] == ':') {
      final port = int.tryParse(raw.substring(end + 2));
      if (port == null || port <= 0 || port > 65535) return null;
      return (host: host, port: port);
    }
    return (host: host, port: null);
  }
  final colon = raw.lastIndexOf(':');
  if (colon > 0 && raw.indexOf(':') == colon) {
    final host = raw.substring(0, colon);
    final port = int.tryParse(raw.substring(colon + 1));
    if (host.isEmpty || port == null || port <= 0 || port > 65535) return null;
    return (host: host, port: port);
  }
  return (host: raw, port: null);
}

String guessMime(String name, PayloadKind kind) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.txt')) return 'text/plain';
  if (kind == PayloadKind.image) return 'image/png';
  return 'application/octet-stream';
}

bool looksLikeImage(Uint8List bytes, String? mime, String? name) {
  if (mime != null && mime.startsWith('image/')) return true;
  final lower = (name ?? '').toLowerCase();
  if (lower.endsWith('.png') ||
      lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.webp')) {
    return true;
  }
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return true;
  }
  if (bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8) return true;
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
    return true;
  }
  return false;
}

String previewText(String text) {
  final oneLine = text.replaceAll('\n', ' ').trim();
  if (oneLine.isEmpty) return '（空白文字）';
  return oneLine.length > 48 ? '${oneLine.substring(0, 48)}…' : oneLine;
}

Map<String, Object?> asJsonMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  throw const FormatException('期望 JSON 对象');
}

String jsonEncodeMap(Map<String, Object?> map) => jsonEncode(map);
