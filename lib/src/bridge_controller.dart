import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'core/bridge_exception.dart';
import 'core/log.dart';
import 'core/models.dart';
import 'core/session_crypto.dart';
import 'discovery/discovery_service.dart';
import 'discovery/tether_probe.dart';
import 'platform/clipboard_port.dart';
import 'session/link_policy.dart';
import 'session/session_service.dart';

class BridgeLaunch {
  const BridgeLaunch({
    this.storageDir,
    this.inboxDir,
    required this.kind,
    required this.clipboard,
    this.discoveryPort = 47821,
    this.tcpPort = 47822,
    this.startNetworking = true,
  });

  final Directory? storageDir;
  final Directory? inboxDir;
  final DeviceKind kind;
  final ClipboardPort clipboard;
  final int discoveryPort;
  final int tcpPort;
  final bool startNetworking;
}

class _BlobReply {
  const _BlobReply(this.accepted, [this.reason]);
  final bool accepted;
  final String? reason;
}

class _IncomingBlob {
  _IncomingBlob({
    required this.kind,
    required this.name,
    required this.mime,
    required this.size,
    required this.partFile,
    required this.writer,
    required this.hash,
  });

  final PayloadKind kind;
  final String name;
  final String mime;
  final int size;
  final File partFile;
  final RandomAccessFile writer;
  final HashSink hash;
  int received = 0;
  int nextIndex = 0;
}

class BridgeController extends ChangeNotifier {
  BridgeController._({
    required this.kind,
    required this.clipboard,
    required this._root,
    required this._inbox,
    required this._identity,
    required this._settings,
    required this._trusted,
    required this._transfers,
    required this._discovery,
    required this._session,
  });

  static const _uuid = Uuid();
  static const _chunkSize = 256 * 1024;
  static const _maxTextBytes = 1024 * 1024;

  final DeviceKind kind;
  final ClipboardPort clipboard;
  final Directory _root;
  final Directory _inbox;
  final DeviceIdentity _identity;
  final DiscoveryService _discovery;
  final SessionService _session;

  AppSettings _settings;
  final List<TrustedPeer> _trusted;
  final List<TransferRecord> _transfers;
  List<DiscoveredPeer> _discovered = const [];
  List<String> _localAddresses = const [];
  LinkPhase _phase = LinkPhase.stopped;
  String? _detail;
  String? _peerName;
  DeviceKind? _peerKind;
  String? _peerId;
  PairPrompt? _pairPrompt;
  ShareItem? _pendingShare;
  bool _suppressAuto = false;
  int _backoffSeconds = 1;
  DateTime _nextDialAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastBackoffAt;
  final ConnectionNotices _notices = ConnectionNotices();
  bool _disposed = false;
  bool _outbound = false;
  bool _probing = false;
  bool _tetherDial = false;
  String? _tetherDialPeerId;
  int _tetherCursor = 0;
  final Map<String, DateTime> _tetherQuietUntil = {};
  int _ignoreSeq = -1;
  int _seenSeq = -1;
  String? _echoText;
  String? _echoImage;
  DateTime _echoUntil = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastSentText;
  DateTime _lastSentAt = DateTime.fromMillisecondsSinceEpoch(0);
  final Map<String, Completer<_BlobReply>> _blobWaits = {};
  final Map<String, Completer<Map<String, Object?>>> _receipts = {};
  final Map<String, _IncomingBlob> _incoming = {};
  final toasts = StreamController<String>.broadcast();
  Timer? _autoTimer;
  Timer? _clipTimer;
  Timer? _uiTimer;
  Timer? _noticeTimer;
  bool _uiDirty = false;
  Future<void> _sendLock = Future<void>.value();
  StreamSubscription<ShareItem>? _shareSub;
  StreamSubscription<String>? _traySub;

  Future<bool> Function(String message)? confirmSend;

  AppSettings get settings => _settings;
  List<TrustedPeer> get trusted => List.unmodifiable(_trusted);
  List<TransferRecord> get transfers => List.unmodifiable(_transfers);
  List<DiscoveredPeer> get discovered => _discovered;
  List<String> get localAddresses => _localAddresses;
  LinkPhase get phase => _phase;
  String? get detail => _detail;
  String? get peerName => _peerName;
  DeviceKind? get peerKind => _peerKind;
  PairPrompt? get pairPrompt => _pairPrompt;
  ShareItem? get pendingShare => _pendingShare;
  String get fingerprint => _identity.fingerprint;
  String get deviceId => _identity.deviceId;
  int get tcpPort => _session.port;
  int get discoveryPort => _discovery.port;
  Directory get inboxDir => _inbox;
  bool get isReady => _phase == LinkPhase.ready && _session.isReady;
  bool get isTransferring =>
      _transfers.any((item) => item.status == TransferStatus.active);

  String get phaseLabel {
    if (_settings.paused && isReady) return '已连接（同步已暂停）';
    return switch (_phase) {
      LinkPhase.stopped => '未连接',
      LinkPhase.discovering =>
        _discovered.isEmpty ? '发现中' : '已发现设备，尚未连接',
      LinkPhase.connecting => '正在连接',
      LinkPhase.pairing => '等待配对确认',
      LinkPhase.ready => isTransferring ? '传输中' : '已连接',
      LinkPhase.error => '连接异常',
    };
  }

  static Future<BridgeController> create(BridgeLaunch launch) async {
    final root = launch.storageDir ?? await _defaultRoot();
    await root.create(recursive: true);
    final inbox = launch.inboxDir ?? await _defaultInbox(launch.kind, root);
    await inbox.create(recursive: true);
    await Directory(p.join(root.path, 'tmp')).create(recursive: true);

    final identity = await _loadIdentity(File(p.join(root.path, 'identity.json')));
    final settings = await _loadSettings(
      File(p.join(root.path, 'settings.json')),
      launch.kind,
    );
    final trusted = await _loadPeers(File(p.join(root.path, 'peers.json')));
    final transfers = await _loadHistory(File(p.join(root.path, 'history.json')));

    late final BridgeController controller;
    final discovery = DiscoveryService(bindPort: launch.discoveryPort);
    final session = SessionService(
      identity: identity,
      deviceName: settings.deviceName,
      kind: launch.kind,
      preferredTcpPort: launch.tcpPort,
      trustLookup: (id) => controller._trust(id),
      autoReconnectEnabled: () =>
          controller._settings.autoReconnect && !controller._suppressAuto,
      onEvent: (event) => controller._onSession(event),
    );
    controller = BridgeController._(
      kind: launch.kind,
      clipboard: launch.clipboard,
      root: root,
      inbox: inbox,
      identity: identity,
      settings: settings,
      trusted: trusted,
      transfers: transfers,
      discovery: discovery,
      session: session,
    );
    if (launch.startNetworking) {
      await controller._startNetworking();
    }
    return controller;
  }

  static Future<Directory> _defaultRoot() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'clipbridge'));
  }

  static Future<Directory> _defaultInbox(DeviceKind kind, Directory root) async {
    if (kind == DeviceKind.pc) {
      try {
        final downloads = await getDownloadsDirectory();
        if (downloads != null) {
          return Directory(p.join(downloads.path, 'ClipBridge'));
        }
      } catch (error) {
        cbLog('downloads directory unavailable: $error');
      }
    }
    return Directory(p.join(root.path, 'inbox'));
  }

  Future<void> _startNetworking() async {
    await _session.start();
    _discovery.onChanged = (peers) {
      _discovered = peers;
      _touch(force: true);
      unawaited(_tetherOutbound());
    };
    await _discovery.start(
      DiscoveryAnnouncement(
        id: _identity.deviceId,
        name: _settings.deviceName,
        kind: kind,
        tcpPort: _session.port,
        fingerprint: _identity.fingerprint,
        publicKeyB64: _identity.publicKeyB64,
      ),
    );
    _phase = LinkPhase.discovering;
    await _refreshLocalAddresses();
    _autoTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      unawaited(_refreshLocalAddresses());
      unawaited(attemptAutoReconnect());
      unawaited(_tetherOutbound());
    });
    if (kind == DeviceKind.pc) {
      _clipTimer = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => unawaited(pollClipboardOnce()),
      );
    }
    _shareSub = clipboard.shares.listen(
      (item) => unawaited(_ingestShare(item)),
    );
    _traySub = clipboard.trayActions.listen(_onTray);
    final pending = await clipboard.takePendingShare();
    if (pending != null) await _ingestShare(pending);
    final presence = 'ClipBridge 正在局域网待命';
    await clipboard.startPresence(presence);
    await clipboard.trayUpdate(tooltip: presence, paused: _settings.paused);
    _touch(force: true);
  }

  TrustedPeer? _trust(String id) {
    for (final peer in _trusted) {
      if (peer.id == id) return peer;
    }
    return null;
  }

  Future<void> attemptAutoReconnect() async {
    if (_disposed || _suppressAuto || _outbound || !_settings.autoReconnect) return;
    if (_linkBusy) return;
    if (DateTime.now().isBefore(_nextDialAt)) {
      cbLog('auto skip reason=backoff until=$_nextDialAt');
      return;
    }
    for (final peer in _discovered) {
      if (sharesUsbTetherSubnet(peer.host, _localAddresses)) continue;
      if (_trust(peer.id) == null) continue;
      final dial = shouldAutoDialPeer(
        localId: _identity.deviceId,
        remoteId: peer.id,
        localKind: kind,
        peerOnUsbTether: false,
      );
      if (!dial) {
        cbLog(
          'auto skip peer=${peer.id} reason=initiator local=${_identity.deviceId}',
        );
        continue;
      }
      cbLog('auto dial peer=${peer.id} initiator=local id=${_identity.deviceId}');
      await connectDiscovered(peer, manual: false);
      return;
    }
  }

  bool get _linkBusy =>
      _outbound ||
      _session.hasLiveLink ||
      _phase == LinkPhase.connecting ||
      _phase == LinkPhase.pairing;

  Future<void> _tetherOutbound() async {
    if (_disposed || kind != DeviceKind.pc || _suppressAuto || _linkBusy) return;
    if (DateTime.now().isBefore(_nextDialAt)) return;
    final plan = planTetherDial(
      kind: kind,
      suppress: _suppressAuto,
      busy: _linkBusy,
      autoReconnect: _settings.autoReconnect,
      localAddresses: _localAddresses,
      discovered: _discovered,
      isTrusted: (id) => _trust(id) != null,
      isCoolingDown: (id) {
        final until = _tetherQuietUntil[id];
        return until != null && DateTime.now().isBefore(until);
      },
    );
    final peer = plan.peer;
    final intent = plan.intent;
    if (peer != null && intent != null) {
      await _dial(
        host: peer.host,
        port: peer.tcpPort,
        intent: intent,
        expectedId: peer.id,
        tether: true,
      );
      return;
    }
    if (_discovered.any((peer) => sharesUsbTetherSubnet(peer.host, _localAddresses))) {
      return;
    }
    await _probeNextTetherPort();
  }

  Future<void> _probeNextTetherPort() async {
    if (_probing || _linkBusy || _disposed) return;
    final targets = tetherTcpTargets(_localAddresses);
    if (targets.isEmpty) return;
    _probing = true;
    final target = targets[_tetherCursor % targets.length];
    _tetherCursor = (_tetherCursor + 1) % targets.length;
    Socket? socket;
    try {
      socket = await Socket.connect(
        target.host,
        target.port,
        timeout: const Duration(milliseconds: 800),
      );
      if (_disposed || _suppressAuto || _linkBusy) {
        await socket.close();
        return;
      }
      final adopted = socket;
      socket = null;
      await _dial(
        host: target.host,
        port: target.port,
        intent: 'manual',
        quiet: true,
        tether: true,
        socket: adopted,
      );
    } catch (_) {
      await socket?.close();
    } finally {
      _probing = false;
    }
  }

  void bumpDiscovery() {
    _discovery.announceNow();
    unawaited(_refreshLocalAddresses());
  }

  Future<void> _refreshLocalAddresses() async {
    if (_disposed) return;
    final next = await localIpv4Addresses();
    if (_disposed) return;
    _discovery.tetherLocals = next;
    if (_sameAddresses(next, _localAddresses)) return;
    cbLog('network change from=$_localAddresses to=$next');
    _localAddresses = next;
    _touch(force: true);
  }

  bool _sameAddresses(List<String> next, List<String> current) {
    if (next.length != current.length) return false;
    final sortedNext = [...next]..sort();
    final sortedCurrent = [...current]..sort();
    for (var i = 0; i < sortedNext.length; i++) {
      if (sortedNext[i] != sortedCurrent[i]) return false;
    }
    return true;
  }

  @visibleForTesting
  void setDirectAnnouncements(List<DirectTarget> targets) {
    _discovery.directTargets
      ..clear()
      ..addAll(targets);
    _discovery.announceNow();
  }

  @visibleForTesting
  void allowAutoReconnect() {
    _suppressAuto = false;
    _clearBackoff();
  }

  void _clearBackoff() {
    _backoffSeconds = 1;
    _nextDialAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  void _armBackoff() {
    final now = DateTime.now();
    final recent = _lastBackoffAt;
    if (recent != null && now.difference(recent) < const Duration(milliseconds: 500)) {
      return;
    }
    _lastBackoffAt = now;
    final wait = _backoffSeconds < 1 ? 1 : _backoffSeconds;
    _nextDialAt = now.add(Duration(seconds: wait));
    _backoffSeconds = nextBackoffSeconds(wait);
    cbLog('backoff ${wait}s next=$_nextDialAt');
  }

  Future<void> connectDiscovered(
    DiscoveredPeer peer, {
    bool manual = true,
  }) async {
    if (manual) {
      _suppressAuto = false;
      _clearBackoff();
    }
    await _dial(
      host: peer.host,
      port: peer.tcpPort,
      intent: manual ? 'manual' : 'auto',
      expectedId: peer.id,
      replaceExisting: manual,
    );
  }

  Future<void> _dial({
    required String host,
    required int port,
    required String intent,
    String? expectedId,
    bool quiet = false,
    bool tether = false,
    bool replaceExisting = false,
    Socket? socket,
  }) async {
    if (_outbound) {
      await socket?.close();
      return;
    }
    if (!replaceExisting && _session.hasLiveLink) {
      await socket?.close();
      cbLog('dial skip host=$host reason=already-connected');
      return;
    }
    _outbound = true;
    if (tether) {
      _tetherDial = true;
      _tetherDialPeerId = expectedId;
    }
    try {
      if (replaceExisting && _session.hasLiveLink) await _session.disconnect();
      await _session.dial(
        host,
        port,
        intent: intent,
        expectedId: expectedId,
        quiet: quiet,
        socket: socket,
      );
    } catch (error) {
      final code = error is BridgeException ? error.code : '';
      if (_session.hasLiveLink ||
          code == 'duplicate' ||
          code == 'yield' ||
          code == 'replaced') {
        cbLog('dial ignored code=$code');
        return;
      }
      if (intent == 'manual' && !quiet) {
        _setError(explainError(error));
        return;
      }
      if (!quiet) {
        _phase = LinkPhase.error;
        _detail = explainError(error);
        _touch(force: true);
      }
      _armBackoff();
      cbLog('dial failed intent=$intent host=$host code=$code');
    } finally {
      _outbound = false;
    }
  }

  Future<void> connectManual(String input) async {
    final parsed = parseHostPort(input);
    if (parsed == null) {
      _toast('请输入对方的 IPv4 地址，例如 192.168.1.20');
      return;
    }
    _suppressAuto = false;
    _clearBackoff();
    await _dial(
      host: parsed.host,
      port: parsed.port ?? 47822,
      intent: 'manual',
      replaceExisting: true,
    );
  }

  Future<void> acceptPair() => _session.acceptPair();

  Future<void> rejectPair() => _session.rejectPair();

  Future<void> disconnect() async {
    _suppressAuto = true;
    _noticeTimer?.cancel();
    _noticeTimer = null;
    _notices.cancelPending();
    _pairPrompt = null;
    await _session.disconnect();
    _peerName = null;
    _peerKind = null;
    _peerId = null;
    _phase = LinkPhase.discovering;
    _detail = '已断开。自动重连已暂停，直到你再次手动连接';
    _touch(force: true);
    await _updatePresence();
  }

  Future<void> forgetPeer(String id) async {
    if (_peerId == id) await disconnect();
    _trusted.removeWhere((peer) => peer.id == id);
    await _savePeers();
    _touch(force: true);
  }

  Future<void> rename(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final clipped = trimmed.length > 32 ? trimmed.substring(0, 32) : trimmed;
    _settings = _settings.copyWith(deviceName: clipped);
    _session.deviceName = clipped;
    _discovery.updateSelf(name: clipped);
    await _saveSettings();
    _touch(force: true);
  }

  Future<void> updateSettings(AppSettings next) async {
    final wasAuto = _settings.autoReconnect;
    final wasLaunch = _settings.launchAtStartup;
    final maxBytes = next.maxFileBytes
        .clamp(1 * 1024 * 1024, 2048 * 1024 * 1024)
        .toInt();
    final normalized = next.copyWith(
      maxFileBytes: maxBytes,
      deviceName: next.deviceName.trim().isEmpty
          ? _settings.deviceName
          : next.deviceName.trim(),
    );
    _settings = normalized;
    if (wasLaunch != normalized.launchAtStartup) {
      unawaited(clipboard.setLaunchAtStartup(normalized.launchAtStartup));
    }
    if (!wasAuto && normalized.autoReconnect) {
      _suppressAuto = false;
      _clearBackoff();
    }
    _session.deviceName = normalized.deviceName;
    _discovery.updateSelf(name: normalized.deviceName);
    await _saveSettings();
    await _syncTray(tooltip: phaseLabel);
    _touch(force: true);
    await _updatePresence();
  }

  Future<void> setPaused(bool value) async {
    await updateSettings(_settings.copyWith(paused: value));
    _toast(value ? '已暂停同步' : '已继续同步');
  }

  Future<void> copyText(String text) async {
    await clipboard.setText(text);
    _toast('已复制');
  }

  Future<void> sendDroppedFile(String path) {
    final name = p.basename(path);
    final image = looksLikeImage(Uint8List(0), guessMime(name, PayloadKind.file), name);
    return _withSendLock(
      () => _sendFile(
        path,
        kind: image ? PayloadKind.image : PayloadKind.file,
        displayName: name,
        interactive: true,
      ),
    );
  }

  @visibleForTesting
  void debugPreview({
    LinkPhase phase = LinkPhase.discovering,
    String? peerName,
    String? detail,
  }) {
    _phase = phase;
    _peerName = peerName;
    _detail = detail;
    _touch(force: true);
  }

  Future<void> sendText(String text, {bool interactive = true}) {
    return _withSendLock(() => _sendText(text, interactive: interactive));
  }

  Future<void> sendClipboard() async {
    final text = await clipboard.getText();
    if (text != null && text.isNotEmpty) {
      await sendText(text);
      return;
    }
    final png = await clipboard.getImagePng();
    if (png != null && png.isNotEmpty) {
      await _withSendLock(() => _sendBytes(
        bytes: png,
        name: 'clipboard.png',
        kind: PayloadKind.image,
        mime: 'image/png',
        interactive: true,
      ));
      return;
    }
    _toast('剪贴板是空的，或不是文字/图片');
  }

  Future<void> pollClipboardOnce() async {
    if (kind != DeviceKind.pc || _disposed) return;
    if (!_settings.autoSyncClipboard || _settings.paused || !isReady) return;
    final sequence = await clipboard.getSequence();
    if (sequence == _seenSeq) return;
    _seenSeq = sequence;
    if (sequence == _ignoreSeq) return;
    final text = await clipboard.getText();
    if (text != null && text.isNotEmpty) {
      if (text == _echoText && DateTime.now().isBefore(_echoUntil)) return;
      if (text == _lastSentText &&
          DateTime.now().difference(_lastSentAt) < const Duration(seconds: 2)) {
        return;
      }
      await sendText(text, interactive: false);
      return;
    }
    final png = await clipboard.getImagePng();
    if (png == null || png.isEmpty) return;
    final hash = base64Encode((await Sha256().hash(png)).bytes);
    if (hash == _echoImage && DateTime.now().isBefore(_echoUntil)) return;
    await _withSendLock(
      () => _sendBytes(
        bytes: png,
        name: 'clipboard.png',
        kind: PayloadKind.image,
        mime: 'image/png',
        interactive: false,
      ),
    );
  }

  Future<void> pickAndSendImage() async {
    final file = await FilePicker.pickFile(
      dialogTitle: '选择图片',
      type: FileType.image,
    );
    if (file == null) return;
    final path = await _materializePicked(file);
    await _withSendLock(
      () => _sendFile(
        path,
        kind: PayloadKind.image,
        displayName: file.name,
        interactive: true,
      ),
    );
  }

  Future<void> pickAndSendFile() async {
    final file = await FilePicker.pickFile(dialogTitle: '选择文件');
    if (file == null) return;
    final path = await _materializePicked(file);
    await _withSendLock(
      () => _sendFile(
        path,
        kind: PayloadKind.file,
        displayName: file.name,
        interactive: true,
      ),
    );
  }

  Future<void> sendPendingShare() async {
    final item = _pendingShare;
    if (item == null) return;
    _pendingShare = null;
    _touch(force: true);
    await _sendShare(item, interactive: true);
  }

  void dismissPendingShare() {
    _pendingShare = null;
    _touch(force: true);
  }

  Future<void> retry(String id) async {
    TransferRecord? record;
    for (final item in _transfers) {
      if (item.id == id) record = item;
    }
    if (record == null || !record.canRetry) return;
    final current = record;
    if (current.kind == PayloadKind.text && current.textBody != null) {
      await sendText(current.textBody!);
      return;
    }
    final source = current.sourcePath;
    if (source == null) return;
    await _withSendLock(
      () => _sendFile(
        source,
        kind: current.kind,
        displayName: current.title,
        interactive: true,
      ),
    );
  }

  Future<void> clearHistory() async {
    _transfers.clear();
    await _saveHistory();
    _touch(force: true);
  }

  Future<void> reveal(String pathOrUri) => clipboard.reveal(pathOrUri);

  Future<void> shutdown() async {
    if (_disposed) return;
    _disposed = true;
    _autoTimer?.cancel();
    _clipTimer?.cancel();
    _uiTimer?.cancel();
    _noticeTimer?.cancel();
    await _shareSub?.cancel();
    await _traySub?.cancel();
    await _discovery.stop();
    await _session.stop();
    await clipboard.stopPresence();
    await _saveHistory();
    notifyListeners();
  }

  Future<void> _onSession(SessionEvent event) async {
    switch (event) {
      case SessionStatusEvent():
        if (event.phase == LinkPhase.connecting || event.phase == LinkPhase.ready) {
          _phase = event.phase;
          _detail = event.detail;
          _touch(force: true);
        }
      case SessionPairingEvent():
        _phase = LinkPhase.pairing;
        _pairPrompt = event.prompt;
        _detail = '请核对两端显示的验证码';
        _touch(force: true);
      case SessionReadyEvent():
        _tetherDial = false;
        _tetherDialPeerId = null;
        _noticeTimer?.cancel();
        _noticeTimer = null;
        _clearBackoff();
        _phase = LinkPhase.ready;
        _pairPrompt = null;
        _peerId = event.peerId;
        _peerName = event.name;
        _peerKind = event.kind;
        _detail = null;
        _upsertPeer(event);
        _touch(force: true);
        await _updatePresence();
        final notice = _notices.onConnected(DateTime.now(), event.name);
        if (notice != null) _toast(notice);
      case SessionJsonEvent():
        await _onJson(event.json);
      case SessionChunkEvent():
        await _onChunk(event);
      case SessionClosedEvent():
        if (_tetherDial && event.reason != 'local') {
          final id = _tetherDialPeerId ?? _pairPrompt?.peerId;
          if (id != null) {
            final seconds = event.reason == 'rejected' || event.reason == 'timeout' ? 60 : 8;
            _tetherQuietUntil[id] = DateTime.now().add(Duration(seconds: seconds));
          }
        }
        _tetherDial = false;
        _tetherDialPeerId = null;
        _failIncoming(explainError(BridgeException(event.reason)));
        _pairPrompt = null;
        _peerName = null;
        _peerKind = null;
        _peerId = null;
        if (event.reason == 'local') {
          _noticeTimer?.cancel();
          _noticeTimer = null;
          _notices.cancelPending();
          _phase = LinkPhase.discovering;
        } else {
          _phase = LinkPhase.error;
          _detail = explainError(BridgeException(event.reason));
          _armBackoff();
          _notices.onDisconnected(DateTime.now());
          _noticeTimer ??= Timer(const Duration(seconds: 10), () {
            _noticeTimer = null;
            if (_disposed || _phase == LinkPhase.ready) return;
            final notice = _notices.onDisconnected(DateTime.now());
            if (notice != null) _toast(notice);
          });
        }
        _touch(force: true);
        await _updatePresence();
    }
  }

  void _upsertPeer(SessionReadyEvent event) {
    final existing = _trust(event.peerId);
    final peer = TrustedPeer(
      id: event.peerId,
      name: event.name,
      kind: event.kind,
      publicKeyB64: event.publicKeyB64,
      fingerprint: event.fingerprint,
      lastSeenMs: DateTime.now().millisecondsSinceEpoch,
      lastHost: event.host,
      lastPort: event.port,
    );
    if (existing == null) {
      _trusted.add(peer);
    } else {
      final index = _trusted.indexWhere((item) => item.id == event.peerId);
      _trusted[index] = peer;
    }
    unawaited(_savePeers());
  }

  Future<void> _sendText(String text, {required bool interactive}) async {
    final body = text;
    if (body.isEmpty) throw BridgeException('empty', '没有可发送的文字');
    if (utf8.encode(body).length > _maxTextBytes) {
      throw BridgeException('text_too_large', '文字过长，请改为发送文件');
    }
    if (!await _prepareSend(
      interactive: interactive,
      summary: '发送文字「${previewText(body)}」到 ${_peerName ?? '对方'}？',
    )) {
      return;
    }
    final id = _uuid.v4();
    _addRecord(
      TransferRecord(
        id: id,
        direction: TransferDirection.outgoing,
        kind: PayloadKind.text,
        title: previewText(body),
        size: utf8.encode(body).length,
        status: TransferStatus.active,
        progress: 0.2,
        createdAt: DateTime.now(),
        textBody: body,
      ),
    );
    try {
      final receipt = _expectReceipt(id);
      await _session.sendJson({'op': 'text', 'id': id, 'body': body});
      final result = await receipt.future.timeout(const Duration(seconds: 20));
      _finishOutgoing(id, result);
      _lastSentText = body;
      _lastSentAt = DateTime.now();
    } catch (error) {
      _markFailed(id, explainError(error));
    }
  }

  Future<void> _sendFile(
    String path, {
    required PayloadKind kind,
    required String displayName,
    required bool interactive,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      _toast('找不到文件');
      return;
    }
    final length = await file.length();
    final mime = guessMime(displayName, kind);
    final effectiveKind =
        kind == PayloadKind.file && looksLikeImage(Uint8List(0), mime, displayName)
        ? kind
        : kind;
    await _sendStream(
      length: length,
      name: displayName,
      kind: effectiveKind,
      mime: mime,
      sourcePath: path,
      interactive: interactive,
      readChunk: (offset, size) async {
        final handle = await file.open();
        try {
          await handle.setPosition(offset);
          return await handle.read(size);
        } finally {
          await handle.close();
        }
      },
    );
  }

  Future<void> _sendBytes({
    required List<int> bytes,
    required String name,
    required PayloadKind kind,
    required String mime,
    required bool interactive,
  }) async {
    final tmp = File(p.join(_root.path, 'tmp', '${_uuid.v4()}-$name'));
    await tmp.writeAsBytes(bytes, flush: true);
    await _sendFile(
      tmp.path,
      kind: kind,
      displayName: name,
      interactive: interactive,
    );
  }

  Future<void> _sendStream({
    required int length,
    required String name,
    required PayloadKind kind,
    required String mime,
    required String sourcePath,
    required bool interactive,
    required Future<List<int>> Function(int offset, int size) readChunk,
  }) async {
    if (length > _settings.maxFileBytes) {
      _toast('超过大小上限（${formatBytes(_settings.maxFileBytes)}）');
      return;
    }
    if (!await _prepareSend(
      interactive: interactive,
      summary: '发送${kind == PayloadKind.image ? '图片' : '文件'}「$name」（${formatBytes(length)}）？',
    )) {
      return;
    }
    final id = _uuid.v4();
    _addRecord(
      TransferRecord(
        id: id,
        direction: TransferDirection.outgoing,
        kind: kind,
        title: name,
        size: length,
        status: TransferStatus.active,
        progress: 0,
        createdAt: DateTime.now(),
        sourcePath: sourcePath,
        mime: mime,
      ),
    );
    try {
      final reply = _expectBlob(id).future;
      await _session.sendJson({
        'op': 'blob_begin',
        'id': id,
        'kind': kind.name,
        'name': name,
        'mime': mime,
        'size': length,
        'chunk': _chunkSize,
      });
      final accepted = await reply.timeout(const Duration(seconds: 30));
      if (!accepted.accepted) {
        throw BridgeException(accepted.reason ?? 'rejected');
      }
      final hash = Sha256().newHashSink();
      var offset = 0;
      var index = 0;
      while (offset < length) {
        final size = length - offset < _chunkSize ? length - offset : _chunkSize;
        final chunk = await readChunk(offset, size);
        hash.add(chunk);
        await _session.sendChunk(id: id, index: index, data: chunk);
        offset += chunk.length;
        index += 1;
        _updateProgress(id, length == 0 ? 1 : offset / length);
      }
      hash.close();
      final digest = base64Encode((await hash.hash()).bytes);
      final receipt = _expectReceipt(id).future;
      await _session.sendJson({'op': 'blob_done', 'id': id, 'sha256': digest});
      final result = await receipt.timeout(const Duration(minutes: 2));
      _finishOutgoing(id, result);
    } catch (error) {
      _markFailed(id, explainError(error));
    }
  }

  Future<bool> _prepareSend({
    required bool interactive,
    required String summary,
  }) async {
    if (!isReady) {
      _toast('请先连接一台设备');
      return false;
    }
    if (_settings.paused) {
      _toast('同步已暂停');
      return false;
    }
    if (interactive && _settings.confirmBeforeSend) {
      final ask = confirmSend;
      if (ask == null) return false;
      return ask(summary);
    }
    return true;
  }

  Future<void> _onJson(Map<String, Object?> json) async {
    final op = json['op'];
    final id = json['id'] as String?;
    if (op == 'blob_accept' && id != null) {
      _blobWaits.remove(id)?.complete(const _BlobReply(true));
      return;
    }
    if (op == 'blob_reject' && id != null) {
      _blobWaits.remove(id)?.complete(
        _BlobReply(false, json['reason'] as String? ?? 'rejected'),
      );
      return;
    }
    if (op == 'receipt' && id != null) {
      _receipts.remove(id)?.complete(json);
      return;
    }
    if (op == 'text' && id != null) {
      await _receiveText(id, json['body'] as String? ?? '');
      return;
    }
    if (op == 'blob_begin' && id != null) {
      await _receiveBegin(json);
      return;
    }
    if (op == 'blob_done' && id != null) {
      await _receiveDone(id, json['sha256'] as String? ?? '');
    }
  }

  Future<void> _receiveText(String id, String body) async {
    _addRecord(
      TransferRecord(
        id: id,
        direction: TransferDirection.incoming,
        kind: PayloadKind.text,
        title: previewText(body),
        size: utf8.encode(body).length,
        status: TransferStatus.active,
        progress: 0.5,
        createdAt: DateTime.now(),
        textBody: body,
      ),
    );
    try {
      if (_settings.paused) throw BridgeException('paused');
      await _applyText(body);
      var detail = kind == DeviceKind.phone ? '已写入手机剪贴板' : '已写入电脑剪贴板';
      if (kind == DeviceKind.pc && _settings.receiveMode == ReceiveMode.paste) {
        detail = await _pasteOrFallback(detail);
      }
      _markSuccess(id, detail: detail);
      await _session.sendJson({'op': 'receipt', 'id': id, 'ok': true, 'detail': detail});
      _toast(detail);
    } catch (error) {
      final message = explainError(error);
      _markFailed(id, message);
      await _session.sendJson({
        'op': 'receipt',
        'id': id,
        'ok': false,
        'detail': message,
      });
    }
  }

  Future<void> _receiveBegin(Map<String, Object?> json) async {
    final id = json['id']! as String;
    final size = json['size'] as int? ?? 0;
    final name = safeFileName(json['name'] as String? ?? '文件');
    final mime = json['mime'] as String? ?? 'application/octet-stream';
    final kind = PayloadKind.values.byName(json['kind'] as String? ?? 'file');
    if (_settings.paused) {
      await _session.sendJson({'op': 'blob_reject', 'id': id, 'reason': 'paused'});
      return;
    }
    if (size > _settings.maxFileBytes) {
      await _session.sendJson({'op': 'blob_reject', 'id': id, 'reason': 'too_large'});
      _toast('对方发来的内容超过本机大小上限');
      return;
    }
    final part = File(p.join(_root.path, 'tmp', '$id.part'));
    final writer = await part.open(mode: FileMode.write);
    final hash = Sha256().newHashSink();
    _incoming[id] = _IncomingBlob(
      kind: kind,
      name: name,
      mime: mime,
      size: size,
      partFile: part,
      writer: writer,
      hash: hash,
    );
    _addRecord(
      TransferRecord(
        id: id,
        direction: TransferDirection.incoming,
        kind: kind,
        title: name,
        size: size,
        status: TransferStatus.active,
        progress: 0,
        createdAt: DateTime.now(),
        mime: mime,
      ),
    );
    await _session.sendJson({'op': 'blob_accept', 'id': id});
  }

  Future<void> _onChunk(SessionChunkEvent event) async {
    final incoming = _incoming[event.id];
    if (incoming == null) return;
    if (event.index != incoming.nextIndex) {
      throw BridgeException('hash', '分片顺序错误');
    }
    await incoming.writer.writeFrom(event.data);
    incoming.hash.add(event.data);
    incoming.received += event.data.length;
    incoming.nextIndex += 1;
    final progress = incoming.size == 0
        ? 1.0
        : incoming.received / incoming.size;
    _updateProgress(event.id, progress.clamp(0, 1));
  }

  Future<void> _receiveDone(String id, String sha256B64) async {
    final incoming = _incoming.remove(id);
    if (incoming == null) return;
    try {
      await incoming.writer.close();
      incoming.hash.close();
      final actual = base64Encode((await incoming.hash.hash()).bytes);
      if (actual != sha256B64) {
        await incoming.partFile.delete();
        throw BridgeException('hash', '文件校验失败');
      }
      final saved = await _placeIncoming(incoming);
      String? published;
      if (kind == DeviceKind.phone) {
        published = await clipboard.publishFile(
          path: saved.path,
          name: p.basename(saved.path),
          mime: incoming.mime,
          gallery: incoming.kind == PayloadKind.image,
        );
      }
      var detail = '已保存到 ${saved.path}';
      if (incoming.kind == PayloadKind.image && incoming.size <= 32 * 1024 * 1024) {
        final bytes = await saved.readAsBytes();
        await _applyImage(bytes);
        detail = kind == DeviceKind.pc
            ? '图片已写入剪贴板，并保存到 ${saved.path}'
            : '图片已保存，并尝试写入剪贴板';
        if (kind == DeviceKind.pc && _settings.receiveMode == ReceiveMode.paste) {
          detail = await _pasteOrFallback(detail);
        }
      }
      _markSuccess(id, detail: detail, savedPath: saved.path, publishedUri: published);
      await _session.sendJson({'op': 'receipt', 'id': id, 'ok': true, 'detail': detail});
      _toast(incoming.kind == PayloadKind.image ? '已收到图片' : '已收到文件 ${incoming.name}');
    } catch (error) {
      final message = explainError(error);
      _markFailed(id, message);
      try {
        await _session.sendJson({
          'op': 'receipt',
          'id': id,
          'ok': false,
          'detail': message,
        });
      } catch (_) {}
    }
  }

  Future<File> _placeIncoming(_IncomingBlob incoming) async {
    final safe = safeFileName(incoming.name);
    var target = File(p.join(_inbox.path, safe));
    var index = 2;
    while (await target.exists()) {
      final stem = p.basenameWithoutExtension(safe);
      final ext = p.extension(safe);
      target = File(p.join(_inbox.path, '$stem ($index)$ext'));
      index += 1;
    }
    try {
      return await incoming.partFile.rename(target.path);
    } catch (_) {
      await incoming.partFile.copy(target.path);
      await incoming.partFile.delete();
      return target;
    }
  }

  Future<void> _applyText(String text) async {
    _echoText = text;
    _echoUntil = DateTime.now().add(const Duration(seconds: 3));
    await clipboard.setText(text);
    _ignoreSeq = await clipboard.getSequence();
  }

  Future<void> _applyImage(List<int> bytes) async {
    final hash = base64Encode((await Sha256().hash(bytes)).bytes);
    _echoImage = hash;
    _echoUntil = DateTime.now().add(const Duration(seconds: 3));
    await clipboard.setImagePng(Uint8List.fromList(bytes));
    _ignoreSeq = await clipboard.getSequence();
  }

  Future<String> _pasteOrFallback(String clipboardDetail) async {
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final result = await clipboard.tryPaste();
    if (result.ok) return '$clipboardDetail，并已自动粘贴';
    final reason = switch (result.reason) {
      'self' => '当前焦点在 ClipBridge 窗口，请先点到记事本等目标窗口',
      'elevated' => '目标窗口以更高权限运行，系统不允许模拟按键',
      'sendinput' => '系统拒绝了模拟按键',
      'no_window' => '没有可粘贴的前台窗口',
      'unsupported' => '当前系统不支持自动粘贴',
      _ => '自动粘贴失败',
    };
    final message = '已写入剪贴板。自动粘贴未成功：$reason';
    await clipboard.notify('ClipBridge', message, sound: _settings.notificationSound);
    return message;
  }

  Future<void> _ingestShare(ShareItem item) async {
    if (item.isEmpty) return;
    if (!isReady) {
      _pendingShare = item;
      _toast('已收到系统分享，连接设备后即可发送');
      _touch(force: true);
      return;
    }
    await _sendShare(item, interactive: true);
  }

  Future<void> _sendShare(ShareItem item, {required bool interactive}) async {
    if (item.text != null && item.text!.isNotEmpty && (item.path == null || item.path!.isEmpty)) {
      await sendText(item.text!, interactive: interactive);
      return;
    }
    final path = item.path;
    if (path == null) return;
    final name = item.name ?? p.basename(path);
    final image = (item.mime ?? '').startsWith('image/') ||
        looksLikeImage(Uint8List(0), item.mime, name);
    await _withSendLock(
      () => _sendFile(
        path,
        kind: image ? PayloadKind.image : PayloadKind.file,
        displayName: name,
        interactive: interactive,
      ),
    );
  }

  void _onTray(String action) {
    switch (action) {
      case 'show':
      case 'pin':
        unawaited(clipboard.showWindow());
      case 'hide':
        unawaited(clipboard.hideWindow());
      case 'pause':
        unawaited(setPaused(!_settings.paused));
      case 'autosync':
        unawaited(
          updateSettings(
            _settings.copyWith(autoSyncClipboard: !_settings.autoSyncClipboard),
          ),
        );
      case 'startup':
        unawaited(
          updateSettings(
            _settings.copyWith(launchAtStartup: !_settings.launchAtStartup),
          ),
        );
      case 'sound':
        unawaited(
          updateSettings(
            _settings.copyWith(notificationSound: !_settings.notificationSound),
          ),
        );
      case 'quit':
        unawaited(_quitFromTray());
    }
  }

  Future<void> _quitFromTray() async {
    await shutdown();
    await clipboard.quitApp();
  }

  Completer<_BlobReply> _expectBlob(String id) {
    final completer = Completer<_BlobReply>();
    _blobWaits[id] = completer;
    return completer;
  }

  Completer<Map<String, Object?>> _expectReceipt(String id) {
    final completer = Completer<Map<String, Object?>>();
    _receipts[id] = completer;
    return completer;
  }

  void _finishOutgoing(String id, Map<String, Object?> receipt) {
    final ok = receipt['ok'] == true;
    final detail = receipt['detail'] as String? ?? (ok ? '对方已接收' : '对方接收失败');
    if (ok) {
      _markSuccess(id, detail: detail);
      _toast('发送成功');
    } else {
      _markFailed(id, detail);
    }
  }

  void _failIncoming(String message) {
    for (final entry in _incoming.entries) {
      unawaited(entry.value.writer.close());
    }
    _incoming.clear();
    for (final wait in _blobWaits.values) {
      if (!wait.isCompleted) wait.complete(const _BlobReply(false, 'closed'));
    }
    _blobWaits.clear();
    for (final wait in _receipts.values) {
      if (!wait.isCompleted) {
        wait.completeError(BridgeException('closed', message));
      }
    }
    _receipts.clear();
    for (var i = 0; i < _transfers.length; i++) {
      if (_transfers[i].status == TransferStatus.active) {
        _transfers[i] = _transfers[i].copyWith(
          status: TransferStatus.failed,
          error: message,
        );
      }
    }
    unawaited(_saveHistory());
  }

  void _addRecord(TransferRecord record) {
    _transfers.insert(0, record);
    if (_transfers.length > 80) {
      _transfers.removeRange(80, _transfers.length);
    }
    _touch(force: true);
  }

  void _updateProgress(String id, double progress) {
    final index = _transfers.indexWhere((item) => item.id == id);
    if (index < 0) return;
    _transfers[index] = _transfers[index].copyWith(progress: progress);
    _touch();
  }

  void _markSuccess(
    String id, {
    required String detail,
    String? savedPath,
    String? publishedUri,
  }) {
    final index = _transfers.indexWhere((item) => item.id == id);
    if (index < 0) return;
    _transfers[index] = _transfers[index].copyWith(
      status: TransferStatus.success,
      progress: 1,
      error: detail,
      savedPath: savedPath,
      publishedUri: publishedUri,
    );
    _touch(force: true);
    unawaited(_saveHistory());
  }

  void _markFailed(String id, String message) {
    final index = _transfers.indexWhere((item) => item.id == id);
    if (index < 0) return;
    _transfers[index] = _transfers[index].copyWith(
      status: TransferStatus.failed,
      error: message,
    );
    _toast(message);
    _touch(force: true);
    unawaited(_saveHistory());
  }

  void _setError(String message) {
    _phase = LinkPhase.error;
    _detail = message;
    _toast(message);
    _touch(force: true);
  }

  void _toast(String message) {
    if (_disposed) return;
    toasts.add(message);
    unawaited(clipboard.notify('ClipBridge', message, sound: _settings.notificationSound));
  }

  Future<void> _updatePresence() async {
    final text = _peerName == null
        ? 'ClipBridge 正在局域网待命'
        : '已连接 $_peerName';
    final label = _settings.paused ? '$text（已暂停）' : text;
    await clipboard.updatePresence(label);
    await _syncTray(tooltip: label);
  }

  Future<void> _syncTray({required String tooltip}) {
    return clipboard.trayUpdate(
      tooltip: tooltip,
      paused: _settings.paused,
      autoSync: _settings.autoSyncClipboard,
      launchAtStartup: _settings.launchAtStartup,
      notificationSound: _settings.notificationSound,
    );
  }

  Future<T> _withSendLock<T>(Future<T> Function() action) {
    final result = _sendLock.then((_) => action());
    _sendLock = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<String> _materializePicked(PlatformFile file) async {
    final existing = file.path;
    if (existing != null && await File(existing).exists()) return existing;
    final out = File(p.join(_root.path, 'tmp', safeFileName(file.name)));
    final sink = out.openWrite();
    await sink.addStream(file.readAsByteStream());
    await sink.close();
    return out.path;
  }

  void _touch({bool force = false}) {
    if (_disposed) return;
    if (force) {
      _uiTimer?.cancel();
      _uiTimer = null;
      _uiDirty = false;
      notifyListeners();
      return;
    }
    _uiDirty = true;
    _uiTimer ??= Timer(const Duration(milliseconds: 100), () {
      _uiTimer = null;
      if (_uiDirty && !_disposed) {
        _uiDirty = false;
        notifyListeners();
      }
    });
  }

  File get _settingsFile => File(p.join(_root.path, 'settings.json'));
  File get _peersFile => File(p.join(_root.path, 'peers.json'));
  File get _historyFile => File(p.join(_root.path, 'history.json'));

  Future<void> _saveSettings() => _writeJson(_settingsFile, _settings.toJson());

  Future<void> _savePeers() => _writeJson(_peersFile, {
    'peers': _trusted.map((peer) => peer.toJson()).toList(),
  });

  Future<void> _saveHistory() => _writeJson(_historyFile, {
    'items': _transfers.map((item) => item.toJson()).toList(),
  });

  static Future<DeviceIdentity> _loadIdentity(File file) async {
    final json = await _readJson(file);
    if (json != null && json['deviceId'] is String && json['seed'] is String) {
      final seed = base64Decode(json['seed']! as String);
      return DeviceIdentity.fromSeed(json['deviceId']! as String, seed);
    }
    final id = _uuid.v4();
    final identity = await DeviceIdentity.generate(id);
    final seed = await identity.extractSeed();
    await _writeJson(file, {'deviceId': id, 'seed': base64Encode(seed)});
    return identity;
  }

  static Future<AppSettings> _loadSettings(File file, DeviceKind kind) async {
    final json = await _readJson(file);
    if (json == null) {
      final initial = AppSettings.initial(kind);
      await _writeJson(file, initial.toJson());
      return initial;
    }
    return AppSettings.fromJson(json, kind);
  }

  static Future<List<TrustedPeer>> _loadPeers(File file) async {
    final json = await _readJson(file);
    final raw = json?['peers'];
    if (raw is! List) return [];
    return raw
        .whereType<Map>()
        .map((item) => TrustedPeer.fromJson(item.map((k, v) => MapEntry('$k', v))))
        .toList();
  }

  static Future<List<TransferRecord>> _loadHistory(File file) async {
    final json = await _readJson(file);
    final raw = json?['items'];
    if (raw is! List) return [];
    return raw.whereType<Map>().map((item) {
      final record = TransferRecord.fromJson(
        item.map((key, value) => MapEntry('$key', value)),
      );
      if (record.status == TransferStatus.active) {
        return record.copyWith(status: TransferStatus.failed, error: '传输被中断');
      }
      return record;
    }).toList();
  }

  static Future<Map<String, Object?>?> _readJson(File file) async {
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return null;
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  static Future<void> _writeJson(File file, Object value) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(value));
  }
}
