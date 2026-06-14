import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'models/device.dart';
import 'ui/pages/devices/devices_page.dart';
import 'ui/pages/transfer/transfer_page.dart';
import 'ui/pages/transfer/receive_confirm_dialog.dart';
import 'ui/pages/history/history_page.dart';
import 'ui/pages/settings/settings_page.dart';
import 'ui/widgets/performance_guard_indicator.dart';
import 'models/transfer_task.dart';
import 'platform/foreground_service_manager.dart';
import 'providers/settings_provider.dart';
import 'providers/connection_provider.dart';
import 'providers/discovery_provider.dart';
import 'providers/transfer_provider.dart';
import 'providers/navigation_provider.dart';
import 'providers/clipboard_provider.dart';
import 'providers/battery_thermal_provider.dart';
import 'main.dart'; // for pendingShareFilesProvider

/// 应用入口 — 深色模式完善 (需求 §32)
///
/// 跟随系统 + 手动切换 + 全页面适配
class FastShareApp extends ConsumerStatefulWidget {
  const FastShareApp({super.key});

  @override
  ConsumerState<FastShareApp> createState() => _FastShareAppState();
}

class _FastShareAppState extends ConsumerState<FastShareApp>
    with WidgetsBindingObserver {
  final _pages = <Widget>[
    const DevicesPage(),
    const TransferPage(),
    const HistoryPage(),
    const SettingsPage(),
  ];

  final _navigatorKey = GlobalKey<NavigatorState>();
  TransferOffer? _lastShownOffer;
  bool _criticalDialogShownThisEpisode = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // ── 系统分享入口 ──
    if (const bool.fromEnvironment('dart.vm.product') || true) {
      // Always register: product mode for real use, debug for testing
      final shareChannel = const MethodChannel('fastshare/share');
      shareChannel.setMethodCallHandler((call) async {
        if (call.method == 'onShareReceived') {
          final files = (call.arguments as List?)
              ?.map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          if (files != null && files.isNotEmpty && mounted) {
            ref.read(pendingShareFilesProvider.notifier).state = files;
            _handleSharedFiles(files);
          }
        }
      });

      // Cold start: poll for pending share data from launch intent
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try {
          final result = await shareChannel.invokeMethod('getPendingShare');
          if (result is List && result.isNotEmpty && mounted) {
            final files = result
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
            ref.read(pendingShareFilesProvider.notifier).state = files;
            _handleSharedFiles(files);
          }
        } catch (_) {}
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _onAppBackground();
    } else if (state == AppLifecycleState.resumed) {
      _onAppForeground();
    }
  }

  void _onAppBackground() {
    final activeTransfer = ref.read(activeTransferProvider);
    final receiveTransfer = ref.read(receiveTransferProvider);
    final serverPort = ref.read(activeServerPortProvider);
    final hasActiveWork = activeTransfer != null ||
        receiveTransfer != null ||
        serverPort > 0;

    if (!hasActiveWork) return;

    String title = '瞬息';
    String body = 'Running in background';
    if (activeTransfer != null &&
        activeTransfer.status == TransferStatus.transferring) {
      body = '发送文件中…';
    } else if (receiveTransfer != null &&
        receiveTransfer.status == TransferStatus.transferring) {
      body = '接收文件中…';
    }

    ForegroundServiceManager().start(title: title, body: body);
  }

  void _onAppForeground() {
    ForegroundServiceManager().stop();

    // 延迟触发发现刷新，快速恢复设备列表
    Future.delayed(const Duration(milliseconds: 500), () {
      if (mounted) {
        ref.read(onlineDevicesProvider.notifier).refreshNow();
      }
    });
  }

  /// 系统分享入口 — 收到文件后弹出设备选择器并开始传输
  void _handleSharedFiles(List<Map<String, dynamic>> files) {
    // 切换到传输页
    ref.read(currentTabProvider.notifier).state = 1;

    // 等一帧让 UI 稳定后弹出设备选择器
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      final onlineDevices = ref.read(onlineDevicesProvider);
      if (onlineDevices.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('暂无在线设备，请确保设备在同一网络')),
          );
        }
        return;
      }

      final navigator = _navigatorKey.currentState;
      if (navigator == null) return;

      final device = await showModalBottomSheet<Device>(
        context: navigator.context,
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
              ...onlineDevices.map((d) => ListTile(
                    leading: CircleAvatar(
                      backgroundColor: d.platform == 'android'
                          ? Colors.green.shade100
                          : Colors.blue.shade100,
                      child: Icon(
                        d.platform == 'android'
                            ? Icons.android
                            : Icons.laptop,
                        size: 22,
                      ),
                    ),
                    title: Text(d.name),
                    subtitle: Text(d.ip),
                    onTap: () => Navigator.pop(ctx, d),
                  )),
              const SizedBox(height: 16),
            ],
          ),
        ),
      );

      if (device == null || !mounted) return;

      // 确保连接
      final isConnected = ref.read(connectionStateProvider)[device.deviceId] == true;
      if (!isConnected) {
        try {
          await ref.read(connectionStateProvider.notifier).connect(device);
        } catch (_) {}
      }

      if (!mounted) return;

      // 开始传输
      await ref.read(transferNotifierProvider.notifier).startTransfer(
        paths: [],
        contentFiles: files,
        targetDevice: device,
        folderMode: false,
        ref: ref,
      );

      // 清除 pending 状态
      ref.read(pendingShareFilesProvider.notifier).state = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final darkMode = ref.watch(darkModeProvider);
    final currentIndex = ref.watch(currentTabProvider);
    final pendingOffer = ref.watch(pendingOfferProvider);
    ref.watch(clipboardAutoReceiveProvider);
    final batteryThermal = ref.watch(batteryThermalProvider);

    if (pendingOffer != null && pendingOffer != _lastShownOffer) {
      _lastShownOffer = pendingOffer;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ref.read(pendingOfferProvider) == pendingOffer) {
          _showReceiveConfirmDialog(pendingOffer);
        }
      });
    }

    // 极低电量弹窗（每轮电量下降事件只弹一次）
    if (batteryThermal.isCriticalBattery &&
        !batteryThermal.dialogDismissedByUser &&
        !_criticalDialogShownThisEpisode) {
      _criticalDialogShownThisEpisode = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showCriticalBatteryDialog(batteryThermal.batteryLevel?.toString() ?? '?');
        }
      });
    }
    if (!batteryThermal.isCriticalBattery) {
      _criticalDialogShownThisEpisode = false;
    }

    ThemeMode themeMode;
    if (darkMode == true) {
      themeMode = ThemeMode.dark;
    } else if (darkMode == false) {
      themeMode = ThemeMode.light;
    } else {
      themeMode = ThemeMode.system;
    }

    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: '瞬息',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.light,
        fontFamily: 'HarmonyOS Sans SC',
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: 'HarmonyOS Sans SC',
      ),
      themeMode: themeMode,
      home: Scaffold(
        body: Stack(
          children: [
            _pages[currentIndex],
            // 低电量通知条（非极端低电量）—— 与刷新按钮同层，状态栏下方
            if (batteryThermal.isLowBattery && !batteryThermal.isCriticalBattery)
              Positioned(
                top: MediaQuery.of(context).padding.top,
                left: 0, right: 0,
                child: _LowBatteryBanner(
                  batteryLevel: batteryThermal.batteryLevel?.toString() ?? '?',
                ),
              ),
            // 性能限制 indicator — 状态栏下方右上角
            if (batteryThermal.activeLimits.isNotEmpty)
              Positioned(
                top: MediaQuery.of(context).padding.top + 8,
                right: 12,
                child: PerformanceGuardIndicator(
                  activeLimits: batteryThermal.activeLimits,
                  onTap: () =>
                      _showPerformanceGuardDetails(batteryThermal.activeLimits),
                ),
              ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: currentIndex,
          onDestinationSelected: (index) {
            ref.read(currentTabProvider.notifier).state = index;
          },
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.devices),
              selectedIcon: Icon(Icons.devices),
              label: '设备',
            ),
            NavigationDestination(
              icon: Icon(Icons.swap_horiz),
              selectedIcon: Icon(Icons.swap_horiz),
              label: '传输',
            ),
            NavigationDestination(
              icon: Icon(Icons.history),
              selectedIcon: Icon(Icons.history),
              label: '历史',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings),
              selectedIcon: Icon(Icons.settings),
              label: '设置',
            ),
          ],
        ),
      ),
    );
  }

  void _showReceiveConfirmDialog(TransferOffer offer) {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;

    final onlineDevices = ref.read(onlineDevicesProvider);
    final sender = onlineDevices
        .where((d) => d.deviceId == offer.senderDeviceId)
        .firstOrNull;

    showDialog<bool>(
      context: navigator.context,
      barrierDismissible: false,
      builder: (ctx) => ReceiveConfirmDialog(
        sender: sender ??
            Device(
              deviceId: offer.senderDeviceId,
              name: offer.senderDeviceName ?? offer.senderDeviceId,
              ip: '',
              port: 0,
              platform: 'unknown',
              protocolVersion: 1,
              lastSeen: DateTime.now(),
            ),
        files: offer.files,
        totalSize: offer.totalSize,
        folderMode: offer.folderMode,
      ),
    ).then((accepted) {
      final notifier = ref.read(connectionStateProvider.notifier);
      if (accepted == true) {
        notifier.acceptPendingOffer();
      } else {
        notifier.rejectPendingOffer();
      }
    });
  }

  void _showPerformanceGuardDetails(List<PerformanceLimit> limits) {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    showDialog(
      context: navigator.context,
      builder: (ctx) => PerformanceGuardDetailsDialog(limits: limits),
    );
  }

  void _showCriticalBatteryDialog(String batteryLevel) {
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;

    showDialog(
      context: navigator.context,
      barrierDismissible: false,
      builder: (ctx) => _CriticalBatteryDialog(
        batteryLevel: batteryLevel,
        onDismiss: () {
          ref.read(batteryThermalProvider.notifier).dismissCriticalDialog();
        },
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 低电量通知条
// ═══════════════════════════════════════════════════════════════

class _LowBatteryBanner extends StatefulWidget {
  final String batteryLevel;
  const _LowBatteryBanner({required this.batteryLevel});

  @override
  State<_LowBatteryBanner> createState() => _LowBatteryBannerState();
}

class _LowBatteryBannerState extends State<_LowBatteryBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();

    return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: Colors.amber.shade100,
        child: Row(
          children: [
            Icon(Icons.battery_alert, size: 18, color: Colors.amber.shade900),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '电量仅剩 ${widget.batteryLevel}%，建议连接充电器',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.amber.shade900,
                ),
              ),
            ),
            GestureDetector(
              onTap: () => setState(() => _dismissed = true),
              child: Icon(Icons.close, size: 18, color: Colors.amber.shade900),
            ),
          ],
        ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
// 极低电量倒计时弹窗
// ═══════════════════════════════════════════════════════════════

class _CriticalBatteryDialog extends StatefulWidget {
  final String batteryLevel;
  final VoidCallback onDismiss;
  const _CriticalBatteryDialog({
    required this.batteryLevel,
    required this.onDismiss,
  });

  @override
  State<_CriticalBatteryDialog> createState() => _CriticalBatteryDialogState();
}

class _CriticalBatteryDialogState extends State<_CriticalBatteryDialog> {
  int _secondsLeft = 10;
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_secondsLeft > 0) {
        setState(() => _secondsLeft--);
      } else {
        _timer.cancel();
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.battery_alert, color: Colors.red, size: 24),
          SizedBox(width: 8),
          Text('极低电量'),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '当前电量仅剩 ${widget.batteryLevel}%，'
            '传输速度已自动限制为 1 MB/s 以保护设备。',
            style: const TextStyle(fontSize: 14),
          ),
          const SizedBox(height: 16),
          Text(
            '${_secondsLeft}s 后自动确认',
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            _timer.cancel();
            widget.onDismiss();
            Navigator.of(context).pop();
          },
          child: const Text('取消限制'),
        ),
        if (_secondsLeft <= 0)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('知道了'),
          ),
      ],
    );
  }
}
