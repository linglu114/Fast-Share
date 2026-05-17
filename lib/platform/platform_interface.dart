/// 平台抽象接口 (架构设计 v2.0 §2.7)
///
/// 定义所有需要平台实现的能力，各平台通过 MethodChannel 实现。
abstract class PlatformInterface {
  /// 获取网络接口列表
  Future<List<NetworkInterfaceInfo>> getNetworkInterfaces();

  /// 启动前台服务 / 系统托盘
  Future<void> startForegroundService(Map<String, dynamic> config);

  /// 显示通知
  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    double? progress,
  });

  /// 获取系统分享的文件 (Android Intent)
  Future<List<String>> getSharedFiles();

  /// 注册 Windows 拖拽目标
  Future<void> registerDropTarget(int windowId);

  /// 写入剪贴板
  Future<void> copyToClipboard(String text);

  /// 读取剪贴板
  Future<String?> getClipboardText();

  /// 打开文件所在位置
  Future<void> openFileLocation(String path);

  /// 获取电量百分比 (Android)
  Future<int?> getBatteryLevel();

  /// 获取热状态 (Android)
  Future<String?> getThermalState();

  /// 获取磁盘剩余空间
  Future<int> getStorageInfo(String path);
}

/// 网络接口信息
class NetworkInterfaceInfo {
  final String name;
  final String ip;
  final String type; // wifi, ethernet, other

  const NetworkInterfaceInfo({
    required this.name,
    required this.ip,
    required this.type,
  });
}
