import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../models/history_record.dart';
import '../../../storage/history_repository.dart';
import '../../../providers/navigation_provider.dart';
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
  final _expandedIds = <int>{}; // 展开的文件夹记录 ID

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
    final cs = Theme.of(context).colorScheme;
    final isExpanded = record.id != null && _expandedIds.contains(record.id);
    final isFolder = record.folderMode;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: _buildStatusIcon(record),
            title: Row(
              children: [
                if (isFolder)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Icon(Icons.folder, size: 16, color: cs.onSurfaceVariant),
                  ),
                Expanded(
                  child: Text(
                    record.batchName ?? '文件传输',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
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
            trailing: IconButton(
              icon: const Icon(Icons.open_in_new, size: 20),
              tooltip: '打开',
              onPressed: () => _openRecord(record),
            ),
            onTap: isFolder && record.id != null
                ? () => setState(() {
                      if (isExpanded) {
                        _expandedIds.remove(record.id);
                      } else {
                        _expandedIds.add(record.id!);
                      }
                    })
                : () => _openRecord(record),
          ),
          if (isFolder && isExpanded) ...[
            const Divider(height: 1),
            _FileList(savePath: record.savePath),
          ],
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

  /// 打开历史记录对应的文件或文件夹
  Future<void> _openRecord(HistoryRecord record) async {
    final path = record.savePath;
    if (path.isEmpty) return;

    final exists =
        await Directory(path).exists() || await File(path).exists();
    if (!exists) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('路径不存在: $path')),
        );
      }
      return;
    }

    try {
      if (Platform.isWindows) {
        // 文件夹 → 资源管理器；单文件 → 系统默认应用打开
        if (record.folderMode) {
          await Process.run('explorer', [path]);
        } else {
          await Process.run('cmd', ['/c', 'start', '', path]);
        }
      } else if (Platform.isAndroid) {
        await _platformChannel.invokeMethod('openFile', {'path': path});
      } else {
        await Process.run('open', [path]);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开文件')),
        );
      }
    }
  }

  static const _platformChannel = MethodChannel('com.fastshare/platform');

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

/// 文件夹展开后的文件列表
/// 读取 savePath 目录下的文件，每个文件可点击打开
class _FileList extends StatelessWidget {
  final String savePath;
  const _FileList({required this.savePath});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    List<FileSystemEntity> entries;
    try {
      entries = Directory(savePath).listSync();
      entries.sort((a, b) {
        final aIsDir = a is Directory;
        final bIsDir = b is Directory;
        if (aIsDir && !bIsDir) return -1;
        if (!aIsDir && bIsDir) return 1;
        return a.path.compareTo(b.path);
      });
    } catch (_) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('无法读取文件夹内容',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
      );
    }

    if (entries.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('文件夹为空',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in entries)
            _FileRow(
              entry: entry,
              cs: cs,
              onTap: () => _openFileEntry(context, entry.path),
            ),
        ],
      ),
    );
  }

  void _openFileEntry(BuildContext context, String path) async {
    try {
      if (Platform.isWindows) {
        if (Directory(path).existsSync()) {
          await Process.run('explorer', [path]);
        } else {
          await Process.run('cmd', ['/c', 'start', '', path]);
        }
      } else if (Platform.isAndroid) {
        await const MethodChannel('com.fastshare/platform')
            .invokeMethod('openFile', {'path': path});
      } else {
        await Process.run('open', [path]);
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法打开文件')),
        );
      }
    }
  }
}

/// 文件列表中的单个文件行
class _FileRow extends StatelessWidget {
  final FileSystemEntity entry;
  final ColorScheme cs;
  final VoidCallback onTap;

  const _FileRow({
    required this.entry,
    required this.cs,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDir = entry is Directory;
    final name = entry.path.split(RegExp(r'[/\\]')).last;
    final sizeStr = isDir
        ? ''
        : (() {
            try {
              return formatSize((entry as File).lengthSync());
            } catch (_) {
              return '';
            }
          })();

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
              isDir ? Icons.folder : Icons.insert_drive_file,
              size: 16,
              color: isDir ? Colors.amber.shade700 : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                name,
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (sizeStr.isNotEmpty)
              Text(
                sizeStr,
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}
