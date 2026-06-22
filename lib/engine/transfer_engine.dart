import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show min;
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../util/constants.dart';
import '../util/logger.dart';
import 'frame.dart';
import 'performance_guard.dart';
import 'session.dart';
import 'transfer_control.dart';

/// Transfer Engine Isolate 入口 (架构设计 v2.0 §3)
///
/// 运行在独立 Isolate 中，处理所有文件 I/O、分块、校验、Socket 写入。
/// 通过 SendPort 与 UI Isolate 通信。
class TransferEngine {
  final SendPort _uiPort;
  final ReceivePort _commandPort = ReceivePort();
  final Map<String, TransferSession> _sessions = {};
  // _running flag removed — unused in MVP

  TransferEngine(this._uiPort) {
    _commandPort.listen(_handleCommand);
    _uiPort.send({
      'type': 'engine_ready',
      'data': {'enginePort': _commandPort.sendPort},
    });
  }

  void _sendEvent(String type, Map<String, dynamic> data) {
    _uiPort.send({'type': type, 'data': data});
  }

  void _handleCommand(dynamic message) {
    if (message is! Map<String, dynamic>) return;
    final type = message['type'] as String?;
    final payload = message['payload'] as Map<String, dynamic>? ?? {};

    switch (type) {
      case 'start_transfer':
        _startTransfer(payload);
        break;
      case 'pause':
        _pauseTransfer(payload['transferId'] as String);
        break;
      case 'resume':
        _resumeTransfer(payload['transferId'] as String);
        break;
      case 'cancel':
        _cancelTransfer(payload['transferId'] as String);
        break;
      case 'chunk_data':
        final tid = payload['transferId'] as String?;
        if (tid != null) {
          _sessions[tid]?.onChunkData(payload);
        }
        break;
      case 'shutdown':
        _commandPort.close();
        break;
      case 'set_speed_limit':
        final tid = payload['transferId'] as String?;
        final limit = payload['speedLimit'] as int? ?? 0;
        if (tid != null) {
          _sessions[tid]?.setSpeedLimit(limit);
        }
        break;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 传输会话管理
  // ═══════════════════════════════════════════════════════════

  void _startTransfer(Map<String, dynamic> payload) {
    final transferId = payload['transferId'] as String;
    final paths = (payload['paths'] as List?)?.cast<String>() ?? [];
    final contentFiles =
        (payload['contentFiles'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final targetIp = payload['targetIp'] as String;
    final targetPort = payload['targetPort'] as int;
    final folderMode = payload['folderMode'] as bool? ?? false;
    final senderDeviceId = payload['senderDeviceId'] as String? ?? 'unknown';
    final senderDeviceName = payload['senderDeviceName'] as String? ?? senderDeviceId;
    final speedLimit = payload['speedLimit'] as int? ?? 0;
    final concurrentCount = payload['concurrentCount'] as int? ?? 0;
    final retryCount = payload['retryCount'] as int? ?? 3;
    final tempDir = payload['tempDir'] as String?;
    final logDir = payload['logDir'] as String?;

    // Re-init Logger with a writable directory (needed on Android where CWD is read-only)
    if (logDir != null) {
      try { Logger.init(dirPath: logDir, suffix: '-Engine'); } catch (_) {}
    }

    final session = TransferSession(
      transferId: transferId,
      paths: paths,
      contentFiles: contentFiles,
      targetIp: targetIp,
      targetPort: targetPort,
      folderMode: folderMode,
      senderDeviceId: senderDeviceId,
      senderDeviceName: senderDeviceName,
      speedLimit: speedLimit,
      concurrentCount: concurrentCount,
      retryCount: retryCount,
      engine: this,
      tempDir: tempDir,
    );

    _sessions[transferId] = session;
    session.start().catchError((e, stack) {
      _sendEvent('error', {
        'transferId': transferId,
        'message': 'Transfer failed: ${e is String ? e : e.toString()}',
      });
    });
  }

  void _pauseTransfer(String transferId) {
    _sessions[transferId]?.pause();
  }

  void _resumeTransfer(String transferId) {
    _sessions[transferId]?.resume();
  }

  void _cancelTransfer(String transferId) {
    _sessions[transferId]?.cancel();
    _sessions.remove(transferId);
  }

  /// Engine Isolate 入口
  static void entry(SendPort uiPort) {
    runZonedGuarded(() {
      try {
        Logger.init(suffix: '-Engine');
      } catch (_) {}
      try {
        TransferEngine(uiPort);
      } catch (e, stack) {
        Logger.log('[ENG] FATAL: engine init failed: $e\n$stack');
        try {
          uiPort.send({
            'type': 'error',
            'data': {'message': 'Engine init failed: $e'},
          });
        } catch (_) {}
      }
    }, (error, stack) {
      // 兜底：捕获所有未被 try-catch 处理的异步错误
      Logger.log('[ENG] UNHANDLED ERROR (zone): $error\n$stack');
      try {
        uiPort.send({
          'type': 'error',
          'data': {'message': 'Engine unhandled error: $error'},
        });
      } catch (_) {}
    });
  }
}

/// 单个传输会话
class TransferSession {
  final String transferId;
  final List<String> paths;
  final List<Map<String, dynamic>> contentFiles;
  final String targetIp;
  final int targetPort;
  final bool folderMode;
  final int speedLimit;
  int concurrentCount;
  final int retryCount;
  final TransferEngine engine;

  Socket? _socket;
  bool _paused = false;
  bool _cancelled = false;
  bool _completed = false;
  bool _socketClosed = false;
  bool _resumeFramePending = false; // 在 chunk 间安全边界发送 TRANSFER_RESUME
  bool _cancelling = false; // 防止 cancel() 重入

  // Socket 监听（接收 ACK）
  Uint8List _frameBuffer = Uint8List(0);
  final Map<String, Completer<void>> _ackWaiters = {};
  final Map<String, Completer<Uint8List>> _chunkWaiters = {};
  final Map<String, bool> _fileCompleted = {};
  final Set<String> _retransferring = {}; // 防止并发重传同一文件
  Completer<void>? _allFilesDone;
  Completer<void>? _acceptReceived;
  bool _acceptRejected = false;
  // 文件列表
  final List<FileEntry> _files = [];

  // 传输状态
  int _bytesTransferred = 0; // 已发送字节数
  int _totalAckedBytes = 0; // 接收端已确认字节数 (ACK)
  int _totalSize = 0;
  double _peakSpeed = 0;
  final List<double> _speedSamples = [];
  int _lastSampleTime = 0;
  int _lastSampleBytes = 0;

  // 令牌桶
  TokenBucket? _tokenBucket;

  // 进度去抖
  Timer? _progressTimer;
  bool _progressDirty = false;
  Timer? _heartbeatTimer;

  // 传输模式
  TransferStrategy _strategy = TransferStrategy.concurrent;

  // 缓冲区复用池
  final BufferPool _bufferPool = BufferPool(chunkSize: chunkSize);

  // 动态并发调整器 (lazy init)
  DynamicConcurrency? _concurrencyAdjuster;

  final String senderDeviceId;
  final String senderDeviceName;
  final String? tempDir;

  TransferSession({
    required this.transferId,
    required this.paths,
    this.contentFiles = const [],
    required this.targetIp,
    required this.targetPort,
    required this.folderMode,
    required this.senderDeviceId,
    required this.senderDeviceName,
    required this.speedLimit,
    required this.concurrentCount,
    required this.retryCount,
    required this.engine,
    this.tempDir,
  }) {
    if (speedLimit > 0) {
      _tokenBucket = TokenBucket(speedLimit);
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 生命周期
  // ═══════════════════════════════════════════════════════════

  Future<void> start() async {
    // 阶段 1: 扫描文件列表 (仅收集路径，不校验)
    await _scanFiles();

    if (_cancelled || _files.isEmpty) {
      _completeWithError('No files to transfer');
      return;
    }

    // 阶段 2: 连接目标 (提前连接，减少用户等待)
    _sendEvent('phase_change', {
      'transferId': transferId,
      'phase': 'connecting',
      'message': 'Connecting to receiver...',
    });

    try {
      _socket = await Socket.connect(targetIp, targetPort,
          timeout: const Duration(seconds: 10));
      _socket!.setOption(SocketOption.tcpNoDelay, true);
    } catch (e) {
      _sendEvent('error', {
        'transferId': transferId,
        'message': 'Connection failed: $e',
      });
      return;
    }

    _sendHello();
    _startSocketListener();
    _startHeartbeat();

    // 阶段 3: 收集文件大小 + 判定传输模式
    _collectFileSizes();
    _sendFileListChunk();
    _strategy = _decideStrategy();

    // 阶段 4: 发送 TRANSFER_OFFER，等待接收端 TRANSFER_ACCEPT
    _sendTransferOffer();
    _sendEvent('phase_change', {
      'transferId': transferId,
      'phase': 'awaiting_accept',
      'message': 'Waiting for receiver to accept...',
    });

    _acceptReceived = Completer<void>();
    Logger.log('[ENG] waiting for TRANSFER_ACCEPT (timeout=30s)');
    try {
      await _acceptReceived!.future.timeout(const Duration(seconds: 30));
      Logger.log('[ENG] TRANSFER_ACCEPT received, starting transfer');
    } on TimeoutException {
      Logger.log('[ENG] TRANSFER_ACCEPT timeout');
      _sendEvent('error', {
        'transferId': transferId,
        'message': 'Receiver did not respond (timeout)',
      });
      _stopHeartbeat();
      try { _socket?.close(); } catch (_) {}
      return;
    }

    // TRANSFER_REJECT received (signalled via _acceptRejected flag)
    if (_acceptRejected) {
      Logger.log('[ENG] TRANSFER_REJECT received');
      _sendEvent('phase_change', {
        'transferId': transferId,
        'phase': 'rejected',
        'message': 'Receiver declined the transfer',
      });
      _stopHeartbeat();
      try { _socket?.close(); } catch (_) {}
      return;
    }

    // Cancelled while waiting for accept
    if (_cancelled) {
      Logger.log('[ENG] cancelled while awaiting accept');
      _stopHeartbeat();
      try { _socket?.close(); } catch (_) {}
      return;
    }

    // TRANSFER_ACCEPT — proceed to transfer
    _sendEvent('mode_change', {
      'transferId': transferId,
      'mode': _strategy.name,
      'fileCount': _files.length,
      'totalSize': _totalSize,
    });

    // 阶段 5: 开始传输
    await _executeTransfer();
  }

  void pause() {
    _paused = true;
    _cancelConcurrencyTimer(); // 暂停期间不调整并发数
    Logger.log('[ENG] PAUSED transferId=$transferId');
    // 立即发送 PAUSE 到 socket — 单次 _sendRawBytes 不与 chunk 数据交织
    if (!_socketClosed) {
      try {
        final pauseFrame = TransferControlMessages.buildPause(transferId: transferId);
        _sendRawBytes(pauseFrame.toBytes());
      } catch (_) {}
    }
    _sendEvent('progress', _progressData());
    _sendEvent('transfer_paused', {'transferId': transferId});
  }

  void resume() {
    _paused = false;
    _startConcurrencyMonitor(); // 恢复后重新评估并发数
    Logger.log('[ENG] RESUMED transferId=$transferId');
    _resumeFramePending = true;
    if (!_socketClosed) {
      try {
        final resumeFrame = TransferControlMessages.buildResume(transferId: transferId);
        _sendRawBytes(resumeFrame.toBytes());
        _resumeFramePending = false;
      } catch (_) {}
    }
    _sendEvent('progress', _progressData());
    _sendEvent('transfer_resumed', {'transferId': transferId});
  }

  void cancel() {
    if (_cancelling) return;
    _cancelling = true;
    _cancelled = true;
    _progressTimer?.cancel();
    _stopHeartbeat();
    _stopConcurrencyMonitor();
    _tokenBucket?.stop();
    for (final c in _ackWaiters.values) {
      if (!c.isCompleted) c.complete();
    }
    _ackWaiters.clear();
    for (final c in _chunkWaiters.values) {
      if (!c.isCompleted) c.completeError(Exception('Transfer cancelled'));
    }
    _chunkWaiters.clear();
    if (_allFilesDone != null && !_allFilesDone!.isCompleted) {
      _allFilesDone!.complete();
    }
    if (_acceptReceived != null && !_acceptReceived!.isCompleted) {
      _acceptReceived!.complete();
    }
    // 尝试通知接收端传输取消（直接写 socket，绕过 _sendRawBytes 的 _cancelling 守卫）
    if (!_socketClosed) {
      try {
        _sendCancelDirect();
      } catch (_) {}
    }
    _socketClosed = true;
    try {
      _socket?.close();
    } catch (_) {}
    _cleanupCacheFiles();
  }

  /// 动态调整传输限速（运行时可被 UI 侧电池/温度保护触发）
  void setSpeedLimit(int bytesPerSecond) {
    if (bytesPerSecond <= 0) {
      _tokenBucket?.stop();
      _tokenBucket = null;
      Logger.log('[ENG] setSpeedLimit: disabled (unlimited)');
    } else if (_tokenBucket == null) {
      _tokenBucket = TokenBucket(bytesPerSecond);
      Logger.log('[ENG] setSpeedLimit: enabled at ${bytesPerSecond} B/s');
    } else {
      _tokenBucket!.stop();
      _tokenBucket = TokenBucket(bytesPerSecond);
      Logger.log('[ENG] setSpeedLimit: updated to ${bytesPerSecond} B/s');
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 文件扫描
  // ═══════════════════════════════════════════════════════════

  Future<void> _scanFiles() async {
    // Content URI / file picker files: prefer real filesystem path when available.
    // On Android, if realPath is unavailable, try fd-based direct read via /proc/self/fd/$fd
    // to eliminate Isolate round-trips.
    for (final f in contentFiles) {
      if (_cancelled) break;
      final uri = f['uri'] as String? ?? '';
      final name = f['name'] as String? ?? 'unknown';
      final size = f['size'] as int? ?? 0;
      final realPath = f['realPath'] as String?;
      final fd = f['fd'] as int?;
      if (uri.isNotEmpty) {
        final id = _makeFileId(_files.length);
        if (fd != null && fd >= 0) {
          _files.add(FileEntry(
            fileId: id, absolutePath: '/proc/self/fd/$fd', relativePath: name,
            size: size, mtime: 0, contentUri: null,
          ));
        } else if (realPath != null) {
          _files.add(FileEntry(
            fileId: id, absolutePath: realPath, relativePath: name,
            size: size, mtime: 0, contentUri: null,
          ));
        } else {
          _files.add(FileEntry(
            fileId: id, absolutePath: uri, relativePath: name,
            size: size, mtime: 0, contentUri: uri,
          ));
        }
        _totalSize += size;
      }
    }

    String? _lastScanError;
    for (final path in paths) {
      if (_cancelled) break;

      try {
        final type = FileSystemEntity.typeSync(path);
        if (type == FileSystemEntityType.directory) {
          await _scanDirectory(path, '');
        } else if (type == FileSystemEntityType.file) {
          _addFileEntry(path, p.basename(path), 0, 0);
        } else {
          _lastScanError = 'Unknown entity type: $path';
        }
      } catch (e) {
        _lastScanError = '$e';
        Logger.log('[ENG] _scanFiles: failed to stat $path: $e');
      }
    }

    if (_files.isEmpty && _lastScanError != null && contentFiles.isEmpty) {
      _sendEvent('error', {
        'transferId': transferId,
        'message': '无法读取路径: $_lastScanError',
      });
    }
  }

  Future<void> _scanDirectory(String dirPath, String relativePrefix) async {
    try {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) {
        Logger.log('[ENG] _scanDirectory: dir not found: $dirPath');
        return;
      }
      await for (final entity in dir.list(recursive: false)) {
        if (_cancelled) break;

        try {
          final name = p.basename(entity.path);
          final relPath = relativePrefix.isEmpty ? name : p.join(relativePrefix, name);
          final normalizedRelPath = relPath.replaceAll('\\', '/');

          if (entity is File) {
            _addFileEntry(entity.path, normalizedRelPath, 0, 0);
          } else if (entity is Directory && folderMode) {
            await _scanDirectory(entity.path, relPath);
          }
        } catch (e) {
          Logger.log('[ENG] _scanDirectory: skip entry ${entity.path}: $e');
        }
      }
    } catch (e) {
      Logger.log('[ENG] _scanDirectory: list failed for $dirPath: $e');
      _sendEvent('error', {
        'transferId': transferId,
        'message': '目录扫描失败: $dirPath — $e',
      });
    }
  }

  void _addFileEntry(String absolutePath, String relativePath, int size, int mtime) {
    // Generate a proper 16-byte fileId: XOR the file index into the transferId UUID.
    // Plain "transferId-N" is too long for the 16-byte binary field in FILE_DATA.
    final id = _makeFileId(_files.length);
    _files.add(FileEntry(
      fileId: id,
      absolutePath: absolutePath,
      relativePath: relativePath,
      size: size,
      mtime: mtime,
    ));
    _totalSize += size;
  }

  /// Generate a 16-byte fileId by XOR-ing the file index into the transferId.
  String _makeFileId(int index) {
    final bytes = _uuidToBytes(transferId);
    final bd = ByteData.sublistView(bytes);
    final current = bd.getUint32(12, Endian.big);
    bd.setUint32(12, current ^ index, Endian.big);
    return _bytesToUuid(bytes);
  }

  static String _bytesToUuid(Uint8List bytes) {
    final hex = StringBuffer();
    for (var i = 0; i < 16; i++) {
      hex.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    final h = hex.toString();
    return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
  }

  void _collectFileSizes() {
    int total = 0;
    for (final entry in _files) {
      if (entry.contentUri != null) {
        total += entry.size;
        continue;
      }
      try {
        entry.size = File(entry.absolutePath).lengthSync();
      } catch (_) {
        entry.size = 0;
      }
      total += entry.size;
    }
    _totalSize = total;
  }

  // ═══════════════════════════════════════════════════════════
  // 传输策略判定 (§4.1)
  // ═══════════════════════════════════════════════════════════

  TransferStrategy _decideStrategy() {
    final hasLarge = _files.any((f) => f.size >= largeFileThreshold);
    final hasSmall = _files.any((f) => f.size < largeFileThreshold);

    if (hasLarge && hasSmall) return TransferStrategy.mixed;
    if (hasLarge) return TransferStrategy.sequential;
    return TransferStrategy.concurrent;
  }

  // ═══════════════════════════════════════════════════════════
  // 传输执行
  // ═══════════════════════════════════════════════════════════

  Future<void> _executeTransfer() async {
    _stopHeartbeat(); // 传输期间数据流即为心跳，避免 PING 和 FILE_DATA 竞争 socket
    _allFilesDone = Completer<void>(); // 必须在传文件之前创建，否则 TRANSFER_COMPLETE 可能丢失
    Logger.flushSync(); // 落盘扫描和连接阶段日志，防止传输阶段崩溃丢失

    // 自动模式：初始化动态并发调整器
    if (concurrentCount == 0) {
      _concurrencyAdjuster = DynamicConcurrency(
        initialConcurrency: _files.length < 50 ? 3 : 4,
        minConcurrency: 1,
        maxConcurrency: 8,
        onConcurrencyChanged: (newCount) {
          if (newCount != concurrentCount) {
            final old = concurrentCount;
            concurrentCount = newCount;
            Logger.log('[ENG] concurrency: $old → $newCount (auto-adjusted)');
            _sendEvent('concurrency_changed', {
              'transferId': transferId,
              'concurrency': newCount,
              'reason': 'auto',
            });
          }
        },
      );
      concurrentCount = _concurrencyAdjuster!.initialConcurrency;
      _startConcurrencyMonitor();
    }

    if (_strategy == TransferStrategy.sequential ||
        _strategy == TransferStrategy.mixed) {
      // 先传大文件
      final largeFiles = _files.where((f) => f.size >= largeFileThreshold).toList();
      for (final file in largeFiles) {
        if (_cancelled) break;
        while (_paused && !_cancelled) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
        await _transferSingleFile(file);
      }
    }

    if (_strategy == TransferStrategy.concurrent ||
        _strategy == TransferStrategy.mixed) {
      // 并发传小文件
      final smallFiles = _files.where((f) => f.size < largeFileThreshold).toList();
      await _transferFilesConcurrent(smallFiles);
    }

    _stopConcurrencyMonitor();

    if (!_cancelled) {
      // 等待接收端 TRANSFER_COMPLETE 确认
      try {
        await _allFilesDone!.future.timeout(
          const Duration(seconds: 60),
        );
        _completed = true;
        _sendEvent('transfer_complete', {'transferId': transferId});
      } on TimeoutException {
        _sendEvent('error', {
          'transferId': transferId,
          'message': 'Transfer timeout waiting for receiver confirmation',
        });
      }
    }
  }

  /// 单文件顺序传输（零拷贝：header + raf.read() 直接写 socket，无 CRC32）
  Future<void> _transferSingleFile(FileEntry file) async {
    // 防重入：socket 已关闭时跳过，避免在重试循环中反复等待 120s 超时
    if (_socketClosed || _cancelled) return;

    // 暂停检查必须在 FILE_META 发送之前：
    // 并发 slot 在进入本函数前会检查 _paused，但 pause() 可能在
    // 检查通过后、sendFrame(FILE_META) 前被调用。此处兜底确保
    // 不会在有暂停标记的情况下继续发送文件元数据和新 chunk。
    while (_paused && !_cancelled) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    if (_cancelled) return;

    final totalChunks = (file.size / chunkSize).ceil();
    final useContentUri = file.contentUri != null;
    Logger.log('[ENG] _transferSingleFile: fileId=${file.fileId} size=${file.size} chunks=$totalChunks contentUri=$useContentUri');

    // 发送 FILE_META
    _sendFrame(_buildFileMeta(file, chunkSize));

    RandomAccessFile? raf;
    if (!useContentUri) {
      raf = await File(file.absolutePath).open(mode: FileMode.read);
    }
    int offset = 0;

    // 计时累积器（每 10 chunk 输出一次）
    int readUs = 0, sendUs = 0;
    final t0 = DateTime.now().microsecondsSinceEpoch;

    try {
      var i = 0;
      while (i < totalChunks) {
        if (_cancelled) {
          Logger.log('[ENG] chunk loop cancelled at i=$i/$totalChunks');
          break;
        }
        while (_paused && !_cancelled) {
          await Future.delayed(const Duration(milliseconds: 100));
        }

        // 让出控制权给事件循环，确保上一个 chunk 处理期间排队中的
        // pause 命令在当前 chunk 开始 I/O 前被消费。否则 round-trip：
        //   raf.read() 完成 → 微任务恢复 → _paused 检查(仍为 false)
        //   → 构建+发送 frame → i++ → 回到顶部 while(_paused)
        //   → 仍为 false（pause 还在事件队列）→ 继续下一轮
        // 导致暂停后至少多传一个 chunk。
        await Future.delayed(Duration.zero);
        if (_cancelled) break;
        if (_paused) { continue; }

        // 恢复后立即在安全边界发送 TRANSFER_RESUME：此时刚退出 while(_paused)，
        // 无 FILE_DATA 正在写入 socket，不会与控制帧交织
        if (_resumeFramePending && !_socketClosed) {
          _resumeFramePending = false;
          try {
            final resumeFrame = TransferControlMessages.buildResume(transferId: transferId);
            _sendRawBytes(resumeFrame.toBytes());
          } catch (_) {}
        }

        final remaining = file.size - offset;
        final currentChunkSize = min(chunkSize, remaining);

        // 令牌桶限速
        if (_tokenBucket != null) {
          await _tokenBucket!.consume(currentChunkSize);
        }
        // 限速等待后可能已暂停，立即检查；while 循环 i 不变，恢复后重试同一 chunk
        if (_paused && !_cancelled) continue;

        // 读文件（定位读写，暂停后重试同一 offset 不丢数据）
        final tRead0 = DateTime.now().microsecondsSinceEpoch;
        final Uint8List data;
        if (useContentUri) {
          data = await _requestChunk(file.fileId, file.contentUri!, i, offset,
              currentChunkSize);
        } else {
          raf!.setPositionSync(offset);
          data = await raf!.read(currentChunkSize);
        }
        final tRead1 = DateTime.now().microsecondsSinceEpoch;
        readUs += tRead1 - tRead0;

        // raf.read() 本身是 await，I/O 期间事件循环已处理排队消息。
        // 只需同步检查，无需额外 yield。
        if (_paused && !_cancelled) continue;

        // 构建 FLP 帧（8MB 数据+头+尾，全程同步，阻塞事件循环 ~1-5ms）。
        // 期间 pause 消息无法被处理，必须在帧构建完成后 yield 一次
        // 让事件循环消费排队中的 pause，再决定是否发送。
        final tSend0 = DateTime.now().microsecondsSinceEpoch;
        final header = FlpFrame.buildFileDataHeader(
          transferId: transferId,
          fileId: file.fileId,
          chunkIndex: i,
          offset: offset,
          dataLength: currentChunkSize,
        );
        final zc = FlpFrame.zeroChecksum;
        final frame = Uint8List(header.length + data.length + zc.length);
        frame.setAll(0, header);
        frame.setAll(header.length, data);
        frame.setAll(header.length + data.length, zc);

        // 帧构建完成后 yield 事件循环：处理帧构建期间排队的 pause 消息
        await Future.delayed(Duration.zero);
        if (_cancelled) break;
        if (_paused) continue; // 丢弃已构建帧，恢复后重读重发

        // 发送数据帧。_sendRawBytes 含同步 _paused 守卫作为最后兜底。
        if (!_sendRawBytes(frame, allowWhenPaused: false)) {
          if (_paused) continue;
          break; // socket closed or cancelling
        }

        // 写入过程中 socket 可能已由错误回调关闭，此时立即终止
        if (_cancelled || _socketClosed) break;

        final tSend1 = DateTime.now().microsecondsSinceEpoch;
        sendUs += tSend1 - tSend0;

        _bytesTransferred += currentChunkSize;
        file.bytesTransferred += currentChunkSize;
        offset += currentChunkSize;
        i++; // 仅在成功发送后递增 chunk 索引

        _updateSpeed();
        _notifyProgress();

        // 每 10 chunk 输出一次计时分布
        if (i % 10 == 0 || i == totalChunks) {
          final n = i % 10 == 0 ? 10 : i % 10;
          Logger.log('[ENG] chunk[${i - 1}]: read=${(readUs / n).toStringAsFixed(0)}us send=${(sendUs / n).toStringAsFixed(0)}us perChunkAvg');
          readUs = 0; sendUs = 0;
        }
      }

      final totalUs = DateTime.now().microsecondsSinceEpoch - t0;
      Logger.log('[ENG] all chunks sent in ${(totalUs / 1000).toStringAsFixed(0)}ms, waiting for FILE_COMPLETE from receiver');

      // socket 已死（发送过程中被错误回调关闭）→ 直接返回，不白白等 120s
      if (_socketClosed || _cancelled) return;

      // 全部 chunk 已发完，但 resume 标志可能残存 → 补发 TRANSFER_RESUME，
      // 否则接收端仍处于 paused 状态，永远不会回复 FILE_COMPLETE
      if (_resumeFramePending && !_socketClosed) {
        _resumeFramePending = false;
        try {
          final resumeFrame = TransferControlMessages.buildResume(transferId: transferId);
          _sendRawBytes(resumeFrame.toBytes());
        } catch (_) {}
      }

      // 等待接收端 FILE_COMPLETE 确认（超时 120s，给慢速磁盘足够时间）。
      // 使用轮询循环以支持暂停：暂停期间不消耗超时配额、不提前返回。
      final ackCompleter = Completer<void>();
      _ackWaiters[file.fileId] = ackCompleter;
      // 0 字节文件 / 竞态修复：FILE_COMPLETE 可能在 raf.open() 或 chunk
      // 发送期间已到达（接收端处理 0 字节文件极快），此时 _fileCompleted
      // 已标记但 waiter 未注册。检查到后立即完成，跳过 120s 等待。
      if (_fileCompleted[file.fileId] == true && !ackCompleter.isCompleted) {
        ackCompleter.complete();
      }
      bool timedOut = false;
      const _pollMs = 500;
      var _remainingMs = 120000; // 120 s

      while (!timedOut && !_cancelled && !ackCompleter.isCompleted) {
        await Future.delayed(const Duration(milliseconds: _pollMs));
        // 暂停时跳过所有检查：不计时、不处理 FILE_COMPLETE，防止恢复前意外推进
        if (_paused) continue;
        if (ackCompleter.isCompleted) break;
        // 防御性检查：FILE_COMPLETE 可能在任意 await 点到达
        if (_fileCompleted[file.fileId] == true) {
          ackCompleter.complete();
          _ackWaiters.remove(file.fileId);
          break;
        }
        _remainingMs -= _pollMs;
        if (_remainingMs <= 0) {
          timedOut = true;
          _ackWaiters.remove(file.fileId);
        }
      }

      if (timedOut) {
        Logger.log('[ENG] FILE_COMPLETE timeout! retries=${file.retries}/$retryCount');
        if (file.retries < retryCount) {
          file.retries++;
          _resetFileProgress(file);
          await _transferSingleFile(file);
          return;
        }
        file.status = FileStatus.failed;
        _sendCancel();
        _sendEvent('file_complete', {
          'transferId': transferId,
          'fileId': file.fileId,
          'success': false,
          'error': 'ACK timeout',
        });
      } else if (_fileCompleted[file.fileId] == true) {
        file.status = FileStatus.completed;
        _sendEvent('file_complete', {
          'transferId': transferId,
          'fileId': file.fileId,
          'success': true,
        });
      } else {
        // FILE_COMPLETE with success=false
        if (file.retries < retryCount) {
          file.retries++;
          _resetFileProgress(file);
          await _transferSingleFile(file);
          return;
        }
        file.status = FileStatus.failed;
        _sendCancel();
        _sendEvent('file_complete', {
          'transferId': transferId,
          'fileId': file.fileId,
          'success': false,
        });
      }
    } catch (e) {
      // 重试逻辑
      if (file.retries < retryCount) {
        file.retries++;
        if (!useContentUri) {
          raf?.setPositionSync(0);
        }
        _resetFileProgress(file);
        await _transferSingleFile(file);
      } else {
        file.status = FileStatus.failed;
        _sendCancel();
        _sendEvent('file_complete', {
          'transferId': transferId,
          'fileId': file.fileId,
          'success': false,
          'error': '$e',
        });
      }
    } finally {
      await raf?.close();
    }
  }

  /// 并发传输多个文件 — 信号量模型
  ///
  /// 每个 slot 在取文件时检查是否超出当前并发配额。
  /// - 降级：配额下调 → slot 传完当前文件后退出，不立即中断
  /// - 扩容：配额上调 → 下一轮 _concurrencyChanged 回调触发补充
  /// 无需定时器轮询，由 onConcurrencyChanged 回调驱动扩容。
  Future<void> _transferFilesConcurrent(List<FileEntry> files) async {
    final allFiles = List<FileEntry>.from(files);
    int nextIndex = 0;
    final active = AtomicInt(0);

    Future<void> slot() async {
      active.inc();
      try {
        while (!_cancelled) {
          while (_paused && !_cancelled) {
            await Future.delayed(const Duration(milliseconds: 100));
          }
          if (_cancelled) return;

          // 配额下调 → 本 slot 退出（传完当前文件后，不中断进行中的传输）
          if (active.get() > concurrentCount) return;

          if (nextIndex >= allFiles.length) return;

          final file = allFiles[nextIndex];
          nextIndex++;
          await _transferSingleFile(file);
        }
      } finally {
        active.dec();
      }
    }

    final futures = <Future<void>>[];

    // onConcurrencyChanged 在 DynamicConcurrency.adjust() 中被调用，
    // 接管扩容逻辑 — 配额上调时补充新 slot
    final origCallback = _concurrencyAdjuster?.onConcurrencyChanged;
    if (_concurrencyAdjuster != null) {
      _concurrencyAdjuster!.onConcurrencyChanged = (newCount) {
        concurrentCount = newCount;
        // 补充 slot 直到达到新配额或文件用完
        while (active.get() < concurrentCount &&
            nextIndex < allFiles.length &&
            !_cancelled) {
          futures.add(slot());
        }
        // 转发到原回调（日志 + UI 事件）
        origCallback?.call(newCount);
      };
    }

    // 启动初始 slot pool
    final initialCount = concurrentCount.clamp(1, allFiles.length);
    for (var i = 0; i < initialCount; i++) {
      futures.add(slot());
    }

    await Future.wait(futures);
  }

  // ═══════════════════════════════════════════════════════════
  // FLP 消息构建
  // ═══════════════════════════════════════════════════════════

  void _sendHello() {
    final frame = SessionMessages.buildHello(
      deviceId: senderDeviceId,
      sessionId: transferId,
      deviceName: 'FastShare',
      platform: Platform.operatingSystem,
      appVersion: '1.0.0',
    );
    _sendFrame(frame);
  }

  void _startHeartbeat() {
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (_cancelled || _completed || _socket == null) {
        Logger.log('[ENG] heartbeat: cancelling (cancelled=$_cancelled completed=$_completed socket=${_socket != null})');
        timer.cancel();
        return;
      }
      _sendFrame(SessionMessages.buildPing());
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _startSocketListener() {
    _socket!.listen(
      (data) {
        final newLen = _frameBuffer.length + data.length;
        final newBuffer = Uint8List(newLen);
        newBuffer.setAll(0, _frameBuffer);
        newBuffer.setAll(_frameBuffer.length, data);
        _frameBuffer = newBuffer;

        while (_frameBuffer.length >= FlpFrame.headerLength + FlpFrame.checksumLength) {
          final bd = ByteData.sublistView(_frameBuffer);
          final payloadLen = bd.getUint32(8, Endian.big);
          final totalLen = FlpFrame.headerLength + payloadLen + FlpFrame.checksumLength;
          if (_frameBuffer.length < totalLen) break;

          try {
            final frame = FlpFrame.parse(Uint8List.sublistView(_frameBuffer, 0, totalLen));
            _handleIncomingFrame(frame);
          } catch (e) {
            Logger.log('[ENG] socket listener: frame parse failed: $e');
            _sendEvent('error', {
              'transferId': transferId,
              'message': 'Frame parse/dispatch failed: $e',
            });
          }

          _frameBuffer = Uint8List.sublistView(_frameBuffer, totalLen);
        }
      },
      onError: (e) {
        Logger.log('[ENG] socket listener onError: $e — cancelling transfer');
        cancel();
        _sendEvent('error', {
          'transferId': transferId,
          'message': 'Socket error: $e',
        });
      },
      onDone: () {
        Logger.log('[ENG] socket listener onDone, completed=$_completed');
        if (!_completed) {
          _sendEvent('error', {
            'transferId': transferId,
            'message': 'Connection closed by receiver',
          });
        }
      },
    );
  }

  void _handleIncomingFrame(FlpFrame frame) {
    // Skip logging for high-frequency frames (FILE_ACK, FILE_NACK, FILE_COMPLETE)
    if (frame.type != FlpMessageType.fileAck &&
        frame.type != FlpMessageType.fileNack &&
        frame.type != FlpMessageType.fileComplete &&
        frame.type != FlpMessageType.pong) {
      Logger.log('[ENG] _handleIncomingFrame: type=0x${frame.type.toRadixString(16)}');
    }
    switch (frame.type) {
      case FlpMessageType.helloAck:
        break;
      case FlpMessageType.transferAccept:
        Logger.log('[ENG] TRANSFER_ACCEPT received, completing _acceptReceived');
        if (_acceptReceived != null && !_acceptReceived!.isCompleted) {
          _acceptReceived!.complete();
        }
        break;
      case FlpMessageType.transferReject:
        Logger.log('[ENG] TRANSFER_REJECT received, signalling rejection');
        _acceptRejected = true;
        if (_acceptReceived != null && !_acceptReceived!.isCompleted) {
          _acceptReceived!.complete();
        }
        break;
      case FlpMessageType.transferCancel:
        Logger.log('[ENG] TRANSFER_CANCEL received from receiver');
        cancel();
        break;
      case FlpMessageType.fileAck:
        _onAckReceived(frame);
        break;
      case FlpMessageType.fileNack:
        _onNackReceived(frame);
        break;
      case FlpMessageType.fileComplete:
        _onFileCompleteReceived(frame);
        break;
      case FlpMessageType.transferComplete:
        _onTransferCompleteReceived(frame);
        break;
      case FlpMessageType.transferSpeedLimit:
        _onSpeedLimitReceived(frame);
        break;
      case FlpMessageType.pong:
        break;
      default:
        // Unknown frame type — log but don't disconnect (FLP §13.1)
        break;
    }
  }

  void _sendCancel() {
    final payload = Uint8List.fromList(utf8.encode(jsonEncode({
      'transferId': transferId,
      'reason': 'TRANSFER_FAILED',
    })));
    _sendFrame(FlpFrame(type: FlpMessageType.transferCancel, payload: payload));
  }

  /// 直接写 socket 发送 TRANSFER_CANCEL，绕过 _sendRawBytes 的守卫。
  /// 仅在 cancel() 内部调用，用于在 socket 可能已受损时做最后一次通知尝试。
  void _sendCancelDirect() {
    final payload = Uint8List.fromList(utf8.encode(jsonEncode({
      'transferId': transferId,
      'reason': 'TRANSFER_FAILED',
    })));
    final frame = FlpFrame(type: FlpMessageType.transferCancel, payload: payload);
    _socket?.add(frame.toBytes());
  }

  void _sendTransferOffer() {
    final fileSummaries = _files.map((f) => {
      'fileId': f.fileId,
      'relativePath': f.relativePath,
      'size': f.size,
    }).toList();

    final offer = TransferControlMessages.buildOffer(
      transferId: transferId,
      senderDeviceId: senderDeviceId,
      senderDeviceName: senderDeviceName,
      batchName: paths.length == 1
          ? paths.first.split('/').last.split('\\').last
          : '${paths.length} 个文件',
      totalSize: _totalSize,
      fileCount: _files.length,
      folderMode: folderMode,
      files: fileSummaries,
    );
    _sendFrame(offer);
  }

  void _onAckReceived(FlpFrame frame) {
    try {
      final json = jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
      final fileId = json['fileId'] as String?;
      final ackOffset = json['ackOffset'] as int? ?? 0;

      if (fileId != null) {
        final file = _files.where((f) => f.fileId == fileId).firstOrNull;
        if (file != null) {
          final prevAcked = file.lastAckedOffset;
          if (ackOffset > prevAcked) {
            _totalAckedBytes += ackOffset - prevAcked;
            file.lastAckedOffset = ackOffset;
          }
          _updateSpeed();
          _notifyProgress();
        } else {
          Logger.log('[ENG] _onAckReceived: UNKNOWN fileId=$fileId (not in _files)');
        }
      }
    } catch (e) {
      _sendEvent('error', {
        'transferId': transferId,
        'message': 'FILE_ACK parse failed: $e',
      });
    }
  }

  void _onNackReceived(FlpFrame frame) {
    try {
      final json = jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
      final fileId = json['fileId'] as String?;
      final missingRanges = (json['missingRanges'] as List?)?.cast<List>() ?? [];

      for (final range in missingRanges) {
        if (fileId != null && range.length >= 2) {
          _resendRange(fileId, range[0] as int, range[1] as int);
        }
      }
    } catch (e) {
      _sendEvent('error', {
        'transferId': transferId,
        'message': 'FILE_NACK parse failed: $e',
      });
    }
  }

  void _onFileCompleteReceived(FlpFrame frame) {
    try {
      final json = jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
      final fileId = json['fileId'] as String?;
      final success = json['success'] as bool? ?? true;
      Logger.log('[ENG] FILE_COMPLETE received: fileId=$fileId success=$success totalAcked=$_totalAckedBytes totalSize=$_totalSize');
      Logger.flushSync();

      if (fileId != null) {
        _fileCompleted[fileId] = success;
        final waiter = _ackWaiters.remove(fileId);
        waiter?.complete();
      }
    } catch (e) {
      _sendEvent('error', {
        'transferId': transferId,
        'message': 'FILE_COMPLETE parse failed: $e',
      });
    }
  }

  void _onTransferCompleteReceived(FlpFrame frame) {
    Logger.log('[ENG] TRANSFER_COMPLETE received: totalAcked=$_totalAckedBytes totalSize=$_totalSize bytesTransferred=$_bytesTransferred');
    Logger.flushSync();

    // Parse receiver's success flag
    bool success = true;
    String? errorDetail;
    try {
      final payload = jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
      success = payload['success'] as bool? ?? true;
      errorDetail = payload['error'] as String?;
      Logger.log('[ENG] TRANSFER_COMPLETE success=$success failedFiles=${payload['failedFiles']} error=$errorDetail');
    } catch (_) {}

    if (!success) {
      _cancelled = true;
      // Stop chunk loops and prevent _executeTransfer from timing out
      if (_allFilesDone != null && !_allFilesDone!.isCompleted) {
        _allFilesDone!.complete();
      }
      _cleanupCacheFiles();
      try { _socket?.close(); } catch (_) {}
      _socketClosed = true;
      _sendEvent('error', {
        'transferId': transferId,
        'message': errorDetail ?? 'Transfer failed on receiver side',
      });
      return;
    }

    // Guard: 仅在全部文件已收到 FILE_COMPLETE 时才接受 TRANSFER_COMPLETE
    // 防止接收端因遗漏 FILE_META 而提前发送 TRANSFER_COMPLETE
    // （接收端只知道已注册的文件，若某文件 FILE_META 丢失则不会计入）
    final allFilesConfirmed = _files.every((f) =>
        _fileCompleted[f.fileId] == true || f.status == FileStatus.failed);
    if (!allFilesConfirmed) {
      final pending = _files.where((f) =>
          _fileCompleted[f.fileId] != true && f.status != FileStatus.failed).toList();
      Logger.log('[ENG] TRANSFER_COMPLETE received but ${pending.length} files still pending (${pending.map((f)=>f.relativePath).join(",")}), ignoring');
      Logger.flushSync();
      return; // 继续等待剩余文件的 FILE_COMPLETE
    }

    _completed = true;
    _cleanupCacheFiles();
    if (_allFilesDone != null && !_allFilesDone!.isCompleted) {
      _allFilesDone!.complete();
    }
  }

  void _onSpeedLimitReceived(FlpFrame frame) {
    try {
      final json = jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
      final limit = json['speedLimit'] as int? ?? 0;
      Logger.log('[ENG] SPEED_LIMIT received: limit=$limit B/s');
      setSpeedLimit(limit);
    } catch (e) {
      Logger.log('[ENG] SPEED_LIMIT parse failed: $e');
    }
  }

  void _resendRange(String fileId, int start, int end) {
    final file = _files.where((f) => f.fileId == fileId).firstOrNull;
    if (file == null) return;
    // Guard against concurrent retransfers of the same file from duplicate NACKs
    if (_retransferring.contains(fileId)) return;
    // 简化：重新发送整个文件（后续可优化为只重发 missingRanges）
    file.retries++;
    if (file.retries <= retryCount) {
      _retransferring.add(fileId);
      _resetFileProgress(file);
      _transferSingleFile(file).then((_) {
        _retransferring.remove(fileId);
      });
    }
  }

  FlpFrame _buildFileMeta(FileEntry file, int chunkSize) {
    final payload = Uint8List.fromList(utf8.encode(jsonEncode({
          'transferId': transferId,
          'fileId': file.fileId,
          'relativePath': file.relativePath,
          'size': file.size,
          'chunkSize': chunkSize,
          'hashAlgo': 'sha256',
        })));
    return FlpFrame(type: FlpMessageType.fileMeta, payload: payload);
  }

  static Uint8List _uuidToBytes(String uuid) {
    final hex = uuid.replaceAll('-', '');
    final bytes = Uint8List(16);
    for (var i = 0; i < 16 && i * 2 < hex.length; i++) {
      bytes[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }

  void _sendFrame(FlpFrame frame) {
    _sendRawBytes(frame.toBytes());
  }

  /// 写字节到 socket。控制帧始终放行；数据帧可通过 [allowWhenPaused] 阻止。
  ///
  /// 返回 `true` 表示字节已成功写入 socket，返回 `false` 表示调用方应放弃
  /// 当前操作（已暂停 / socket 已关闭 / 正在取消）。
  bool _sendRawBytes(Uint8List bytes, {bool allowWhenPaused = true}) {
    if (_socketClosed || _cancelling) return false;
    if (!allowWhenPaused && _paused) return false;
    try {
      _socket?.add(bytes);
      return true;
    } catch (e) {
      Logger.log('[ENG] _sendRawBytes FAILED: len=${bytes.length} error=$e');
      Logger.flushSync();
      _sendEvent('error', {
        'transferId': transferId,
        'message': 'Socket write failed: $e',
      });
      cancel();
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 速度计算 (§六 — 1s 采样，3s 滑动窗口)
  // ═══════════════════════════════════════════════════════════

  void _updateSpeed() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastSampleTime == 0) {
      _lastSampleTime = now;
      _lastSampleBytes = _bytesTransferred;
      return;
    }

    final deltaMs = now - _lastSampleTime;
    if (deltaMs >= 1000) {
      final deltaBytes = _bytesTransferred - _lastSampleBytes;
      final speed = deltaBytes / (deltaMs / 1000.0); // bytes/s
      _speedSamples.add(speed);

      // 保留 3 秒窗口
      while (_speedSamples.length > 3) {
        _speedSamples.removeAt(0);
      }

      if (speed > _peakSpeed) _peakSpeed = speed;

      _lastSampleTime = now;
      _lastSampleBytes = _bytesTransferred;
    }
  }

  double _avgSpeed() {
    if (_speedSamples.isEmpty) return 0;
    return _speedSamples.reduce((a, b) => a + b) / _speedSamples.length;
  }

  // ═══════════════════════════════════════════════════════════
  // 动态并发监控 (5s 周期，基于吞吐量趋势自动调整)
  // ═══════════════════════════════════════════════════════════

  Timer? _concurrencyTimer;

  void _startConcurrencyMonitor() {
    if (_concurrencyAdjuster == null) return;
    _concurrencyTimer?.cancel();
    _concurrencyTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_cancelled || _completed) {
        _concurrencyTimer?.cancel();
        return;
      }
      _concurrencyAdjuster!.adjust(
        currentThroughput: _avgSpeed(),
      );
    });
  }

  void _cancelConcurrencyTimer() {
    _concurrencyTimer?.cancel();
    _concurrencyTimer = null;
  }

  void _stopConcurrencyMonitor() {
    _cancelConcurrencyTimer();
    _concurrencyAdjuster = null;
  }

  // ═══════════════════════════════════════════════════════════
  // 进度汇报 (去抖 ≤10次/秒)
  // ═══════════════════════════════════════════════════════════

  void _notifyProgress() {
    _progressDirty = true;
    _progressTimer ??= Timer(const Duration(milliseconds: 250), () {
      _progressTimer = null;
      if (_progressDirty) {
        _progressDirty = false;
        _sendEvent('progress', _progressData());
      }
    });
  }

  Map<String, dynamic> _progressData() => {
        'transferId': transferId,
        'bytesTransferred': _totalAckedBytes > 0 ? _totalAckedBytes : _bytesTransferred,
        'totalSize': _totalSize,
        'speed': _avgSpeed(),
        'peakSpeed': _peakSpeed,
        'fileCount': _files.length,
        'completedFiles': _files.where((f) => f.status == FileStatus.completed).length,
      };


  // ═══════════════════════════════════════════════════════════
  // 辅助方法
  // ═══════════════════════════════════════════════════════════

  /// 文件重传时重置进度计数器，防止 _totalAckedBytes 累积旧值
  void _resetFileProgress(FileEntry file) {
    _totalAckedBytes -= file.lastAckedOffset;
    _bytesTransferred -= file.bytesTransferred;
    file.lastAckedOffset = 0;
    file.bytesTransferred = 0;
  }

  void _sendFileListChunk() {
    final summaries = _files.map((f) => {
      'fileId': f.fileId,
      'relativePath': f.relativePath,
      'size': f.size,
    }).toList();

    _sendEvent('file_list_chunk', {
      'transferId': transferId,
      'files': summaries,
      'totalSize': _totalSize,
    });
  }

  void _sendEvent(String type, Map<String, dynamic> data) {
    engine._sendEvent(type, data);
  }

  void _completeWithError(String message) {
    _sendEvent('error', {
      'transferId': transferId,
      'message': message,
    });
  }

  void _cleanupCacheFiles() {
    if (tempDir == null) return;
    for (final entry in _files) {
      if (entry.contentUri != null) continue;
      try {
        if (!entry.absolutePath.startsWith(tempDir!)) continue;
        final file = File(entry.absolutePath);
        if (file.existsSync()) file.deleteSync();
      } catch (_) {}
    }
  }

  Future<Uint8List> _requestChunk(
      String fileId, String uri, int chunkIndex, int offset, int length) async {
    final key = '$transferId:$fileId:$chunkIndex';
    final completer = Completer<Uint8List>();
    _chunkWaiters[key] = completer;

    _sendEvent('request_chunk', {
      'transferId': transferId,
      'fileId': fileId,
      'uri': uri,
      'chunkIndex': chunkIndex,
      'offset': offset,
      'length': length,
    });

    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _chunkWaiters.remove(key);
        throw Exception('Chunk read timeout: $key');
      },
    );
  }

  void onChunkData(Map<String, dynamic> payload) {
    final fileId = payload['fileId'] as String? ?? '';
    final chunkIndex = payload['chunkIndex'] as int? ?? 0;
    final data = payload['data'] as Uint8List?;
    final error = payload['error'] as String?;

    final key = '$transferId:$fileId:$chunkIndex';
    final waiter = _chunkWaiters.remove(key);
    if (waiter == null || waiter.isCompleted) return;

    if (error != null) {
      waiter.completeError(Exception(error));
    } else {
      waiter.complete(data ?? Uint8List(0));
    }
  }
}

// ═══════════════════════════════════════════════════════════
// 辅助类型
// ═══════════════════════════════════════════════════════════

/// 单线程安全的整数计数器 — Dart Isolate 内所有 slot 运行在同一事件循环，
/// 仅在 await 点让出控制权，无需真正的原子操作。
class AtomicInt {
  int _val;
  AtomicInt(this._val);
  int get() => _val;
  void inc() { _val++; }
  void dec() { _val--; }
}

class FileEntry {
  final String fileId;
  final String absolutePath;
  final String relativePath;
  final String? contentUri;
  int size;
  int mtime;
  int bytesTransferred;
  int lastAckedOffset = 0;
  FileStatus status;
  int retries;

  FileEntry({
    required this.fileId,
    required this.absolutePath,
    required this.relativePath,
    required this.size,
    required this.mtime,
    this.contentUri,
    this.bytesTransferred = 0,
    this.lastAckedOffset = 0,
    this.status = FileStatus.pending,
    this.retries = 0,
  });
}

enum FileStatus { pending, transferring, completed, failed }

enum TransferStrategy { sequential, concurrent, mixed }

/// 令牌桶限速器 (需求 §16)
///
/// 使用 burst 容量 + 简单自旋等待。burst 至少能容纳一个完整 chunk
/// (8 MB)，防止 chunkSize > rate 时死锁。空闲时令牌累积到 burst 上限，
/// 活跃时维持在 _maxRate 附近。
class TokenBucket {
  final int _maxRate; // bytes/s
  late final int _burstSize;
  int _tokens;
  int _lastRefill;
  Timer? _timer;

  TokenBucket(this._maxRate)
      : _tokens = (_maxRate > (8 * 1024 * 1024) ? _maxRate : (8 * 1024 * 1024)),
        _burstSize = (_maxRate > (8 * 1024 * 1024) ? _maxRate : (8 * 1024 * 1024)),
        _lastRefill = DateTime.now().millisecondsSinceEpoch {
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _refill());
  }

  void _refill() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = now - _lastRefill;
    _lastRefill = now;
    final added = (_maxRate * elapsed / 1000).round();
    _tokens = _tokens + added > _burstSize ? _burstSize : _tokens + added;
  }

  Future<void> consume(int bytes) async {
    while (_tokens < bytes) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    _tokens -= bytes;
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
