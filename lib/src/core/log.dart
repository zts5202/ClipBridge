import 'package:flutter/foundation.dart';

void cbLog(String message) {
  assert(() {
    debugPrint('[ClipBridge] $message');
    return true;
  }());
}
