import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../../models/device.dart';
import '../../engine/frame.dart';
import '../../engine/session.dart';
import '../../engine/pairing.dart';
import '../../engine/receive_engine.dart';
import '../../network/tcp_server.dart';
import '../../util/logger.dart';

/// 配对请求（暴露给 UI）
class PairRequest {
  final String deviceId;
  final String deviceName;
  final String pairCode;
  final String nonce;
  const PairRequest({
    required this.deviceId,
    required this.deviceName,
    required this.pairCode,
    required this.nonce,
  });
}

/// 配对完成结果（用于 UI 保存信任）
class PairResult {
  final String deviceId;
  final String deviceName;
  final String token;
  final bool success;
  const PairResult({
    required this.deviceId,
    required this.deviceName,
    required this.token,
    required this.success,
  });
}

/// 连接管理器 (架构设计 v2.0 §2.2)
///
/// 管理 TCP 连接池、配对流程、心跳维护。
class ConnectionManager {
  final String localDeviceId;
  final String localDeviceName;
  final String platform;
  int port;

  final Map<String, Socket> _connections = {};
  final Map<String, TcpConnection> _tcpConns = {};
  // Engine 连接独立存储，不覆盖 discovery 连接
  final Map<String, Socket> _engineConnections = {};
  final Map<String, TcpConnection> _engineTcpConns = {};
  final Map<String, Timer> _heartbeatTimers = {};
  final Map<String, Map<String, dynamic>> _peerInfo = {};
  // Receive Engine Isolates: transferId → engine command SendPort
  final Map<String, SendPort> _receiveEngines = {};
  // Raw frame buffers: transferId → raw Uint8List frames arriving before engine ready
  final Map<String, List<Uint8List>> _rawFrameBuffers = {};
  final Map<String, String> _receiverDevice = {}; // transferId → deviceId
  final Map<String, List<FlpFrame>> _pendingFrames = {}; // frames arriving before receiver ready

  final _frameController = StreamController<PeerFrame>.broadcast();
  Stream<PeerFrame> get onFrame => _frameController.stream;

  final _pairRequestController = StreamController<PairRequest>.broadcast();
  Stream<PairRequest> get onPairRequest => _pairRequestController.stream;

  final _pairResultController = StreamController<PairResult>.broadcast();
  Stream<PairResult> get onPairResult => _pairResultController.stream;

  final _disconnectController = StreamController<String>.broadcast();
  Stream<String> get onDisconnect => _disconnectController.stream;

  final _connectedController = StreamController<String>.broadcast();
  Stream<String> get onConnected => _connectedController.stream;

  final _receiveEventController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onReceiveEvent => _receiveEventController.stream;

  // 待处理的接收传输元数据
  final Map<String, Map<String, dynamic>> _receiveMeta = {};

  /// 待处理的配对请求（deviceId → PairRequest），收到 PAIR_CONFIRM 时查找
  final Map<String, PairRequest> _pendingPairRequests = {};

  ConnectionManager({
    required this.localDeviceId,
    required this.localDeviceName,
    required this.platform,
    this.port = 34568,
  });

  /// Update the port used in discovery broadcasts after TCP server binds.
  void updatePort(int newPort) {
    port = newPort;
  }

  /// Get IP address of a connected peer by deviceId.
  String? getPeerIp(String deviceId) {
    return _connections[deviceId]?.remoteAddress.address;
  }

  /// Get parsed HELLO info for a connected peer.
  Map<String, dynamic>? getPeerInfo(String deviceId) => _peerInfo[deviceId];

  // ═══ 对外连接 ═══

  /// 连接到设备
  Future<void> connect(Device device) async {
    if (_connections.containsKey(device.deviceId)) return;

    final socket = await Socket.connect(
      device.ip,
      device.port,
      timeout: const Duration(seconds: 5),
    );

    // 使用 TcpConnection 包装 Socket，支持 onRawFrame 钩子转发到 ReceiveEngine
    final conn = TcpConnection(socket);
    _connections[device.deviceId] = socket;
    _tcpConns[device.deviceId] = conn;
    _connectedController.add(device.deviceId);

    // 发送 HELLO
    final hello = SessionMessages.buildHello(
      deviceId: localDeviceId,
      sessionId: _generateSessionId(),
      deviceName: localDeviceName,
      platform: platform,
      appVersion: '1.0.0',
    );
    conn.send(hello);

    // 监听响应 — 通过 TcpConnection 处理，支持 onRawFrame 钩子
    bool helloReceived = false;
    conn.onFrame.listen((frame) {
      if (!helloReceived) {
        if (frame.type == FlpMessageType.helloAck) {
          helloReceived = true;
          debugPrint('[FastShare] Connection established to ${device.deviceId}');
        }
        return;
      }
      _dispatchFrame(device.deviceId, frame);
    });

    conn.onDone.then((_) {
      disconnect(device.deviceId);
    });

    // 启动心跳
    _startHeartbeat(device.deviceId, socket);
  }

  // ═══ 接收连接（来自 TcpServer） ═══

  /// 处理来自 TcpServer 的入站连接
  void handleIncomingConnection(TcpConnection conn) {
    bool helloReceived = false;
    String deviceId = conn.id;

    conn.onFrame.listen((frame) {
      if (!helloReceived) {
        if (frame.type == FlpMessageType.hello) {
          helloReceived = true;
          final hello = SessionMessages.parseHello(frame);
          deviceId = hello['deviceId'] as String;
          debugPrint('[FastShare] Connection accepted from $deviceId');
          _peerInfo[deviceId] = hello;

          final ackFrame = SessionMessages.buildHelloAck(
            deviceId: localDeviceId,
            sessionId: _generateSessionId(),
          );

          // 如果该 deviceId 已有 discovery 连接，这是 engine 连接，不覆盖
          if (_tcpConns.containsKey(deviceId)) {
            Logger.log('[CM] handleIncomingConnection: engine connection for $deviceId (keeping discovery)');
            _engineConnections[deviceId] = conn.socket;
            _engineTcpConns[deviceId] = conn;

            // 监听 engine 连接上的控制帧 (PAUSE/RESUME/CANCEL)，
            // FILE_DATA/FILE_META 已被 onRawFrame 钩子消费，不会重复处理
            conn.onFrame.listen((frame) {
              _dispatchFrame(deviceId, frame);
            });

            // Transfer onRawFrame hook to engine connection for active transfers.
            // Keep the discovery connection hook alive — null-ing it races with
            // FILE_DATA frames that may still arrive on the discovery socket.
            final discoveryConn = _tcpConns[deviceId];
            if (discoveryConn != null && discoveryConn.onRawFrame != null) {
              conn.onRawFrame = discoveryConn.onRawFrame;
              Logger.log('[CM] handleIncomingConnection: set onRawFrame on engine conn for deviceId=$deviceId');
            }
          } else {
            Logger.log('[CM] handleIncomingConnection: discovery connection for $deviceId');
            _connections[deviceId] = conn.socket;
            _tcpConns[deviceId] = conn;
            _startHeartbeat(deviceId, conn.socket);
            _connectedController.add(deviceId);
          }

          conn.send(ackFrame);
          return;
        }

        // First frame is not HELLO, dispatch by conn id
        _dispatchFrame(conn.id, frame);
        return;
      }

      _dispatchFrame(deviceId, frame);
    });

    conn.onDone.then((_) {
      // 检查是否 engine 连接先于 discovery 被清理
      final engineDid = _engineConnections.entries
          .where((e) => e.value == conn.socket)
          .map((e) => e.key)
          .firstOrNull;
      if (engineDid != null) {
        Logger.log('[CM] engine conn.onDone: deviceId=$engineDid conn.id=${conn.id}');
        _engineConnections.remove(engineDid);
        _engineTcpConns.remove(engineDid);
        // Clean up receive engines for this device
        for (final tid in _receiverDevice.keys.where((k) => _receiverDevice[k] == engineDid).toList()) {
          _shutdownReceiveEngine(engineDid, tid);
          _receiveEventController.add({
            'type': 'error',
            'transferId': tid,
            'deviceId': engineDid,
            'message': 'Sender disconnected',
          });
        }
        return;
      }
      final did = _connections.entries
          .where((e) => e.value == conn.socket)
          .map((e) => e.key)
          .firstOrNull;
      Logger.log('[CM] handleIncomingConnection conn.onDone: did=$did conn.id=${conn.id}');
      if (did != null) disconnect(did);
    });
  }

  /// 帧分发到统一的处理入口
  void _dispatchFrame(String deviceId, FlpFrame frame) {
    _frameController.add(PeerFrame(deviceId: deviceId, frame: frame));
    _handleFrame(deviceId, frame);
  }

  // ═══ 帧处理 ═══

  void _handleFrame(String deviceId, FlpFrame frame) {
    switch (frame.type) {
      case FlpMessageType.helloAck:
        final ack = SessionMessages.parseHelloAck(frame);
        if (ack['accepted'] == true) {
          _peerInfo[deviceId] = {
            'name': deviceId,
            'negotiatedVersion': ack['negotiatedVersion']
          };
        }
        break;

      case FlpMessageType.hello:
        // 已在 handleIncomingConnection 中处理
        break;

      case FlpMessageType.ping:
        final ping = SessionMessages.parsePingPong(frame);
        final socket = _connections[deviceId];
        if (socket != null) {
          final pongFrame = SessionMessages.buildPong(
            timestamp: ping['timestamp'] as int,
          );
          socket.add(pongFrame.toBytes());
        }
        break;

      case FlpMessageType.transferOffer:
        debugPrint('[FastShare] Transfer offer received from $deviceId');
        // 由 Provider 层处理（UI 弹出确认对话框）
        break;

      case FlpMessageType.transferAccept:
        // 发送端收到接收端的接受确认
        break;

      case FlpMessageType.transferReject:
        // 发送端收到拒绝
        break;

      case FlpMessageType.transferCancel:
        // 取消传输
        _cancelReceiving(deviceId, frame);
        break;

      case FlpMessageType.fileMeta:
        _routeToReceiver(deviceId, frame);
        break;

      case FlpMessageType.fileData:
        _routeToReceiver(deviceId, frame);
        break;

      case FlpMessageType.transferPause:
      case FlpMessageType.transferResume:
        _routeToReceiver(deviceId, frame);
        break;

      case FlpMessageType.fileAck:
      case FlpMessageType.fileNack:
      case FlpMessageType.fileComplete:
      case FlpMessageType.transferComplete:
        // 来自接收端的ACK，由 Provider 转发给发送端 Engine
        break;

      case FlpMessageType.pairRequest:
        final req = PairingProtocol.parsePairRequest(frame);
        final pairReq = PairRequest(
          deviceId: req['deviceId'] as String,
          deviceName: req['deviceName'] as String? ?? 'Unknown',
          pairCode: req['pairCode'] as String,
          nonce: req['nonce'] as String,
        );
        _pendingPairRequests[pairReq.deviceId] = pairReq;
        _pairRequestController.add(pairReq);
        break;

      case FlpMessageType.pairConfirm:
        final confirm = PairingProtocol.parsePairConfirm(frame);
        if (confirm['confirm'] == true) {
          final pendingReq = _pendingPairRequests[deviceId];
          if (pendingReq != null) {
            final token = PairingProtocol.generateToken(
              deviceIdA: pendingReq.deviceId,
              deviceIdB: localDeviceId,
              nonce: pendingReq.nonce,
              pairCode: pendingReq.pairCode,
            );
            final resultFrame = PairingProtocol.buildPairResult(
              success: true,
              token: token,
            );
            final socket = _connections[deviceId];
            socket?.add(resultFrame.toBytes());

            // 通知 UI 保存信任（被连接端）
            _pairResultController.add(PairResult(
              deviceId: pendingReq.deviceId,
              deviceName: pendingReq.deviceName,
              token: token,
              success: true,
            ));
          }
        }
        _pendingPairRequests.remove(deviceId);
        break;

      case FlpMessageType.pairResult:
        final result = PairingProtocol.parsePairResult(frame);
        if (result['success'] == true && result['token'] != null) {
          final peerName = _peerInfo[deviceId]?['deviceName'] as String? ??
              _peerInfo[deviceId]?['name'] as String? ??
              deviceId;
          _pairResultController.add(PairResult(
            deviceId: deviceId,
            deviceName: peerName,
            token: result['token'] as String,
            success: true,
          ));
        }
        break;
    }
  }

  // ═══ 文件接收 ═══

  /// 接受传输，发送 TRANSFER_ACCEPT 并启动 ReceiveEngine Isolate
  Future<void> acceptTransfer(String deviceId, String transferId, String savePath,
      {String? senderDeviceName, String? batchName, int totalSize = 0, int fileCount = 0,
       List<Map<String, dynamic>>? files, String? logDir}) async {
    Logger.log('[CM] acceptTransfer: START deviceId=$deviceId transferId=$transferId savePath=$savePath');

    // 防止重复 TRANSFER_OFFER 导致创建多个引擎
    if (_receiveEngines.containsKey(transferId)) {
      Logger.log('[CM] acceptTransfer: already have engine for $transferId, skipping duplicate');
      return;
    }

    _sendJsonFrame(deviceId, FlpMessageType.transferAccept, {
      'transferId': transferId,
      'savePath': savePath,
      'overwritePolicy': 'rename',
    });
    Logger.log('[CM] acceptTransfer: TRANSFER_ACCEPT sent');

    _receiverDevice[transferId] = deviceId;
    _receiveMeta[transferId] = {
      'senderDeviceId': deviceId,
      'senderDeviceName': senderDeviceName ?? deviceId,
      'batchName': batchName,
      'totalSize': totalSize,
      'fileCount': fileCount,
      'files': files ?? const [],
      'logDir': logDir,
    };

    _receiveEventController.add({
      'type': 'transfer_started',
      'transferId': transferId,
      'deviceId': deviceId,
      'senderDeviceName': senderDeviceName ?? deviceId,
      'batchName': batchName,
      'totalSize': totalSize,
      'fileCount': fileCount,
      'savePath': savePath,
    });

    // Set onRawFrame hook synchronously — buffers raw bytes until engine ready
    final rawBuffer = <Uint8List>[];
    _rawFrameBuffers[transferId] = rawBuffer;

    final conn = _engineTcpConns[deviceId] ?? _tcpConns[deviceId];
    if (conn != null) {
      conn.onRawFrame = (frameType, rawBytes) {
        final enginePort = _receiveEngines[transferId];
        if (enginePort != null) {
          enginePort.send({
            'type': 'data',
            'payload': {'transferId': transferId, 'rawBytes': rawBytes},
          });
        } else {
          rawBuffer.add(rawBytes);
        }
      };
    }

    // Spawn ReceiveEngine Isolate (async, buffers protect the gap)
    _spawnReceiveEngine(transferId, savePath, deviceId);
  }

  Future<void> _spawnReceiveEngine(String transferId, String savePath, String deviceId) async {
    final receivePort = ReceivePort();
    SendPort? enginePort;

    // Get fallback save path in case the primary path fails (e.g. Android permission issue)
    String? fallbackPath;
    try {
      fallbackPath = (await getTemporaryDirectory()).path;
    } catch (_) {}

    try {
      await Isolate.spawn(ReceiveEngine.entry, receivePort.sendPort);
    } catch (e) {
      Logger.log('[CM] _spawnReceiveEngine: Isolate.spawn failed: $e');
      _receiveEventController.add({
        'type': 'error',
        'transferId': transferId,
        'deviceId': deviceId,
        'message': 'Failed to start receive engine: $e',
      });
      return;
    }

    receivePort.listen((message) {
      if (message is! Map<String, dynamic>) return;
      final type = message['type'] as String?;
      final data = message['data'] as Map<String, dynamic>? ?? {};

      // Engine-ready handshake (first message)
      if (type == 'engine_ready') {
        enginePort = data['enginePort'] as SendPort;
        _receiveEngines[transferId] = enginePort!;

        // Send start command with fallback path, expected file count, and logDir
        final meta = _receiveMeta[transferId];
        final fileCount = meta?['fileCount'] as int? ?? 0;
        final files = meta?['files'] as List?;
        final logDir = meta?['logDir'] as String?;
        enginePort!.send({
          'type': 'start',
          'payload': {
            'transferId': transferId,
            'savePath': savePath,
            if (fallbackPath != null) 'fallbackPath': fallbackPath,
            'expectedFileCount': fileCount,
            if (files != null) 'files': files,
            if (logDir != null) 'logDir': logDir,
          },
        });

        // Flush buffered raw frames
        final buffer = _rawFrameBuffers.remove(transferId);
        if (buffer != null) {
          for (final rawBytes in buffer) {
            enginePort!.send({
              'type': 'data',
              'payload': {'transferId': transferId, 'rawBytes': rawBytes},
            });
          }
        }

        // Flush any pending parsed frames (pre-hook edge case)
        final pending = _pendingFrames.remove(transferId);
        if (pending != null) {
          for (final frame in pending) {
            if (frame.type == FlpMessageType.fileMeta ||
                frame.type == FlpMessageType.fileData) {
              enginePort!.send({
                'type': 'data',
                'payload': {'transferId': transferId, 'rawBytes': frame.toBytes()},
              });
            }
          }
        }
        return;
      }

      // ACK frames — write raw bytes to socket
      if (type == 'ack_frame') {
        final frameBytes = data['frameBytes'] as Uint8List?;
        if (frameBytes != null) {
          final conn = _engineTcpConns[deviceId] ?? _tcpConns[deviceId];
          if (conn != null) {
            conn.socket.add(frameBytes);
          } else {
            _connections[deviceId]?.add(frameBytes);
          }
        }
        return;
      }

      // All other events — forward via existing receiver event path
      if (type != null) {
        _onReceiverEvent(deviceId, transferId, type, data);
      }
    });
  }

  /// 拒绝传输
  void rejectTransfer(String deviceId, String transferId) {
    _sendJsonFrame(deviceId, FlpMessageType.transferReject, {
      'transferId': transferId,
      'reason': 'USER_REJECTED',
    });
  }

  /// 通知接收端 Engine 向发送端转发 SPEED_LIMIT 帧
  void setReceiveSpeedLimit(String transferId, int bytesPerSecond) {
    Logger.log('[CM] setReceiveSpeedLimit: transferId=$transferId limit=$bytesPerSecond');
    _receiveEngines[transferId]?.send({
      'type': 'set_speed_limit',
      'payload': {'speedLimit': bytesPerSecond},
    });
  }

  /// 取消正在接收的传输（接收端主动取消）
  void cancelReceiveTransfer(String deviceId, String transferId) {
    Logger.log('[CM] cancelReceiveTransfer: deviceId=$deviceId transferId=$transferId');
    _sendJsonFrame(deviceId, FlpMessageType.transferCancel, {
      'transferId': transferId,
      'reason': 'USER_CANCELLED',
    });
    _shutdownReceiveEngine(deviceId, transferId);
    _receiveEventController.add({
      'type': 'error',
      'transferId': transferId,
      'deviceId': deviceId,
      'message': 'Cancelled by user',
    });
  }

  void _shutdownReceiveEngine(String deviceId, String transferId) {
    final enginePort = _receiveEngines.remove(transferId);
    if (enginePort != null) {
      try {
        enginePort.send({'type': 'shutdown'});
      } catch (_) {}
    }
    _rawFrameBuffers.remove(transferId);
    _receiverDevice.remove(transferId);
    _pendingFrames.remove(transferId);
    _receiveMeta.remove(transferId);
    // Clear onRawFrame hook
    final conn = _engineTcpConns[deviceId] ?? _tcpConns[deviceId];
    if (conn != null) {
      conn.onRawFrame = null;
    }
  }

  void _routeToReceiver(String deviceId, FlpFrame frame) {
    // Extract transferId from payload
    String? transferId;
    try {
      if (frame.type == FlpMessageType.fileMeta) {
        final json = jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
        transferId = json['transferId'] as String?;
      } else if (frame.type == FlpMessageType.fileData) {
        final buffer = ByteData.sublistView(frame.payload);
        transferId = _readUuidFromBuffer(buffer, 0);
      } else if (frame.type == FlpMessageType.transferPause ||
                 frame.type == FlpMessageType.transferResume) {
        final json = jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
        transferId = json['transferId'] as String?;
      }
    } catch (e) {
      Logger.log('[CM] _routeToReceiver: failed to extract transferId: $e');
      _frameController.addError(
        FormatException('Failed to extract transferId from frame: $e'),
      );
      return;
    }

    if (transferId == null) return;

    // Pause / resume — forward to engine
    if (frame.type == FlpMessageType.transferPause) {
      _receiveEngines[transferId]?.send({
        'type': 'pause',
        'payload': {'transferId': transferId},
      });
      return;
    }
    if (frame.type == FlpMessageType.transferResume) {
      _receiveEngines[transferId]?.send({
        'type': 'resume',
        'payload': {'transferId': transferId},
      });
      return;
    }

    // FILE_DATA / FILE_META arriving without onRawFrame hook (pre-hook edge case)
    // Forward raw bytes to engine if ready, otherwise buffer
    final enginePort = _receiveEngines[transferId];
    if (enginePort != null) {
      enginePort.send({
        'type': 'data',
        'payload': {'transferId': transferId, 'rawBytes': frame.toBytes()},
      });
      return;
    }

    // Engine not ready yet — buffer
    Logger.log('[CM] _routeToReceiver: engine not ready for transferId=$transferId, buffering');
    _pendingFrames.putIfAbsent(transferId, () => []).add(frame);
  }

  static String _readUuidFromBuffer(ByteData buffer, int offset) {
    final sb = StringBuffer();
    for (var i = 0; i < 16; i++) {
      sb.write(buffer.getUint8(offset + i).toRadixString(16).padLeft(2, '0'));
    }
    final hex = sb.toString();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  void _cancelReceiving(String deviceId, FlpFrame frame) {
    try {
      final json = jsonDecode(utf8.decode(frame.payload)) as Map<String, dynamic>;
      final transferId = json['transferId'] as String?;
      Logger.log('[CM] _cancelReceiving: transferId=$transferId');
      if (transferId != null) {
        _shutdownReceiveEngine(deviceId, transferId);
        _receiveEventController.add({
          'type': 'transfer_cancelled',
          'transferId': transferId,
          'deviceId': deviceId,
          'message': 'Transfer cancelled by sender',
        });
      }
    } catch (e) {
      _frameController.addError(
        FormatException('Failed to parse TRANSFER_CANCEL: $e'),
      );
    }
  }

  void _onReceiverEvent(
      String deviceId, String transferId, String type, Map<String, dynamic> data) {
    final meta = _receiveMeta[transferId];
    _receiveEventController.add({
      'type': type,
      'transferId': transferId,
      'deviceId': deviceId,
      'senderDeviceName': meta?['senderDeviceName'] ?? deviceId,
      ...data,
    });

    if (type == 'transfer_complete' || type == 'error') {
      _cleanupReceiveState(deviceId, transferId);
    }
  }

  void _cleanupReceiveState(String deviceId, String transferId) {
    _receiveEngines.remove(transferId);
    _rawFrameBuffers.remove(transferId);
    _receiverDevice.remove(transferId);
    _receiveMeta.remove(transferId);
    _pendingFrames.remove(transferId);
    // Clear onRawFrame hook
    final conn = _engineTcpConns[deviceId] ?? _tcpConns[deviceId];
    if (conn != null) {
      conn.onRawFrame = null;
    }
  }

  void _sendJsonFrame(String deviceId, int type, Map<String, dynamic> json) {
    final payload = Uint8List.fromList(utf8.encode(jsonEncode(json)));
    final frame = FlpFrame(type: type, payload: payload);
    // 优先使用 engine 连接（文件传输），fallback 到 discovery 连接
    final conn = _engineTcpConns[deviceId] ?? _tcpConns[deviceId];
    if (conn != null) {
      conn.send(frame);
    } else {
      send(deviceId, frame);
    }
  }

  // ═══ 配对发送 ═══

  /// 发送配对请求到指定设备
  void sendPairRequest(String deviceId, String pairCode, String nonce, String deviceName) {
    final frame = PairingProtocol.buildPairRequest(
      deviceId: localDeviceId,
      deviceName: deviceName,
      pairCode: pairCode,
      nonce: nonce,
    );
    send(deviceId, frame);
  }

  /// 发送配对确认
  void sendPairConfirm(String deviceId, String pairCode, String nonce) {
    final frame = PairingProtocol.buildPairConfirm(
      pairCode: pairCode,
      nonce: nonce,
      confirm: true,
    );
    send(deviceId, frame);
  }

  /// 发送配对取消
  void sendPairCancel(String deviceId, String pairCode, String nonce) {
    final frame = PairingProtocol.buildPairConfirm(
      pairCode: pairCode,
      nonce: nonce,
      confirm: false,
    );
    send(deviceId, frame);
  }

  // ═══ 心跳 ═══

  void _startHeartbeat(String deviceId, Socket socket) {
    _heartbeatTimers[deviceId]?.cancel();
    _heartbeatTimers[deviceId] = Timer.periodic(
      const Duration(seconds: 3),
      (_) {
        try {
          final ping = SessionMessages.buildPing();
          socket.add(ping.toBytes());
        } catch (_) {
          disconnect(deviceId);
        }
      },
    );
  }

  void disconnect(String deviceId) {
    Logger.log('[CM] disconnect: deviceId=$deviceId receiverDevs=${_receiverDevice.entries.where((e) => e.value == deviceId).map((e) => e.key).toList()}');
    _heartbeatTimers[deviceId]?.cancel();
    _heartbeatTimers.remove(deviceId);
    _connections[deviceId]?.close();
    _connections.remove(deviceId);
    _tcpConns.remove(deviceId);
    _engineConnections[deviceId]?.close();
    _engineConnections.remove(deviceId);
    _engineTcpConns.remove(deviceId);
    _peerInfo.remove(deviceId);
    _pendingPairRequests.remove(deviceId);
    // Clean up receive engines for this device
    final toRemove = <String>[];
    for (final entry in _receiverDevice.entries) {
      if (entry.value == deviceId) {
        toRemove.add(entry.key);
      }
    }
    for (final tid in toRemove) {
      _shutdownReceiveEngine(deviceId, tid);
      Logger.log('[CM] disconnect: emitting error for transferId=$tid');
      _receiveEventController.add({
        'type': 'error',
        'transferId': tid,
        'deviceId': deviceId,
        'message': 'Connection lost',
      });
    }
    _disconnectController.add(deviceId);
  }

  /// 发送 Control Frame 到指定设备
  void send(String deviceId, FlpFrame frame) {
    final socket = _connections[deviceId];
    socket?.add(frame.toBytes());
  }

  /// 关闭所有连接
  void dispose() {
    for (final t in _heartbeatTimers.values) {
      t.cancel();
    }
    // Shutdown all receive engines
    for (final entry in _receiveEngines.entries) {
      try {
        entry.value.send({'type': 'shutdown'});
      } catch (_) {}
    }
    _receiveEngines.clear();
    _rawFrameBuffers.clear();
    for (final socket in _connections.values) {
      socket.close();
    }
    for (final socket in _engineConnections.values) {
      socket.close();
    }
    _connections.clear();
    _tcpConns.clear();
    _engineConnections.clear();
    _engineTcpConns.clear();
    _receiverDevice.clear();
    _pendingFrames.clear();
    _frameController.close();
    _connectedController.close();
    _pairRequestController.close();
    _pairResultController.close();
    _disconnectController.close();
    _receiveEventController.close();
  }

  String _generateSessionId() {
    final r = DateTime.now().microsecondsSinceEpoch;
    final bytes = List.generate(16, (i) => ((r >> (i * 8)) & 0xFF));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

/// 带设备标识的 Frame
class PeerFrame {
  final String deviceId;
  final FlpFrame frame;
  const PeerFrame({required this.deviceId, required this.frame});
}
