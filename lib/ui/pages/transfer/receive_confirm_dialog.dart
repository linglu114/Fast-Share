import 'package:flutter/material.dart';
import '../../../models/device.dart';
import '../../../util/format.dart';

/// 接收确认对话框 (需求 §11)
///
/// 展示发送方设备名、文件列表及大小；
/// 用户必须主动点击"接受"才开始传输。
class ReceiveConfirmDialog extends StatelessWidget {
  final Device sender;
  final List<Map<String, dynamic>> files;
  final int totalSize;
  final bool folderMode;

  const ReceiveConfirmDialog({
    super.key,
    required this.sender,
    required this.files,
    required this.totalSize,
    this.folderMode = false,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('接收文件'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 发送方信息
            Row(
              children: [
                const Icon(Icons.person, size: 20),
                const SizedBox(width: 8),
                Text(
                  sender.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                _buildPlatformBadge(sender.platform),
              ],
            ),
            const Divider(height: 24),
            // 统计
            Text(
              '${files.length} 个文件 · ${formatSize(totalSize)}',
              style: const TextStyle(fontSize: 14),
            ),
            if (folderMode) ...[
              const SizedBox(height: 4),
              Text('包含文件夹结构',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
            ],
            const SizedBox(height: 8),
            // 文件列表 (最多显示 10 个)
            ...files.take(10).map((f) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Icon(
                        Icons.insert_drive_file,
                        size: 16,
                        color: Colors.grey.shade500,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          f['relativePath'] as String? ?? 'unknown',
                          style: const TextStyle(fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        formatSize(f['size'] as int? ?? 0),
                        style: TextStyle(
                            fontSize: 12, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                )),
            if (files.length > 10)
              Text(
                '... 还有 ${files.length - 10} 个文件',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('拒绝'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('接受'),
        ),
      ],
    );
  }

  Widget _buildPlatformBadge(String platform) {
    final icon = platform == 'android' ? Icons.android : Icons.laptop;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14),
          const SizedBox(width: 4),
          Text(platform == 'android' ? 'Android' : 'Windows',
              style: const TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}
