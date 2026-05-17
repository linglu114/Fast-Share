import 'dart:io';
import 'package:flutter/services.dart';
import '../platform/platform_interface.dart';

/// 平台实现 — Android 端
class AndroidPlatform implements PlatformInterface {
  static const _channel = MethodChannel('com.fastshare/platform');

  @override
  Future<List<NetworkInterfaceInfo>> getNetworkInterfaces() async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );

    return interfaces.map((iface) {
      String type = 'other';
      if (iface.name.toLowerCase().contains('wlan')) {
        type = 'wifi';
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
    try {
      await _channel.invokeMethod('startForegroundService', config);
    } on MissingPluginException {}
  }

  @override
  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    double? progress,
  }) async {
    try {
      await _channel.invokeMethod('showNotification', {
        'id': id,
        'title': title,
        'body': body,
        'progress': progress,
      });
    } on MissingPluginException {}
  }

  @override
  Future<List<String>> getSharedFiles() async {
    try {
      final result = await _channel.invokeMethod('getSharedFiles');
      if (result is List) return result.cast<String>();
    } on MissingPluginException {}
    return [];
  }

  @override
  Future<void> registerDropTarget(int windowId) async {}

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
    try {
      await _channel.invokeMethod('openFileLocation', {'path': path});
    } on MissingPluginException {}
  }

  @override
  Future<int?> getBatteryLevel() async {
    try {
      final level = await _channel.invokeMethod('getBatteryLevel');
      if (level is int) return level;
    } on MissingPluginException {}
    return null;
  }

  @override
  Future<String?> getThermalState() async {
    try {
      final state = await _channel.invokeMethod('getThermalState');
      if (state is String) return state;
    } on MissingPluginException {}
    return null;
  }

  @override
  Future<int> getStorageInfo(String path) async {
    try {
      final free = await _channel.invokeMethod('getFreeSpace', {'path': path});
      if (free is int) return free;
    } on MissingPluginException {}
    return 0;
  }
}
