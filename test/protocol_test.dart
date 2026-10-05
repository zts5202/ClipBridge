import 'dart:typed_data';

import 'package:clipbridge/src/core/frame_codec.dart';
import 'package:clipbridge/src/core/models.dart';
import 'package:clipbridge/src/core/session_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('frames survive split packets', () {
    final first = FrameCodec.encode(encrypted: false, body: [1, 2, 3, 4]);
    final second = FrameCodec.encode(encrypted: true, body: [9, 8, 7]);
    final buffer = FrameBuffer();
    buffer.add(first.sublist(0, 2));
    expect(buffer.next(), isNull);
    buffer.add(first.sublist(2));
    buffer.add(second.sublist(0, 1));
    final frame = buffer.next()!;
    expect(frame.encrypted, isFalse);
    expect(frame.body, [1, 2, 3, 4]);
    expect(buffer.next(), isNull);
    buffer.add(second.sublist(1));
    final next = buffer.next()!;
    expect(next.encrypted, isTrue);
    expect(next.body, [9, 8, 7]);
    expect(buffer.next(), isNull);
  });

  test('host parser and file names', () {
    expect(parseHostPort('192.168.1.8')?.host, '192.168.1.8');
    expect(parseHostPort('192.168.1.8:47822')?.port, 47822);
    expect(parseHostPort('bad:port'), isNull);
    expect(safeFileName(r'..\a/b:c?.txt'), 'b_c_.txt');
    expect(formatFingerprint('AB12CD34EF56'), 'AB12-CD34-EF56');
  });

  test('session keys and sas match, tamper fails', () async {
    final alice = await DeviceIdentity.generate('alice');
    final bob = await DeviceIdentity.generate('bob');
    final restored = await DeviceIdentity.fromSeed('alice', await alice.extractSeed());
    expect(restored.publicKey, alice.publicKey);

    final aliceEph = await newEphemeral();
    final bobEph = await newEphemeral();
    final aliceSig = await signHello(
      keyPair: alice.keyPair,
      ephemeralPublic: aliceEph.publicBytes,
      deviceId: alice.deviceId,
      intent: 'manual',
    );
    expect(
      await verifyHello(
        publicKey: alice.publicKey,
        ephemeralPublic: aliceEph.publicBytes,
        deviceId: alice.deviceId,
        intent: 'manual',
        signature: aliceSig,
      ),
      isTrue,
    );
    final flipped = Uint8List.fromList(aliceSig);
    flipped[0] ^= 0xFF;
    expect(
      await verifyHello(
        publicKey: alice.publicKey,
        ephemeralPublic: aliceEph.publicBytes,
        deviceId: alice.deviceId,
        intent: 'manual',
        signature: flipped,
      ),
      isFalse,
    );

    final aliceShared = await sharedSecret(
      pair: aliceEph.pair,
      remotePublic: bobEph.publicBytes,
    );
    final bobShared = await sharedSecret(
      pair: bobEph.pair,
      remotePublic: aliceEph.publicBytes,
    );
    final aliceKey = await deriveSessionKey(
      sharedSecret: aliceShared,
      localPublic: alice.publicKey,
      remotePublic: bob.publicKey,
    );
    final bobKey = await deriveSessionKey(
      sharedSecret: bobShared,
      localPublic: bob.publicKey,
      remotePublic: alice.publicKey,
    );
    expect(aliceKey, bobKey);
    expect(await sasCode(aliceKey), await sasCode(bobKey));
    expect((await sasCode(aliceKey)).length, 6);

    final cipher = SessionCipher(aliceKey);
    final other = SessionCipher(bobKey);
    final sealed = await cipher.seal(encodeJsonInner({'op': 'ping'}));
    final opened = decodeInner(await other.open(sealed));
    expect(opened, isA<InnerJson>());
    expect((opened as InnerJson).json['op'], 'ping');
    sealed[sealed.length - 1] ^= 1;
    expect(other.open(sealed), throwsA(anything));

    final chunk = encodeChunkInner(id: 'abc', index: 3, data: [4, 5, 6]);
    final decoded = decodeInner(chunk) as InnerChunk;
    expect(decoded.id, 'abc');
    expect(decoded.index, 3);
    expect(decoded.data, [4, 5, 6]);
  });
}
