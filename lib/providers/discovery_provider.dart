import 'dart:async';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/device.dart';
import '../business/discovery/discovery_service.dart';
import '../util/logger.dart';
import 'settings_provider.dart';

/// 在线设备列表
final onlineDevicesProvider =
    NotifierProvider<DiscoveryNotifier, List<Device>>(DiscoveryNotifier.new);

/// 设备上线事件流
final deviceUpProvider = StreamProvider<Device>((ref) {
  return ref.watch(onlineDevicesProvider.notifier).deviceUpStream;
});

/// 设备下线事件流
final deviceDownProvider = StreamProvider<String>((ref) {
  return ref.watch(onlineDevicesProvider.notifier).deviceDownStream;
});

class DiscoveryNotifier extends Notifier<List<Device>> {
  DiscoveryService? _service;
  StreamSubscription<List<Device>>? _deviceSub;
  StreamSubscription<Device>? _upSub;
  StreamSubscription<String>? _downSub;

  final _deviceUpController = StreamController<Device>.broadcast();
  final _deviceDownController = StreamController<String>.broadcast();

  /// 自动检测到的所有局域网 IPv4 地址
  final List<String> _allLocalIps = [];

  /// 按优先级排序的局域网 IP 列表（只读）
  List<String> get allDetectedIps => List.unmodifiable(_allLocalIps);

  /// 当前生效的局域网 IP（手动选择优先，否则自动检测最优）
  String? get localIp {
    final manual = ref.read(selectedNetworkIpProvider);
    if (manual != null && manual.isNotEmpty) return manual;
    return _allLocalIps.isNotEmpty ? _allLocalIps.first : null;
  }

  Stream<Device> get deviceUpStream => _deviceUpController.stream;
  Stream<String> get deviceDownStream => _deviceDownController.stream;

  @override
  List<Device> build() {
    // 异步启动：先解析 IP，再绑定到正确网卡启动服务
    _startDiscovery();
    ref.onDispose(_onDispose);
    return [];
  }

  void _startDiscovery() {
    // 防止 build() 多次调用导致多个 UDP socket 并存、互相抢包
    if (_service != null) return;

    final settings = ref.read(settingsRepositoryProvider);
    final localDevice = ref.read(localDeviceProvider);

    Logger.log('[DISCOVERY] Creating service: deviceId=${localDevice.deviceId} port=${settings.serverPort}');

    _service = DiscoveryService(
      localDeviceId: localDevice.deviceId,
      localDeviceName: localDevice.name,
      localPort: settings.serverPort,
      protocolVersion: 1,
      platform: 'flutter',
    );

    _deviceSub = _service!.devices.listen((devices) {
      state = devices;
    });

    _upSub = _service!.onDeviceUp.listen((device) {
      _deviceUpController.add(device);
    });

    _downSub = _service!.onDeviceDown.listen((deviceId) {
      _deviceDownController.add(deviceId);
    });

    // 先解析 IP，再用最佳 IP 绑定启动
    Future(() async {
      await _resolveLocalIp();
      final bindAddr = localIp;
      Logger.log('[DISCOVERY] Resolved IPs: $_allLocalIps, bindAddr=$bindAddr');
      await _service!.start(bindAddress: bindAddr);
      if (bindAddr != null) {
        _service!.updateBroadcastAddresses(_allLocalIps);
      }
    });
  }

  /// 智能网卡判断：按局域网优先级排序
  /// 优先级：192.168.x.x > 10.x.x.x > 172.16~31.x.x > 其他
  Future<void> _resolveLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );

      final scored = <_ScoredAddress>[];

      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip == '127.0.0.1') continue;
          scored.add(_ScoredAddress(ip, _scoreAddress(ip), iface.name));
        }
      }

      scored.sort((a, b) => b.score.compareTo(a.score));

      _allLocalIps.clear();
      _allLocalIps.addAll(scored.map((s) => s.ip));

      // 更新广播目标地址
      _service?.updateBroadcastAddresses(_allLocalIps);

      // 触发重建
      final manual = ref.read(selectedNetworkIpProvider);
      if (manual == null || manual.isEmpty) {
        state = [...state];
      }
    } catch (e) {
      Logger.log('[DISCOVERY] _resolveLocalIp failed: $e');
    }
  }

  /// 为 IP 地址打分，局域网地址得分更高
  static int _scoreAddress(String addr) {
    if (addr.startsWith('192.168.')) return 100;
    if (addr.startsWith('10.')) return 90;
    if (addr.startsWith('172.')) {
      final parts = addr.split('.');
      if (parts.length >= 2) {
        final second = int.tryParse(parts[1]) ?? 0;
        if (second >= 16 && second <= 31) return 80;
      }
    }
    // 169.254.x.x (APIPA) — 低优先级
    if (addr.startsWith('169.254.')) return 10;
    return 50;
  }

  /// 手动选择网卡 IP。传 null 恢复自动检测。
  Future<void> selectLocalIp(String? ip) async {
    await ref.read(selectedNetworkIpProvider.notifier).update(ip);
    final effectiveIp = localIp;
    if (effectiveIp != null && _service != null) {
      await _service!.rebind(effectiveIp);
      _service!.updateBroadcastAddresses(_allLocalIps);
    }
    state = [...state];
  }

  /// 立即刷新设备发现：重新解析 IP + 立即广播
  Future<void> refreshNow() async {
    await _resolveLocalIp();
    _service?.broadcastNow();
  }

  void _onDispose() {
    _deviceSub?.cancel();
    _upSub?.cancel();
    _downSub?.cancel();
    _service?.stop();
    _service?.dispose();
    _service = null;
    _deviceUpController.close();
    _deviceDownController.close();
  }
}

/// 用于排序的 IP + 分数 + 网卡名
class _ScoredAddress {
  final String ip;
  final int score;
  final String interfaceName;
  const _ScoredAddress(this.ip, this.score, this.interfaceName);
}
