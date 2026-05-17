import 'package:flutter/material.dart';
import '../../util/format.dart';

/// 传输进度卡片组件 (单文件级别)
class TransferProgressCard extends StatelessWidget {
  final String fileName;
  final int bytesTransferred;
  final int totalSize;
  final double speed; // bytes/s
  final String status; // pending, transferring, completed, failed
  final String? errorMessage;
  final VoidCallback? onRetry;

  const TransferProgressCard({
    super.key,
    required this.fileName,
    required this.bytesTransferred,
    required this.totalSize,
    this.speed = 0,
    this.status = 'pending',
    this.errorMessage,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final progress = totalSize > 0 ? bytesTransferred / totalSize : 0.0;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _buildStatusIcon(),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    fileName,
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (status == 'failed' && onRetry != null)
                  TextButton.icon(
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('重试', style: TextStyle(fontSize: 12)),
                    onPressed: onRetry,
                  ),
              ],
            ),
            if (status == 'transferring' || status == 'completed') ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                borderRadius: BorderRadius.circular(2),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${formatSize(bytesTransferred)} / ${formatSize(totalSize)}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  Text(
                    '${(progress * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(fontSize: 11),
                  ),
                ],
              ),
              if (speed > 0) ...[
                const SizedBox(height: 2),
                Text(
                  formatSpeed(speed),
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ],
            if (errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  errorMessage!,
                  style: const TextStyle(fontSize: 11, color: Colors.red),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIcon() {
    return switch (status) {
      'completed' => const Icon(Icons.check_circle, size: 20, color: Colors.green),
      'failed' => const Icon(Icons.error, size: 20, color: Colors.red),
      'transferring' => const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      _ => const Icon(Icons.hourglass_empty, size: 20, color: Colors.grey),
    };
  }
}
