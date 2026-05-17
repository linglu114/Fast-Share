import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../../models/device.dart';

/// 设备发现服务 (MVP: UDP 广播)
///
/// - 定时发送 UDP 广播宣告本机在线
/// - 监听 UDP 广播发现局域网设备
/// - 绑定到具体网卡 IP（而非 anyIPv4）确保 Windows 广播从正确接口发出
class DiscoveryService {
  static const int _discoveryPort = 45679;

  final _devicesController = StreamController<List<Device>>.broadcast();
  final _deviceUpController = StreamController<Device>.broadcast();
  final _deviceDownController = StreamController<String>.broadcast();

  final Map<String, Device> _devices = {};
  final Map<String, Timer> _offlineTimers = {};

  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  bool _started = false;

  /// 广播目标地址列表（255.255.255.255 + 各子网定向广播）
  List<String> _broadcastAddresses = ['255.255.255.255'];

  final String localDeviceId;
  final String localDeviceName;
  final int localPort;
  final int protocolVersion;
  final String platform;

  Stream<List<Device>> get devices => _devicesController.stream;
  Stream<Device> get onDeviceUp => _deviceUpController.stream;
  Stream<String> get onDeviceDown => _deviceDownController.stream;
  Map<String, Device> get currentDevices => Map.unmodifiable(_devices);

  DiscoveryService({
    required this.localDeviceId,
    required this.localDeviceName,
    required this.localPort,
    required this.protocolVersion,
    required this.platform,
  });

  /// 启动发现服务。bindAddress 指定绑定的网卡 IP，为 null 则绑定 anyIPv4。
  Future<void> start({String? bindAddress}) async {
    if (_started) return;
    _started = true;

    await _bind(bindAddress);
    if (_socket == null) {
      _started = false;
      return;
    }

    _socket!.listen(_onData);
    // Burst broadcasts for fast initial discovery
    _broadcast();
    Future.delayed(const Duration(milliseconds: 500), _broadcast);
    Future.delayed(const Duration(seconds: 1), _broadcast);

    _broadcastTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _broadcast());
    _cleanupTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => _cleanupOffline());
  }

  Future<void> _bind(String? bindAddress) async {
    try {
      final addr = bindAddress != null && bindAddress.isNotEmpty
          ? InternetAddress(bindAddress)
          : InternetAddress.anyIPv4;
      _socket = await RawDatagramSocket.bind(addr, _discoveryPort,
          reuseAddress: true);
      _socket!.broadcastEnabled = true;
    } catch (_) {
      _socket = null;
    }
  }

  /// 切换到新的网卡绑定（用于手动切换 IP）
  Future<void> rebind(String bindAddress) async {
    _broadcastTimer?.cancel();
    _cleanupTimer?.cancel();
    _socket?.close();
    _socket = null;

    await _bind(bindAddress);
    if (_socket == null) return;

    _socket!.listen(_onData);
    _broadcast();
    Future.delayed(const Duration(milliseconds: 500), _broadcast);
    Future.delayed(const Duration(seconds: 1), _broadcast);

    _broadcastTimer =
        Timer.periodic(const Duration(seconds: 5), (_) => _broadcast());
    _cleanupTimer =
        Timer.periodic(const Duration(seconds: 10), (_) => _cleanupOffline());
  }

  void _onData(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;

    final datagram = _socket!.receive();
    if (datagram == null) return;

    try {
      final json = utf8.decode(datagram.data);
      final data = jsonDecode(json) as Map<String, dynamic>;

      final type = data['type'] as String?;
      if (type != 'fastshare_hello') return;

      final deviceId = data['deviceId'] as String? ?? '';
      if (deviceId.isEmpty || deviceId == localDeviceId) return;

      final port = data['port'] as int? ?? localPort;
      final ver = data['ver'] as int? ?? 1;
      final name = data['name'] as String? ?? 'Unknown';
      final plat = data['platform'] as String? ?? 'unknown';

      // 使用实际的发送方 IP 而不是广播地址
      final deviceIp = datagram.address.address;

      final device = Device(
        deviceId: deviceId,
        name: name,
        platform: plat,
        ip: deviceIp,
        port: port,
        protocolVersion: ver,
        lastSeen: DateTime.now(),
      );

      final isNew = !_devices.containsKey(deviceId);
      _devices[deviceId] = device;

      // 重置离线计时器 (3 个心跳周期 = 15s)
      _offlineTimers[deviceId]?.cancel();
      _offlineTimers[deviceId] = Timer(const Duration(seconds: 15), () {
        _devices.remove(deviceId);
        _offlineTimers.remove(deviceId);
        _deviceDownController.add(deviceId);
        _devicesController.add(_devices.values.toList());
      });

      if (isNew) {
        _deviceUpController.add(device);
      }

      _devicesController.add(_devices.values.toList());
    } catch (_) {
      // 解析失败静默处理
    }
  }

  /// 立即发送一次广播宣告（供外部刷新调用）
  void broadcastNow() {
    _broadcast();
  }

  /// 根据检测到的本机 IP 列表更新广播目标地址
  void updateBroadcastAddresses(List<String> localIps) {
    final addrs = <String>['255.255.255.255'];
    for (final ip in localIps) {
      final ba = _subnetBroadcast(ip);
      if (ba != null && ba != '255.255.255.255') {
        addrs.add(ba);
      }
    }
    _broadcastAddresses = addrs;
  }

  /// 根据 IP 计算子网广播地址（假设 /24）
  static String? _subnetBroadcast(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return null;
    final third = int.tryParse(parts[2]);
    if (third == null) return null;

    if (ip.startsWith('192.168.') || ip.startsWith('10.')) {
      return '${parts[0]}.${parts[1]}.$third.255';
    }
    if (ip.startsWith('172.')) {
      final second = int.tryParse(parts[1]) ?? 0;
      if (second >= 16 && second <= 31) {
        return '${parts[0]}.${parts[1]}.$third.255';
      }
    }
    return null;
  }

  void _broadcast() {
    if (_socket == null) return;

    final message = jsonEncode({
      'type': 'fastshare_hello',
      'deviceId': localDeviceId,
      'name': localDeviceName,
      'port': localPort,
      'ver': protocolVersion,
      'platform': platform,
    });

    final data = utf8.encode(message);
    for (final addr in _broadcastAddresses) {
      try {
        _socket!.send(
          data,
          InternetAddress(addr),
          _discoveryPort,
        );
      } catch (_) {
        // 单个地址广播失败，继续尝试下一个
      }
    }
  }

  void _cleanupOffline() {
    final now = DateTime.now();
    final offlineIds = <String>[];

    for (final entry in _devices.entries) {
      if (now.difference(entry.value.lastSeen).inSeconds > 15) {
        offlineIds.add(entry.key);
      }
    }

    for (final id in offlineIds) {
      _devices.remove(id);
      _offlineTimers[id]?.cancel();
      _offlineTimers.remove(id);
      _deviceDownController.add(id);
    }

    if (offlineIds.isNotEmpty) {
      _devicesController.add(_devices.values.toList());
    }
  }

  /// 停止发现服务
  Future<void> stop() async {
    _broadcastTimer?.cancel();
    _cleanupTimer?.cancel();
    _started = false;
    _devices.clear();
    for (final t in _offlineTimers.values) {
      t.cancel();
    }
    _offlineTimers.clear();
    _socket?.close();
    _socket = null;
  }

  /// 关闭所有流
  void dispose() {
    _devicesController.close();
    _deviceUpController.close();
    _deviceDownController.close();
  }
}
