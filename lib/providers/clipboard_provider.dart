import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../engine/transfer_control.dart';
import '../business/clipboard/clipboard_service.dart';
import 'connection_provider.dart';

/// 剪贴板服务 Provider
final clipboardServiceProvider = Provider<ClipboardService>((ref) {
  final service = ClipboardService();
  ref.onDispose(service.dispose);
  return service;
});

/// 收到远程剪贴板推送时自动写入本地剪贴板
final clipboardAutoReceiveProvider = Provider<void>((ref) {
  final service = ref.read(clipboardServiceProvider);
  final connection = ref.read(connectionStateProvider.notifier);

  connection.clipboardStream.listen((push) {
    service.onReceiveText(push.text);
  });
});

/// 剪贴板 Notifier
final clipboardNotifierProvider =
    NotifierProvider<ClipboardNotifier, void>(ClipboardNotifier.new);

class ClipboardNotifier extends Notifier<void> {
  @override
  void build() {
    // 订阅在 clipboardAutoReceiveProvider 中处理
  }

  /// 推送文本到目标设备
  void pushText(String deviceId, String text) {
    final connection = ref.read(connectionStateProvider.notifier);
    final frame = TransferControlMessages.buildClipboardPush(text: text);
    connection.send(deviceId, frame);

    ref.read(clipboardServiceProvider).copyToClipboard(text);
  }

  /// 获取当前剪贴板内容
  Future<String?> getClipboardText() async {
    return ref.read(clipboardServiceProvider).getClipboardText();
  }
}
