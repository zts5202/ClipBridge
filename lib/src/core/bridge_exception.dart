class BridgeException implements Exception {
  BridgeException(this.code, [String? message]) : message = message ?? code;

  final String code;
  final String message;

  @override
  String toString() => message;
}

String explainError(Object error) {
  if (error is BridgeException) {
    return switch (error.code) {
      'too_large' => '超过大小上限',
      'paused' => '对方已暂停同步',
      'hash' => '文件校验失败',
      'busy' => '对方正在与其他设备通信',
      'rejected' => '对方拒绝了配对或传输',
      'timeout' => '连接或配对超时',
      'auto_off' => '对方已关闭自动重连',
      'not_paired' => '对方尚未与本机配对',
      'key_changed' => '对方密钥已变化，请先忘记该设备再重新配对',
      'crypto' => '加密通道校验失败',
      'handshake' => '握手失败',
      'version' => '协议版本不一致，请两端更新到同一版本',
      'mismatch' => '连到的设备与所选设备不一致',
      'disk' => '写入磁盘失败，请检查剩余空间',
      'closed' => '连接已断开',
      'not_ready' => '尚未连接设备',
      'empty' => '没有可发送的内容',
      'text_too_large' => '文字过长，请改为发送文件',
      _ => error.message,
    };
  }
  final text = error.toString();
  if (text.contains('SocketException') || text.contains('Connection refused')) {
    return '无法连接。请确认同一局域网，并在 Windows 防火墙中允许剪贴坞';
  }
  if (text.contains('timed out') || text.contains('TimeoutException')) {
    return '等待对方响应超时';
  }
  return text.replaceFirst('Bad state: ', '').replaceFirst('Exception: ', '');
}
