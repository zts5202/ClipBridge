import 'dart:typed_data';

import 'bridge_exception.dart';

class Frame {
  Frame({required this.encrypted, required this.body});

  final bool encrypted;
  final Uint8List body;
}

class FrameCodec {
  static const int maxBody = 2 * 1024 * 1024;

  static Uint8List encode({required bool encrypted, required List<int> body}) {
    if (body.length > maxBody) {
      throw BridgeException('frame', '数据帧过大');
    }
    final out = Uint8List(5 + body.length);
    final view = ByteData.sublistView(out);
    view.setUint32(0, body.length, Endian.big);
    out[4] = encrypted ? 1 : 0;
    out.setRange(5, out.length, body);
    return out;
  }
}

class FrameBuffer {
  Uint8List _buf = Uint8List(0);

  void add(List<int> data) {
    if (data.isEmpty) return;
    final next = Uint8List(_buf.length + data.length);
    next.setRange(0, _buf.length, _buf);
    next.setRange(_buf.length, next.length, data);
    _buf = next;
  }

  Frame? next() {
    if (_buf.length < 5) return null;
    final bodyLen = ByteData.sublistView(_buf).getUint32(0, Endian.big);
    if (bodyLen > FrameCodec.maxBody) {
      throw BridgeException('frame', '数据帧过大');
    }
    final total = 5 + bodyLen;
    if (_buf.length < total) return null;
    final encrypted = _buf[4] == 1;
    final body = Uint8List.sublistView(_buf, 5, total);
    final copy = Uint8List.fromList(body);
    final rest = _buf.length == total
        ? Uint8List(0)
        : Uint8List.fromList(Uint8List.sublistView(_buf, total));
    _buf = rest;
    return Frame(encrypted: encrypted, body: copy);
  }
}
