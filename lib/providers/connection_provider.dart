import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../models/device.dart';
import '../models/transfer_task.dart';
import '../models/history_record.dart';
import '../storage/history_repository.dart';
import '../engine/frame.dart';
import '../engine/transfer_control.dart';
import '../business/connection/connection_manager.dart';
import '../network/tcp_server.dart';
import '../storage/trusted_device_repository.dart';
import '../util/logger.dart';
import '../platform/foreground_service_manager.dart';
import 'settings_provider.dart';
import 'transfer_provider.dart';
import 'discovery_provider.dart';

/// 信任设备仓库 Provider
final trustedDeviceRepoProvider = Provider<TrustedDeviceRepository>((ref) {
  return TrustedDeviceRepository();
});

/// 传输请求数据
class TransferOffer {
  final String transferId;
  final String senderDeviceId;
  final String? senderDeviceName;
  final String? batchName;
  final int totalSize;
  final int fileCount;
  final bool folderMode;
  final List<Map<String, dynamic>> files;

  const TransferOffer({
    required this.transferId,
    required this.senderDeviceId,
    this.senderDeviceName,
    this.batchName,
    required this.totalSize,
    required this.fileCount,
    this.folderMode = false,
    required this.files,
  });
}

/// 剪贴板推送数据
class ClipboardPush {
  final String deviceId;
  final String text;
  const ClipboardPush({required this.deviceId, required this.text});
}

/// 待处理的传输请求 — UI 监听此 Provider，非 null 时弹出确认对话框
final pendingOfferProvider = StateProvider<TransferOffer?>((ref) => null);

/// 收到的剪贴板推送事件流
final incomingClipboardProvider = StreamProvider<ClipboardPush>((ref) {
  return ref.watch(connectionStateProvider.notifier).clipboardStream;
});

/// 收到的配对请求事件流
final incomingPairRequestProvider = StreamProvider<PairRequest>((ref) {
  return ref.watch(connectionStateProvider.notifier).pairRequestStream;
});

/// 当前正在接收的传输任务
final receiveTransferProvider = StateProvider<TransferTask?>((ref) => null);

/// 连接状态 (deviceId → 是否已连接)
final connectionStateProvider =
    NotifierProvider<ConnectionNotifier, Map<String, bool>>(
        ConnectionNotifier.new);

/// TCP 服务器实际绑定的端口（可能与设置值不同）
final activeServerPortProvider = StateProvider<int>((ref) {
  return ref.watch(serverPortProvider);
});

class ConnectionNotifier extends Notifier<Map<String, bool>> {
  ConnectionManager? _manager;
  TcpServer? _server;
  StreamSubscription<PeerFrame>? _frameSub;
  StreamSubscription<TcpConnection>? _serverSub;
  StreamSubscription<String>? _disconnectSub;
  StreamSubscription<String>? _connectedSub;
  StreamSubscription<Map<String, dynamic>>? _receiveSub;

  final _clipboardController = StreamController<ClipboardPush>.broadcast();

  Stream<ClipboardPush> get clipboardStream => _clipboardController.stream;
  Stream<PairRequest> get pairRequestStream =>
      _manager?.onPairRequest ?? const Stream.empty();
  Stream<PairResult> get pairResultStream =>
      _manager?.onPairResult ?? const Stream.empty();

  @override
  Map<String, bool> build() {
    final settings = ref.read(settingsRepositoryProvider);
    final localDevice = ref.read(localDeviceProvider);

    _manager = ConnectionManager(
      localDeviceId: localDevice.deviceId,
      localDeviceName: localDevice.name,
      platform: 'flutter',
      port: settings.serverPort,
    );

    _frameSub = _manager!.onFrame.listen(_handleFrame);

    _disconnectSub = _manager!.onDisconnect.listen((deviceId) {
      state = {...state}..remove(deviceId);
    });

    _connectedSub = _manager!.onConnected.listen((deviceId) {
      state = {...state, deviceId: true};
      // 回退：TCP 连接建立但 UDP 广播可能丢失时，手动添加到发现列表
      final info = _manager!.getPeerInfo(deviceId);
      final ip = _manager!.getPeerIp(deviceId);
      if (info != null && ip != null) {
        final device = Device(
          deviceId: deviceId,
          name: info['deviceName'] as String? ?? info['name'] as String? ?? deviceId,
          platform: info['platform'] as String? ?? 'unknown',
          ip: ip,
          port: info['port'] as int? ?? _manager!.port,
          protocolVersion: info['ver'] as int? ?? 1,
          lastSeen: DateTime.now(),
        );
        ref.read(onlineDevicesProvider.notifier).upsertDevice(device);
      }
    });

    _receiveSub = _manager!.onReceiveEvent.listen(_handleReceiveEvent);

    _startServer(settings.serverPort);

    ref.onDispose(_onDispose);
    return {};
  }

  Future<void> _startServer(int port) async {
    // Try the preferred port, then fall back to system-assigned
    final ports = <int>[port, 0];
    for (final p in ports) {
      try {
        _server = TcpServer(port: p);
        await _server!.start();
        debugPrint('[FastShare] TcpServer started on port ${_server!.port}');
        _manager?.updatePort(_server!.port);
        ref.read(activeServerPortProvider.notifier).state = _server!.port;
        Logger.log('[CN] TcpServer bound to port ${_server!.port}');
        _serverSub = _server!.onConnection.listen((conn) {
          _manager?.handleIncomingConnection(conn);
        });
        return;
      } catch (e) {
        Logger.log('[CN] TcpServer bind failed for port $p: $e');
        _server = null;
      }
    }
    Logger.log('[CN] TcpServer failed to bind to any port');
  }

  void _handleFrame(PeerFrame peerFrame) {
    try {
      // 只在非高频帧时记录日志，避免 I/O 阻塞 UI 线程
      if (peerFrame.frame.type != FlpMessageType.fileData &&
          peerFrame.frame.type != FlpMessageType.fileAck &&
          peerFrame.frame.type != FlpMessageType.pong &&
          peerFrame.frame.type != FlpMessageType.ping) {
        Logger.log('[CN] _handleFrame: type=0x${peerFrame.frame.type.toRadixString(16)} from=${peerFrame.deviceId}');
      }
      switch (peerFrame.frame.type) {
        case FlpMessageType.transferOffer:
          final payload = TransferControlMessages.parseOffer(peerFrame.frame);
          final offer = TransferOffer(
            transferId: payload['transferId'] as String,
            senderDeviceId: payload['senderDeviceId'] as String,
            senderDeviceName: payload['senderDeviceName'] as String?,
            batchName: payload['batchName'] as String?,
            totalSize: payload['totalSize'] as int,
            fileCount: payload['fileCount'] as int,
            folderMode: payload['folderMode'] as bool? ?? false,
            files: (payload['files'] as List).cast<Map<String, dynamic>>(),
          );
          _onTransferOffer(offer);
          break;

        case FlpMessageType.clipboardPush:
          final payload = jsonDecode(utf8.decode(peerFrame.frame.payload));
          final text = payload['text'] as String? ?? '';
          _clipboardController
              .add(ClipboardPush(deviceId: peerFrame.deviceId, text: text));
          break;
      }
    } catch (e) {
      debugPrint('[FastShare] Error handling frame: $e');
    }
  }

  /// 处理收到的传输请求 — 放入 pendingOfferProvider 等待用户确认
  void _onTransferOffer(TransferOffer offer) {
    Logger.log('[CN] _onTransferOffer: transferId=${offer.transferId} sender=${offer.senderDeviceId} files=${offer.fileCount} size=${offer.totalSize}');
    ref.read(pendingOfferProvider.notifier).state = offer;
  }

  Future<void> acceptPendingOffer() async {
    final offer = ref.read(pendingOfferProvider);
    if (offer == null) return;
    Logger.log('[CN] acceptPendingOffer: transferId=${offer.transferId}');
    final basePath = ref.read(downloadPathProvider);

    // 确定历史记录中 savePath 应指向的实际路径
    // - 单文件传输（非文件夹模式、1 个文件）→ 指向具体文件
    // - 文件夹传输 → 指向顶层文件夹名（引擎在 basePath 下重建相对路径）
    // - 多文件传输 → 保持 basePath（无法归纳到单个文件/文件夹）
    String taskSavePath = basePath;
    if (offer.files.isNotEmpty) {
      final firstRel = offer.files.first['relativePath'] as String? ?? '';
      if (firstRel.isNotEmpty) {
        if (!offer.folderMode && offer.fileCount == 1) {
          // 单文件 → basePath/文件名
          taskSavePath = '$basePath${Platform.pathSeparator}$firstRel';
        } else if (offer.folderMode) {
          final parts = firstRel.split(RegExp(r'[/\\]'));
          if (parts.length > 1) {
            taskSavePath = '$basePath${Platform.pathSeparator}${parts.first}';
          }
        }
      }
    }

    final tempDir = (await getTemporaryDirectory()).path;
    _manager?.acceptTransfer(
      offer.senderDeviceId,
      offer.transferId,
      basePath, // 引擎使用根目录重建相对路径
      senderDeviceName: offer.senderDeviceName,
      batchName: offer.batchName,
      totalSize: offer.totalSize,
      fileCount: offer.fileCount,
      files: offer.files,
      logDir: tempDir,
    );

    final task = TransferTask(
      transferId: offer.transferId,
      senderDeviceId: offer.senderDeviceId,
      targetDeviceId: ref.read(localDeviceProvider).deviceId,
      peerDeviceName: offer.senderDeviceName ?? offer.senderDeviceId,
      batchName: _resolveBatchName(offer),
      totalSize: offer.totalSize,
      fileCount: offer.fileCount,
      files: offer.files
          .map((f) => FileTransferItem(
                fileId: f['fileId'] as String? ?? '',
                relativePath: f['relativePath'] as String? ?? '',
                size: f['size'] as int? ?? 0,
              ))
          .toList(),
      folderMode: offer.folderMode,
      status: TransferStatus.transferring,
      savePath: taskSavePath,
    );
    ref.read(receiveTransferProvider.notifier).state = task;
    // pendingOffer 延迟到 transfer_started 事件时清除，
    // 防止引擎启动失败时 UI 失去反馈
  }

  void rejectPendingOffer() {
    final offer = ref.read(pendingOfferProvider);
    if (offer == null) return;
    Logger.log('[CN] rejectPendingOffer: transferId=${offer.transferId}');
    _manager?.rejectTransfer(offer.senderDeviceId, offer.transferId);
    ref.read(pendingOfferProvider.notifier).state = null;
  }

  void _handleReceiveEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    final transferId = event['transferId'] as String?;
    final rtask = ref.read(receiveTransferProvider);
    // Skip logging for high-frequency progress events to avoid main-thread I/O
    if (type != 'progress') {
      Logger.log('[CN] _handleReceiveEvent: type=$type transferId=$transferId hasTask=${rtask != null} taskMatch=${rtask?.transferId == transferId}');
    }
    if (rtask == null || rtask.transferId != transferId) return;

    switch (type) {
      case 'transfer_started':
        ref.read(pendingOfferProvider.notifier).state = null;
        break;
      case 'transfer_paused':
        ref.read(receiveTransferProvider.notifier).update((task) {
          if (task == null) return null;
          task.status = TransferStatus.paused;
          return task.clone();
        });
        break;
      case 'transfer_resumed':
        ref.read(receiveTransferProvider.notifier).update((task) {
          if (task == null) return null;
          task.status = TransferStatus.transferring;
          return task.clone();
        });
        break;
      case 'file_meta_received':
        // 更新接收任务的文件列表，确保 UI 实时显示
        final fileId = event['fileId'] as String?;
        final relativePath = event['relativePath'] as String?;
        final size = event['size'] as int?;
        if (fileId != null && relativePath != null && size != null) {
          ref.read(receiveTransferProvider.notifier).update((task) {
            if (task == null) return null;
            // 替换占位条目或追加新条目
            final idx = task.files.indexWhere((f) => f.fileId == fileId);
            if (idx >= 0) {
              task.files[idx].size = size;
              task.files[idx].relativePath = relativePath;
            } else {
              task.files.add(FileTransferItem(
                fileId: fileId,
                relativePath: relativePath,
                size: size,
              ));
            }
            return task.clone();
          });
        }
        break;
      case 'progress':
        ref.read(receiveTransferProvider.notifier).update((task) {
          if (task == null) return null;
          task.bytesTransferred = event['bytesWritten'] as int? ?? task.bytesTransferred;
          // 防止 _pendingSize 为 0 时覆盖 offer 中的正确 totalSize
          final newTotal = event['totalSize'] as int?;
          if (newTotal != null && newTotal > 0) {
            task.totalSize = newTotal;
          }
          task.avgSpeed = (event['speed'] as num?)?.toDouble() ?? task.avgSpeed;
          final peak = (event['peakSpeed'] as num?)?.toDouble() ?? 0;
          if (peak > task.peakSpeed) task.peakSpeed = peak;
          return task.clone();
        });
        // 更新前台通知进度
        if (ForegroundServiceManager().isRunning) {
          final task = ref.read(receiveTransferProvider);
          if (task != null) {
            ForegroundServiceManager().updateNotification(
              title: '接收自${task.peerDeviceName ?? ""}',
              body: '${(task.bytesTransferred / 1024 / 1024).toStringAsFixed(0)} / '
                  '${(task.totalSize / 1024 / 1024).toStringAsFixed(0)} MB',
              progress: task.bytesTransferred,
              progressMax: task.totalSize,
            );
          }
        }
        break;
      case 'file_complete':
        final fileId = event['fileId'] as String?;
        ref.read(receiveTransferProvider.notifier).update((task) {
          if (task == null) return null;
          final file = task.files.where((f) => f.fileId == fileId).firstOrNull;
          if (file != null) {
            file.status = TransferStatus.completed;
            file.bytesTransferred = file.size;
          }
          return task.clone();
        });
        break;
      case 'transfer_complete':
        _onReceiveComplete(rtask, true);
        break;
      case 'transfer_cancelled':
        _onReceiveComplete(rtask, false, cancelled: true);
        break;
      case 'error':
        _onReceiveComplete(rtask, false);
        break;
    }
  }

  Future<void> _onReceiveComplete(TransferTask task, bool success, {bool cancelled = false}) async {
    task.status = cancelled ? TransferStatus.cancelled
        : success ? TransferStatus.completed : TransferStatus.failed;
    // 没有活跃发送时停止前台服务
    if (ref.read(activeTransferProvider) == null) {
      ForegroundServiceManager().stop();
    }
    if (success) task.bytesTransferred = task.totalSize;
    ref.read(receiveTransferProvider.notifier).state = task.clone();

    try {
      final repo = HistoryRepository();
      await repo.insert(HistoryRecord(
        transferId: task.transferId,
        deviceId: task.senderDeviceId,
        deviceName: task.peerDeviceName ?? task.senderDeviceId,
        batchName: task.batchName,
        totalSize: task.totalSize,
        fileCount: task.fileCount,
        success: false,
        peakSpeed: task.peakSpeed,
        avgSpeed: task.avgSpeed,
        status: cancelled ? 'cancelled' : (success ? 'completed' : 'failed'),
        timestamp: DateTime.now(),
        savePath: task.savePath,
        folderMode: task.folderMode,
      ));
    } catch (_) {}
  }

  ConnectionManager? get manager => _manager;

  Future<void> connect(Device device) async {
    await _manager?.connect(device);
    state = {...state, device.deviceId: true};
  }

  void disconnect(String deviceId) {
    _manager?.disconnect(deviceId);
    state = {...state}..remove(deviceId);
  }

  void send(String deviceId, FlpFrame frame) {
    _manager?.send(deviceId, frame);
  }

  void sendPairRequest(String deviceId, String pairCode, String nonce) {
    final localDevice = ref.read(localDeviceProvider);
    _manager?.sendPairRequest(deviceId, pairCode, nonce, localDevice.name);
  }

  void sendPairConfirm(String deviceId, String pairCode, String nonce) {
    _manager?.sendPairConfirm(deviceId, pairCode, nonce);
  }

  void sendPairCancel(String deviceId, String pairCode, String nonce) {
    _manager?.sendPairCancel(deviceId, pairCode, nonce);
  }

  void rejectTransfer(String deviceId, String transferId) {
    _manager?.rejectTransfer(deviceId, transferId);
  }

  void setReceiveSpeedLimit(String transferId, int bytesPerSecond) {
    _manager?.setReceiveSpeedLimit(transferId, bytesPerSecond);
  }

  void cancelReceiveTransfer(String deviceId, String transferId) {
    Logger.log('[CN] cancelReceiveTransfer: deviceId=$deviceId transferId=$transferId');
    _manager?.cancelReceiveTransfer(deviceId, transferId);
    final rtask = ref.read(receiveTransferProvider);
    if (rtask?.transferId == transferId) {
      ref.read(receiveTransferProvider.notifier).state = null;
    }
  }

  void _onDispose() {
    _frameSub?.cancel();
    _serverSub?.cancel();
    _disconnectSub?.cancel();
    _connectedSub?.cancel();
    _receiveSub?.cancel();
    _manager?.dispose();
    _server?.stop();
    _clipboardController.close();
  }

  /// 根据 offer 推断显示名称：文件夹→文件夹名，单文件→文件名，多文件→数量
  static String _resolveBatchName(TransferOffer offer) {
    if (offer.files.isEmpty) return '文件传输';
    final firstRel = offer.files.first['relativePath'] as String? ?? '';
    if (offer.folderMode) {
      final parts = firstRel.split(RegExp(r'[/\\]'));
      return parts.length > 1 ? parts.first : firstRel;
    }
    if (offer.fileCount == 1) {
      return firstRel.split(RegExp(r'[/\\]')).last;
    }
    return '${offer.fileCount} 个文件';
  }
}
