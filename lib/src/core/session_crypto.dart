import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'bridge_exception.dart';

class DeviceIdentity {
  DeviceIdentity({
    required this.deviceId,
    required this.keyPair,
    required this.publicKey,
    required this.fingerprint,
  });

  final String deviceId;
  final SimpleKeyPair keyPair;
  final Uint8List publicKey;
  final String fingerprint;

  String get publicKeyB64 => base64Encode(publicKey);

  static Future<DeviceIdentity> generate(String deviceId) async {
    final algorithm = Ed25519();
    final keyPair = await algorithm.newKeyPair();
    return DeviceIdentity.fromKeyPair(deviceId, keyPair);
  }

  static Future<DeviceIdentity> fromSeed(
    String deviceId,
    List<int> seed,
  ) async {
    final keyPair = await Ed25519().newKeyPairFromSeed(seed);
    return DeviceIdentity.fromKeyPair(deviceId, keyPair);
  }

  static Future<DeviceIdentity> fromKeyPair(
    String deviceId,
    SimpleKeyPair keyPair,
  ) async {
    final publicKey = Uint8List.fromList(
      (await keyPair.extractPublicKey()).bytes,
    );
    final fingerprint = await fingerprintOf(publicKey);
    return DeviceIdentity(
      deviceId: deviceId,
      keyPair: keyPair,
      publicKey: publicKey,
      fingerprint: fingerprint,
    );
  }

  Future<List<int>> extractSeed() => keyPair.extractPrivateKeyBytes();
}

Future<String> fingerprintOf(List<int> publicKey) async {
  final hash = await Sha256().hash(publicKey);
  final hex = hash.bytes
      .take(6)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
  return hex;
}

Uint8List helloSignPayload({
  required List<int> ephemeralPublic,
  required String deviceId,
  required String intent,
}) {
  final builder = BytesBuilder(copy: false);
  builder.add(utf8.encode('clipbridge-hello-v1\n'));
  builder.add(ephemeralPublic);
  builder.add(utf8.encode('\n$deviceId\n$intent'));
  return builder.takeBytes();
}

Future<Uint8List> signHello({
  required SimpleKeyPair keyPair,
  required List<int> ephemeralPublic,
  required String deviceId,
  required String intent,
}) async {
  final payload = helloSignPayload(
    ephemeralPublic: ephemeralPublic,
    deviceId: deviceId,
    intent: intent,
  );
  final signature = await Ed25519().sign(payload, keyPair: keyPair);
  return Uint8List.fromList(signature.bytes);
}

Future<bool> verifyHello({
  required List<int> publicKey,
  required List<int> ephemeralPublic,
  required String deviceId,
  required String intent,
  required List<int> signature,
}) async {
  final payload = helloSignPayload(
    ephemeralPublic: ephemeralPublic,
    deviceId: deviceId,
    intent: intent,
  );
  final ok = await Ed25519().verify(
    payload,
    signature: Signature(
      signature,
      publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
    ),
  );
  return ok;
}

int compareBytes(List<int> a, List<int> b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final diff = a[i] - b[i];
    if (diff != 0) return diff;
  }
  return a.length - b.length;
}

Future<Uint8List> deriveSessionKey({
  required List<int> sharedSecret,
  required List<int> localPublic,
  required List<int> remotePublic,
}) async {
  final localFirst = compareBytes(localPublic, remotePublic) <= 0;
  final first = localFirst ? localPublic : remotePublic;
  final second = localFirst ? remotePublic : localPublic;
  final saltInput = Uint8List(first.length + second.length);
  saltInput.setRange(0, first.length, first);
  saltInput.setRange(first.length, saltInput.length, second);
  final salt = await Sha256().hash(saltInput);
  final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
    secretKey: SecretKey(sharedSecret),
    nonce: salt.bytes,
    info: utf8.encode('clipbridge-session-v1'),
  );
  return Uint8List.fromList(await key.extractBytes());
}

Future<String> sasCode(List<int> sessionKey) async {
  final material = await Hkdf(hmac: Hmac.sha256(), outputLength: 4).deriveKey(
    secretKey: SecretKey(sessionKey),
    nonce: utf8.encode('clipbridge-sas-v1'),
    info: utf8.encode('sas'),
  );
  final bytes = Uint8List.fromList(await material.extractBytes());
  final value = ByteData.sublistView(bytes).getUint32(0, Endian.big);
  return (value % 1000000).toString().padLeft(6, '0');
}

class SessionCipher {
  SessionCipher(List<int> keyBytes)
    : _key = SecretKey(keyBytes),
      _prefix = _randomBytes(8);

  final SecretKey _key;
  final Uint8List _prefix;
  final AesGcm _aes = AesGcm.with256bits();
  int _counter = 0;

  Future<Uint8List> seal(List<int> plaintext) async {
    _counter++;
    if (_counter > 0xFFFFFFFF) {
      throw BridgeException('crypto', '会话消息序号耗尽');
    }
    final nonce = Uint8List(12);
    final view = ByteData.sublistView(nonce);
    view.setUint32(0, _counter, Endian.big);
    nonce.setRange(4, 12, _prefix);
    final box = await _aes.encrypt(plaintext, secretKey: _key, nonce: nonce);
    final out = Uint8List(12 + box.mac.bytes.length + box.cipherText.length);
    out.setRange(0, 12, nonce);
    out.setRange(12, 28, box.mac.bytes);
    out.setRange(28, out.length, box.cipherText);
    return out;
  }

  Future<Uint8List> open(List<int> body) async {
    if (body.length < 28) {
      throw BridgeException('crypto', '加密数据过短');
    }
    final nonce = body.sublist(0, 12);
    final mac = Mac(body.sublist(12, 28));
    final cipherText = body.sublist(28);
    try {
      final clear = await _aes.decrypt(
        SecretBox(cipherText, nonce: nonce, mac: mac),
        secretKey: _key,
      );
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw BridgeException('crypto', '加密通道校验失败');
    }
  }
}

Future<({SimpleKeyPair pair, Uint8List publicBytes})> newEphemeral() async {
  final pair = await X25519().newKeyPair();
  final publicBytes = Uint8List.fromList((await pair.extractPublicKey()).bytes);
  return (pair: pair, publicBytes: publicBytes);
}

Future<Uint8List> sharedSecret({
  required SimpleKeyPair pair,
  required List<int> remotePublic,
}) async {
  final shared = await X25519().sharedSecretKey(
    keyPair: pair,
    remotePublicKey: SimplePublicKey(remotePublic, type: KeyPairType.x25519),
  );
  return Uint8List.fromList(await shared.extractBytes());
}

Uint8List _randomBytes(int length) {
  final random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

Uint8List encodeJsonInner(Map<String, Object?> message) {
  final encoded = utf8.encode(jsonEncode(message));
  final out = Uint8List(1 + encoded.length);
  out[0] = 1;
  out.setRange(1, out.length, encoded);
  return out;
}

Uint8List encodeChunkInner({
  required String id,
  required int index,
  required List<int> data,
}) {
  final idBytes = utf8.encode(id);
  if (idBytes.length > 0xFFFF) {
    throw BridgeException('frame', '传输编号过长');
  }
  final out = Uint8List(1 + 2 + idBytes.length + 4 + data.length);
  final view = ByteData.sublistView(out);
  out[0] = 2;
  view.setUint16(1, idBytes.length, Endian.big);
  out.setRange(3, 3 + idBytes.length, idBytes);
  final indexAt = 3 + idBytes.length;
  view.setUint32(indexAt, index, Endian.big);
  out.setRange(indexAt + 4, out.length, data);
  return out;
}

sealed class InnerMessage {}

class InnerJson extends InnerMessage {
  InnerJson(this.json);
  final Map<String, Object?> json;
}

class InnerChunk extends InnerMessage {
  InnerChunk({required this.id, required this.index, required this.data});
  final String id;
  final int index;
  final Uint8List data;
}

InnerMessage decodeInner(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw BridgeException('frame', '空消息');
  }
  if (bytes[0] == 1) {
    final decoded = jsonDecode(utf8.decode(bytes.sublist(1)));
    if (decoded is! Map) {
      throw BridgeException('frame', '消息格式错误');
    }
    return InnerJson(decoded.map((key, value) => MapEntry(key.toString(), value)));
  }
  if (bytes[0] == 2) {
    if (bytes.length < 7) throw BridgeException('frame', '分片过短');
    final view = ByteData.sublistView(bytes);
    final idLen = view.getUint16(1, Endian.big);
    final idStart = 3;
    final indexAt = idStart + idLen;
    if (bytes.length < indexAt + 4) {
      throw BridgeException('frame', '分片头部损坏');
    }
    final id = utf8.decode(bytes.sublist(idStart, indexAt));
    final index = view.getUint32(indexAt, Endian.big);
    final data = Uint8List.sublistView(bytes, indexAt + 4);
    return InnerChunk(id: id, index: index, data: Uint8List.fromList(data));
  }
  throw BridgeException('frame', '未知消息类型');
}
