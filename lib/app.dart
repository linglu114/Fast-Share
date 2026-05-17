import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'models/device.dart';
import 'ui/pages/devices/devices_page.dart';
import 'ui/pages/transfer/transfer_page.dart';
import 'ui/pages/transfer/receive_confirm_dialog.dart';
import 'ui/pages/history/history_page.dart';
import 'ui/pages/settings/settings_page.dart';
import 'providers/settings_provider.dart';
import 'providers/connection_provider.dart';
import 'providers/discovery_provider.dart';
import 'providers/navigation_provider.dart';

/// 应用入口 — 深色模式完善 (需求 §32)
///
/// 跟随系统 + 手动切换 + 全页面适配
class FastShareApp extends ConsumerStatefulWidget {
  const FastShareApp({super.key});

  @override
  ConsumerState<FastShareApp> createState() => _FastShareAppState();
}

class _FastShareAppState extends ConsumerState<FastShareApp> {
  final _pages = <Widget>[
    const DevicesPage(),
    const TransferPage(),
    const HistoryPage(),
    const SettingsPage(),
  ];

  TransferOffer? _lastShownOffer;

  @override
  Widget build(BuildContext context) {
    final darkMode = ref.watch(darkModeProvider);
    final currentIndex = ref.watch(currentTabProvider);
    final pendingOffer = ref.watch(pendingOfferProvider);

    if (pendingOffer != null && pendingOffer != _lastShownOffer) {
      _lastShownOffer = pendingOffer;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ref.read(pendingOfferProvider) == pendingOffer) {
          _showReceiveConfirmDialog(context, pendingOffer);
        }
      });
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
      title: 'FastShare',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.blue,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      themeMode: themeMode,
      home: Scaffold(
        body: _pages[currentIndex],
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

  void _showReceiveConfirmDialog(BuildContext context, TransferOffer offer) {
    final onlineDevices = ref.read(onlineDevicesProvider);
    final sender = onlineDevices.where((d) => d.deviceId == offer.senderDeviceId).firstOrNull;

    showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ReceiveConfirmDialog(
        sender: sender ?? Device(
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
}
