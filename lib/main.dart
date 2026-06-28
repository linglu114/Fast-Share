import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'storage/database.dart';
import 'storage/settings_repository.dart';
import 'providers/settings_provider.dart';
import 'providers/platform_provider.dart';
import 'providers/transfer_provider.dart';
import 'platform/platform_android.dart';
import 'platform/platform_windows.dart';
import 'util/logger.dart';
import 'app.dart';

/// 来自系统分享的待处理文件 — 非 null 时 UI 应弹出设备选择器
final pendingShareFilesProvider = StateProvider<List<Map<String, dynamic>>?>((ref) => null);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Android: 传统存储权限 + 通知权限
  // MANAGE_EXTERNAL_STORAGE 的引导对话框由 app.dart 在首帧后处理
  if (Platform.isAndroid) {
    await _requestStoragePermissions();
    await _requestNotificationPermission();
  }

  // 获取可写目录初始化日志：移动端用临时目录，桌面端用系统 TEMP
  String? logDir;
  try {
    logDir = (await getTemporaryDirectory()).path;
  } catch (_) {}
  Logger.init(dirPath: logDir);

  // 初始化 SharedPreferences
  final prefs = await SharedPreferences.getInstance();
  final settingsRepo = SettingsRepository(prefs);

  // 迁移旧的默认端口 45678 → 34568
  if (settingsRepo.serverPort == 45678) {
    await settingsRepo.setServerPort(34568);
  }

  // 生成并持久化设备 ID（首次启动）
  if (settingsRepo.deviceId == null) {
    await settingsRepo.setDeviceId(const Uuid().v4());
  }

  // 读取设备名：Android 用 Build.MODEL，其他平台用 hostname
  try {
    final deviceName = await _getDeviceName();
    if (deviceName != null) {
      if (settingsRepo.deviceName == 'My Device') {
        await settingsRepo.setDeviceName(deviceName);
      }
    }
  } catch (_) {}

  // 初始化数据库
  await AppDatabase.database;

  runApp(
    ProviderScope(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(settingsRepo),
        platformProvider.overrideWithValue(
          Platform.isAndroid ? AndroidPlatform() : WindowsPlatform(),
        ),
      ],
      child: const FastShareApp(),
    ),
  );
}

/// 读取设备名：Android 通过 MethodChannel 读取 Build.MODEL，
/// 其他平台用 Platform.localHostname。
Future<String?> _getDeviceName() async {
  if (Platform.isAndroid) {
    try {
      const channel = MethodChannel('fastshare/device_info');
      final model = await channel.invokeMethod<String>('getDeviceModel');
      if (model != null && model.isNotEmpty) {
        return model;
      }
    } catch (_) {}
  }
  try {
    final hostname = Platform.localHostname;
    if (hostname.isNotEmpty && hostname != 'localhost') {
      return hostname;
    }
  } catch (_) {}
  return null;
}

/// 传统存储权限（仅 Android 9 及以下需要）
/// Android 11+ 的 MANAGE_EXTERNAL_STORAGE 引导对话框由 app.dart 处理
Future<void> _requestStoragePermissions() async {
  final sdkInt = _parseAndroidSdkInt();
  if (sdkInt < 29) {
    final status = await Permission.storage.status;
    if (!status.isGranted) {
      await Permission.storage.request();
    }
  }
}

/// Android 13+ 通知权限（前台服务必需）
Future<void> _requestNotificationPermission() async {
  final sdkInt = _parseAndroidSdkInt();
  if (sdkInt >= 33) {
    final status = await Permission.notification.status;
    if (!status.isGranted) {
      await Permission.notification.request();
    }
  }
}

int _parseAndroidSdkInt() {
  try {
    final versionStr = Platform.operatingSystemVersion;
    // e.g. "Android 10 (API 29)" or "Android 13 (API 33)"
    final match = RegExp(r'API\s*(\d+)').firstMatch(versionStr);
    if (match != null) {
      return int.parse(match.group(1)!);
    }
  } catch (_) {}
  return 29;
}
