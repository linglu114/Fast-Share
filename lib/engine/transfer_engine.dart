import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
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
      case 'shutdown':
        _commandPort.close();
        break;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 传输会话管理
  // ═══════════════════════════════════════════════════════════

  void _startTransfer(Map<String, dynamic> payload) {
    final transferId = payload['transferId'] as String;
    final paths = (payload['paths'] as List).cast<String>();
    final targetIp = payload['targetIp'] as String;
    final targetPort = payload['targetPort'] as int;
    final folderMode = payload['folderMode'] as bool? ?? false;
    final senderDeviceId = payload['senderDeviceId'] as String? ?? 'unknown';
    final senderDeviceName = payload['senderDeviceName'] as String? ?? senderDeviceId;
    final speedLimit = payload['speedLimit'] as int? ?? 0;
    final concurrentCount = payload['concurrentCount'] as int? ?? 0;
    final retryCount = payload['retryCount'] as int? ?? 3;

    final session = TransferSession(
      transferId: transferId,
      paths: paths,
      targetIp: targetIp,
      targetPort: targetPort,
      folderMode: folderMode,
      senderDeviceId: senderDeviceId,
      senderDeviceName: senderDeviceName,
      speedLimit: speedLimit,
      concurrentCount: concurrentCount,
      retryCount: retryCount,
      engine: this,
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

  // Socket 监听（接收 ACK）
  Uint8List _frameBuffer = Uint8List(0);
  final Map<String, Completer<void>> _ackWaiters = {};
  final Map<String, bool> _fileCompleted = {};
  Completer<void>? _allFilesDone;
  Completer<void>? _acceptReceived;
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

  TransferSession({
    required this.transferId,
    required this.paths,
    required this.targetIp,
    required this.targetPort,
    required this.folderMode,
    required this.senderDeviceId,
    required this.senderDeviceName,
    required this.speedLimit,
    required this.concurrentCount,
    required this.retryCount,
    required this.engine,
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

    // 阶段 2: 收集文件大小 (轻量级 lengthSync, 非 stat)
    _collectFileSizes();
    _sendFileListChunk(); // 此时文件大小已收集完毕，重新发送列表

    // 阶段 3: 判定传输模式 + 并发数
    _strategy = _decideStrategy();
    if (concurrentCount == 0) {
      concurrentCount = _files.length < 200 ? _randomInRange(3, 6) : _randomInRange(4, 8);
    }

    // 阶段 4: 连接目标
    _sendEvent('phase_change', {
      'transferId': transferId,
      'phase': 'connecting',
      'message': 'Connecting to receiver...',
    });

    try {
      _socket = await Socket.connect(targetIp, targetPort,
          timeout: const Duration(seconds: 10));
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

    // 阶段 5: 发送 TRANSFER_OFFER，等待接收端 TRANSFER_ACCEPT 再发送文件数据
    _sendTransferOffer();
    _sendEvent('mode_change', {
      'transferId': transferId,
      'mode': _strategy.name,
      'fileCount': _files.length,
      'totalSize': _totalSize,
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
        'message': 'Receiver did not accept transfer (timeout)',
      });
      return;
    }

    // 阶段 6: 开始传输
    await _executeTransfer();
  }

  void pause() {
    _paused = true;
    _sendEvent('progress', _progressData());
    try {
      _sendFrame(TransferControlMessages.buildPause(transferId: transferId));
    } catch (_) {}
  }

  void resume() {
    _paused = false;
    _sendEvent('progress', _progressData());
    try {
      _sendFrame(TransferControlMessages.buildResume(transferId: transferId));
    } catch (_) {}
  }

  void cancel() {
    _cancelled = true;
    _progressTimer?.cancel();
    _stopHeartbeat();
    _tokenBucket?.stop();
    for (final c in _ackWaiters.values) {
      if (!c.isCompleted) c.complete();
    }
    _ackWaiters.clear();
    if (_allFilesDone != null && !_allFilesDone!.isCompleted) {
      _allFilesDone!.complete();
    }
    if (_acceptReceived != null && !_acceptReceived!.isCompleted) {
      _acceptReceived!.complete();
    }
    // Notify receiver (skip if _sendFrame already set this)
    if (!_socketClosed) {
      try {
        _sendCancel();
      } catch (_) {}
    }
    _socketClosed = true;
    try {
      _socket?.close();
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════════════
  // 文件扫描
  // ═══════════════════════════════════════════════════════════

  Future<void> _scanFiles() async {
    for (final path in paths) {
      if (_cancelled) break;

      try {
        final type = FileSystemEntity.typeSync(path);
        if (type == FileSystemEntityType.directory) {
          await _scanDirectory(path, '');
        } else if (type == FileSystemEntityType.file) {
          _addFileEntry(path, p.basename(path), 0, 0);
        }
      } catch (e) {
        // skip inaccessible paths
      }
    }

    // file list sent after _collectFileSizes
  }

  Future<void> _scanDirectory(String dirPath, String relativePrefix) async {
    try {
      final dir = Directory(dirPath);
      await for (final entity in dir.list(recursive: false)) {
        if (_cancelled) break;

        try {
          final name = p.basename(entity.path);
          final relPath = relativePrefix.isEmpty ? name : p.join(relativePrefix, name);
          // Normalize to forward slashes for cross-platform compatibility (FLP v1.2)
          final normalizedRelPath = relPath.replaceAll('\\', '/');

          if (entity is File) {
            _addFileEntry(entity.path, normalizedRelPath, 0, 0);
          } else if (entity is Directory && folderMode) {
            await _scanDirectory(entity.path, relPath);
          }
        } catch (_) {}
      }
    } catch (e) {
      _sendEvent('error', {
        'transferId': transferId,
        'message': 'Directory scan failed: $dirPath — $e',
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

  /// 单文件顺序传输
  Future<void> _transferSingleFile(FileEntry file) async {
    final totalChunks = (file.size / chunkSize).ceil();
    Logger.log('[ENG] _transferSingleFile: fileId=${file.fileId} size=${file.size} chunks=$totalChunks');

    // 发送 FILE_META
    _sendFrame(_buildFileMeta(file, chunkSize));

    final raf = await File(file.absolutePath).open(mode: FileMode.read);
    int offset = 0;

    try {
      for (var i = 0; i < totalChunks; i++) {
        if (_cancelled) {
          Logger.log('[ENG] chunk loop cancelled at i=$i/$totalChunks');
          break;
        }
        while (_paused && !_cancelled) {
          await Future.delayed(const Duration(milliseconds: 100));
        }

        final remaining = file.size - offset;
        final currentChunkSize = min(chunkSize, remaining);

        // 令牌桶限速
        if (_tokenBucket != null) {
          await _tokenBucket!.consume(currentChunkSize);
        }

        final data = await raf.read(currentChunkSize);
        _sendFrame(_buildFileData(file.fileId, i, offset, data));

        _bytesTransferred += currentChunkSize;
        file.bytesTransferred += currentChunkSize;
        offset += currentChunkSize;

        _updateSpeed();
        _notifyProgress();

        if (i % 4 == 3 || i == totalChunks - 1) {
          await _socket?.flush();
          if (i % 100 == 99 || i == totalChunks - 1) {
            Logger.log('[ENG] flush done: chunk $i/$totalChunks offset=$offset');
          }
        }
      }

      Logger.log('[ENG] all chunks sent, waiting for FILE_COMPLETE from receiver');
      // 等待接收端 FILE_COMPLETE 确认（超时 120s，给慢速磁盘足够时间）
      final ackCompleter = Completer<void>();
      _ackWaiters[file.fileId] = ackCompleter;
      bool timedOut = false;

      await ackCompleter.future.timeout(
        const Duration(seconds: 120),
        onTimeout: () {
          timedOut = true;
          _ackWaiters.remove(file.fileId);
        },
      );

      if (timedOut) {
        Logger.log('[ENG] FILE_COMPLETE timeout! retries=${file.retries}/$retryCount');
        if (file.retries < retryCount) {
          file.retries++;
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
        raf.setPositionSync(0);
        offset = 0;
        _bytesTransferred -= file.bytesTransferred;
        file.bytesTransferred = 0;
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
      await raf.close();
    }
  }

  /// 并发传输多个文件 (worker-pool 模式)
  Future<void> _transferFilesConcurrent(List<FileEntry> files) async {
    final allFiles = List<FileEntry>.from(files);
    int nextIndex = 0;

    Future<void> worker() async {
      while (nextIndex < allFiles.length && !_cancelled) {
        while (_paused && !_cancelled) {
          await Future.delayed(const Duration(milliseconds: 100));
        }
        if (_cancelled) return;

        final idx = nextIndex;
        nextIndex++;
        await _transferSingleFile(allFiles[idx]);
      }
    }

    final workerCount = concurrentCount.clamp(1, allFiles.length);
    final workers = List.generate(workerCount, (_) => worker());
    await Future.wait(workers);
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
      Logger.log('[ENG] heartbeat: sending PING');
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
        Logger.log('[ENG] socket data done: remaining=${_frameBuffer.length}');
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
    Logger.log('[ENG] _handleIncomingFrame: type=0x${frame.type.toRadixString(16)}');
    switch (frame.type) {
      case FlpMessageType.helloAck:
        break;
      case FlpMessageType.transferAccept:
        if (_acceptReceived != null && !_acceptReceived!.isCompleted) {
          _acceptReceived!.complete();
        }
        break;
      case FlpMessageType.transferReject:
        if (_acceptReceived != null && !_acceptReceived!.isCompleted) {
          _acceptReceived!.completeError('Transfer rejected by receiver');
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
          Logger.log('[ENG] _onAckReceived: fileId=$fileId ackOffset=$ackOffset prevAcked=$prevAcked totalAcked=$_totalAckedBytes totalSize=$_totalSize');
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
    _completed = true;
    if (_allFilesDone != null && !_allFilesDone!.isCompleted) {
      _allFilesDone!.complete();
    }
  }

  void _resendRange(String fileId, int start, int end) {
    final file = _files.where((f) => f.fileId == fileId).firstOrNull;
    if (file == null) return;
    // 简化：重新发送整个文件（后续可优化为只重发 missingRanges）
    file.retries++;
    if (file.retries <= retryCount) {
      _transferSingleFile(file);
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

  FlpFrame _buildFileData(
      String fileId, int chunkIndex, int offset, Uint8List data) {
    // Binary payload: transferId(16) + fileId(16) + chunkIndex(4) + offset(8) + dataLength(4) + data(N)
    final payload = Uint8List(48 + data.length);
    final bd = ByteData.sublistView(payload);

    payload.setAll(0, _uuidToBytes(transferId));
    payload.setAll(16, _uuidToBytes(fileId));
    bd.setUint32(32, chunkIndex, Endian.big);
    bd.setUint64(36, offset, Endian.big);
    bd.setUint32(44, data.length, Endian.big);
    payload.setAll(48, data);

    return FlpFrame(type: FlpMessageType.fileData, payload: payload);
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
    if (_socketClosed) return;
    try {
      _socket?.add(frame.toBytes());
    } catch (e) {
      _socketClosed = true;
      Logger.log('[ENG] _sendFrame FAILED: type=0x${frame.type.toRadixString(16)} error=$e');
      _sendEvent('error', {
        'transferId': transferId,
        'message': 'Socket write failed: $e',
      });
      cancel();
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

      _sendEvent('speed', {
        'transferId': transferId,
        'speed': _avgSpeed(),
        'peakSpeed': _peakSpeed,
      });
    }
  }

  double _avgSpeed() {
    if (_speedSamples.isEmpty) return 0;
    return _speedSamples.reduce((a, b) => a + b) / _speedSamples.length;
  }

  // ═══════════════════════════════════════════════════════════
  // 进度汇报 (去抖 ≤10次/秒)
  // ═══════════════════════════════════════════════════════════

  void _notifyProgress() {
    _progressDirty = true;
    _progressTimer ??= Timer(const Duration(milliseconds: 100), () {
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

  int _randomInRange(int min, int max) =>
      min + Random().nextInt(max - min + 1);
}

// ═══════════════════════════════════════════════════════════
// 辅助类型
// ═══════════════════════════════════════════════════════════

class FileEntry {
  final String fileId;
  final String absolutePath;
  final String relativePath;
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
    this.bytesTransferred = 0,
    this.lastAckedOffset = 0,
    this.status = FileStatus.pending,
    this.retries = 0,
  });
}

enum FileStatus { pending, transferring, completed, failed }

enum TransferStrategy { sequential, concurrent, mixed }

/// 令牌桶限速器 (需求 §16)
class TokenBucket {
  final int _maxRate; // bytes/s
  int _tokens;
  int _lastRefill;
  Timer? _timer;
  final _waiters = <int, Completer<void>>{};
  int _waiterId = 0;

  TokenBucket(this._maxRate)
      : _tokens = _maxRate,
        _lastRefill = DateTime.now().millisecondsSinceEpoch {
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) => _refill());
  }

  void _refill() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final elapsed = now - _lastRefill;
    _lastRefill = now;
    _tokens = min(_maxRate, _tokens + (_maxRate * elapsed / 1000).round());
    _processWaiters();
  }

  Future<void> consume(int bytes) async {
    if (bytes <= _tokens) {
      _tokens -= bytes;
      return;
    }

    final id = _waiterId++;
    final completer = Completer<void>();
    _waiters[id] = completer;
    await completer.future;
    _tokens -= bytes;
  }

  void _processWaiters() {
    final toRemove = <int>[];
    for (final entry in _waiters.entries) {
      toRemove.add(entry.key);
      entry.value.complete();
    }
    for (final id in toRemove) {
      _waiters.remove(id);
    }
  }

  void stop() {
    _timer?.cancel();
    for (final c in _waiters.values) {
      if (!c.isCompleted) c.complete();
    }
    _waiters.clear();
  }
}
