import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import '../../../models/transfer_task.dart';
import '../../../models/device.dart';
import '../../../platform/content_uri_reader.dart';
import '../../../providers/transfer_provider.dart';
import '../../../providers/connection_provider.dart';
import '../../../providers/discovery_provider.dart';
import '../../../util/format.dart';

/// 传输页 (需求 §9-§12, §15)
class TransferPage extends ConsumerStatefulWidget {
  const TransferPage({super.key});

  @override
  ConsumerState<TransferPage> createState() => _TransferPageState();
}

class _TransferPageState extends ConsumerState<TransferPage> {
  @override
  Widget build(BuildContext context) {
    final activeTask = ref.watch(activeTransferProvider);
    final receiveTask = ref.watch(receiveTransferProvider);

    final showActive =
        activeTask != null || receiveTask != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('传输'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '发送文件/文件夹',
            onPressed: () => _showSendOptions(context, ref),
          ),
        ],
      ),
      body: DropTarget(
        onDragDone: (detail) => _onDragDone(context, ref, detail),
        child: Container(
          color: Colors.transparent,
          child: !showActive
              ? const _EmptyState()
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (receiveTask != null) ...[
                      _ReceiveTransferCard(task: receiveTask, ref: ref),
                      const SizedBox(height: 16),
                    ],
                    if (activeTask != null) ...[
                      _ActiveTransferCard(task: activeTask, ref: ref),
                      const SizedBox(height: 16),
                    ],
                  ],
                ),
        ),
      ),
    );
  }

  Future<void> _showSendOptions(BuildContext context, WidgetRef ref) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('发送内容',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.insert_drive_file),
              title: const Text('发送文件'),
              subtitle: const Text('选择一个或多个文件'),
              onTap: () => Navigator.pop(ctx, 'files'),
            ),
            ListTile(
              leading: const Icon(Icons.folder),
              title: const Text('发送文件夹'),
              subtitle: const Text('选择整个文件夹'),
              onTap: () => Navigator.pop(ctx, 'folder'),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );

    if (choice == null || !context.mounted) return;

    if (choice == 'files') {
      await _pickFilesAndSend(context, ref);
    } else if (choice == 'folder') {
      await _pickFolderAndSend(context, ref);
    }
  }

  Future<void> _pickFilesAndSend(BuildContext context, WidgetRef ref) async {
    if (ContentUriReader.isSupported) {
      final files = await ContentUriReader.pickFiles();
      if (files.isEmpty) return;
      await _selectDeviceAndSend(context, ref, [], false,
          contentFiles: files);
      return;
    }
    // Fallback for non-Android platforms
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.any,
    );

    if (result == null || result.files.isEmpty) return;

    final paths = result.files
        .where((f) => f.path != null)
        .map((f) => f.path!)
        .toList();

    if (paths.isEmpty) return;
    await _selectDeviceAndSend(context, ref, paths, false);
  }

  Future<void> _pickFolderAndSend(BuildContext context, WidgetRef ref) async {
    if (ContentUriReader.isSupported) {
      // Android: SAF tree picker avoids filesystem permission issues
      final contentFiles = await ContentUriReader.pickFolder();
      if (contentFiles == null) return; // user cancelled
      if (contentFiles.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('所选文件夹为空或无法读取，请检查权限')),
          );
        }
        return;
      }
      await _selectDeviceAndSend(context, ref, [], true,
          contentFiles: contentFiles);
    } else {
      // Desktop / iOS: FilePicker returns a real filesystem path
      final path = await FilePicker.getDirectoryPath();
      if (path == null) return;
      await _selectDeviceAndSend(context, ref, [path], true);
    }
  }

  void _onDragDone(
      BuildContext context, WidgetRef ref, DropDoneDetails detail) {
    final paths = detail.files
        .map((f) => f.path)
        .where((p) => p.isNotEmpty)
        .toList();
    if (paths.isEmpty) return;
    _selectDeviceAndSend(context, ref, paths, false);
  }

  Future<void> _selectDeviceAndSend(BuildContext context, WidgetRef ref,
      List<String> paths, bool folderMode,
      {List<Map<String, dynamic>>? contentFiles}) async {
    final device = await _showDevicePicker(context, ref);
    if (device == null) return;

    if (!context.mounted) return;

    // 确保设备已连接（首次使用时需要先建立发现连接）
    final isConnected = ref.read(connectionStateProvider)[device.deviceId] == true;
    if (!isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('正在连接 ${device.name}...'), duration: const Duration(seconds: 1)),
      );
      try {
        await ref.read(connectionStateProvider.notifier).connect(device);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('连接失败: $e')),
          );
        }
        return;
      }
    }

    if (context.mounted) {
      final notifier = ref.read(transferNotifierProvider.notifier);
      await notifier.startTransfer(
        paths: paths,
        contentFiles: contentFiles,
        targetDevice: device,
        folderMode: folderMode,
        ref: ref,
      );
    }
  }

  Future<Device?> _showDevicePicker(
      BuildContext context, WidgetRef ref) async {
    final onlineDevices = ref.read(onlineDevicesProvider);

    if (onlineDevices.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('暂无在线设备，请确保设备在同一网络')),
        );
      }
      return null;
    }

    return showModalBottomSheet<Device>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('选择目标设备',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            ),
            const Divider(height: 1),
            ...onlineDevices.map((device) => ListTile(
                  leading: CircleAvatar(
                    backgroundColor: device.platform == 'android'
                        ? Colors.green.shade100
                        : Colors.blue.shade100,
                    child: Icon(
                      device.platform == 'android'
                          ? Icons.android
                          : Icons.laptop,
                      size: 22,
                    ),
                  ),
                  title: Text(device.name),
                  subtitle: Text(device.ip),
                  onTap: () => Navigator.pop(ctx, device),
                )),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud_off, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          Text('暂无传输任务',
              style: TextStyle(fontSize: 16, color: Colors.grey.shade600)),
          const SizedBox(height: 8),
          Text('点击右上角 + 选择文件发送',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
        ],
      ),
    );
  }
}

class _ActiveTransferCard extends StatelessWidget {
  final TransferTask task;
  final WidgetRef ref;

  const _ActiveTransferCard({required this.task, required this.ref});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 头部：目标设备 + 状态 ──
            Row(
              children: [
                const Icon(Icons.swap_horiz, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    task.batchName ?? '文件传输',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                  ),
                ),
                _buildStatusChip(task.status),
              ],
            ),
            const SizedBox(height: 4),
            Text('发送到: ${task.peerDeviceName ?? task.targetDeviceId}',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            const SizedBox(height: 2),
            Text('${task.fileCount} 个文件 · ${formatSize(task.totalSize)}',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            // ── 当前传输文件 ──
            if (task.files.isNotEmpty) ...[
              const SizedBox(height: 8),
              ..._buildActiveFiles(task, cs),
            ],
            const SizedBox(height: 12),
            // ── 进度条 ──
            LinearProgressIndicator(
              value: task.progress,
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${formatSize(task.bytesTransferred)} / ${formatSize(task.totalSize)}',
                  style: const TextStyle(fontSize: 13),
                ),
                Text(
                  '${(task.progress * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                _SpeedChip(bytesPerSecond: task.avgSpeed),
                const SizedBox(width: 12),
                if (task.avgSpeed > 0)
                  Text(
                    formatEta(task.totalSize, task.bytesTransferred, task.avgSpeed),
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                const Spacer(),
                Text(
                  '${task.files.where((f) => f.status == TransferStatus.completed).length}/${task.fileCount} 完成',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
            if (task.errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(task.errorMessage!,
                    style: TextStyle(fontSize: 12, color: Colors.red.shade700)),
              ),
            const SizedBox(height: 8),
            _buildActions(task, ref),
          ],
        ),
      ),
    );
  }

  Widget _buildActions(TransferTask task, WidgetRef ref) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (task.status == TransferStatus.transferring)
          IconButton(
              icon: const Icon(Icons.pause, size: 20),
              tooltip: '暂停',
              onPressed: () =>
                  ref.read(transferNotifierProvider.notifier).pauseTransfer(task.transferId)),
        if (task.status == TransferStatus.paused)
          IconButton(
              icon: const Icon(Icons.play_arrow, size: 20),
              tooltip: '继续',
              onPressed: () =>
                  ref.read(transferNotifierProvider.notifier).resumeTransfer(task.transferId)),
        if (task.status == TransferStatus.transferring ||
            task.status == TransferStatus.paused ||
            task.status == TransferStatus.awaitingAccept ||
            task.status == TransferStatus.connecting ||
            task.status == TransferStatus.scanning)
          IconButton(
              icon: const Icon(Icons.close, size: 20),
              tooltip: '取消',
              onPressed: () =>
                  ref.read(transferNotifierProvider.notifier).cancelTransfer(task.transferId)),
        if (task.status == TransferStatus.completed ||
            task.status == TransferStatus.failed ||
            task.status == TransferStatus.cancelled ||
            task.status == TransferStatus.rejected)
          TextButton(
            onPressed: () {
              ref.read(activeTransferProvider.notifier).state = null;
              final queue = ref.read(transferQueueProvider);
              ref.read(transferQueueProvider.notifier).state =
                  queue.where((t) => t.transferId != task.transferId).toList();
            },
            child: const Text('关闭'),
          ),
      ],
    );
  }

  Widget _buildStatusChip(TransferStatus status) => _sharedStatusChip(status);
}

class _ReceiveTransferCard extends StatelessWidget {
  final TransferTask task;
  final WidgetRef ref;
  const _ReceiveTransferCard({required this.task, required this.ref});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 头部：来源 + 状态 ──
            Row(
              children: [
                const Icon(Icons.swap_horiz, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    task.batchName ?? '文件传输',
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                  ),
                ),
                _buildStatusChip(task.status),
              ],
            ),
            const SizedBox(height: 4),
            Text('来自: ${task.peerDeviceName ?? task.senderDeviceId}',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            const SizedBox(height: 2),
            Text('${task.fileCount} 个文件 · ${formatSize(task.totalSize)}',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
            // ── 当前传输文件 ──
            if (task.files.isNotEmpty) ...[
              const SizedBox(height: 8),
              ..._buildActiveFiles(task, cs),
            ],
            const SizedBox(height: 12),
            // ── 进度条 ──
            LinearProgressIndicator(
              value: task.progress,
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${formatSize(task.bytesTransferred)} / ${formatSize(task.totalSize)}',
                  style: const TextStyle(fontSize: 13),
                ),
                Text(
                  '${(task.progress * 100).toStringAsFixed(1)}%',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                _SpeedChip(bytesPerSecond: task.avgSpeed),
                const SizedBox(width: 12),
                if (task.avgSpeed > 0)
                  Text(formatEta(task.totalSize, task.bytesTransferred, task.avgSpeed),
                      style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
                const Spacer(),
                Text(
                  '${task.files.where((f) => f.status == TransferStatus.completed).length}/${task.fileCount} 完成',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
            if (task.errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(task.errorMessage!,
                    style: TextStyle(fontSize: 12, color: Colors.red.shade700)),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text('保存到 ${task.savePath}',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                ),
                if (task.status == TransferStatus.transferring)
                  IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      tooltip: '取消',
                      onPressed: () => ref
                          .read(connectionStateProvider.notifier)
                          .cancelReceiveTransfer(task.senderDeviceId, task.transferId)),
                if (task.status == TransferStatus.completed ||
                    task.status == TransferStatus.failed ||
                    task.status == TransferStatus.cancelled ||
                    task.status == TransferStatus.rejected)
                  TextButton(
                    onPressed: () =>
                        ref.read(receiveTransferProvider.notifier).state = null,
                    child: const Text('关闭'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip(TransferStatus status) => _sharedStatusChip(status);
}

/// 共享的状态标签组件
Widget _sharedStatusChip(TransferStatus status) {
  final (label, color) = switch (status) {
    TransferStatus.scanning => ('扫描中', Colors.orange),
    TransferStatus.connecting => ('连接中', Colors.orange),
    TransferStatus.awaitingAccept => ('等待接受', Colors.orange),
    TransferStatus.accepted => ('已接受', Colors.lightGreen),
    TransferStatus.rejected => ('已拒绝', Colors.red),
    TransferStatus.transferring => ('传输中', Colors.blue),
    TransferStatus.paused => ('已暂停', Colors.orange),
    TransferStatus.completed => ('完成', Colors.green),
    TransferStatus.failed => ('失败', Colors.red),
    TransferStatus.cancelled => ('已取消', Colors.grey),
    _ => ('等待中', Colors.grey),
  };
  return Chip(
    label: Text(label, style: const TextStyle(fontSize: 12, color: Colors.white)),
    backgroundColor: color,
    padding: EdgeInsets.zero,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
}

/// 提取路径中的文件名（去掉文件夹前缀）
String _basename(String path) {
  final parts = path.split(RegExp(r'[/\\]'));
  return parts.last;
}

/// 构建当前正在传输的文件指示器
/// 只显示尚未完成的文件的文件名，不显示文件夹路径
List<Widget> _buildActiveFiles(TransferTask task, ColorScheme cs) {
  final active = task.files
      .where((f) =>
          f.status != TransferStatus.completed &&
          f.status != TransferStatus.failed &&
          f.status != TransferStatus.cancelled)
      .toList();

  if (active.isEmpty) return [];

  final f = active.first;
  final name = _basename(f.relativePath);
  final remaining = active.length - 1;

  final widgets = <Widget>[
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          Icon(Icons.sync, size: 14, color: cs.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              name,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            formatSize(f.size),
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    ),
  ];

  if (remaining > 0) {
    widgets.add(
      Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          '还有 $remaining 个文件等待传输',
          style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
        ),
      ),
    );
  }

  return widgets;
}

class _SpeedChip extends StatelessWidget {
  final double bytesPerSecond;
  const _SpeedChip({required this.bytesPerSecond});

  @override
  Widget build(BuildContext context) {
    final text = formatSpeed(bytesPerSecond);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child:
          Text(text, style: TextStyle(fontSize: 12, color: Colors.blue.shade700)),
    );
  }
}
