/// 传输历史记录
class HistoryRecord {
  final int? id;
  final String transferId;
  final String deviceId;
  final String deviceName;
  final String? batchName;
  final int totalSize;
  final int fileCount;
  final bool success;
  final String? errorMessage;
  final double peakSpeed;
  final double avgSpeed;
  final String status; // completed, failed, cancelled, partial
  final DateTime timestamp;
  final String savePath;
  final bool folderMode; // 是否为文件夹传输

  HistoryRecord({
    this.id,
    required this.transferId,
    required this.deviceId,
    required this.deviceName,
    this.batchName,
    required this.totalSize,
    required this.fileCount,
    required this.success,
    this.errorMessage,
    required this.peakSpeed,
    required this.avgSpeed,
    required this.status,
    required this.timestamp,
    required this.savePath,
    this.folderMode = false,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'transferId': transferId,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'batchName': batchName,
        'totalSize': totalSize,
        'fileCount': fileCount,
        'success': success ? 1 : 0,
        'errorMessage': errorMessage,
        'peakSpeed': peakSpeed,
        'avgSpeed': avgSpeed,
        'status': status,
        'timestamp': timestamp.millisecondsSinceEpoch,
        'savePath': savePath,
        'folderMode': folderMode ? 1 : 0,
      };

  factory HistoryRecord.fromMap(Map<String, dynamic> map) {
    return HistoryRecord(
      id: map['id'] as int?,
      transferId: map['transferId'] as String,
      deviceId: map['deviceId'] as String,
      deviceName: map['deviceName'] as String,
      batchName: map['batchName'] as String?,
      totalSize: map['totalSize'] as int,
      fileCount: map['fileCount'] as int,
      success: (map['success'] as int) == 1,
      errorMessage: map['errorMessage'] as String?,
      peakSpeed: (map['peakSpeed'] as num).toDouble(),
      avgSpeed: (map['avgSpeed'] as num).toDouble(),
      status: map['status'] as String,
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      savePath: map['savePath'] as String,
      folderMode: (map['folderMode'] as int?) == 1,
    );
  }
}
