import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import '../platform/platform_interface.dart';

/// 平台实现 — Windows 端
class WindowsPlatform implements PlatformInterface {
  @override
  Future<List<NetworkInterfaceInfo>> getNetworkInterfaces() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );

    return interfaces.map((iface) {
      String type = 'other';
      if (iface.name.toLowerCase().contains('wi-fi') ||
          iface.name.toLowerCase().contains('wlan')) {
        type = 'wifi';
      } else if (iface.name.toLowerCase().contains('eth')) {
        type = 'ethernet';
      }

      return NetworkInterfaceInfo(
        name: iface.name,
        ip: iface.addresses.isNotEmpty
            ? iface.addresses.first.address
            : '0.0.0.0',
        type: type,
      );
    }).toList();
  }

  @override
  Future<void> startForegroundService(Map<String, dynamic> config) async {
    // Windows: system tray handled by UI layer via AppBar/system tray icons
  }

  @override
  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    double? progress,
  }) async {
    // Windows: use a toast-style notification where possible
    // For now, progress is tracked via the in-app UI
  }

  @override
  Future<List<String>> getSharedFiles() async => [];

  @override
  Future<void> registerDropTarget(int windowId) async {
    // Drag-and-drop handled by desktop_drop package directly in the UI layer
  }

  @override
  Future<void> copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  @override
  Future<String?> getClipboardText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  }

  @override
  Future<void> openFileLocation(String path) async {
    if (File(path).existsSync() || Directory(path).existsSync()) {
      await Process.run('explorer', ['/select,', path]);
    } else {
      final dir = path.contains('\\') || path.contains('/')
          ? path.substring(0, path.lastIndexOf(RegExp(r'[\\/]')))
          : path;
      if (Directory(dir).existsSync()) {
        await Process.run('explorer', [dir]);
      }
    }
  }

  @override
  Future<int?> getBatteryLevel() async {
    try {
      // Try Win32_Battery via wmic first
      final result = await Process.run('wmic', [
        'path', 'Win32_Battery', 'get', 'EstimatedChargeRemaining',
        '/format:value',
      ]);
      final output = result.stdout.toString();
      final match =
          RegExp(r'EstimatedChargeRemaining[=\s]*(\d+)').firstMatch(output);
      if (match != null) {
        final level = int.tryParse(match.group(1)!);
        if (level != null && level >= 0 && level <= 100) return level;
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<String?> getThermalState() async {
    // Windows does not expose thermal state through a standard API without WinRT
    return null;
  }

  @override
  Future<int> getStorageInfo(String path) async {
    try {
      final drive = path.isEmpty ? 'C' : path[0].toUpperCase();
      final result = await Process.run('cmd', [
        '/c',
        'wmic logicaldisk where "DeviceID=\'$drive:\'" get FreeSpace /value',
      ]);
      final output = result.stdout.toString();
      final match = RegExp(r'FreeSpace=(\d+)').firstMatch(output);
      if (match != null) {
        return int.parse(match.group(1)!);
      }
    } catch (_) {}
    return 0;
  }
}
