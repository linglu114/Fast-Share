import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import '../util/logger.dart';
import 'frame.dart';

/// Receive Engine Isolate (FLP v1.2 §8)
///
/// Runs in a dedicated Isolate, handling frame parsing (CRC32), disk I/O,
/// and ACK generation — symmetric to [TransferEngine] on the sender side.
///
/// Communication protocol (UI Isolate ↔ Engine Isolate via SendPort):
///
/// Commands (UI → Engine):
///   start    {transferId, savePath}
///   data     {transferId, rawBytes: Uint8List} — raw FILE_DATA / FILE_META frame
///   pause    {transferId}
///   resume   {transferId}
///   cancel   {transferId}
///   shutdown —
///
/// Events (Engine → UI):
///   progress         {transferId, bytesWritten, totalSize, speed, peakSpeed}
///   file_complete      {transferId, fileId, relativePath, success}
///   transfer_complete  {transferId, success, totalWritten}
///   error              {transferId, message}
///   ack_frame          {transferId, frameBytes: Uint8List}
class ReceiveEngine {
  final SendPort _uiPort;
  final ReceivePort _commandPort = ReceivePort();

  String? _transferId;
  String? _saveRoot;
  String? _fallbackRoot;
  bool _paused = false;
  bool _cancelled = false;
  String? _lastError;
  List<Map<String, dynamic>> _pendingFiles = []; // for directory pre-creation

  final Map<String, _ReceivingFile> _files = {};
  // Cached binary fileId for O(1) lookup without hex string conversion.
  // Most transfers are single-file; even multi-file transfers have fileId
  // stable within a batch of FILE_DATA frames.
  String? _lastFileIdStr;
  _ReceivingFile? _lastFile;
  (int, int, int, int)? _lastFileIdBytes;
  int _totalBytesWritten = 0;
  int _pendingSize = 0;
  int _lastAckBytes = 0;
  Timer? _ackTimer;
  Timer? _progressTimer;

  // Speed tracking (1 s samples, 6 s sliding window)
  int _lastSpeedTime = 0;
  int _lastSpeedBytes = 0;
  final List<double> _speedSamples = [];
  double _peakSpeed = 0;

  static const _ackBatchBytes = 16 * 1024 * 1024; // 16 MB
  static const _ackInterval = Duration(milliseconds: 500);

  ReceiveEngine(this._uiPort) {
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
      case 'start':
        _start(payload);
        break;
      case 'set_files':
        _setFiles(payload);
        break;
      case 'data':
        _handleData(payload);
        break;
      case 'pause':
        _pause();
        break;
      case 'resume':
        _resume();
        break;
      case 'cancel':
        _cancel();
        break;
      case 'set_speed_limit':
        _handleSpeedLimitCommand(payload);
        break;
      case 'shutdown':
        _shutdown();
        break;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // Lifecycle
  // ═══════════════════════════════════════════════════════════

  void _start(Map<String, dynamic> payload) {
    _transferId = payload['transferId'] as String;
    _saveRoot = payload['savePath'] as String;
    _fallbackRoot = payload['fallbackPath'] as String?;
    _lastFileIdStr = null;
    _lastFile = null;
    _lastFileIdBytes = null;
    Logger.log('[RECV] _start: transferId=$_transferId saveRoot=$_saveRoot fallbackRoot=$_fallbackRoot');

    // Pre-create directory structure from pending file list
    if (_pendingFiles.isNotEmpty) {
      final paths = _pendingFiles
          .map((f) => (f['relativePath'] as String?)?.replaceAll('\\', '/'))
          .where((p) => p != null && p.contains('/'))
          .cast<String>()
          .toList();
      if (paths.isNotEmpty) {
        try {
          final rootDir = Directory(_saveRoot!);
          if (!rootDir.existsSync()) {
            rootDir.createSync(recursive: true);
          }
          for (final path in paths) {
            final parts = path.split('/');
            if (parts.length > 1) {
              final subDir = Directory(
                  '${_saveRoot!}/${parts.sublist(0, parts.length - 1).join('/')}');
              if (!subDir.existsSync()) {
                subDir.createSync(recursive: true);
              }
            }
          }
        } catch (_) {}
      }
      _pendingFiles.clear();
    }
  }

  void _setFiles(Map<String, dynamic> payload) {
    _pendingFiles = (payload['files'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    Logger.log('[RECV] _setFiles: ${_pendingFiles.length} files pending');
  }

  void _pause() {
    // 暂停前 flush 所有待确认的 ACK，防止发送端因收不到确认而超时
    _flushPendingAcks();
    _paused = true;
    _ackTimer?.cancel();
    _ackTimer = null;
    _stopProgress();
  }

  /// Flush ACKs for all active files before pausing — prevents sender timeout
  void _flushPendingAcks() {
    for (final rf in _files.values) {
      if (rf.bytesWritten > 0) {
        final ackPayload = utf8.encode(jsonEncode({
          'transferId': _transferId,
          'fileId': rf.fileId,
          'ackOffset': rf.bytesWritten,
          'receivedRanges': [
            [0, rf.bytesWritten]
          ],
        }));
        final frame = FlpFrame(type: FlpMessageType.fileAck, payload: Uint8List.fromList(ackPayload));
        _sendFrameToUi(frame);
      }
    }
    _lastAckBytes = _totalBytesWritten;
  }

  void _resume() {
    _paused = false;
    _lastSpeedBytes = _totalBytesWritten;
    _lastAckBytes = _totalBytesWritten; // 重置以便恢复后按新批次发送 ACK
    _startProgress();
  }

  void _cancel() {
    _cancelled = true;
    _ackTimer?.cancel();
    _ackTimer = null;
    _stopProgress();
    for (final rf in _files.values) {
      try {
        rf.raf.closeSync();
      } catch (_) {}
      try {
        File(rf.filePath).deleteSync();
      } catch (_) {}
    }
    _files.clear();
  }

  void _shutdown() {
    _cancel();
    _commandPort.close();
  }

  /// 接收端本地限速触发 → 通过 TRANSFER_SPEED_LIMIT 帧通知发送端
  void _handleSpeedLimitCommand(Map<String, dynamic> payload) {
    final bytesPerSecond = payload['speedLimit'] as int? ?? 0;
    Logger.log('[RECV] handleSpeedLimitCommand: $bytesPerSecond B/s');
    try {
      // 构建 SPEED_LIMIT 帧，通过 ack_frame 通道发往发送端
      final frame = FlpFrame(
        type: FlpMessageType.transferSpeedLimit,
        payload: Uint8List.fromList(utf8.encode(jsonEncode({
          'transferId': _transferId,
          'speedLimit': bytesPerSecond,
        }))),
      );
      _sendFrameToUi(frame);
    } catch (e) {
      Logger.log('[RECV] handleSpeedLimitCommand error: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════
  // Frame processing (CRC32 in this Isolate)
  // ═══════════════════════════════════════════════════════════

  void _handleData(Map<String, dynamic> payload) {
    if (_paused || _cancelled || _transferId == null) return;

    final rawBytes = payload['rawBytes'] as Uint8List;

    try {
      final frame = FlpFrame.parse(rawBytes); // CRC32 runs here

      if (frame.type == FlpMessageType.fileMeta) {
        _handleFileMeta(frame);
      } else if (frame.type == FlpMessageType.fileData) {
        _handleFileData(frame);
      }
    } catch (e) {
      _lastError = 'Frame parse failed: $e';
      _sendEvent('error', {
        'transferId': _transferId,
        'message': _lastError,
      });
      _sendTransferComplete(false);
      _cancel();
    }
  }

  // ═══════════════════════════════════════════════════════════
  // FILE_META (FLP v1.2 §8.1)
  // ═══════════════════════════════════════════════════════════

  void _handleFileMeta(FlpFrame frame) {
    if (_cancelled) return;

    final json = jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
    final fileId = json['fileId'] as String;
    final relativePath = (json['relativePath'] as String).replaceAll('\\', '/');
    final size = json['size'] as int;
    final chunkSize = json['chunkSize'] as int? ?? 1048576;

    Logger.log('[RECV] handleFileMeta: transferId=$_transferId fileId=$fileId path=$relativePath size=$size');

    if (_files.containsKey(fileId)) {
      Logger.log('[RECV] handleFileMeta: skipping duplicate fileId=$fileId');
      return;
    }

    RandomAccessFile? raf;
    String? filePath;

    // Try primary path first, then fallback
    for (final root in <String>[_saveRoot!, if (_fallbackRoot != null) _fallbackRoot!]) {
      try {
        final rootDir = Directory(root);
        if (!rootDir.existsSync()) {
          rootDir.createSync(recursive: true);
        }

        final parts = relativePath.split('/');
        if (parts.length > 1) {
          final subDir = Directory('$root/${parts.sublist(0, parts.length - 1).join('/')}');
          if (!subDir.existsSync()) {
            subDir.createSync(recursive: true);
          }
        }

        filePath = '$root/$relativePath';
        raf = File(filePath).openSync(mode: FileMode.write);
        if (root != _saveRoot) {
          Logger.log('[RECV] handleFileMeta: using fallback path $filePath');
        }
        break;
      } catch (e) {
        Logger.log('[RECV] handleFileMeta: path $root failed: $e');
        if (root == _fallbackRoot || _fallbackRoot == null) {
          _lastError = 'FILE_META failed: $e (path: $root)';
          Logger.log('[RECV] handleFileMeta FAILED: $e (path: $root)');
          _sendEvent('error', {
            'transferId': _transferId,
            'message': _lastError,
          });
          _sendTransferComplete(false);
          _cancel();
          return;
        }
      }
    }

    if (raf == null || filePath == null) return; // unreachable, but safe

    _files[fileId] = _ReceivingFile(
      fileId: fileId,
      relativePath: relativePath,
      size: size,
      chunkSize: chunkSize,
      raf: raf,
      filePath: filePath,
    );

    _pendingSize += size;
    _startProgress();

    _sendEvent('file_meta_received', {
      'transferId': _transferId,
      'fileId': fileId,
      'relativePath': relativePath,
      'size': size,
    });
  }

  // ═══════════════════════════════════════════════════════════
  // FILE_DATA — sync disk write in background Isolate
  // ═══════════════════════════════════════════════════════════

  void _handleFileData(FlpFrame frame) {
    if (_cancelled) return;

    try {
      final buffer = ByteData.sublistView(frame.payload);

      // offset (8 B at byte 36: 16 transferId + 16 fileId + 4 chunkIndex)
      final offset = buffer.getUint64(36, Endian.big);

      // dataLength (4 B at byte 44)
      final dataLength = buffer.getUint32(44, Endian.big);

      // Fast fileId lookup: if last file matches, skip UUID parsing entirely.
      // For single-file transfers (the common case), this avoids 3720+ string allocs.
      _ReceivingFile? rf;
      const pos = 48; // data starts after: 16 + 16 + 4 + 8 + 4 = 48 bytes

      if (_lastFile != null) {
        // Check if this frame belongs to the same file (compare offset continuity)
        // For out-of-order delivery or multi-file, fall back to UUID lookup
        rf = _lastFile;
        // Verify by checking if a different fileId is present at byte 16-31
        final b0 = buffer.getUint32(16, Endian.big);
        final b1 = buffer.getUint32(20, Endian.big);
        final b2 = buffer.getUint32(24, Endian.big);
        final b3 = buffer.getUint32(28, Endian.big);
        final same = _lastFileIdBytes != null &&
            b0 == _lastFileIdBytes!.$1 &&
            b1 == _lastFileIdBytes!.$2 &&
            b2 == _lastFileIdBytes!.$3 &&
            b3 == _lastFileIdBytes!.$4;
        if (!same) {
          final fileId = _readUuid(buffer, 16);
          rf = _files[fileId];
          _lastFileIdStr = fileId;
          _lastFile = rf;
          _lastFileIdBytes = rf != null
              ? (b0, b1, b2, b3)
              : null;
        }
      } else {
        final fileId = _readUuid(buffer, 16);
        rf = _files[fileId];
        _lastFileIdStr = fileId;
        _lastFile = rf;
        _lastFileIdBytes = rf != null
            ? (buffer.getUint32(16, Endian.big), buffer.getUint32(20, Endian.big),
               buffer.getUint32(24, Endian.big), buffer.getUint32(28, Endian.big))
            : null;
      }

      if (rf == null) {
        Logger.log('[RECV] Unknown fileId in FILE_DATA: $_lastFileIdStr');
        return;
      }

      // Sync write — safe here in background Isolate
      rf.raf.setPositionSync(offset);
      rf.raf.writeFromSync(frame.payload, pos, pos + dataLength);

      rf.bytesWritten += dataLength;
      _totalBytesWritten += dataLength;

      _scheduleAck(rf.fileId);
      _updateSpeed();

      // Check if file is complete
      if (rf.bytesWritten >= rf.size) {
        Logger.log('[RECV] _handleFileData: file complete detected fileId=${rf.fileId} bytesWritten=${rf.bytesWritten} size=${rf.size} offset=$offset dataLength=$dataLength');
        _onFileComplete(rf.fileId);
      }
    } catch (e) {
      _lastError = 'FILE_DATA write failed: $e';
      _sendEvent('error', {
        'transferId': _transferId,
        'message': _lastError,
      });
      _sendTransferComplete(false);
      _cancel();
    }
  }

  // ═══════════════════════════════════════════════════════════
  // ACK scheduling (4 MB batch / 200 ms timer)
  // ═══════════════════════════════════════════════════════════

  void _scheduleAck(String fileId) {
    if (_totalBytesWritten - _lastAckBytes >= _ackBatchBytes) {
      _sendAck(fileId);
      _lastAckBytes = _totalBytesWritten;
      _ackTimer?.cancel();
      _ackTimer = null;
      return;
    }
    _ackTimer ??= Timer(_ackInterval, () {
      // 发送所有活跃文件的 ACK（而非仅设置定时器时的 fileId），
      // 避免因 fileId 对应的文件已完成导致 ACK 被静默丢弃
      _sendAcksForAllActive();
      _lastAckBytes = _totalBytesWritten;
      _ackTimer = null;
    });
  }

  void _sendAck(String fileId) {
    final rf = _files[fileId];
    if (rf == null) return;

    final ackPayload = utf8.encode(jsonEncode({
      'transferId': _transferId,
      'fileId': fileId,
      'ackOffset': rf.bytesWritten,
      'receivedRanges': [
        [0, rf.bytesWritten]
      ],
    }));
    final frame = FlpFrame(type: FlpMessageType.fileAck, payload: Uint8List.fromList(ackPayload));
    _sendFrameToUi(frame);
  }

  /// 为所有未完成的文件发送 ACK，防止定时器回调 fileId 过期
  void _sendAcksForAllActive() {
    for (final rf in _files.values) {
      if (rf.bytesWritten < rf.size) {
        final ackPayload = utf8.encode(jsonEncode({
          'transferId': _transferId,
          'fileId': rf.fileId,
          'ackOffset': rf.bytesWritten,
          'receivedRanges': [
            [0, rf.bytesWritten]
          ],
        }));
        final frame = FlpFrame(type: FlpMessageType.fileAck, payload: Uint8List.fromList(ackPayload));
        _sendFrameToUi(frame);
      }
    }
  }

  void _onFileComplete(String fileId) {
    final rf = _files[fileId];
    if (rf == null) return;

    Logger.log('[RECV] _onFileComplete: fileId=$fileId bytesWritten=${rf.bytesWritten} size=${rf.size} totalWritten=$_totalBytesWritten pendingSize=$_pendingSize');
    Logger.flushSync(); // Ensure logs survive Isolate exit

    // Send final ACK before cancelling the timer — the last batch (< 4MB)
    // may not have triggered the volume threshold or timer yet, and the
    // sender needs these bytes to reach 100% progress.
    _sendAck(fileId);

    _ackTimer?.cancel();
    _ackTimer = null;

    try {
      rf.raf.closeSync();
    } catch (_) {}

    final completePayload = utf8.encode(jsonEncode({
      'transferId': _transferId,
      'fileId': fileId,
      'success': true,
    }));
    final frame = FlpFrame(type: FlpMessageType.fileComplete, payload: Uint8List.fromList(completePayload));
    _sendFrameToUi(frame);

    _sendEvent('file_complete', {
      'transferId': _transferId,
      'fileId': fileId,
      'relativePath': rf.relativePath,
      'success': true,
    });

    // Check if all files are done
    final allDone = _files.values.every((f) => f.bytesWritten >= f.size);
    if (allDone) {
      _stopProgress();
      _sendTransferComplete(true);
    }
  }

  void _sendTransferComplete(bool success) {
    Logger.log('[RECV] _sendTransferComplete: success=$success totalWritten=$_totalBytesWritten pendingSize=$_pendingSize files=${_files.length} error=$_lastError');
    Logger.flushSync(); // Ensure logs survive Isolate exit
    final payload = utf8.encode(jsonEncode({
      'transferId': _transferId,
      'success': success,
      'failedFiles': _files.values.where((f) => f.bytesWritten < f.size).length,
      if (_lastError != null) 'error': _lastError,
    }));
    final frame = FlpFrame(type: FlpMessageType.transferComplete, payload: Uint8List.fromList(payload));
    _sendFrameToUi(frame);

    _sendEvent('transfer_complete', {
      'transferId': _transferId,
      'success': success,
      'totalWritten': _totalBytesWritten,
    });
  }

  /// Send a frame's raw bytes to the UI Isolate for socket write
  void _sendFrameToUi(FlpFrame frame) {
    _uiPort.send({
      'type': 'ack_frame',
      'data': {
        'transferId': _transferId,
        'frameBytes': frame.toBytes(),
      },
    });
  }

  // ═══════════════════════════════════════════════════════════
  // Speed tracking (1 s samples, 6 s sliding window)
  // ═══════════════════════════════════════════════════════════

  void _updateSpeed() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastSpeedTime == 0) {
      _lastSpeedTime = now;
      _lastSpeedBytes = _totalBytesWritten;
      return;
    }

    final deltaMs = now - _lastSpeedTime;
    if (deltaMs >= 1000) {
      final deltaBytes = _totalBytesWritten - _lastSpeedBytes;
      final speed = deltaBytes / (deltaMs / 1000.0);
      _speedSamples.add(speed);

      while (_speedSamples.length > 6) {
        _speedSamples.removeAt(0);
      }

      _lastSpeedTime = now;
      _lastSpeedBytes = _totalBytesWritten;
    }

    _notifyProgress();
  }

  double _avgSpeed() {
    if (_speedSamples.isEmpty) return 0;
    return _speedSamples.reduce((a, b) => a + b) / _speedSamples.length;
  }

  // ═══════════════════════════════════════════════════════════
  // Progress (debounced ≤ 10 Hz)
  // ═══════════════════════════════════════════════════════════

  void _notifyProgress() {
    _progressTimer ??= Timer(const Duration(milliseconds: 250), () {
      _progressTimer = null;
      if (_cancelled) return;
      final avg = _avgSpeed();
      if (avg > _peakSpeed) _peakSpeed = avg;
      _sendEvent('progress', {
        'transferId': _transferId,
        'bytesWritten': _totalBytesWritten,
        'totalSize': _pendingSize,
        'speed': avg,
        'peakSpeed': _peakSpeed,
      });
    });
  }

  void _startProgress() {
    _lastSpeedTime = DateTime.now().millisecondsSinceEpoch;
    _lastSpeedBytes = _totalBytesWritten;
  }

  void _stopProgress() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  // ═══════════════════════════════════════════════════════════
  // Helpers
  // ═══════════════════════════════════════════════════════════

  static String _readUuid(ByteData buffer, int offset) {
    final sb = StringBuffer();
    for (var i = 0; i < 16; i++) {
      sb.write(buffer.getUint8(offset + i).toRadixString(16).padLeft(2, '0'));
    }
    final hex = sb.toString();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  /// Isolate entry point
  static void entry(SendPort uiPort) {
    runZonedGuarded(() {
      try {
        Logger.init(suffix: '-RecvEngine');
      } catch (_) {}
      try {
        ReceiveEngine(uiPort);
      } catch (e, stack) {
        Logger.log('[RECV] FATAL: engine init failed: $e\n$stack');
        try {
          uiPort.send({
            'type': 'error',
            'data': {'message': 'Receive engine init failed: $e'},
          });
        } catch (_) {}
      }
    }, (error, stack) {
      Logger.log('[RECV] UNHANDLED ERROR (zone): $error\n$stack');
      try {
        uiPort.send({
          'type': 'error',
          'data': {'message': 'Receive engine unhandled error: $error'},
        });
      } catch (_) {}
    });
  }
}

class _ReceivingFile {
  final String fileId;
  final String relativePath;
  final int size;
  final int chunkSize;
  final RandomAccessFile raf;
  final String filePath;
  int bytesWritten = 0;

  _ReceivingFile({
    required this.fileId,
    required this.relativePath,
    required this.size,
    required this.chunkSize,
    required this.raf,
    required this.filePath,
  });
}
