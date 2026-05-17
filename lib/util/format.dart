String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

String formatSpeed(double bytesPerSecond) {
  if (bytesPerSecond < 1024) return '${bytesPerSecond.toStringAsFixed(1)} B/s';
  if (bytesPerSecond < 1024 * 1024) {
    return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
  }
  if (bytesPerSecond < 1024 * 1024 * 1024) {
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
  return '${(bytesPerSecond / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB/s';
}

String formatEta(int totalSize, int bytesTransferred, double speed) {
  if (speed <= 0) return '';
  final remaining = totalSize - bytesTransferred;
  final seconds = (remaining / speed).round();
  if (seconds < 60) return '剩余 ${seconds}s';
  if (seconds < 3600) return '剩余 ${seconds ~/ 60}min';
  return '剩余 ${seconds ~/ 3600}h${(seconds % 3600) ~/ 60}min';
}

String formatTime(DateTime time) {
  final now = DateTime.now();
  final diff = now.difference(time);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  return '${time.month}/${time.day} ${time.hour}:${time.minute.toString().padLeft(2, '0')}';
}
