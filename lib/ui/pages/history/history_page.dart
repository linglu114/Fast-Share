import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/history_record.dart';
import '../../../storage/history_repository.dart';
import '../../../providers/navigation_provider.dart';
import '../../../providers/discovery_provider.dart';
import '../../../util/format.dart';

/// 传输历史页 (需求 §28, §29)
///
/// 历史记录列表 + 一键重发 + 打开文件夹
class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  final _repository = HistoryRepository();
  List<HistoryRecord> _records = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  Future<void> _loadRecords() async {
    setState(() => _loading = true);
    final records = await _repository.getAll();
    setState(() {
      _records = records;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(currentTabProvider, (prev, next) {
      if (next == 2) _loadRecords();
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('历史'),
        actions: [
          if (_records.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              tooltip: '清空记录',
              onPressed: _clearAll,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _records.isEmpty
              ? RefreshIndicator(
                  onRefresh: _loadRecords,
                  child: ListView(
                    children: [
                      SizedBox(
                        height: MediaQuery.of(context).size.height * 0.6,
                        child: _buildEmptyState(),
                      ),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadRecords,
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _records.length,
                    itemBuilder: (_, i) => _buildRecordCard(_records[i]),
                  ),
                ),
    );
  }

  Widget _buildEmptyState() {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.6,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text('暂无传输记录',
                style: TextStyle(fontSize: 16, color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }

  Widget _buildRecordCard(HistoryRecord record) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ExpansionTile(
        leading: _buildStatusIcon(record),
        title: Text(
          record.batchName ?? '文件传输',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text(
              '${record.deviceName} · ${formatSize(record.totalSize)} · ${record.fileCount} 个文件',
              style: const TextStyle(fontSize: 12),
            ),
            Text(
              '${formatTime(record.timestamp)} · 峰值 ${formatSpeed(record.peakSpeed)} · 平均 ${formatSpeed(record.avgSpeed)}',
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ],
        ),
        children: [
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('重发', style: TextStyle(fontSize: 13)),
                  onPressed: record.status == 'completed'
                      ? () => _resendTransfer(record)
                      : null,
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  icon: const Icon(Icons.folder_open, size: 16),
                  label: const Text('打开', style: TextStyle(fontSize: 13)),
                  onPressed: () => _openFolder(record),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusIcon(HistoryRecord record) {
    return switch (record.status) {
      'completed' => const Icon(Icons.check_circle, color: Colors.green, size: 24),
      'failed' => const Icon(Icons.error, color: Colors.red, size: 24),
      'cancelled' => const Icon(Icons.cancel, color: Colors.grey, size: 24),
      'partial' => const Icon(Icons.warning, color: Colors.orange, size: 24),
      _ => const Icon(Icons.help, color: Colors.grey, size: 24),
    };
  }

  void _resendTransfer(HistoryRecord record) {
    final onlineDevices = ref.read(onlineDevicesProvider);
    final device = onlineDevices.where((d) => d.deviceId == record.deviceId).firstOrNull;

    if (device == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${record.deviceName} 不在线，无法重发'),
        ),
      );
      return;
    }

    ref.read(currentTabProvider.notifier).state = 1;

    Future.delayed(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              '请在传输页重新选择要发送到 ${record.deviceName} 的文件'),
          duration: const Duration(seconds: 2),
        ),
      );
    });
  }

  void _openFolder(HistoryRecord record) {
    final path = record.savePath;
    if (path.isEmpty) return;

    try {
      if (Directory(path).existsSync() || File(path).existsSync()) {
        if (Platform.isWindows) {
          Process.run('explorer', ['/select,', path]);
        } else if (Platform.isAndroid) {
          Process.run('am', [
            'start',
            '-a',
            'android.intent.action.VIEW',
            '-d',
            'content://$path',
          ]);
        } else {
          Process.run('open', [path]);
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('路径不存在: $path')),
        );
      }
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开文件夹')),
      );
    }
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空历史'),
        content: const Text('确定要清空所有传输历史记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _repository.clearAll();
      _loadRecords();
    }
  }
}
