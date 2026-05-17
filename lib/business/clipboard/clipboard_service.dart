import 'dart:async';
import 'package:flutter/services.dart';

/// 剪贴板共享服务 (需求 §30)
///
/// 通过现有 TCP 连接推送文本，接收端写入系统剪贴板。
class ClipboardService {
  final _controller = StreamController<String>.broadcast();
  Stream<String> get onTextReceived => _controller.stream;

  /// 复制到系统剪贴板
  Future<void> copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  /// 推送文本到接收端（由 ConnectionManager 处理网络发送）
  void pushText(String text) {
    // 由上层调用 ConnectionManager.send()
  }

  /// 通知有新文本（由 ConnectionManager 收到 CLIPBOARD_PUSH 时调用）
  void onReceiveText(String text) {
    _controller.add(text);
    copyToClipboard(text);
  }

  /// 获取系统剪贴板内容
  Future<String?> getClipboardText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  void dispose() {
    _controller.close();
  }
}
