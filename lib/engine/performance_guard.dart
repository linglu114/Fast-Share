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

/// 滑动窗口管理器 — 限制发送端在途未确认字节数，提供真正的流控与即时暂停。
///
/// 工作原理：发送每个 chunk 前调用 [acquire] 预占窗口额度，收到接收端
/// ACK 后调用 [release] 归还额度。窗口满时 [acquire] 阻塞，迫使发送端
/// 停止向 socket 灌数据——此时在途数据量 = 窗口占用，而非内核缓冲上限。
///
/// 暂停语义：[pause] 后 [acquire] 立即阻塞（不消费窗口额度），即使窗口
/// 有空闲；[resume] 后恢复竞争。点击暂停后发送端最多再发完窗口内已预占
/// 的数据（默认 1 个 8MB chunk ≈ 0.16s@50MB/s），真正实现网络级即时暂停。
class SlidingWindow {
  /// 默认窗口 8MB（= 一个 chunkSize），暂停时在途数据上限即此值。
  static const int defaultMaxBytes = 8 * 1024 * 1024; // 8MB

  final int maxBytes;

  int _pendingBytes = 0;
  final _waiters = <_WindowWaiter>[];
  bool _paused = false;
  bool _cancelled = false;

  SlidingWindow({this.maxBytes = defaultMaxBytes});

  /// 预占窗口额度。窗口满或已暂停时阻塞，直到 [release] 释放额度或
  /// [resume]/[cancel] 唤醒。
  ///
  /// 取消时抛出 [StateError]，调用方 catch 后跳出发送循环。
  Future<void> acquire(int bytes) async {
    while (true) {
      if (_cancelled) {
        throw StateError('SlidingWindow cancelled');
      }
      // 暂停时阻塞：不消费窗口，等 resume 或 cancel 唤醒。
      if (_paused) {
        final completer = Completer<void>();
        final waiter = _WindowWaiter(completer, bytes, paused: true);
        _waiters.add(waiter);
        await completer.future;
        // resume 后回到循环顶部，重新检查 _cancelled / _paused / 窗口
        continue;
      }

      if (_pendingBytes + bytes <= maxBytes) {
        _pendingBytes += bytes;
        return;
      }

      // 窗口满，排队等待 release 唤醒
      final completer = Completer<void>();
      final waiter = _WindowWaiter(completer, bytes);
      _waiters.add(waiter);
      await completer.future;
      // release 唤醒后回到循环顶部——release 已预占 _pendingBytes
      // 重新检查窗口状态（可能在等待期间被暂停/取消）
    }
  }

  /// 归还额度（收到 ACK 时调用）。唤醒等待中的 acquire。
  void release(int bytes) {
    if (_pendingBytes > bytes) {
      _pendingBytes -= bytes;
    } else {
      _pendingBytes = 0;
    }

    _wakeWaiters();
  }

  /// 暂停：后续 acquire 阻塞，但已 acquire 的在途数据不变。
  void pause() {
    _paused = true;
  }

  /// 恢复：唤醒所有因 pause 阻塞的 acquire，让它们重新竞争窗口额度。
  void resume() {
    _paused = false;
    _wakeWaiters();
  }

  /// 取消：以错误唤醒所有等待者，acquire 抛 StateError，发送循环退出。
  void cancel() {
    _cancelled = true;
    final waiters = List<_WindowWaiter>.from(_waiters);
    _waiters.clear();
    for (final w in waiters) {
      if (!w.completer.isCompleted) {
        w.completer.completeError(StateError('SlidingWindow cancelled'));
      }
    }
  }

  /// 唤醒已排队的等待者（release / resume 共用）。
  ///
  /// paused waiter 由 resume 唤醒后，回到 acquire 内的 while(true) 循环
  /// 重新走判断——它们此时已完成 await，在循环顶部自行决定是否入队。
  /// 非 paused waiter 由 release 唤醒时，release 已预占 _pendingBytes，
  /// acquire 循环顶部的 `_pendingBytes + bytes <= maxBytes` 检查会通过，
  /// 直接 return（不会重复入队）。
  void _wakeWaiters() {
    final toWake = <_WindowWaiter>[];
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.first;
      if (waiter.paused && _paused) {
        // 暂停态 waiter 且仍在暂停中——不唤醒（resume 会重新调 _wakeWaiters）
        break;
      }
      if (!waiter.paused && _pendingBytes + waiter.bytes > maxBytes) {
        // 非暂停 waiter 但窗口空间不够——不唤醒
        break;
      }
      _waiters.removeAt(0);
      if (!waiter.paused) {
        // 非 paused waiter：预占空间
        _pendingBytes += waiter.bytes;
      }
      toWake.add(waiter);
    }
    for (final w in toWake) {
      if (!w.completer.isCompleted) {
        w.completer.complete();
      }
    }
  }

  int get pendingBytes => _pendingBytes;
  double get usage => maxBytes > 0 ? _pendingBytes / maxBytes : 0;
}

class _WindowWaiter {
  final Completer<void> completer;
  final int bytes;
  final bool paused;
  const _WindowWaiter(this.completer, this.bytes, {this.paused = false});
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
