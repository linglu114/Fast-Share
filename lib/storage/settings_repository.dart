import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

/// 应用设置存储
class SettingsRepository {
  static const _keyDeviceName = 'device_name';
  static const _keyDeviceId = 'device_id';
  static const _keyDarkMode = 'dark_mode';
  static const _keySpeedLimit = 'speed_limit';
  static const _keyConcurrentCount = 'concurrent_count';
  static const _keyRetryCount = 'retry_count';
  static const _keyAutoAccept = 'auto_accept_default';
  static const _keyAggregateEnabled = 'aggregate_enabled';
  static const _keyLowBatteryThreshold = 'low_battery_threshold';
  static const _keyCriticalBatteryThreshold = 'critical_battery_threshold';
  static const _keyThermalProtection = 'thermal_protection';
  static const _keyServerPort = 'server_port';
  static const _keySelectedNetworkIp = 'selected_network_ip';
  static const _keyDownloadPath = 'download_path';

  final SharedPreferences _prefs;

  SettingsRepository(this._prefs);

  // 设备名称
  String get deviceName => _prefs.getString(_keyDeviceName) ?? 'My Device';
  Future<bool> setDeviceName(String name) =>
      _prefs.setString(_keyDeviceName, name);

  // 设备 ID
  String? get deviceId => _prefs.getString(_keyDeviceId);
  Future<bool> setDeviceId(String id) =>
      _prefs.setString(_keyDeviceId, id);

  // 深色模式: null=跟随系统, true=深色, false=浅色
  bool? get darkMode => _prefs.getBool(_keyDarkMode);
  Future<bool> setDarkMode(bool? value) =>
      value == null ? _prefs.remove(_keyDarkMode) : _prefs.setBool(_keyDarkMode, value);

  // 限速 (bytes/s)，0 表示不限制
  int get speedLimit => _prefs.getInt(_keySpeedLimit) ?? 0;
  Future<bool> setSpeedLimit(int limit) =>
      _prefs.setInt(_keySpeedLimit, limit);

  // 并发数，0 表示自动
  int get concurrentCount => _prefs.getInt(_keyConcurrentCount) ?? 0;
  Future<bool> setConcurrentCount(int count) =>
      _prefs.setInt(_keyConcurrentCount, count);

  // 重试次数 (0~5)
  int get retryCount => _prefs.getInt(_keyRetryCount) ?? 3;
  Future<bool> setRetryCount(int count) =>
      _prefs.setInt(_keyRetryCount, count);

  // 自动接受开关
  bool get autoAccept => _prefs.getBool(_keyAutoAccept) ?? false;
  Future<bool> setAutoAccept(bool value) =>
      _prefs.setBool(_keyAutoAccept, value);

  // 聚合发送开关
  bool get aggregateEnabled => _prefs.getBool(_keyAggregateEnabled) ?? true;
  Future<bool> setAggregateEnabled(bool value) =>
      _prefs.setBool(_keyAggregateEnabled, value);

  // 低电量阈值 (百分比, 默认 20)
  int get lowBatteryThreshold => _prefs.getInt(_keyLowBatteryThreshold) ?? 20;
  Future<bool> setLowBatteryThreshold(int value) =>
      _prefs.setInt(_keyLowBatteryThreshold, value);

  // 极低电量阈值 (百分比, 默认 5)
  int get criticalBatteryThreshold =>
      _prefs.getInt(_keyCriticalBatteryThreshold) ?? 5;
  Future<bool> setCriticalBatteryThreshold(int value) =>
      _prefs.setInt(_keyCriticalBatteryThreshold, value);

  // 温度保护开关
  bool get thermalProtection => _prefs.getBool(_keyThermalProtection) ?? false;
  Future<bool> setThermalProtection(bool value) =>
      _prefs.setBool(_keyThermalProtection, value);

  // 服务端口
  int get serverPort => _prefs.getInt(_keyServerPort) ?? 45678;
  Future<bool> setServerPort(int port) =>
      _prefs.setInt(_keyServerPort, port);

  // 手动选择的网卡 IP（null = 自动检测）
  String? get selectedNetworkIp => _prefs.getString(_keySelectedNetworkIp);
  Future<bool> setSelectedNetworkIp(String? ip) =>
      ip == null ? _prefs.remove(_keySelectedNetworkIp) : _prefs.setString(_keySelectedNetworkIp, ip);

  // 文件下载保存路径
  static String get defaultDownloadPath {
    if (Platform.isWindows) {
      return _getWindowsDownloadsPath();
    }
    if (Platform.isAndroid) {
      return '/storage/emulated/0/Download';
    }
    if (Platform.isMacOS || Platform.isLinux) {
      final home = Platform.environment['HOME'] ?? '/tmp';
      return '$home/Downloads';
    }
    return '.';
  }

  /// Read the real Downloads folder path from Windows registry.
  ///
  /// The user may have relocated the Downloads folder via
  /// Properties → Location, which updates:
  ///   HKCU\...\User Shell Folders\{374DE290-123F-4565-9164-39C4925E467B}
  static String _getWindowsDownloadsPath() {
    try {
      final result = Process.runSync('reg', [
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders',
        '/v',
        '{374DE290-123F-4565-9164-39C4925E467B}',
      ]);
      if (result.exitCode == 0) {
        final match = RegExp(r'REG_EXPAND_SZ\s+(.+)')
            .firstMatch(result.stdout.toString());
        if (match != null) {
          final path = _expandEnvVars(match.group(1)!.trim());
          if (path.isNotEmpty) return path;
        }
      }
    } catch (_) {}
    // Fallback: try REG_SZ variant, then default location
    final home = Platform.environment['USERPROFILE'] ?? r'C:\Users\Public';
    return '$home\\Downloads';
  }

  /// Expand %VAR% style environment variables within a path string.
  static String _expandEnvVars(String path) {
    return path.replaceAllMapped(RegExp(r'%([^%]+)%'), (m) {
      return Platform.environment[m.group(1)!] ?? m.group(0)!;
    });
  }

  String get downloadPath =>
      _prefs.getString(_keyDownloadPath) ?? defaultDownloadPath;
  Future<bool> setDownloadPath(String path) =>
      _prefs.setString(_keyDownloadPath, path);
}
