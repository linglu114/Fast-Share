import '../platform/platform_interface.dart';

/// 网卡管理器 (需求 §6)
///
/// 多网卡智能选择 + 手动指定
class NetworkManager {
  List<NetworkInterfaceInfo> _interfaces = [];
  String? _manualIp;
  String? _selectedIp;

  /// 刷新网卡列表
  Future<void> refresh(PlatformInterface platform) async {
    _interfaces = await platform.getNetworkInterfaces();
  }

  /// 接口列表
  List<NetworkInterfaceInfo> get interfaces => List.unmodifiable(_interfaces);

  /// 当前选中的 IP
  String? get selectedIp => _manualIp ?? _selectedIp;

  /// 手动指定 IP
  void setManualIp(String? ip) {
    _manualIp = ip;
  }

  /// 智能选择最佳网卡 — 优先 WiFi，其次 Ethernet
  Future<String?> selectBest() async {
    if (_interfaces.isEmpty) return null;

    final wifi = _interfaces.where((i) => i.type == 'wifi').firstOrNull;
    final eth = _interfaces.where((i) => i.type == 'ethernet').firstOrNull;

    _selectedIp = wifi?.ip ?? eth?.ip ?? _interfaces.first.ip;
    return _selectedIp;
  }

  /// 自动匹配网段 — 找到和目标 IP 同网段的接口
  Future<String?> matchSubnet(String targetIp) async {
    for (final iface in _interfaces) {
      if (_sameSubnet(iface.ip, targetIp)) {
        _selectedIp = iface.ip;
        return iface.ip;
      }
    }
    return null;
  }

  /// 判断两个 IP 是否在同一 /24 子网
  bool _sameSubnet(String ip1, String ip2) {
    try {
      final parts1 = ip1.split('.');
      final parts2 = ip2.split('.');
      if (parts1.length != 4 || parts2.length != 4) return false;
      for (var i = 0; i < 3; i++) {
        if (parts1[i] != parts2[i]) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
