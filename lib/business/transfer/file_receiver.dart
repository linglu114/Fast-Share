import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import '../../util/logger.dart';
import '../../engine/frame.dart';

/// @Deprecated — 接收逻辑已迁移至 [ReceiveEngine] Isolate (lib/engine/receive_engine.dart)
///
/// 保留本文件作为参考实现，所有 FILE_META/FILE_DATA 处理现在在独立 Isolate 中运行，
/// 由 [ConnectionManager] 通过 `onRawFrame` hook 转发原始帧字节到 ReceiveEngine。
///
/// 原始文档：接收端文件写入器 (FLP v1.2 §8)
/// 处理 FILE_META 创建文件，FILE_DATA 写入分块，发送 FILE_ACK/FILE_COMPLETE。
class FileReceiver {
  final String transferId;
  final String saveRoot;
  final void Function(FlpFrame frame) _sendFrame;
  final void Function(String type, Map<String, dynamic> data) _onEvent;

  final Map<String, _ReceivingFile> _files = {};
  bool _cancelled = false;
  int _totalBytesWritten = 0;
  int _pendingSize = 0;
  int _lastAckBytes = 0;
  Timer? _ackTimer;
  Timer? _progressTimer;

  // Timing instrumentation for UI lag diagnosis
  int _chunkCount = 0;
  final List<int> _writeDurationsUs = [];
  final List<int> _parseDurationsUs = [];

  // Speed tracking
  int _lastSpeedTime = 0;
  int _lastSpeedBytes = 0;
  final List<double> _speedSamples = [];

  double _peakSpeed = 0;

  static const _ackBatchBytes = 4 * 1024 * 1024; // 4MB
  static const _ackInterval = Duration(milliseconds: 200);

  FileReceiver({
    required this.transferId,
    required this.saveRoot,
    required void Function(FlpFrame frame) sendFrame,
    required void Function(String type, Map<String, dynamic> data) onEvent,
  })  : _sendFrame = sendFrame,
        _onEvent = onEvent;

  /// 处理 FILE_META (FLP v1.2 §8.1)
  void handleFileMeta(FlpFrame frame) {
    if (_cancelled) return;

    try {
      final json = jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
      final fileId = json['fileId'] as String;
      final relativePath = (json['relativePath'] as String).replaceAll('\\', '/');
      final size = json['size'] as int;
      final chunkSize = json['chunkSize'] as int? ?? 1048576;

      Logger.log('[FR] handleFileMeta: transferId=$transferId fileId=$fileId path=$relativePath size=$size saveRoot=$saveRoot');

      // 防止重复 FILE_META（发送端可能重发 TRANSFER_OFFER 导致重复帧）
      if (_files.containsKey(fileId)) {
        Logger.log('[FR] handleFileMeta: skipping duplicate fileId=$fileId');
        return;
      }

      // Ensure save root exists
      final rootDir = Directory(saveRoot);
      if (!rootDir.existsSync()) {
        Logger.log('[FR] Creating saveRoot: $saveRoot');
        rootDir.createSync(recursive: true);
      }

      // Build save path: saveRoot/relativePath
      final sep = saveRoot.endsWith('/') || saveRoot.endsWith('\\') ? '' : '/';
      final parts = relativePath.split('/');
      if (parts.length > 1) {
        final subDir = Directory('$saveRoot$sep${parts.sublist(0, parts.length - 1).join('/')}');
        if (!subDir.existsSync()) {
          Logger.log('[FR] Creating subDir: $subDir');
          subDir.createSync(recursive: true);
        }
      }

      final filePath = '$saveRoot$sep$relativePath';
      Logger.log('[FR] Opening file: $filePath');
      final raf = File(filePath).openSync(mode: FileMode.write);
      raf.setPositionSync(0); // Reset after open (no pre-allocation needed)

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

      _onEvent('file_meta_received', {
        'fileId': fileId,
        'relativePath': relativePath,
        'size': size,
      });
    } catch (e, stack) {
      Logger.log('[FR] handleFileMeta FAILED: $e\n$stack');
      _onEvent('error', {
        'message': 'FILE_META failed: $e',
        'transferId': transferId,
      });
      cancel();
    }
  }

  /// 处理 FILE_DATA — 同步写入磁盘，避免 payload 在内存中堆积
  void handleFileData(FlpFrame frame) {
    if (_cancelled) return;

    final t0 = DateTime.now().microsecondsSinceEpoch;

    try {
      final buffer = ByteData.sublistView(frame.payload);
      int pos = 0;

      // transferId (16B) — skip
      pos += 16;

      // fileId (16B)
      final fileId = _readUuid(buffer, pos);
      pos += 16;

      // chunkIndex (4B) — skip
      pos += 4;

      // offset (8B)
      final offset = buffer.getUint64(pos, Endian.big);
      pos += 8;

      // dataLength (4B)
      final dataLength = buffer.getUint32(pos, Endian.big);
      pos += 4;

      final rf = _files[fileId];
      if (rf == null) {
        Logger.log('[FR] Unknown fileId in FILE_DATA: $fileId (may arrive before FILE_META)');
        return;
      }

      final t1 = DateTime.now().microsecondsSinceEpoch;

      // 同步写入：数据立即落到磁盘，frame.payload 随后可被 GC 回收
      rf.raf.setPositionSync(offset);
      rf.raf.writeFromSync(frame.payload, pos, pos + dataLength);

      final t2 = DateTime.now().microsecondsSinceEpoch;

      rf.bytesWritten += dataLength;
      _totalBytesWritten += dataLength;

      // ACK
      _scheduleAck(fileId);

      // Timing instrumentation
      _parseDurationsUs.add(t1 - t0);
      _writeDurationsUs.add(t2 - t1);
      _chunkCount++;

      if (_chunkCount % 100 == 0) {
        final parseMin = _parseDurationsUs.reduce((a, b) => a < b ? a : b);
        final parseMax = _parseDurationsUs.reduce((a, b) => a > b ? a : b);
        final parseAvg = _parseDurationsUs.reduce((a, b) => a + b) ~/ _parseDurationsUs.length;
        final writeMin = _writeDurationsUs.reduce((a, b) => a < b ? a : b);
        final writeMax = _writeDurationsUs.reduce((a, b) => a > b ? a : b);
        final writeAvg = _writeDurationsUs.reduce((a, b) => a + b) ~/ _writeDurationsUs.length;
        Logger.log('[FR] perf chunk $_chunkCount: parse=${parseMin}/${parseAvg}/${parseMax}us write=${writeMin}/${writeAvg}/${writeMax}us');
        _parseDurationsUs.clear();
        _writeDurationsUs.clear();
      }

      // 检查文件是否完成
      if (rf.bytesWritten >= rf.size) {
        _onFileComplete(fileId);
      }
    } catch (e) {
      _onEvent('error', {'message': 'FILE_DATA write failed: $e', 'transferId': transferId});
      _sendTransferComplete(false);
      cancel();
    }
  }

  void _scheduleAck(String fileId) {
    if (_totalBytesWritten - _lastAckBytes >= _ackBatchBytes) {
      _sendAck(fileId);
      _lastAckBytes = _totalBytesWritten;
      _ackTimer?.cancel();
      _ackTimer = null;
      return;
    }
    _ackTimer ??= Timer(_ackInterval, () {
      _sendAck(fileId);
      _lastAckBytes = _totalBytesWritten;
      _ackTimer = null;
    });
  }

  void _startProgress() {
    _lastSpeedTime = DateTime.now().millisecondsSinceEpoch;
    _lastSpeedBytes = 0;
    _progressTimer ??= Timer.periodic(const Duration(milliseconds: 1000), (_) {
      if (_cancelled) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final deltaMs = now - _lastSpeedTime;
      double speed = 0;
      if (deltaMs > 0) {
        final deltaBytes = _totalBytesWritten - _lastSpeedBytes;
        speed = deltaBytes / (deltaMs / 1000.0);
        _speedSamples.add(speed);
        while (_speedSamples.length > 6) {
          _speedSamples.removeAt(0);
        }
      }
      _lastSpeedTime = now;
      _lastSpeedBytes = _totalBytesWritten;
      final avgSpeed = _speedSamples.isEmpty
          ? 0.0
          : _speedSamples.reduce((a, b) => a + b) / _speedSamples.length;
      if (avgSpeed > _peakSpeed) _peakSpeed = avgSpeed;

      _onEvent('progress', {
        'bytesWritten': _totalBytesWritten,
        'totalSize': _pendingSize,
        'speed': avgSpeed,
        'peakSpeed': _peakSpeed,
      });
    });
  }

  void _stopProgress() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  void _sendAck(String fileId) {
    final rf = _files[fileId];
    if (rf == null) return;

    final ackPayload = utf8.encode(jsonEncode({
      'transferId': transferId,
      'fileId': fileId,
      'ackOffset': rf.bytesWritten,
      'receivedRanges': [
        [0, rf.bytesWritten]
      ],
    }));
    _sendFrame(FlpFrame(type: FlpMessageType.fileAck, payload: Uint8List.fromList(ackPayload)));
  }

  void _onFileComplete(String fileId) {
    final rf = _files[fileId];
    if (rf == null) return;

    _ackTimer?.cancel();
    _ackTimer = null;

    try {
      rf.raf.closeSync();
    } catch (_) {}

    final completePayload = utf8.encode(jsonEncode({
      'transferId': transferId,
      'fileId': fileId,
      'success': true,
    }));
    _sendFrame(FlpFrame(type: FlpMessageType.fileComplete, payload: Uint8List.fromList(completePayload)));

    _onEvent('file_complete', {
      'transferId': transferId,
      'fileId': fileId,
      'relativePath': rf.relativePath,
      'success': true,
    });

    // 检查是否全部完成
    final allDone = _files.values.every((f) => f.bytesWritten >= f.size);
    if (allDone) {
      _stopProgress();
      _sendTransferComplete(true);
    }
  }

  void _sendTransferComplete(bool success) {
    final payload = utf8.encode(jsonEncode({
      'transferId': transferId,
      'success': success,
      'failedFiles': _files.values.where((f) => f.bytesWritten < f.size).length,
    }));
    _sendFrame(FlpFrame(type: FlpMessageType.transferComplete, payload: Uint8List.fromList(payload)));

    _onEvent('transfer_complete', {
      'transferId': transferId,
      'success': success,
      'totalWritten': _totalBytesWritten,
    });
  }

  void pause() {
    _stopProgress();
    _ackTimer?.cancel();
    _ackTimer = null;
  }

  void resume() {
    _lastSpeedBytes = _totalBytesWritten;
    _startProgress();
  }

  void cancel() {
    _cancelled = true;
    _ackTimer?.cancel();
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

  void dispose() {
    _ackTimer?.cancel();
    _stopProgress();
    for (final rf in _files.values) {
      try {
        rf.raf.closeSync();
      } catch (_) {}
    }
    _files.clear();
  }

  /// 检查磁盘空间 (需求 §25)
  bool checkDiskSpace(int requiredBytes) {
    try {
      final dir = Directory(saveRoot);
      if (!dir.existsSync()) return false; // will create
      // Windows doesn't support statSync for free space easily,
      // but we check on first write failure
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 从 ByteData 中读取 UUID（供外部通过 FILE_DATA payload 查找 FileReceiver）
  static String readUuid(ByteData buffer, int offset) {
    return _readUuid(buffer, offset);
  }

  static String _readUuid(ByteData buffer, int offset) {
    final sb = StringBuffer();
    for (var i = 0; i < 16; i++) {
      sb.write(buffer.getUint8(offset + i).toRadixString(16).padLeft(2, '0'));
    }
    final hex = sb.toString();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
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
