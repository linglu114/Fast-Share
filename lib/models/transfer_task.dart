import 'package:uuid/uuid.dart';

/// 传输状态枚举
enum TransferStatus {
  pending,
  scanning,
  connecting,
  awaitingAccept,
  transferring,
  paused,
  completed,
  failed,
  cancelled,
}

/// 传输模式
enum TransferMode {
  sequential, // 顺序传输 (仅大文件)
  concurrent, // 自动并发 (仅小文件)
  mixed, // 混合模式
}

/// 单个文件传输记录
class FileTransferItem {
  final String fileId;
  final String relativePath;
  final int size;
  final int mtime;

  int bytesTransferred;
  int chunkSize;
  TransferStatus status;
  String? errorMessage;
  int retryCount;
  List<Range> receivedRanges; // 用于断点续传

  FileTransferItem({
    String? fileId,
    required this.relativePath,
    required this.size,
    this.mtime = 0,
    this.bytesTransferred = 0,
    this.chunkSize = 1048576, // 默认 1MB
    this.status = TransferStatus.pending,
    this.errorMessage,
    this.retryCount = 0,
    List<Range>? receivedRanges,
  })  : fileId = fileId ?? const Uuid().v4(),
        receivedRanges = receivedRanges ?? [];

  /// 进度百分比
  double get progress => size > 0 ? bytesTransferred / size : 0.0;
}

/// 传输任务
class TransferTask {
  final String transferId;
  final String senderDeviceId;
  final String targetDeviceId;
  final String? peerDeviceName;
  final String? batchName;
  int totalSize;
  List<FileTransferItem> files;
  final bool folderMode;

  TransferStatus status;
  TransferMode mode;
  int bytesTransferred;
  int concurrentCount;
  double peakSpeed; // 峰值速度 bytes/s
  double avgSpeed; // 平均速度 bytes/s
  DateTime createdAt;
  DateTime? completedAt;
  String? errorMessage;
  String savePath;

  TransferTask({
    String? transferId,
    required this.senderDeviceId,
    required this.targetDeviceId,
    this.peerDeviceName,
    this.batchName,
    required this.totalSize,
    required this.files,
    this.folderMode = false,
    this.status = TransferStatus.pending,
    this.mode = TransferMode.concurrent,
    this.bytesTransferred = 0,
    this.concurrentCount = 3,
    this.peakSpeed = 0,
    this.avgSpeed = 0,
    DateTime? createdAt,
    this.completedAt,
    this.errorMessage,
    this.savePath = '',
  })  : transferId = transferId ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();

  /// 创建浅拷贝（引用不同，触发 Riverpod 通知）
  TransferTask clone() {
    return TransferTask(
      transferId: transferId,
      senderDeviceId: senderDeviceId,
      targetDeviceId: targetDeviceId,
      peerDeviceName: peerDeviceName,
      batchName: batchName,
      totalSize: totalSize,
      files: List<FileTransferItem>.from(files),
      folderMode: folderMode,
      status: status,
      mode: mode,
      bytesTransferred: bytesTransferred,
      concurrentCount: concurrentCount,
      peakSpeed: peakSpeed,
      avgSpeed: avgSpeed,
      createdAt: createdAt,
      completedAt: completedAt,
      errorMessage: errorMessage,
      savePath: savePath,
    );
  }

  /// 总进度
  double get progress => totalSize > 0 ? bytesTransferred / totalSize : 0.0;

  /// 剩余文件数
  int get remainingFiles =>
      files.where((f) => f.status == TransferStatus.pending).length;

  /// 文件数量
  int get fileCount => files.length;
}

/// 字节范围 (用于断点续传)
class Range {
  final int start;
  final int end;

  const Range(this.start, this.end);

  int get length => end - start;

  Map<String, dynamic> toJson() => {'start': start, 'end': end};

  factory Range.fromJson(Map<String, dynamic> json) =>
      Range(json['start'] as int, json['end'] as int);

  @override
  String toString() => 'Range($start, $end)';
}
