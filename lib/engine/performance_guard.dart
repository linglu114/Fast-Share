import 'dart:async';
import 'dart:io';
import 'dart:math';

/// 性能保护与优化模块 (需求 §18, §19, §4.2, §4.3)
///
/// - 磁盘 IO 保护：256KB 顺序写缓冲
/// - 内存保护：64MB 滑动窗口 + 流式读写
/// - 动态并发调整
/// - 聚合发送

// ═══════════════════════════════════════════════════════════
// 磁盘 IO 保护 (需求 §18)
// ═══════════════════════════════════════════════════════════

/// 顺序写入器 — 使用 256KB 缓冲区
class SequentialWriter {
  static const int bufferSize = 256 * 1024; // 256KB
  final List<int> _buffer = [];
  final RandomAccessFile _file;

  SequentialWriter(this._file);

  /// 写入数据（缓冲到 256KB 后落盘）
  Future<void> write(List<int> data) async {
    _buffer.addAll(data);

    if (_buffer.length >= bufferSize) {
      await _flush();
    }
  }

  /// 强制刷新缓冲区
  Future<void> flush() async {
    await _flush();
  }

  Future<void> _flush() async {
    if (_buffer.isEmpty) return;
    await _file.writeFrom(_buffer);
    _buffer.clear();
  }
}

/// 目录树预创建 — 传输文件夹时先建完整目录结构
class DirectoryTreeCreator {
  /// 根据 relativePath 列表预先创建所有目录
  static Future<void> createDirectories(
    String basePath,
    List<String> relativePaths,
  ) async {
    final dirs = <String>{};
    for (final path in relativePaths) {
      final dir = _parentDir(path);
      if (dir.isNotEmpty) {
        String current = '';
        for (final part in dir.split('/')) {
          current = current.isEmpty ? part : '$current/$part';
          dirs.add(current);
        }
      }
    }

    for (final dir in dirs) {
      await Directory('$basePath/$dir').create(recursive: true);
    }
  }

  static String _parentDir(String path) {
    final lastSep = path.lastIndexOf('/');
    return lastSep > 0 ? path.substring(0, lastSep) : '';
  }
}

// ═══════════════════════════════════════════════════════════
// 内存保护 (需求 §19)
// ═══════════════════════════════════════════════════════════

/// 滑动窗口管理器 — 待处理数据上限 64MB
class SlidingWindow {
  static const int maxPendingBytes = 64 * 1024 * 1024; // 64MB
  final int maxBytes;

  int _pendingBytes = 0;
  final _waiters = <Completer<void>>[];

  SlidingWindow({this.maxBytes = maxPendingBytes});

  /// 尝试分配空间，超出则等待
  Future<void> acquire(int bytes) async {
    if (_pendingBytes + bytes <= maxBytes) {
      _pendingBytes += bytes;
      return;
    }

    final completer = Completer<void>();
    _waiters.add(completer);
    await completer.future;
    _pendingBytes += bytes;
  }

  /// 释放空间
  void release(int bytes) {
    _pendingBytes -= bytes;

    // 唤醒等待者
    while (_waiters.isNotEmpty) {
      final next = _waiters.first;
      final canProceed = _pendingBytes < maxBytes;
      if (canProceed) {
        _waiters.removeAt(0);
        next.complete();
      } else {
        break;
      }
    }
  }

  int get pendingBytes => _pendingBytes;
  double get usage => maxBytes > 0 ? _pendingBytes / maxBytes : 0;
}

/// 缓冲区复用池 — 避免频繁分配/释放
class BufferPool {
  static const int defaultChunkSize = 1024 * 1024; // 1MB
  final int chunkSize;
  final _pool = <List<int>>[];
  int _hits = 0;
  int _misses = 0;

  BufferPool({this.chunkSize = defaultChunkSize});

  /// 获取缓冲区（优先复用）
  List<int> acquire() {
    if (_pool.isNotEmpty) {
      _hits++;
      final buf = _pool.removeLast();
      buf.clear();
      return buf;
    }
    _misses++;
    return List.filled(chunkSize, 0, growable: true);
  }

  /// 归还缓冲区
  void release(List<int> buffer) {
    if (_pool.length < 8) {
      // 最多缓存 8 个
      _pool.add(buffer);
    }
  }

  double get hitRate => (_hits + _misses) > 0 ? _hits / (_hits + _misses) : 0;
}

// ═══════════════════════════════════════════════════════════
// 动态并发调整器 (需求 §4.3)
// ═══════════════════════════════════════════════════════════

class DynamicConcurrency {
  final int initialConcurrency;
  final int minConcurrency;
  final int maxConcurrency;
  final Function(int) onConcurrencyChanged;

  int _currentConcurrency;
  int _lastAdjustTime = 0;
  double _lastThroughput = 0;

  DynamicConcurrency({
    required this.initialConcurrency,
    this.minConcurrency = 1,
    this.maxConcurrency = 8,
    required this.onConcurrencyChanged,
  }) : _currentConcurrency = initialConcurrency;

  int get current => _currentConcurrency;

  /// 根据性能指标调整并发数
  void adjust({
    required double currentThroughput,
    required int diskWriteLatencyMs,
    required int engineMemoryMB,
    required double uiFps,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;

    // 调整间隔 ≥ 5 秒
    if (now - _lastAdjustTime < 5000) return;
    _lastAdjustTime = now;

    bool changed = false;

    // 严重卡顿：<15fps 持续 3 秒 → 强制退回默认
    if (uiFps < 15) {
      if (_currentConcurrency > initialConcurrency) {
        _currentConcurrency = initialConcurrency;
        changed = true;
      }
      onConcurrencyChanged(_currentConcurrency);
      return;
    }

    // UI 帧率 < 30fps → 降低并发
    if (uiFps < 30 && _currentConcurrency > minConcurrency) {
      _currentConcurrency--;
      changed = true;
    }

    // 磁盘写入延迟过高 (>100ms) → 降低并发
    if (diskWriteLatencyMs > 100 && _currentConcurrency > minConcurrency) {
      _currentConcurrency--;
      changed = true;
    }

    // 引擎内存 > 80MB → 暂停新文件
    if (engineMemoryMB > 80) {
      if (_currentConcurrency > 0) {
        _currentConcurrency = max(0, _currentConcurrency - 2);
        changed = true;
      }
    }

    // 吞吐量下降 → 降低并发
    if (_lastThroughput > 0 && currentThroughput < _lastThroughput * 0.8) {
      if (_currentConcurrency > minConcurrency) {
        _currentConcurrency--;
        changed = true;
      }
    }

    // 吞吐量良好 → 尝试增加并发
    if (!changed &&
        currentThroughput >= _lastThroughput * 0.95 &&
        _currentConcurrency < maxConcurrency &&
        engineMemoryMB < 50 &&
        diskWriteLatencyMs < 50) {
      _currentConcurrency++;
      changed = true;
    }

    _lastThroughput = currentThroughput;

    if (changed) {
      onConcurrencyChanged(_currentConcurrency);
    }
  }

  void forceDowngrade(int reason) {
    _currentConcurrency = minConcurrency;
    onConcurrencyChanged(_currentConcurrency);
  }
}

// ═══════════════════════════════════════════════════════════
// 聚合发送 (需求 §4.2)
// ═══════════════════════════════════════════════════════════

/// 聚合发送配置
class AggregateConfig {
  static const int smallFileThreshold = 10 * 1024 * 1024; // 10MB
  static const int maxAggregateSize = 16 * 1024 * 1024; // 16MB (不超过 Frame 上限)

  /// 将多个小文件打包为一个聚合流
  /// 格式: [pathLen(2B) + pathBytes + fileSize(8B) + fileHash(8B) + fileBytes]...
  static List<int> aggregate(
    List<AggregateFileEntry> files,
  ) {
    final buffer = <int>[];

    for (final file in files) {
      final pathBytes = file.relativePath.codeUnits;
      final pathLen = pathBytes.length;

      // pathLen (2B, Big Endian)
      buffer.addAll(_intToBytes(pathLen, 2));

      // pathBytes
      buffer.addAll(pathBytes);

      // fileSize (8B, Big Endian)
      buffer.addAll(_intToBytes(file.size, 8));

      // fileHash (8B, placeholder)
      buffer.addAll(_intToBytes(file.hash, 8));

      // fileBytes
      buffer.addAll(file.data);
    }

    return buffer;
  }

  /// 解析聚合流
  static List<AggregateFileEntry> parse(List<int> data) {
    final files = <AggregateFileEntry>[];
    int offset = 0;

    while (offset + 2 <= data.length) {
      final pathLen = _bytesToInt(data.sublist(offset, offset + 2));
      offset += 2;

      if (offset + pathLen + 16 > data.length) break;

      final path = String.fromCharCodes(data.sublist(offset, offset + pathLen));
      offset += pathLen;

      final fileSize = _bytesToInt(data.sublist(offset, offset + 8));
      offset += 8;

      final fileHash = _bytesToInt(data.sublist(offset, offset + 8));
      offset += 8;

      if (offset + fileSize > data.length) break;

      final fileData = data.sublist(offset, offset + fileSize);
      offset += fileSize;

      files.add(AggregateFileEntry(
        relativePath: path,
        size: fileSize,
        hash: fileHash,
        data: fileData,
      ));
    }

    return files;
  }

  static List<int> _intToBytes(int value, int length) {
    final bytes = <int>[];
    for (var i = length - 1; i >= 0; i--) {
      bytes.add((value >> (i * 8)) & 0xFF);
    }
    return bytes;
  }

  static int _bytesToInt(List<int> bytes) {
    int result = 0;
    for (var i = 0; i < bytes.length; i++) {
      result = (result << 8) | bytes[i];
    }
    return result;
  }
}

class AggregateFileEntry {
  final String relativePath;
  final int size;
  final int hash;
  final List<int> data;

  const AggregateFileEntry({
    required this.relativePath,
    required this.size,
    required this.hash,
    required this.data,
  });
}
