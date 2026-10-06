import 'dart:io';
import 'dart:typed_data';

import 'package:clipbridge/src/bridge_controller.dart';
import 'package:clipbridge/src/core/models.dart';
import 'package:clipbridge/src/discovery/discovery_service.dart';
import 'package:clipbridge/src/platform/clipboard_port.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> waitFor(bool Function() predicate, {String? why}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 12));
  while (DateTime.now().isBefore(deadline)) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
  throw TestFailure(why ?? '条件在超时前没有满足');
}

Future<BridgeController> launch({
  required Directory root,
  required DeviceKind kind,
  required MemoryClipboard clipboard,
}) {
  return BridgeController.create(
    BridgeLaunch(
      storageDir: root,
      inboxDir: Directory('${root.path}/inbox')..createSync(recursive: true),
      kind: kind,
      clipboard: clipboard,
      discoveryPort: 0,
      tcpPort: 0,
    ),
  );
}

void main() {
  test('paired devices exchange text, image, and file', () async {
    final rootA = await Directory.systemTemp.createTemp('cb_a_');
    final rootB = await Directory.systemTemp.createTemp('cb_b_');
    final clipA = MemoryClipboard();
    final clipB = MemoryClipboard();
    final phone = await launch(root: rootA, kind: DeviceKind.phone, clipboard: clipA);
    final pc = await launch(root: rootB, kind: DeviceKind.pc, clipboard: clipB);
    addTearDown(() async {
      await phone.shutdown();
      await pc.shutdown();
      await rootA.delete(recursive: true);
      await rootB.delete(recursive: true);
    });

    phone.setDirectAnnouncements([
      DirectTarget(InternetAddress.loopbackIPv4, pc.discoveryPort),
    ]);
    pc.setDirectAnnouncements([
      DirectTarget(InternetAddress.loopbackIPv4, phone.discoveryPort),
    ]);
    await waitFor(
      () => phone.discovered.any((peer) => peer.id == pc.deviceId) &&
          pc.discovered.any((peer) => peer.id == phone.deviceId),
      why: 'UDP 发现没有互相看见',
    );

    final remote = phone.discovered.firstWhere((peer) => peer.id == pc.deviceId);
    final connecting = phone.connectDiscovered(remote);
    await waitFor(
      () => phone.pairPrompt != null && pc.pairPrompt != null,
      why: '没有弹出双方配对确认',
    );
    expect(phone.pairPrompt!.sas, pc.pairPrompt!.sas);
    await phone.acceptPair();
    await pc.acceptPair();
    await connecting.timeout(const Duration(seconds: 8));
    await waitFor(() => phone.isReady && pc.isReady, why: '配对后没有进入已连接');

    await phone.sendText('你好，ClipBridge');
    await waitFor(() => clipB.text == '你好，ClipBridge', why: '电脑没有收到文字');
    expect(pc.transfers.first.status, TransferStatus.success);

    await pc.updateSettings(pc.settings.copyWith(receiveMode: ReceiveMode.paste));
    clipB.pasteResult = const PasteResult(ok: false, reason: 'self');
    await phone.sendText('请粘贴到前台');
    await waitFor(
      () => clipB.notifications.any((item) => item.contains('自动粘贴未成功')),
      why: '自动粘贴失败时没有通知',
    );

    await pc.sendText('从电脑回到手机');
    await waitFor(() => clipA.text == '从电脑回到手机', why: '手机没有收到文字');

    final png = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4,
    ]);
    clipA.text = null;
    clipA.png = png;
    clipA.sequence += 1;
    await phone.sendClipboard();
    await waitFor(
      () => clipB.png != null && _same(clipB.png!, png),
      why: '电脑没有把图片放进剪贴板',
    );

    final payload = Uint8List.fromList(List<int>.generate(4096, (i) => i % 251));
    final source = File('${rootA.path}/notes.bin');
    await source.writeAsBytes(payload);
    final recordBefore = phone.transfers.length;
    clipA.emitShare(ShareItem(path: source.path, name: 'notes.bin', mime: 'application/octet-stream'));
    await waitFor(
      () => phone.transfers.length > recordBefore &&
          phone.transfers.any((item) => item.title == 'notes.bin' && item.status == TransferStatus.success),
      why: '文件没有发送成功',
    );
    final saved = pc.transfers.firstWhere((item) => item.title == 'notes.bin').savedPath;
    expect(saved, isNotNull);
    expect(await File(saved!).readAsBytes(), payload);

    await pc.updateSettings(pc.settings.copyWith(maxFileBytes: 1024 * 1024));
    await phone.updateSettings(phone.settings.copyWith(maxFileBytes: 2 * 1024 * 1024));
    final big = File('${rootA.path}/big.bin');
    await big.writeAsBytes(Uint8List(1024 * 1024 + 64));
    clipA.emitShare(ShareItem(path: big.path, name: 'big.bin', mime: 'application/octet-stream'));
    await waitFor(
      () => phone.transfers.any(
        (item) => item.title == 'big.bin' && item.status == TransferStatus.failed,
      ),
      why: '超限文件没有被拒绝',
    );

    await phone.disconnect();
    expect(phone.isReady, isFalse);
    phone.allowAutoReconnect();
    phone.setDirectAnnouncements([
      DirectTarget(InternetAddress.loopbackIPv4, pc.discoveryPort),
    ]);
    await waitFor(
      () => phone.discovered.any((peer) => peer.id == pc.deviceId),
      why: '断开后没有重新发现电脑',
    );
    await phone.attemptAutoReconnect();
    await waitFor(() => phone.isReady && pc.isReady, why: '已配对设备没有自动重连');
    expect(phone.pairPrompt, isNull);
    expect(pc.pairPrompt, isNull);

    clipB.text = '自动同步的一段话';
    clipB.sequence += 1;
    await pc.updateSettings(pc.settings.copyWith(autoSyncClipboard: true));
    await pc.pollClipboardOnce();
    await waitFor(() => clipA.text == '自动同步的一段话', why: '电脑剪贴板没有自动同步到手机');
  });

  test('unicast discovery reply reaches the prober', () async {
    final rootA = await Directory.systemTemp.createTemp('cb_reply_a_');
    final rootB = await Directory.systemTemp.createTemp('cb_reply_b_');
    final phone = await launch(
      root: rootA,
      kind: DeviceKind.phone,
      clipboard: MemoryClipboard(),
    );
    final pc = await launch(
      root: rootB,
      kind: DeviceKind.pc,
      clipboard: MemoryClipboard(),
    );
    addTearDown(() async {
      await phone.shutdown();
      await pc.shutdown();
      await rootA.delete(recursive: true);
      await rootB.delete(recursive: true);
    });

    pc.setDirectAnnouncements([
      DirectTarget(InternetAddress.loopbackIPv4, phone.discoveryPort),
    ]);
    await waitFor(
      () => pc.discovered.any((peer) => peer.id == phone.deviceId) &&
          phone.discovered.any((peer) => peer.id == pc.deviceId),
      why: '只从电脑发出单播时，手机的回复没有回到电脑',
    );
  });
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
