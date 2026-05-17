import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'settings_provider.dart';

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
    });

    _receiveSub = _manager!.onReceiveEvent.listen(_handleReceiveEvent);

    _startServer(settings.serverPort);

    ref.onDispose(_onDispose);
    return {};
  }

  Future<void> _startServer(int port) async {
    _server = TcpServer(port: port);
    await _server!.start();
    debugPrint('[FastShare] TcpServer started on port $port');
    _serverSub = _server!.onConnection.listen((conn) {
      _manager?.handleIncomingConnection(conn);
    });
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
          final text = utf8.decode(peerFrame.frame.payload);
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

  void acceptPendingOffer() {
    final offer = ref.read(pendingOfferProvider);
    if (offer == null) return;
    Logger.log('[CN] acceptPendingOffer: transferId=${offer.transferId}');
    final savePath = ref.read(downloadPathProvider);

    _manager?.acceptTransfer(
      offer.senderDeviceId,
      offer.transferId,
      savePath,
      senderDeviceName: offer.senderDeviceName,
      batchName: offer.batchName,
      totalSize: offer.totalSize,
      fileCount: offer.fileCount,
    );

    final task = TransferTask(
      transferId: offer.transferId,
      senderDeviceId: offer.senderDeviceId,
      targetDeviceId: ref.read(localDeviceProvider).deviceId,
      peerDeviceName: offer.senderDeviceName ?? offer.senderDeviceId,
      batchName: offer.batchName ?? '${offer.fileCount} 个文件',
      totalSize: offer.totalSize,
      files: offer.files
          .map((f) => FileTransferItem(
                fileId: f['fileId'] as String? ?? '',
                relativePath: f['relativePath'] as String? ?? '',
                size: f['size'] as int? ?? 0,
              ))
          .toList(),
      folderMode: offer.folderMode,
      status: TransferStatus.transferring,
      savePath: savePath,
    );
    ref.read(receiveTransferProvider.notifier).state = task;
    ref.read(pendingOfferProvider.notifier).state = null;
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
        break;
      case 'file_meta_received':
        break;
      case 'progress':
        ref.read(receiveTransferProvider.notifier).update((task) {
          if (task == null) return null;
          task.bytesTransferred = event['bytesWritten'] as int? ?? task.bytesTransferred;
          task.totalSize = event['totalSize'] as int? ?? task.totalSize;
          task.avgSpeed = (event['speed'] as num?)?.toDouble() ?? task.avgSpeed;
          final peak = (event['peakSpeed'] as num?)?.toDouble() ?? 0;
          if (peak > task.peakSpeed) task.peakSpeed = peak;
          return task.clone();
        });
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
      case 'error':
        _onReceiveComplete(rtask, false);
        break;
    }
  }

  Future<void> _onReceiveComplete(TransferTask task, bool success) async {
    task.status = success ? TransferStatus.completed : TransferStatus.failed;
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
        success: success,
        peakSpeed: task.peakSpeed,
        avgSpeed: task.avgSpeed,
        status: success ? 'completed' : 'failed',
        timestamp: DateTime.now(),
        savePath: task.savePath,
      ));
    } catch (_) {}

    // Clear after a brief delay so UI can show the final state
    Future.delayed(const Duration(seconds: 3), () {
      if (ref.read(receiveTransferProvider)?.transferId == task.transferId) {
        ref.read(receiveTransferProvider.notifier).state = null;
      }
    });
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
}
