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
  final _waiters = <_WindowWaiter>[];

  SlidingWindow({this.maxBytes = maxPendingBytes});

  /// 尝试分配空间，超出则等待
  Future<void> acquire(int bytes) async {
    if (_pendingBytes + bytes <= maxBytes && _waiters.isEmpty) {
      _pendingBytes += bytes;
      return;
    }

    final completer = Completer<void>();
    _waiters.add(_WindowWaiter(completer, bytes));
    await completer.future;
    _pendingBytes += bytes;
  }

  /// 释放空间
  void release(int bytes) {
    _pendingBytes -= bytes;

    // 按 FIFO 顺序唤醒等待者，仅在剩余空间足够时释放
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.first;
      if (_pendingBytes + waiter.bytes <= maxBytes) {
        _waiters.removeAt(0);
        waiter.completer.complete();
        // acquire() 会在 completer 完成后立即 _pendingBytes += bytes，
        // 所以这里需要预先占用空间防止超额：
        _pendingBytes += waiter.bytes;
      } else {
        break;
      }
    }
  }

  int get pendingBytes => _pendingBytes;
  double get usage => maxBytes > 0 ? _pendingBytes / maxBytes : 0;
}

class _WindowWaiter {
  final Completer<void> completer;
  final int bytes;
  const _WindowWaiter(this.completer, this.bytes);
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
  Function(int) onConcurrencyChanged;

  int _currentConcurrency;
  int _lastAdjustTime = 0;
  double _lastThroughput = 0;
  int _upStreak = 0;   // 连续上升次数
  int _downStreak = 0; // 连续下降次数

  DynamicConcurrency({
    required this.initialConcurrency,
    this.minConcurrency = 1,
    this.maxConcurrency = 8,
    required this.onConcurrencyChanged,
  }) : _currentConcurrency = initialConcurrency;

  int get current => _currentConcurrency;

  /// 根据性能指标调整并发数。
  ///
  /// Engine Isolate 中仅有 [currentThroughput] 可用，其余指标为 -1。
  /// 使用滞回机制防止振荡：需要连续 2 次同向信号才调整。
  void adjust({
    required double currentThroughput,
    int diskWriteLatencyMs = -1,
    int engineMemoryMB = -1,
    double uiFps = -1,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;

    // 调整间隔 ≥ 5 秒
    if (now - _lastAdjustTime < 5000) return;
    _lastAdjustTime = now;

    // 严重卡顿：立即退回初始值（仅 UI 端可用）
    if (uiFps >= 0 && uiFps < 15) {
      _upStreak = 0; _downStreak = 0;
      if (_currentConcurrency > initialConcurrency) {
        _currentConcurrency = initialConcurrency;
        onConcurrencyChanged(_currentConcurrency);
      }
      return;
    }

    // UI FPS < 30 (仅 UI 端，无滞回)
    if (uiFps >= 0 && uiFps < 30 && _currentConcurrency > minConcurrency) {
      _upStreak = 0; _downStreak = 0;
      _currentConcurrency--;
      onConcurrencyChanged(_currentConcurrency);
      _lastThroughput = currentThroughput;
      return;
    }

    // 磁盘延迟过高 (仅 UI 端，无滞回)
    if (diskWriteLatencyMs >= 0 && diskWriteLatencyMs > 100 && _currentConcurrency > minConcurrency) {
      _upStreak = 0; _downStreak = 0;
      _currentConcurrency--;
      onConcurrencyChanged(_currentConcurrency);
      _lastThroughput = currentThroughput;
      return;
    }

    // 内存 > 80MB (仅 UI 端，无滞回)
    if (engineMemoryMB >= 0 && engineMemoryMB > 80 && _currentConcurrency > 0) {
      _upStreak = 0; _downStreak = 0;
      _currentConcurrency = max(0, _currentConcurrency - 2);
      onConcurrencyChanged(_currentConcurrency);
      _lastThroughput = currentThroughput;
      return;
    }

    // ── 吞吐量趋势判断（含滞回） ──
    bool raise = false;
    bool lower = false;

    if (_lastThroughput > 0) {
      final ratio = currentThroughput / _lastThroughput;
      if (ratio < 0.8) {
        // 下降 > 20%
        _downStreak++;
        _upStreak = 0;
        if (_downStreak >= 2) lower = true;
      } else if (ratio >= 0.95 && _currentConcurrency < maxConcurrency) {
        // 稳定或上升
        _upStreak++;
        _downStreak = 0;
        if (_upStreak >= 2) raise = true;
      } else {
        // 中间地带 (0.8–0.95)：重置计数，不调整
        _upStreak = 0;
        _downStreak = 0;
      }
    } else {
      // 首次采样 — 尝试上调（如果低于 max）
      if (_currentConcurrency < maxConcurrency) raise = true;
    }

    _lastThroughput = currentThroughput;

    if (lower && _currentConcurrency > minConcurrency) {
      _currentConcurrency--;
      _downStreak = 0;
      onConcurrencyChanged(_currentConcurrency);
    } else if (raise) {
      _currentConcurrency++;
      _upStreak = 0;
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
