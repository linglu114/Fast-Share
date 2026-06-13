import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../platform/platform_interface.dart';
import '../platform/platform_android.dart';
import '../platform/platform_windows.dart';

/// 平台实现 Provider — 在 ProviderScope.overrides 中覆盖。
///
/// ```dart
/// ProviderScope(
///   overrides: [
///     platformProvider.overrideWithValue(
///       Platform.isAndroid ? AndroidPlatform() : WindowsPlatform(),
///     ),
///   ],
/// )
/// ```
final platformProvider = Provider<PlatformInterface>((ref) {
  throw UnimplementedError('必须在 ProviderScope 中覆盖 platformProvider');
});
