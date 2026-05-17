import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'storage/database.dart';
import 'storage/settings_repository.dart';
import 'providers/settings_provider.dart';
import 'util/logger.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  Logger.init();

  // 初始化 SharedPreferences
  final prefs = await SharedPreferences.getInstance();
  final settingsRepo = SettingsRepository(prefs);

  // 生成并持久化设备 ID（首次启动）
  if (settingsRepo.deviceId == null) {
    await settingsRepo.setDeviceId(const Uuid().v4());
  }

  // 读取本机主机名作为默认设备名
  try {
    final hostname = Platform.localHostname;
    if (hostname.isNotEmpty && hostname != 'localhost') {
      // 只在首次启动时设置（deviceName 为默认值 "My Device" 说明未修改过）
      if (settingsRepo.deviceName == 'My Device') {
        await settingsRepo.setDeviceName(hostname);
      }
    }
  } catch (_) {}

  // 初始化数据库
  await AppDatabase.database;

  runApp(
    ProviderScope(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(settingsRepo),
      ],
      child: const FastShareApp(),
    ),
  );
}
