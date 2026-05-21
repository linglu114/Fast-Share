import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../../engine/pairing.dart';
import '../../../models/device.dart';
import '../../../business/connection/connection_manager.dart';
import '../../../providers/discovery_provider.dart';
import '../../../providers/connection_provider.dart';
import '../../../providers/settings_provider.dart';
import '../../../providers/transfer_provider.dart';
import '../../../providers/clipboard_provider.dart';
import '../../../storage/trusted_device_repository.dart';
import 'pairing_dialog.dart';

/// 根据 deviceId 生成稳定的 6 位短码
String generateShortCode(String deviceId) {
  final hex = deviceId.replaceAll('-', '').substring(0, 8);
  final hash = int.parse(hex, radix: 16);
  return (hash % 900000 + 100000).toString();
}

/// 设备与发现页
class DevicesPage extends ConsumerStatefulWidget {
  const DevicesPage({super.key});

  @override
  ConsumerState<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends ConsumerState<DevicesPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _dotAnim;
  StreamSubscription<PairRequest>? _pairReqSub;
  StreamSubscription<PairResult>? _pairResultSub;
  bool _pairDialogShowing = false;
  BuildContext? _pinDialogContext;

  @override
  void initState() {
    super.initState();
    _dotAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    // 订阅配对事件（等第一次 build 后 ref 可用）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pairReqSub = ref
          .read(connectionStateProvider.notifier)
          .pairRequestStream
          .listen(_onIncomingPairRequest);
      _pairResultSub = ref
          .read(connectionStateProvider.notifier)
          .pairResultStream
          .listen(_onPairResult);
    });
  }

  @override
  void dispose() {
    _dotAnim.dispose();
    _pairReqSub?.cancel();
    _pairResultSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onlineDevices = ref.watch(onlineDevicesProvider);
    final connectionStates = ref.watch(connectionStateProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('设备'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新设备列表',
            onPressed: () {
              ref.read(onlineDevicesProvider.notifier).refreshNow();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('正在扫描局域网设备...'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.qr_code),
            tooltip: '二维码 / 短码 / 扫码',
            onPressed: () => _showUnifiedQrSheet(context, ref),
          ),
        ],
      ),
      body: onlineDevices.isEmpty
          ? _buildEmptyState()
          : RefreshIndicator(
              onRefresh: () async {
                await ref.read(onlineDevicesProvider.notifier).refreshNow();
              },
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _SectionHeader(title: '在线设备', count: onlineDevices.length),
                  ...onlineDevices.map((d) => _buildDeviceTile(
                        context,
                        ref,
                        d,
                        isOnline: true,
                        isConnected: connectionStates[d.deviceId] == true,
                      )),
                ],
              ),
            ),
    );
  }

  // ═══ 空状态 ═══

  Widget _buildEmptyState() {
    final ip = ref.watch(onlineDevicesProvider.notifier).localIp;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.search_off, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          AnimatedBuilder(
            animation: _dotAnim,
            builder: (_, child) {
              final dots = '.' * ((_dotAnim.value * 3).floor() % 4);
              return Text(
                '正在发现局域网设备$dots',
                style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
              );
            },
          ),
          const SizedBox(height: 8),
          Text('确保设备在同一 Wi-Fi 网络',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
          if (ip != null) ...[
            const SizedBox(height: 4),
            Text('本机 IP: $ip',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          ],
          const SizedBox(height: 24),
          OutlinedButton.icon(
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('立即刷新'),
            onPressed: () {
              ref.read(onlineDevicesProvider.notifier).refreshNow();
            },
          ),
        ],
      ),
    );
  }

  // ═══ 设备卡片 ═══

  Widget _buildDeviceTile(
    BuildContext context,
    WidgetRef ref,
    Device device, {
    bool isOnline = false,
    bool isConnected = false,
  }) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: device.platform == 'android'
                      ? Colors.green.shade100
                      : Colors.blue.shade100,
                  child: Icon(
                    device.platform == 'android' ? Icons.android : Icons.laptop,
                    size: 20,
                    color: device.platform == 'android' ? Colors.green : Colors.blue,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(device.name,
                          style: const TextStyle(fontSize: 14),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(
                        '${device.ip} · ${isConnected ? "已连接" : "未连接"}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (isConnected) ...[
                  IconButton(
                    icon: const Icon(Icons.link_off, size: 18),
                    tooltip: '断开连接',
                    color: Colors.red.shade400,
                    onPressed: () {
                      ref.read(connectionStateProvider.notifier).disconnect(device.deviceId);
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('已断开与 ${device.name} 的连接')),
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.send, size: 18),
                    tooltip: '发送文件',
                    onPressed: () => _sendFilesToDevice(context, ref, device),
                  ),
                  IconButton(
                    icon: const Icon(Icons.content_paste, size: 18),
                    tooltip: '发送剪贴板',
                    onPressed: () => _showClipboardSendDialog(context, ref, device),
                  ),
                ] else ...[
                  TextButton(
                    onPressed: () => _connectToDevice(context, ref, device),
                    child: const Text('连接'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ═══ 连接 + 配对（新版流程） ═══

  Future<void> _connectToDevice(
      BuildContext context, WidgetRef ref, Device device) async {
    final connection = ref.read(connectionStateProvider.notifier);
    final localDevice = ref.read(localDeviceProvider);

    final repo = TrustedDeviceRepository();
    final trusted = await repo.findByDeviceId(device.deviceId);

    if (trusted != null) {
      await connection.connect(device);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已连接到 ${device.name}')),
        );
      }
      return;
    }

    // ── 未信任：走配对流程 ──

    // 1. 建立 TCP 连接
    try {
      await connection.connect(device);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法连接到 ${device.name}: $e')),
        );
      }
      return;
    }

    // 2. 生成配对码和 nonce
    final pairCode = PairingProtocol.generatePairCode();
    final nonce = PairingProtocol.generateNonce();

    // 3. 发送 PAIR_REQUEST 给对方
    connection.sendPairRequest(device.deviceId, pairCode, nonce);

    if (!context.mounted) return;

    // 4. 双方同时显示 PIN — 发起端有确认按钮
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PairingPinDialog(
        deviceName: device.name,
        pairCode: pairCode,
        isConnector: true,
        onCancel: () {
          connection.sendPairCancel(device.deviceId, pairCode, nonce);
          Navigator.of(ctx).pop(false);
        },
        onConfirm: () => Navigator.of(ctx).pop(true),
      ),
    );

    if (confirmed != true) {
      connection.sendPairCancel(device.deviceId, pairCode, nonce);
      return;
    }

    // 5. 发送 PAIR_CONFIRM
    connection.sendPairConfirm(device.deviceId, pairCode, nonce);

    // 6. 本地生成 token 并保存信任
    final token = PairingProtocol.generateToken(
      deviceIdA: localDevice.deviceId,
      deviceIdB: device.deviceId,
      nonce: nonce,
      pairCode: pairCode,
    );
    await repo.upsert(
      deviceId: device.deviceId,
      deviceName: device.name,
      token: token,
    );

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已与 ${device.name} 配对并连接')),
      );
    }
  }

  // ═══ 接收端：收到配对请求 ═══

  void _onIncomingPairRequest(PairRequest req) async {
    if (_pairDialogShowing || !mounted) return;

    // 如果发送方已在信任列表，自动确认配对，跳过弹窗
    final repo = TrustedDeviceRepository();
    final trusted = await repo.findByDeviceId(req.deviceId);
    if (trusted != null) {
      ref.read(connectionStateProvider.notifier).sendPairConfirm(
        req.deviceId, req.pairCode, req.nonce);
      return;
    }

    _pairDialogShowing = true;

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        _pinDialogContext = ctx;
        return PairingPinDialog(
          deviceName: req.deviceName,
          pairCode: req.pairCode,
          isConnector: false,
          onReject: () {
            ref.read(connectionStateProvider.notifier).sendPairCancel(
              req.deviceId, req.pairCode, req.nonce);
            Navigator.of(ctx).pop();
          },
        );
      },
    ).then((_) {
      _pairDialogShowing = false;
      _pinDialogContext = null;
    });
  }

  // ═══ 接收端/发起端：配对完成保存信任 ═══

  void _onPairResult(PairResult result) async {
    if (!result.success) return;

    // 自动关闭接收端的 PIN 对话框
    if (_pinDialogContext != null && _pinDialogContext!.mounted) {
      Navigator.of(_pinDialogContext!).pop();
      _pinDialogContext = null;
      _pairDialogShowing = false;
    }

    final repo = TrustedDeviceRepository();
    final existing = await repo.findByDeviceId(result.deviceId);
    if (existing == null) {
      await repo.upsert(
        deviceId: result.deviceId,
        deviceName: result.deviceName,
        token: result.token,
      );
    }
  }

  // ═══ 统一二维码 / 短码 / 扫码 ═══

  void _showUnifiedQrSheet(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(onlineDevicesProvider.notifier);
    _UnifiedQrSheet.show(
      context,
      ref,
      notifier,
      onDeviceFound: (device) => _connectToDevice(context, ref, device),
    );
  }

  // ═══ 发送文件 / 剪贴板 ═══

  Future<void> _sendFilesToDevice(
      BuildContext context, WidgetRef ref, Device device) async {
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
      await _startTransferToDevice(ref, device, paths, false);
    } else if (choice == 'folder') {
      final path = await FilePicker.getDirectoryPath();
      if (path == null) return;
      await _startTransferToDevice(ref, device, [path], true);
    }
  }

  Future<void> _startTransferToDevice(
      WidgetRef ref, Device device, List<String> paths, bool folderMode) async {
    await ref.read(transferNotifierProvider.notifier).startTransfer(
          paths: paths,
          targetDevice: device,
          folderMode: folderMode,
          ref: ref,
        );
  }

  void _showClipboardSendDialog(
      BuildContext context, WidgetRef ref, Device device) {
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.content_paste, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text('发送文本到${device.name}的剪贴板',
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        content: TextField(
          controller: textController,
          autofocus: true,
          maxLines: 5,
          minLines: 3,
          textInputAction: TextInputAction.newline,
          decoration: const InputDecoration(
            hintText: '输入要发送的文本...',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () {
              final text = textController.text;
              if (text.isEmpty) {
                Navigator.pop(ctx);
                return;
              }
              ref
                  .read(clipboardNotifierProvider.notifier)
                  .pushText(device.deviceId, text);
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('已发送文本到${device.name}的剪贴板')),
              );
            },
            child: const Text('发送'),
          ),
        ],
      ),
    );
  }
}

// ═══ 统一二维码弹窗 (扫码 / 短码 / 本机码 三合一) ═══

class _UnifiedQrSheet extends StatefulWidget {
  final WidgetRef ref;
  final DiscoveryNotifier notifier;
  final void Function(Device device) onDeviceFound;

  const _UnifiedQrSheet({
    required this.ref,
    required this.notifier,
    required this.onDeviceFound,
  });

  static void show(
    BuildContext context,
    WidgetRef ref,
    DiscoveryNotifier notifier, {
    required void Function(Device device) onDeviceFound,
  }) {
    showDialog(
      context: context,
      builder: (_) => _UnifiedQrSheet(
        ref: ref,
        notifier: notifier,
        onDeviceFound: onDeviceFound,
      ),
    );
  }

  @override
  State<_UnifiedQrSheet> createState() => _UnifiedQrSheetState();
}

class _UnifiedQrSheetState extends State<_UnifiedQrSheet> {
  late String _currentIp;
  StreamSubscription<PairRequest>? _pairReqSub;

  @override
  void initState() {
    super.initState();
    _currentIp = widget.notifier.localIp ?? '未知';
    // Auto-close when someone scans our QR and connects
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pairReqSub = widget.ref
          .read(connectionStateProvider.notifier)
          .pairRequestStream
          .listen((_) {
        if (mounted) Navigator.of(context).pop();
      });
    });
  }

  @override
  void dispose() {
    _pairReqSub?.cancel();
    super.dispose();
  }

  QrCode _buildQr(String ip) {
    final localDevice = widget.ref.read(localDeviceProvider);
    final serverPort = widget.ref.read(serverPortProvider);
    final qrData = jsonEncode({
      'ip': ip,
      'port': serverPort,
      'deviceId': localDevice.deviceId,
      'name': localDevice.name,
      'ver': 1,
      'platform': Platform.operatingSystem,
    });
    return QrCode.fromData(data: qrData, errorCorrectLevel: QrErrorCorrectLevel.L);
  }

  void _showIpPicker() {
    final allIps = widget.notifier.allDetectedIps;
    if (allIps.isEmpty) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择网卡 IP'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: allIps.length + 1,
            itemBuilder: (ctx, i) {
              if (i == allIps.length) {
                return ListTile(
                  leading: Icon(Icons.auto_mode,
                      color: (widget.notifier.allDetectedIps.isNotEmpty &&
                              _currentIp == widget.notifier.allDetectedIps.first)
                          ? Theme.of(ctx).colorScheme.primary
                          : null),
                  title: const Text('自动检测'),
                  subtitle: Text(allIps.isNotEmpty ? '当前自动: ${allIps.first}' : '无可用'),
                  onTap: () {
                    widget.notifier.selectLocalIp(null);
                    setState(() { _currentIp = widget.notifier.localIp ?? '未知'; });
                    Navigator.pop(ctx);
                  },
                );
              }
              final ip = allIps[i];
              final isSelected = ip == _currentIp;
              final isAuto = widget.ref.read(selectedNetworkIpProvider) == null;
              final isAutoBest = isAuto && i == 0;
              return ListTile(
                leading: Icon(
                  isSelected ? Icons.check_circle : Icons.circle_outlined,
                  color: isSelected ? Theme.of(ctx).colorScheme.primary : null,
                ),
                title: Text(ip),
                subtitle: Text(isAutoBest ? '自动检测 · 推荐' : '手动选择'),
                onTap: () {
                  widget.notifier.selectLocalIp(ip);
                  setState(() { _currentIp = ip; });
                  Navigator.pop(ctx);
                },
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

  void _onInputShortCode() {
    final codeController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('输入短码连接'),
        content: TextField(
          controller: codeController,
          autofocus: true,
          maxLength: 6,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 24, letterSpacing: 4),
          decoration: const InputDecoration(
            hintText: '6 位短码',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final code = codeController.text.trim();
              if (code.length != 6) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('请输入完整的 6 位短码')),
                );
                return;
              }
              Navigator.pop(ctx); // close input dialog
              Navigator.pop(context); // close unified sheet

              final onlineDevices = widget.ref.read(onlineDevicesProvider);
              Device? match;
              for (final d in onlineDevices) {
                if (generateShortCode(d.deviceId) == code) {
                  match = d;
                  break;
                }
              }
              if (match != null) {
                widget.onDeviceFound(match);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('未找到匹配的设备，请确认短码正确且设备在线')),
                );
              }
            },
            child: const Text('连接'),
          ),
        ],
      ),
    );
  }

  Future<void> _onScanQrCode() async {
    final isMobile = Platform.isAndroid || Platform.isIOS;
    if (!isMobile) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('不支持扫码'),
          content: const Text('扫码功能仅在移动端（Android/iOS）可用，请在电脑端使用二维码或短码连接。'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }

    // 检查并请求摄像头权限
    var status = await Permission.camera.status;
    if (!status.isGranted) {
      status = await Permission.camera.request();
      if (!status.isGranted) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('需要摄像头权限才能扫描二维码')),
          );
        }
        return;
      }
    }

    if (!context.mounted) return;

    // 打开扫码页面，返回扫描到的 Device
    final device = await Navigator.of(context).push<Device>(
      MaterialPageRoute(builder: (_) => const _QrScannerPage()),
    );

    if (device != null) {
      // Close the QR sheet before triggering connection, matching shortcode behavior
      Navigator.of(context).pop();
      widget.onDeviceFound(device);
    }
  }

  @override
  Widget build(BuildContext context) {
    final localDevice = widget.ref.read(localDeviceProvider);
    final serverPort = widget.ref.read(serverPortProvider);
    final shortCode = generateShortCode(localDevice.deviceId);

    QrCode qrCode;
    try {
      qrCode = _buildQr(_currentIp);
    } catch (_) {
      return const SizedBox.shrink();
    }

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text('本机二维码',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                const Spacer(),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: shortCode));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('短码已复制')),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '短码: $shortCode',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.blue.shade700,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: 220,
              height: 220,
              child: QrImageView.withQr(
                qr: qrCode,
                backgroundColor: Colors.white,
                padding: const EdgeInsets.all(8),
              ),
            ),
            const SizedBox(height: 16),
            Text(localDevice.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            GestureDetector(
              onTap: _showIpPicker,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('IP: $_currentIp · 端口: $serverPort',
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  const SizedBox(width: 4),
                  Icon(Icons.arrow_drop_down, size: 16, color: Colors.grey.shade600),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text('让对方扫描二维码或输入上方短码即可连接',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            const SizedBox(height: 16),
            // ── 整合功能按钮（短码输入 + 扫码连接）──
            OutlinedButton.icon(
              onPressed: _onInputShortCode,
              icon: const Icon(Icons.dialpad, size: 18),
              label: const Text('输入短码'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _onScanQrCode,
              icon: const Icon(Icons.qr_code_scanner, size: 18),
              label: const Text('扫描二维码'),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;

  const _SectionHeader({required this.title, required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        '$title ($count)',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────
// QR Scanner page — full-screen camera with scan overlay
// ────────────────────────────────────────────────────────────

class _QrScannerPage extends StatefulWidget {
  const _QrScannerPage();

  @override
  State<_QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<_QrScannerPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;

  Device? _tryParse(String? raw) {
    if (raw == null) return null;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      // Validate required fields
      if (data['deviceId'] is! String ||
          data['ip'] is! String ||
          data['port'] is! int) {
        return null;
      }
      return Device(
        deviceId: data['deviceId'] as String,
        name: (data['name'] as String?) ?? 'Unknown',
        platform: (data['platform'] as String?) ?? 'unknown',
        ip: data['ip'] as String,
        port: data['port'] as int,
        protocolVersion: (data['ver'] as int?) ?? 1,
        lastSeen: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final device = _tryParse(barcode.rawValue);
      if (device != null) {
        _handled = true;
        HapticFeedback.mediumImpact();
        _controller.stop();
        Navigator.of(context).pop(device);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scanAreaSize = MediaQuery.of(context).size.width * 0.65;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('扫描二维码'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, color: Colors.white70, size: 48),
                    const SizedBox(height: 16),
                    Text(
                      '摄像头不可用',
                      style: TextStyle(color: Colors.white70, fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('返回'),
                    ),
                  ],
                ),
              );
            },
          ),
          // Semi-transparent overlay with scan area cutout
          _ScannerOverlay(scanAreaSize: scanAreaSize),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class _ScannerOverlay extends StatelessWidget {
  final double scanAreaSize;
  const _ScannerOverlay({required this.scanAreaSize});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: scanAreaSize,
        height: scanAreaSize,
        child: CustomPaint(
          painter: _ScannerFramePainter(),
        ),
      ),
    );
  }
}

class _ScannerFramePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    const cornerLen = 32.0;

    // Top-left
    canvas.drawLine(Offset.zero, Offset(0, cornerLen), paint);
    canvas.drawLine(Offset.zero, Offset(cornerLen, 0), paint);
    // Top-right
    canvas.drawLine(Offset(size.width, 0), Offset(size.width, cornerLen), paint);
    canvas.drawLine(Offset(size.width, 0), Offset(size.width - cornerLen, 0), paint);
    // Bottom-left
    canvas.drawLine(Offset(0, size.height), Offset(0, size.height - cornerLen), paint);
    canvas.drawLine(Offset(0, size.height), Offset(cornerLen, size.height), paint);
    // Bottom-right
    canvas.drawLine(Offset(size.width, size.height), Offset(size.width, size.height - cornerLen), paint);
    canvas.drawLine(Offset(size.width, size.height), Offset(size.width - cornerLen, size.height), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
