import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/device.dart';
import '../storage/settings_repository.dart';

/// 设置仓库 Provider（main.dart 中必须 override）
final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  throw UnimplementedError('必须在 runApp 前覆盖此 Provider');
});

// ═══════════════════════════════════════════════════════════
// 可写设置 Providers (Notifier 模式)
// ═══════════════════════════════════════════════════════════

/// 设备名称
final deviceNameProvider = NotifierProvider<DeviceNameNotifier, String>(
  DeviceNameNotifier.new,
);

class DeviceNameNotifier extends Notifier<String> {
  @override
  String build() => ref.watch(settingsRepositoryProvider).deviceName;

  Future<void> update(String name) async {
    await ref.read(settingsRepositoryProvider).setDeviceName(name);
    state = name;
  }
}

/// 深色模式 (null = 跟随系统)
final darkModeProvider = NotifierProvider<DarkModeNotifier, bool?>(
  DarkModeNotifier.new,
);

class DarkModeNotifier extends Notifier<bool?> {
  @override
  bool? build() => ref.watch(settingsRepositoryProvider).darkMode;

  Future<void> setDarkMode(bool? value) async {
    await ref.read(settingsRepositoryProvider).setDarkMode(value);
    state = value;
  }
}

/// 传输限速 (bytes/s, 0 = 不限制)
final speedLimitProvider = NotifierProvider<SpeedLimitNotifier, int>(
  SpeedLimitNotifier.new,
);

class SpeedLimitNotifier extends Notifier<int> {
  @override
  int build() => ref.watch(settingsRepositoryProvider).speedLimit;

  Future<void> update(int value) async {
    await ref.read(settingsRepositoryProvider).setSpeedLimit(value);
    state = value;
  }
}

/// 并发数 (0 = 自动)
final concurrentCountProvider = NotifierProvider<ConcurrentCountNotifier, int>(
  ConcurrentCountNotifier.new,
);

class ConcurrentCountNotifier extends Notifier<int> {
  @override
  int build() => ref.watch(settingsRepositoryProvider).concurrentCount;

  Future<void> update(int value) async {
    await ref.read(settingsRepositoryProvider).setConcurrentCount(value);
    state = value;
  }
}

/// 重试次数 (0-5)
final retryCountProvider = NotifierProvider<RetryCountNotifier, int>(
  RetryCountNotifier.new,
);

class RetryCountNotifier extends Notifier<int> {
  @override
  int build() => ref.watch(settingsRepositoryProvider).retryCount;

  Future<void> update(int value) async {
    await ref.read(settingsRepositoryProvider).setRetryCount(value);
    state = value;
  }
}

/// 服务端口
final serverPortProvider = NotifierProvider<ServerPortNotifier, int>(
  ServerPortNotifier.new,
);

class ServerPortNotifier extends Notifier<int> {
  @override
  int build() => ref.watch(settingsRepositoryProvider).serverPort;

  Future<void> update(int value) async {
    await ref.read(settingsRepositoryProvider).setServerPort(value);
    state = value;
  }
}

/// 自动接受白名单
final autoAcceptProvider = NotifierProvider<AutoAcceptNotifier, bool>(
  AutoAcceptNotifier.new,
);

class AutoAcceptNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(settingsRepositoryProvider).autoAccept;

  Future<void> update(bool value) async {
    await ref.read(settingsRepositoryProvider).setAutoAccept(value);
    state = value;
  }
}

/// 聚合发送
final aggregateEnabledProvider = NotifierProvider<AggregateEnabledNotifier, bool>(
  AggregateEnabledNotifier.new,
);

class AggregateEnabledNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(settingsRepositoryProvider).aggregateEnabled;

  Future<void> update(bool value) async {
    await ref.read(settingsRepositoryProvider).setAggregateEnabled(value);
    state = value;
  }
}

/// 低电量提醒阈值 (%)
final lowBatteryProvider = NotifierProvider<LowBatteryNotifier, int>(
  LowBatteryNotifier.new,
);

class LowBatteryNotifier extends Notifier<int> {
  @override
  int build() => ref.watch(settingsRepositoryProvider).lowBatteryThreshold;

  Future<void> update(int value) async {
    await ref.read(settingsRepositoryProvider).setLowBatteryThreshold(value);
    state = value;
  }
}

/// 极低电量阈值 (%)
final criticalBatteryProvider = NotifierProvider<CriticalBatteryNotifier, int>(
  CriticalBatteryNotifier.new,
);

class CriticalBatteryNotifier extends Notifier<int> {
  @override
  int build() => ref.watch(settingsRepositoryProvider).criticalBatteryThreshold;

  Future<void> update(int value) async {
    await ref.read(settingsRepositoryProvider).setCriticalBatteryThreshold(value);
    state = value;
  }
}

/// 温度保护开关
final thermalProtectionProvider =
    NotifierProvider<ThermalProtectionNotifier, bool>(
  ThermalProtectionNotifier.new,
);

class ThermalProtectionNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(settingsRepositoryProvider).thermalProtection;

  Future<void> update(bool value) async {
    await ref.read(settingsRepositoryProvider).setThermalProtection(value);
    state = value;
  }
}

/// 文件下载保存路径
final downloadPathProvider = NotifierProvider<DownloadPathNotifier, String>(
  DownloadPathNotifier.new,
);

class DownloadPathNotifier extends Notifier<String> {
  @override
  String build() => ref.watch(settingsRepositoryProvider).downloadPath;

  Future<void> update(String value) async {
    await ref.read(settingsRepositoryProvider).setDownloadPath(value);
    state = value;
  }
}

/// 手动选择的网卡 IP（null = 自动检测）
final selectedNetworkIpProvider = NotifierProvider<SelectedNetworkIpNotifier, String?>(
  SelectedNetworkIpNotifier.new,
);

class SelectedNetworkIpNotifier extends Notifier<String?> {
  @override
  String? build() => ref.watch(settingsRepositoryProvider).selectedNetworkIp;

  Future<void> update(String? ip) async {
    await ref.read(settingsRepositoryProvider).setSelectedNetworkIp(ip);
    state = ip;
  }
}

/// 本机设备信息
final localDeviceProvider = Provider<LocalDevice>((ref) {
  final settings = ref.watch(settingsRepositoryProvider);
  final name = ref.watch(deviceNameProvider);
  return LocalDevice(
    deviceId: settings.deviceId,
    name: name,
  );
});
