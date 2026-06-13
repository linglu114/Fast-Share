import 'dart:io';
import 'package:flutter/services.dart';

/// Content URI 操作 — Android 端通过 MethodChannel 调用原生 ContentUriHelper
class ContentUriReader {
  static const _channel = MethodChannel('fastshare/content_uri');

  static bool get isSupported => Platform.isAndroid;

  /// 打开系统文件选择器，返回 content:// URI 列表（无文件拷贝）
  /// 每个条目包含 uri, name, size, realPath 字段。
  static Future<List<Map<String, dynamic>>> pickFiles() async {
    if (!isSupported) return [];
    try {
      final result = await _channel.invokeMethod('pickFiles');
      if (result is List) {
        return result.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      }
    } on MissingPluginException {
      // plugin not registered on this platform
    }
    return [];
  }

  /// 打开 content URI 获取文件描述符编号，用于 Engine Isolate 直读。
  /// 返回 -1 表示失败（此时回退到 readChunk 路径）。
  static Future<int> openContentFd(String uri) async {
    if (!isSupported) return -1;
    try {
      final fd = await _channel.invokeMethod('openContentFd', {'uri': uri});
      if (fd is int) return fd;
    } catch (_) {}
    return -1;
  }

  /// 从 content:// URI 读取指定偏移和长度的数据。
  /// 原生端使用持久 FileChannel + O(1) lseek，无 O(n²) skip 开销。
  static Future<Uint8List?> readChunk(
      String uri, int offset, int length) async {
    if (!isSupported) return null;
    try {
      final data = await _channel.invokeMethod('readChunk', {
        'uri': uri,
        'offset': offset,
        'length': length,
      });
      if (data is Uint8List) return data;
    } catch (_) {}
    return null;
  }

  /// 关闭指定 content URI 的持久读取通道
  static Future<void> closeContentStream(String uri) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('closeContentStream', {'uri': uri});
    } catch (_) {}
  }

  /// 关闭所有持久读取通道
  static Future<void> closeAllContentStreams() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('closeAllContentStreams');
    } catch (_) {}
  }
}
