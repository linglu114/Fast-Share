import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../../engine/pairing.dart';
import '../../../models/device.dart';
import '../../../business/connection/connection_manager.dart';
import '../../../providers/discovery_provider.dart';
import '../../../providers/connection_provider.dart';
import '../../../providers/settings_provider.dart';
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
            icon: const Icon(Icons.qr_code_scanner),
            tooltip: '扫码连接',
            onPressed: () {},
          ),
          IconButton(
            icon: const Icon(Icons.qr_code),
            tooltip: '显示二维码 / 短码',
            onPressed: () => _showLocalQrCode(context, ref),
          ),
          IconButton(
            icon: const Icon(Icons.dialpad),
            tooltip: '输入短码',
            onPressed: () => _showShortCodeInput(context, ref),
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
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: device.platform == 'android'
              ? Colors.green.shade100
              : Colors.blue.shade100,
          child: Icon(
            device.platform == 'android' ? Icons.android : Icons.laptop,
            size: 22,
            color: device.platform == 'android' ? Colors.green : Colors.blue,
          ),
        ),
        title: Text(device.name, style: const TextStyle(fontSize: 14)),
        subtitle: Text(
          '${device.ip} · ${isConnected ? "已连接" : "未连接"}',
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isConnected) ...[
              IconButton(
                icon: const Icon(Icons.send, size: 18),
                tooltip: '发送文件',
                onPressed: () {
                  // 跳转到传输页并预选该设备
                  Navigator.of(context).pushNamed('/transfer');
                },
              ),
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
            ] else ...[
              TextButton(
                onPressed: () => _connectToDevice(context, ref, device),
                child: const Text('连接'),
              ),
            ],
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

  // ═══ 二维码 + 短码 ═══

  void _showLocalQrCode(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(onlineDevicesProvider.notifier);
    _QrCodeDialog.show(context, ref, notifier);
  }

  void _showShortCodeInput(BuildContext context, WidgetRef ref) {
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
              Navigator.pop(ctx);

              final onlineDevices = ref.read(onlineDevicesProvider);
              Device? match;
              for (final d in onlineDevices) {
                if (generateShortCode(d.deviceId) == code) {
                  match = d;
                  break;
                }
              }

              if (match != null) {
                _connectToDevice(context, ref, match);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text('未找到匹配的设备，请确认短码正确且设备在线')),
                );
              }
            },
            child: const Text('连接'),
          ),
        ],
      ),
    );
  }
}

// ═══ QR 码弹窗组件 ═══

class _QrCodeDialog extends StatefulWidget {
  final WidgetRef ref;
  final DiscoveryNotifier notifier;

  const _QrCodeDialog({required this.ref, required this.notifier});

  static void show(BuildContext context, WidgetRef ref, DiscoveryNotifier notifier) {
    showDialog(
      context: context,
      builder: (_) => _QrCodeDialog(ref: ref, notifier: notifier),
    );
  }

  @override
  State<_QrCodeDialog> createState() => _QrCodeDialogState();
}

class _QrCodeDialogState extends State<_QrCodeDialog> {
  late String _currentIp;

  @override
  void initState() {
    super.initState();
    _currentIp = widget.notifier.localIp ?? '未知';
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
                      color:
                          (widget.notifier.allDetectedIps.isNotEmpty &&
                                  _currentIp == widget.notifier.allDetectedIps.first)
                              ? Theme.of(ctx).colorScheme.primary
                              : null),
                  title: const Text('自动检测'),
                  subtitle: Text(allIps.isNotEmpty
                      ? '当前自动: ${allIps.first}'
                      : '无可用'),
                  onTap: () {
                    widget.notifier.selectLocalIp(null);
                    setState(() {
                      _currentIp = widget.notifier.localIp ?? '未知';
                    });
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
                  color: isSelected
                      ? Theme.of(ctx).colorScheme.primary
                      : null,
                ),
                title: Text(ip),
                subtitle: Text(isAutoBest ? '自动检测 · 推荐' : '手动选择'),
                onTap: () {
                  widget.notifier.selectLocalIp(ip);
                  setState(() {
                    _currentIp = ip;
                  });
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
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const Spacer(),
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: shortCode));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('短码已复制')),
                    );
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
            Text(localDevice.name,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            GestureDetector(
              onTap: _showIpPicker,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('IP: $_currentIp · 端口: $serverPort',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade600)),
                  const SizedBox(width: 4),
                  Icon(Icons.arrow_drop_down,
                      size: 16, color: Colors.grey.shade600),
                ],
              ),
            ),
            const SizedBox(height: 4),
            Text('让对方扫描二维码或输入上方短码即可连接',
                style:
                    TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            const SizedBox(height: 16),
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
