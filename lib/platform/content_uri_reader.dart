import 'dart:io';
import 'package:flutter/services.dart';

/// Content URI 操作 — Android 端通过 MethodChannel 调用原生 ContentUriHelper
class ContentUriReader {
  static const _channel = MethodChannel('fastshare/content_uri');

  static bool get isSupported => Platform.isAndroid;

  /// 打开系统文件选择器，返回 content:// URI 列表（无文件拷贝）
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

  /// 从 content:// URI 读取指定偏移和长度的数据
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
    } on MissingPluginException {
      // plugin not registered on this platform
    }
    return null;
  }
}
