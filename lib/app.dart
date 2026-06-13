import 'dart:async';
import 'package:flutter/material.dart';
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
            // 低电量通知条（非极端低电量）
            if (batteryThermal.isLowBattery && !batteryThermal.isCriticalBattery)
              Positioned(
                top: 0, left: 0, right: 0,
                child: _LowBatteryBanner(
                  batteryLevel: batteryThermal.batteryLevel?.toString() ?? '?',
                ),
              ),
            // 性能限制 indicator（右上角浮动）
            if (batteryThermal.activeLimits.isNotEmpty)
              Positioned(
                top: 8, right: 12,
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

    return SafeArea(
      child: Container(
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
