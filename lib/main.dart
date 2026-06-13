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
import 'platform/platform_android.dart';
import 'platform/platform_windows.dart';
import 'util/logger.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Android: 首次启动时就申请存储权限，确保下载目录可写
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

/// Android 存储权限 — 按 API 级别精确适配，避免过度授权触发系统警告
///
/// API < 29 (Android 9-): 仍需 READ/WRITE_EXTERNAL_STORAGE
/// API 29-32 (Android 10-12): 分区存储已生效，写入 Download 目录无需权限
/// API 33+ (Android 13+): 使用 READ_MEDIA_* 细粒度权限
Future<void> _requestStoragePermissions() async {
  final sdkInt = _parseAndroidSdkInt();

  if (sdkInt < 29) {
    // Android 9 及以下：传统存储权限
    final status = await Permission.storage.status;
    if (!status.isGranted) {
      await Permission.storage.request();
    }
  } else if (sdkInt >= 33) {
    // Android 13+：无需在启动时申请存储权限，file_picker 自行处理读权限，
    // 写入 Download 目录由分区存储机制保证无需额外权限
  }
  // API 29-32：分区存储下写入 Download 目录已无需权限，无需请求
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
