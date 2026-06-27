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

  /// 判断两个 IP 是否在同一 RFC 1918 子网
  bool _sameSubnet(String ip1, String ip2) {
    try {
      final parts1 = ip1.split('.');
      final parts2 = ip2.split('.');
      if (parts1.length != 4 || parts2.length != 4) return false;
      final a1 = int.parse(parts1[0]), a2 = int.parse(parts2[0]);
      final b1 = int.parse(parts1[1]), b2 = int.parse(parts2[1]);

      // 10.0.0.0/8
      if (a1 == 10 && a2 == 10) return true;
      // 172.16.0.0/12
      if (a1 == 172 && a2 == 172 && b1 >= 16 && b1 <= 31 && b2 >= 16 && b2 <= 31) return true;
      // 192.168.0.0/16
      if (a1 == 192 && a2 == 192 && b1 == 168 && b2 == 168) return true;

      return false;
    } catch (_) {
      return false;
    }
  }
}
