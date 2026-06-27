import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../providers/settings_provider.dart';
import '../../../storage/settings_repository.dart';
import '../../../storage/trusted_device_repository.dart';

/// 设置页 (需求 §5,§12,§16,§21,§22,§32)
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final deviceName = ref.watch(deviceNameProvider);
    final darkMode = ref.watch(darkModeProvider);
    final speedLimit = ref.watch(speedLimitProvider);
    final concurrentCount = ref.watch(concurrentCountProvider);
    final retryCount = ref.watch(retryCountProvider);
    final serverPort = ref.watch(serverPortProvider);
    final lowBattery = ref.watch(lowBatteryProvider);
    final criticalBattery = ref.watch(criticalBatteryProvider);
    final thermalProtection = ref.watch(thermalProtectionProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: [
          _SectionHeader(title: '设备'),
          ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('设备名称'),
            subtitle: Text(deviceName),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _editDeviceName(context, ref),
          ),
          const Divider(),
          _SectionHeader(title: '传输'),
          ListTile(
            leading: const Icon(Icons.speed),
            title: const Text('传输限速'),
            subtitle: Text(_speedLabel(speedLimit)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickSpeedLimit(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.swap_vert),
            title: const Text('并发数'),
            subtitle: Text(concurrentCount == 0 ? '自动' : '$concurrentCount'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickConcurrentCount(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('失败重试次数'),
            subtitle: Text('$retryCount 次'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickRetryCount(context, ref),
          ),
          const Divider(),
          _SectionHeader(title: '安全与信任'),
          ListTile(
            leading: const Icon(Icons.verified_user),
            title: const Text('已知设备'),
            subtitle: const Text('管理信任设备列表'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showTrustedDevices(context, ref),
          ),
          const Divider(),
          _SectionHeader(title: '外观'),
          ListTile(
            leading: const Icon(Icons.dark_mode),
            title: const Text('深色模式'),
            subtitle: Text(_darkModeLabel(darkMode)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickDarkMode(context, ref),
          ),
          const Divider(),
          _SectionHeader(title: '保护'),
          ListTile(
            leading: const Icon(Icons.battery_alert),
            title: const Text('低电量提醒阈值'),
            subtitle: Text('$lowBattery%'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickBatteryThreshold(
                context, ref, true, lowBattery),
          ),
          ListTile(
            leading: const Icon(Icons.battery_charging_full),
            title: const Text('极低电量限制阈值'),
            subtitle: Text('$criticalBattery%'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickBatteryThreshold(
                context, ref, false, criticalBattery),
          ),
          ListTile(
            leading: const Icon(Icons.thermostat),
            title: const Text('温度保护'),
            subtitle: Text(thermalProtection ? '已启用' : '已关闭'),
            trailing: Switch(
              value: thermalProtection,
              onChanged: (v) =>
                  ref.read(thermalProtectionProvider.notifier).update(v),
            ),
          ),
          const Divider(),
          _SectionHeader(title: '存储'),
          ListTile(
            leading: const Icon(Icons.folder),
            title: const Text('下载保存路径'),
            subtitle: Text(ref.watch(downloadPathProvider)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _editDownloadPath(context, ref),
          ),
          const Divider(),
          _SectionHeader(title: '网络'),
          ListTile(
            leading: const Icon(Icons.lan),
            title: const Text('服务端口'),
            subtitle: Text('$serverPort'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _editPort(context, ref, serverPort),
          ),
          const Divider(),
          _SectionHeader(title: '关于'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('关于瞬息'),
            subtitle: const Text('版本 1.0.0'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showAboutDialog(context),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  // ═══ 编辑弹窗 ═══

  Future<void> _editDeviceName(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(
        text: ref.read(deviceNameProvider));
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设备名称'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 32,
          decoration: const InputDecoration(hintText: '输入设备名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null && result.isNotEmpty) {
      await ref.read(deviceNameProvider.notifier).update(result);
    }
  }

  Future<void> _pickSpeedLimit(BuildContext context, WidgetRef ref) async {
    final currentLimit = ref.read(speedLimitProvider);
    // 当前值：0 = 不限制，否则转换为 MB/s
    final initialUnlimited = currentLimit == 0;
    final initialMB = initialUnlimited ? 100 : (currentLimit ~/ (1024 * 1024)).clamp(1, 100);

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => _SpeedLimitDialog(
        initialUnlimited: initialUnlimited,
        initialMB: initialMB,
      ),
    );
    if (result != null) {
      final unlimited = result['unlimited'] as bool;
      final mb = result['mb'] as int;
      final bytesPerSecond = unlimited ? 0 : mb * 1024 * 1024;
      await ref.read(speedLimitProvider.notifier).update(bytesPerSecond);
    }
  }

  Future<void> _pickConcurrentCount(BuildContext context, WidgetRef ref) async {
    final selected = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('并发数'),
        children: [
          _countOption(ctx, 0, '自动'),
          for (final n in [3, 4, 5, 6, 7, 8])
            _countOption(ctx, n, '$n'),
        ],
      ),
    );
    if (selected != null) {
      await ref.read(concurrentCountProvider.notifier).update(selected);
    }
  }

  Widget _countOption(BuildContext context, int value, String label) {
    return SimpleDialogOption(
      onPressed: () => Navigator.pop(context, value),
      child: Text(label),
    );
  }

  Future<void> _pickRetryCount(BuildContext context, WidgetRef ref) async {
    final selected = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('失败重试次数'),
        children: [
          for (final n in [0, 1, 2, 3, 4, 5])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, n),
              child: Text('$n 次${n == 0 ? " (不重试)" : ""}'),
            ),
        ],
      ),
    );
    if (selected != null) {
      await ref.read(retryCountProvider.notifier).update(selected);
    }
  }

  Future<void> _pickDarkMode(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('深色模式'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'system'),
            child: const Text('跟随系统'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'light'),
            child: const Text('浅色模式'),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, 'dark'),
            child: const Text('深色模式'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final value = switch (result) {
      'system' => null,
      'light' => false,
      'dark' => true,
      _ => null,
    };
    // 需要区分 null(未选) 和 null(跟随系统)，只有明确选择才更新
    if (result == 'system' || result == 'light' || result == 'dark') {
      await ref.read(darkModeProvider.notifier).setDarkMode(value);
    }
  }

  Future<void> _pickBatteryThreshold(
    BuildContext context,
    WidgetRef ref,
    bool isLow,
    int current,
  ) async {
    final selected = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(isLow ? '低电量提醒阈值' : '极低电量限制阈值'),
        children: [
          for (final p in [5, 10, 15, 20, 25, 30])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p),
              child: Text('$p%'),
            ),
        ],
      ),
    );
    if (selected != null) {
      if (isLow) {
        await ref.read(lowBatteryProvider.notifier).update(selected);
      } else {
        await ref.read(criticalBatteryProvider.notifier).update(selected);
      }
    }
  }

  Future<void> _editPort(
      BuildContext context, WidgetRef ref, int current) async {
    final controller = TextEditingController(text: '$current');
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('服务端口'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: '1024-65535'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final port = int.tryParse(controller.text.trim());
              if (port != null && port >= 1024 && port <= 65535) {
                Navigator.pop(ctx, port);
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null) {
      await ref.read(serverPortProvider.notifier).update(result);
    }
  }

  Future<void> _editDownloadPath(BuildContext context, WidgetRef ref) async {
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => _DownloadPathDialog(
        currentPath: ref.read(downloadPathProvider),
        defaultPath: SettingsRepository.defaultDownloadPath,
      ),
    );
    if (result != null && result.isNotEmpty) {
      await ref.read(downloadPathProvider.notifier).update(result);
    }
  }

  Future<void> _showTrustedDevices(
      BuildContext context, WidgetRef ref) async {
    final repo = TrustedDeviceRepository();
    final devices = await repo.getAll();

    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('已知设备'),
        content: SizedBox(
          width: double.maxFinite,
          child: devices.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: Text('暂无信任设备')),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: devices.length,
                  itemBuilder: (_, i) {
                    final d = devices[i];
                    return ListTile(
                      leading: const Icon(Icons.devices),
                      title: Text(d.deviceName,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: const Text('已配对'),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: '删除设备',
                        onPressed: () async {
                          await repo.remove(d.deviceId);
                          Navigator.pop(ctx);
                          _showTrustedDevices(context, ref);
                        },
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  // ═══ 标签格式化 ═══

  String _speedLabel(int bytesPerSecond) {
    if (bytesPerSecond == 0) return '不限制';
    if (bytesPerSecond < 1024 * 1024) return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(0)} MB/s';
  }

  String _darkModeLabel(bool? value) {
    return switch (value) {
      null => '跟随系统',
      true => '深色模式',
      false => '浅色模式',
    };
  }
}

/// 下载路径编辑弹窗 — 路径选择器 + 恢复默认
class _DownloadPathDialog extends StatefulWidget {
  final String currentPath;
  final String defaultPath;
  const _DownloadPathDialog({required this.currentPath, required this.defaultPath});

  @override
  State<_DownloadPathDialog> createState() => _DownloadPathDialogState();
}

class _DownloadPathDialogState extends State<_DownloadPathDialog> {
  late String _path;

  @override
  void initState() {
    super.initState();
    _path = widget.currentPath;
  }

  Future<void> _pickFolder() async {
    final dir = await FilePicker.getDirectoryPath();
    if (dir != null && dir.isNotEmpty) {
      setState(() => _path = dir);
    }
  }

  void _restoreDefault() {
    setState(() => _path = widget.defaultPath);
  }

  @override
  Widget build(BuildContext context) {
    final isDefault = _path == widget.defaultPath;
    return AlertDialog(
      title: const Text('下载保存路径'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _path,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('浏览...'),
              onPressed: _pickFolder,
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: Icon(
                isDefault ? Icons.check_circle : Icons.restore,
                size: 18,
              ),
              label: const Text('恢复默认'),
              onPressed: isDefault ? null : _restoreDefault,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _path),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

void _showAboutDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.swap_horiz, size: 24),
          SizedBox(width: 8),
          Text('关于瞬息'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '瞬息 (FastShare)',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text('版本 1.0.0'),
          const SizedBox(height: 12),
          const Text(
            '基于 FLP 协议 (v1.2) 的局域网文件传输工具。\n'
            '支持 Android ↔ Windows 高速互传。',
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () => launchUrl(
              Uri.parse('https://github.com/linglu114/Fast-Share'),
              mode: LaunchMode.externalApplication,
            ),
            child: const Text(
              'https://github.com/linglu114/Fast-Share',
              style: TextStyle(
                fontSize: 12,
                color: Colors.blue,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

/// 传输限速设置弹窗 — 滑块 + 可点击编辑数值 + 不限制开关
class _SpeedLimitDialog extends StatefulWidget {
  final bool initialUnlimited;
  final int initialMB;
  const _SpeedLimitDialog({required this.initialUnlimited, required this.initialMB});

  @override
  State<_SpeedLimitDialog> createState() => _SpeedLimitDialogState();
}

class _SpeedLimitDialogState extends State<_SpeedLimitDialog> {
  late bool _unlimited;
  late int _mb;
  late int _lastMb; // 取消不限制后恢复的值
  late double _sliderValue;
  bool _editing = false;
  final _editController = TextEditingController();
  final _editFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _unlimited = widget.initialUnlimited;
    _mb = widget.initialMB;
    _lastMb = widget.initialMB;
    _sliderValue = _mb.toDouble();
    _editFocus.addListener(_onEditFocusLost);
  }

  @override
  void dispose() {
    _editFocus.removeListener(_onEditFocusLost);
    _editFocus.dispose();
    _editController.dispose();
    super.dispose();
  }

  void _onEditFocusLost() {
    if (!_editFocus.hasFocus) _commitEdit();
  }

  void _commitEdit() {
    final text = _editController.text.trim();
    final parsed = int.tryParse(text);
    final clamped = parsed?.clamp(1, 100) ?? _mb;
    setState(() {
      _mb = clamped;
      _lastMb = clamped;
      _sliderValue = clamped.toDouble();
      _editing = false;
    });
  }

  void _startEdit() {
    if (_unlimited) return;
    _editController.text = _mb.toString();
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _editFocus.requestFocus();
        _editController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _editController.text.length,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('传输限速'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 数值显示 / 编辑
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_editing)
                  SizedBox(
                    width: 64,
                    child: TextField(
                      controller: _editController,
                      focusNode: _editFocus,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: scheme.primary),
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _commitEdit(),
                    ),
                  )
                else
                  GestureDetector(
                    onTap: _unlimited ? null : _startEdit,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: _unlimited
                            ? Colors.grey.shade200
                            : scheme.primaryContainer.withAlpha(120),
                      ),
                      child: Text(
                        _unlimited ? '—' : '$_mb',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: _unlimited ? Colors.grey : scheme.primary,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                Text('MB/s',
                    style: TextStyle(fontSize: 15, color: _unlimited ? Colors.grey : null)),
              ],
            ),
            const SizedBox(height: 16),
            // 滑块
            Slider(
              value: _sliderValue,
              min: 1,
              max: 100,
              divisions: 99,
              onChanged: _unlimited
                  ? null
                  : (v) {
                      setState(() {
                        _sliderValue = v;
                        _mb = v.round();
                        _lastMb = _mb;
                      });
                      if (_editing) {
                        _editController.text = _mb.toString();
                      }
                    },
            ),
            // 最小/最大标签
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('1 MB/s', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                  Text('100 MB/s', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                ],
              ),
            ),
            // 不限制开关
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('不限制', style: TextStyle(fontSize: 14)),
              value: _unlimited,
              onChanged: (v) {
                setState(() {
                  _unlimited = v ?? false;
                  _editing = false;
                  if (!_unlimited) {
                    _mb = _lastMb;
                    _sliderValue = _lastMb.toDouble();
                  }
                });
              },
              controlAffinity: ListTileControlAffinity.leading,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, {
            'unlimited': _unlimited,
            'mb': _mb,
          }),
          child: const Text('确定'),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}
