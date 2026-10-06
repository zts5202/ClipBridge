import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/bridge_exception.dart';
import '../core/frame_codec.dart';
import '../core/log.dart';
import '../core/models.dart';
import '../core/session_crypto.dart';
import 'link_policy.dart';

class HelloView {
  HelloView({
    required this.id,
    required this.name,
    required this.kind,
    required this.intent,
    required this.publicKey,
    required this.ephemeralPublic,
    required this.signature,
  });

  final String id;
  final String name;
  final DeviceKind kind;
  final String intent;
  final Uint8List publicKey;
  final Uint8List ephemeralPublic;
  final Uint8List signature;
}

sealed class SessionEvent {}

class SessionStatusEvent extends SessionEvent {
  SessionStatusEvent(this.phase, {this.detail});
  final LinkPhase phase;
  final String? detail;
}

class SessionPairingEvent extends SessionEvent {
  SessionPairingEvent(this.prompt);
  final PairPrompt prompt;
}

class SessionReadyEvent extends SessionEvent {
  SessionReadyEvent({
    required this.peerId,
    required this.name,
    required this.kind,
    required this.fingerprint,
    required this.publicKeyB64,
    required this.host,
    required this.port,
  });

  final String peerId;
  final String name;
  final DeviceKind kind;
  final String fingerprint;
  final String publicKeyB64;
  final String host;
  final int port;
}

class SessionJsonEvent extends SessionEvent {
  SessionJsonEvent(this.json);
  final Map<String, Object?> json;
}

class SessionChunkEvent extends SessionEvent {
  SessionChunkEvent({required this.id, required this.index, required this.data});
  final String id;
  final int index;
  final Uint8List data;
}

class SessionClosedEvent extends SessionEvent {
  SessionClosedEvent(this.reason);
  final String reason;
}

typedef TrustLookup = TrustedPeer? Function(String id);
typedef SessionListener = Future<void> Function(SessionEvent event);

class SessionService {
  SessionService({
    required this.identity,
    required this.deviceName,
    required this.kind,
    required this.onEvent,
    required this.trustLookup,
    required this.autoReconnectEnabled,
    this.preferredTcpPort = 47822,
  });

  final DeviceIdentity identity;
  String deviceName;
  final DeviceKind kind;
  final SessionListener onEvent;
  final TrustLookup trustLookup;
  bool Function() autoReconnectEnabled;
  final int preferredTcpPort;

  ServerSocket? _server;
  _Link? _active;
  Future<void> _gate = Future<void>.value();
  int _port = 0;
  int _linkSerial = 0;

  int get port => _port;
  bool get isReady => _active?.ready == true;
  bool get hasLiveLink => _active != null && !_active!.closed;
  String? get peerId => _active?.peerId;

  Future<void> start() async {
    if (preferredTcpPort == 0) {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    } else {
      Object? lastError;
      for (var port = preferredTcpPort; port < preferredTcpPort + 20; port++) {
        try {
          _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
          lastError = null;
          break;
        } catch (error) {
          lastError = error;
        }
      }
      if (_server == null) {
        throw BridgeException('bind', 'TCP 端口被占用：$lastError');
      }
    }
    _port = _server!.port;
    _server!.listen(
      (socket) {
        unawaited(
          _runLink(
            socket,
            dialer: false,
            intent: 'incoming',
            expectedId: null,
            emitDialErrors: false,
          ),
        );
      },
      onError: (Object error) => cbLog('accept error: $error'),
    );
  }

  Future<void> dial(
    String host,
    int port, {
    required String intent,
    String? expectedId,
    Socket? socket,
    bool quiet = false,
  }) async {
    final connected = socket ??
        await Socket.connect(
          host,
          port,
          timeout: const Duration(seconds: 6),
        );
    try {
      if (!quiet) await onEvent(SessionStatusEvent(LinkPhase.connecting));
    } catch (error) {
      await connected.close();
      rethrow;
    }
    final ready = Completer<void>();
    unawaited(
      _runLink(
        connected,
        dialer: true,
        intent: intent,
        expectedId: expectedId,
        emitDialErrors: !quiet,
        readySignal: ready,
      ),
    );
    return ready.future;
  }

  Future<void> acceptPair() async {
    final link = _active;
    if (link == null) return;
    await link.acceptPair();
    await _maybeSendReady(link);
  }

  Future<void> rejectPair() => _active?.rejectPair() ?? Future<void>.value();

  Future<void> sendJson(Map<String, Object?> message) async {
    final link = _active;
    if (link == null || !link.ready) {
      throw BridgeException('not_ready', '尚未连接设备');
    }
    await link.sendEncryptedJson(message);
  }

  Future<void> sendChunk({
    required String id,
    required int index,
    required List<int> data,
  }) async {
    final link = _active;
    if (link == null || !link.ready) {
      throw BridgeException('not_ready', '尚未连接设备');
    }
    await link.sendEncryptedBytes(
      encodeChunkInner(id: id, index: index, data: data),
    );
  }

  Future<void> disconnect() async {
    final link = _active;
    if (link == null) return;
    link.closeReason = 'local';
    await link.close();
  }

  Future<void> stop() async {
    await disconnect();
    await _server?.close();
    _server = null;
  }

  Future<void> _runLink(
    Socket socket, {
    required bool dialer,
    required String intent,
    required String? expectedId,
    required bool emitDialErrors,
    Completer<void>? readySignal,
  }) async {
    final link = _Link(
      id: 'link-${++_linkSerial}',
      socket: socket,
      dialer: dialer,
    );
    cbLog(
      'open id=${link.id} initiator=${dialer ? 'local' : 'remote'} intent=$intent',
    );
    link.readySignal = readySignal;
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
      await _handshake(link, intent: intent, expectedId: expectedId);
      final keep = await _serialized(() => _decideKeep(link));
      if (!keep) {
        final reason = link.closeReason ?? 'busy';
        final benign = reason == 'duplicate' || reason == 'yield' || reason == 'replaced';
        final kept = _active != null && !_active!.closed;
        if (benign && kept) {
          _completeReady(link, null);
        } else {
          _completeReady(link, BridgeException(reason));
        }
        await link.close();
        if (!benign && link.dialer) {
          await onEvent(SessionClosedEvent(reason));
        }
        return;
      }
      _active = link;
      await _authenticateAndServe(link);
      await _fail(link, link.closeReason ?? 'closed', emit: true);
    } catch (error, stack) {
      final quiet = error is BridgeException &&
          (error.code == 'closed' || link.closeReason == 'local' || link.silent);
      if (!quiet) cbLog('link ended: $error\n$stack');
      final reason = link.closeReason ??
          (error is BridgeException ? error.code : 'closed');
      await _fail(link, reason, emit: emitDialErrors || identical(_active, link));
    }
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _gate.then((_) => action());
    _gate = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<bool> _decideKeep(_Link link) async {
    final current = _active;
    if (current == null || current.closed) {
      return true;
    }
    if (current.peerId == link.peerId) {
      final healthy = existingLinkHealthy(
        closed: current.closed,
        missedPings: current.missed,
      );
      if (decideDuplicate(existingHealthy: healthy) == DuplicateChoice.keepExisting) {
        link.silent = true;
        link.closeReason = 'duplicate';
        cbLog(
          'duplicate drop new=${link.id} keep=${current.id} peer=${link.peerId} '
          'missed=${current.missed}',
        );
        return false;
      }
      cbLog(
        'duplicate replace old=${current.id} with=${link.id} peer=${link.peerId} '
        'reason=unhealthy missed=${current.missed}',
      );
      current.silent = true;
      current.closeReason = 'replaced';
      await current.close();
      return true;
    }
    try {
      await link.sendEncryptedJson({
        'op': 'auth',
        'mode': 'reject',
        'reason': 'busy',
      });
    } catch (_) {}
    link.closeReason = 'busy';
    return false;
  }

  Future<void> _handshake(
    _Link link, {
    required String intent,
    required String? expectedId,
  }) async {
    final ephemeral = await newEphemeral();
    final signature = await signHello(
      keyPair: identity.keyPair,
      ephemeralPublic: ephemeral.publicBytes,
      deviceId: identity.deviceId,
      intent: intent,
    );
    final hello = <String, Object?>{
      'op': 'hello',
      'v': 1,
      'id': identity.deviceId,
      'name': deviceName,
      'kind': kind.wire,
      'intent': intent,
      'lt': identity.publicKeyB64,
      'eph': base64Encode(ephemeral.publicBytes),
      'sig': base64Encode(signature),
    };
    link.pump.start();
    await link.sendPlainJson(hello);
    final frame = await link.pump.next().timeout(
      const Duration(seconds: 8),
      onTimeout: () => throw BridgeException('timeout', '握手超时'),
    );
    if (frame.encrypted) {
      throw BridgeException('handshake', '握手消息不应加密');
    }
    final remote = _parseHello(frame.body);
    if (remote.id == identity.deviceId) {
      throw BridgeException('handshake', '不能连接本机');
    }
    if (expectedId != null && remote.id != expectedId) {
      throw BridgeException('mismatch', '设备不匹配');
    }
    if (remote.publicKey.length != 32 || remote.ephemeralPublic.length != 32) {
      throw BridgeException('handshake', '密钥长度错误');
    }
    final verified = await verifyHello(
      publicKey: remote.publicKey,
      ephemeralPublic: remote.ephemeralPublic,
      deviceId: remote.id,
      intent: remote.intent,
      signature: remote.signature,
    );
    if (!verified) throw BridgeException('handshake', '签名校验失败');
    final shared = await sharedSecret(
      pair: ephemeral.pair,
      remotePublic: remote.ephemeralPublic,
    );
    final sessionKey = await deriveSessionKey(
      sharedSecret: shared,
      localPublic: identity.publicKey,
      remotePublic: remote.publicKey,
    );
    link.peerId = remote.id;
    link.peerName = remote.name;
    link.peerKind = remote.kind;
    link.peerIntent = remote.intent;
    link.peerPublic = remote.publicKey;
    link.fingerprint = await fingerprintOf(remote.publicKey);
    link.sas = await sasCode(sessionKey);
    link.cipher = SessionCipher(sessionKey);
    link.host = link.socket.remoteAddress.address;
    link.remotePort = link.socket.remotePort;
  }

  HelloView _parseHello(Uint8List body) {
    final decoded = jsonDecode(utf8.decode(body));
    if (decoded is! Map || decoded['op'] != 'hello') {
      throw BridgeException('handshake', '无效握手');
    }
    if (decoded['v'] != 1) throw BridgeException('version', '协议版本不一致');
    final id = decoded['id'];
    final name = decoded['name'];
    final kind = decoded['kind'];
    final intent = decoded['intent'];
    final lt = decoded['lt'];
    final eph = decoded['eph'];
    final sig = decoded['sig'];
    if (id is! String ||
        name is! String ||
        kind is! String ||
        intent is! String ||
        lt is! String ||
        eph is! String ||
        sig is! String) {
      throw BridgeException('handshake', '握手字段缺失');
    }
    return HelloView(
      id: id,
      name: name,
      kind: DeviceKindLabel.parse(kind),
      intent: intent,
      publicKey: Uint8List.fromList(base64Decode(lt)),
      ephemeralPublic: Uint8List.fromList(base64Decode(eph)),
      signature: Uint8List.fromList(base64Decode(sig)),
    );
  }

  Future<void> _authenticateAndServe(_Link link) async {
    final mode = _localAuthMode(link);
    link.localMode = mode.mode;
    link.rejectReason = mode.reason;
    await link.sendEncryptedJson({
      'op': 'auth',
      'mode': mode.mode,
      'reason': mode.reason ?? '',
    });
    if (mode.mode == 'reject') {
      throw BridgeException(mode.reason ?? 'rejected');
    }
    while (!link.closed && !link.ready) {
      final message = await _read(link);
      await _handleBeforeReady(link, message);
    }
    link.watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      if (link.closed || !link.ready) return;
      link.missed += 1;
      if (link.missed >= 3) {
        cbLog(
          'close id=${link.id} reason=${disconnectReasonLabel('timeout')} '
          'initiator=${link.dialer ? 'local' : 'remote'} peer=${link.peerId} missed=${link.missed}',
        );
        link.closeReason = 'timeout';
        unawaited(link.close());
        return;
      }
      unawaited(
        link.sendEncryptedJson({
          'op': 'ping',
          'ts': DateTime.now().millisecondsSinceEpoch,
        }).catchError((_) {}),
      );
    });
    while (!link.closed) {
      final message = await _read(link);
      await _handleReady(link, message);
    }
  }

  ({String mode, String? reason}) _localAuthMode(_Link link) {
    final known = trustLookup(link.peerId!);
    if (known != null) {
      if (known.publicKeyB64 != base64Encode(link.peerPublic!)) {
        return (mode: 'reject', reason: 'key_changed');
      }
      if (link.peerIntent == 'auto' && !autoReconnectEnabled()) {
        return (mode: 'reject', reason: 'auto_off');
      }
      return (mode: 'trusted', reason: null);
    }
    if (link.peerIntent == 'auto') {
      return (mode: 'reject', reason: 'not_paired');
    }
    return (mode: 'pair', reason: null);
  }

  Future<InnerMessage> _read(_Link link) async {
    final frame = await link.pump.next();
    link.lastRx = DateTime.now();
    link.missed = 0;
    if (!frame.encrypted || link.cipher == null) {
      throw BridgeException('crypto', '会话未加密');
    }
    final clear = await link.cipher!.open(frame.body);
    return decodeInner(clear);
  }

  Future<void> _handleBeforeReady(_Link link, InnerMessage message) async {
    if (message is! InnerJson) {
      throw BridgeException('handshake', '配对完成前收到了数据');
    }
    final op = message.json['op'];
    if (op == 'auth') {
      link.remoteMode = message.json['mode'] as String? ?? 'reject';
      final reason = message.json['reason'] as String?;
      if (reason != null && reason.isNotEmpty) link.rejectReason = reason;
      if (link.localMode != null && link.remoteMode != null) {
        await _evaluateAuth(link);
      }
      return;
    }
    if (op == 'pair') {
      final decision = message.json['decision'];
      if (decision == 'reject') throw BridgeException('rejected', '对方拒绝配对');
      if (decision == 'accept') {
        link.remoteAccepted = true;
        await _maybeSendReady(link);
      }
      return;
    }
    if (op == 'ready') {
      link.remoteReady = true;
      await _maybeMarkReady(link);
      return;
    }
    if (op == 'ping') return;
  }

  Future<void> _evaluateAuth(_Link link) async {
    if (link.authEvaluated) return;
    link.authEvaluated = true;
    if (link.localMode == 'reject' || link.remoteMode == 'reject') {
      final reason = link.localMode == 'reject'
          ? (link.rejectReason ?? 'rejected')
          : (link.rejectReason ?? 'rejected');
      throw BridgeException(reason);
    }
    final needPair = link.localMode == 'pair' || link.remoteMode == 'pair';
    if (needPair) {
      link.stage = _Stage.pairing;
      await onEvent(
        SessionPairingEvent(
          PairPrompt(
            peerId: link.peerId!,
            name: link.peerName ?? '未知设备',
            kind: link.peerKind ?? DeviceKind.pc,
            fingerprint: link.fingerprint ?? '',
            sas: link.sas ?? '------',
            deadline: DateTime.now().add(const Duration(seconds: 45)),
          ),
        ),
      );
      link.pairTimer = Timer(const Duration(seconds: 45), () {
        link.closeReason = 'timeout';
        unawaited(link.close());
      });
      return;
    }
    await link.sendEncryptedJson({'op': 'ready'});
    link.localReadySent = true;
    await _maybeMarkReady(link);
  }

  Future<void> _maybeSendReady(_Link link) async {
    if (link.localReadySent) return;
    if (link.localAccepted && link.remoteAccepted) {
      await link.sendEncryptedJson({'op': 'ready'});
      link.localReadySent = true;
      await _maybeMarkReady(link);
    }
  }

  Future<void> _maybeMarkReady(_Link link) async {
    if (link.ready || !link.localReadySent || !link.remoteReady) return;
    link.ready = true;
    link.pairTimer?.cancel();
    cbLog(
      'ready id=${link.id} peer=${link.peerId} initiator=${link.dialer ? 'local' : 'remote'}',
    );
    await onEvent(SessionStatusEvent(LinkPhase.ready));
    _completeReady(link, null);
    await onEvent(
      SessionReadyEvent(
        peerId: link.peerId!,
        name: link.peerName ?? '未知设备',
        kind: link.peerKind ?? DeviceKind.pc,
        fingerprint: link.fingerprint ?? '',
        publicKeyB64: base64Encode(link.peerPublic!),
        host: link.host ?? '',
        port: link.remotePort ?? 0,
      ),
    );
  }

  Future<void> _handleReady(_Link link, InnerMessage message) async {
    if (message is InnerChunk) {
      await onEvent(
        SessionChunkEvent(id: message.id, index: message.index, data: message.data),
      );
      return;
    }
    final json = (message as InnerJson).json;
    final op = json['op'];
    if (op == 'ping') {
      await link.sendEncryptedJson({'op': 'pong'});
      return;
    }
    if (op == 'pong' || op == 'ready' || op == 'auth') return;
    await onEvent(SessionJsonEvent(json));
  }

  Future<void> _fail(_Link link, String reason, {required bool emit}) async {
    if (link.silent) {
      await link.close();
      if (identical(_active, link)) _active = null;
      return;
    }
    final wasActive = identical(_active, link);
    await link.close();
    if (wasActive) _active = null;
    cbLog(
      'close id=${link.id} reason=${disconnectReasonLabel(reason)} '
      'initiator=${link.dialer ? 'local' : 'remote'} peer=${link.peerId}',
    );
    if (reason == 'yield' || reason == 'duplicate' || reason == 'replaced') return;
    _completeReady(link, BridgeException(reason));
    final otherLive = _active != null && !_active!.closed;
    if (otherLive && !wasActive) {
      cbLog('close ignored id=${link.id} kept=${_active!.id}');
      return;
    }
    if (emit || wasActive) await onEvent(SessionClosedEvent(reason));
  }

  void _completeReady(_Link link, Object? error) {
    final signal = link.readySignal;
    if (signal == null || signal.isCompleted) return;
    if (error == null) {
      signal.complete();
    } else {
      signal.completeError(error);
    }
  }
}

enum _Stage { handshake, pairing }

class _FramePump {
  _FramePump(this.socket);

  final Socket socket;
  final FrameBuffer buffer = FrameBuffer();
  final List<Frame> _queued = [];
  Completer<Frame>? _waiter;
  bool _started = false;
  bool _done = false;
  Object? _error;

  void start() {
    if (_started) return;
    _started = true;
    socket.listen(
      (data) {
        try {
          buffer.add(data);
          while (true) {
            final frame = buffer.next();
            if (frame == null) break;
            _push(frame);
          }
        } catch (error) {
          _fail(error);
        }
      },
      onError: _fail,
      onDone: () => _fail(BridgeException('closed', '连接已断开')),
      cancelOnError: true,
    );
  }

  void _push(Frame frame) {
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) {
      _waiter = null;
      waiter.complete(frame);
    } else {
      _queued.add(frame);
    }
  }

  void _fail(Object error) {
    _done = true;
    _error = error;
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) {
      _waiter = null;
      waiter.completeError(error);
    }
  }

  Future<Frame> next() {
    if (_queued.isNotEmpty) return Future<Frame>.value(_queued.removeAt(0));
    if (_done) return Future<Frame>.error(_error ?? BridgeException('closed'));
    final waiter = Completer<Frame>();
    _waiter = waiter;
    return waiter.future;
  }
}

class _Link {
  _Link({required this.id, required this.socket, required this.dialer})
    : pump = _FramePump(socket);

  final String id;
  final Socket socket;
  final bool dialer;
  final _FramePump pump;
  SessionCipher? cipher;
  String? peerId;
  String? peerName;
  DeviceKind? peerKind;
  String? peerIntent;
  Uint8List? peerPublic;
  String? fingerprint;
  String? sas;
  String? host;
  int? remotePort;
  String? localMode;
  String? remoteMode;
  String? rejectReason;
  bool authEvaluated = false;
  bool localAccepted = false;
  bool remoteAccepted = false;
  bool localReadySent = false;
  bool remoteReady = false;
  bool ready = false;
  bool closed = false;
  int missed = 0;
  bool silent = false;
  String? closeReason;
  Completer<void>? readySignal;
  _Stage stage = _Stage.handshake;
  Timer? pairTimer;
  Timer? watchdog;
  DateTime lastRx = DateTime.now();

  Future<void> sendPlainJson(Map<String, Object?> message) async {
    final frame = FrameCodec.encode(
      encrypted: false,
      body: utf8.encode(jsonEncode(message)),
    );
    socket.add(frame);
    await socket.flush();
  }

  Future<void> sendEncryptedJson(Map<String, Object?> message) {
    return sendEncryptedBytes(encodeJsonInner(message));
  }

  Future<void> sendEncryptedBytes(Uint8List inner) async {
    final cipher = this.cipher;
    if (cipher == null) throw BridgeException('crypto', '会话未建立');
    final sealed = await cipher.seal(inner);
    final frame = FrameCodec.encode(encrypted: true, body: sealed);
    socket.add(frame);
    await socket.flush();
  }

  Future<void> acceptPair() async {
    if (stage != _Stage.pairing) return;
    localAccepted = true;
    await sendEncryptedJson({'op': 'pair', 'decision': 'accept'});
  }

  Future<void> rejectPair() async {
    closeReason = 'rejected';
    try {
      await sendEncryptedJson({'op': 'pair', 'decision': 'reject'});
    } catch (_) {}
    await close();
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    pairTimer?.cancel();
    watchdog?.cancel();
    try {
      await socket.close();
    } catch (_) {}
  }
}
