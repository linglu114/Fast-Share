import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../engine/frame.dart';

/// FLP TCP 服务器 (架构设计 v2.0 §2.2)
///
/// 监听指定端口，接受连接，管理连接池。
class TcpServer {
  final int port;
  ServerSocket? _server;
  final _connections = <String, TcpConnection>{};
  final _connectionController = StreamController<TcpConnection>.broadcast();

  Stream<TcpConnection> get onConnection => _connectionController.stream;

  TcpServer({this.port = 45678});

  /// 启动服务器
  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    _server!.listen(_handleConnection);
  }

  void _handleConnection(Socket socket) {
    debugPrint('[FastShare] TCP connection accepted from ${socket.remoteAddress.address}:${socket.remotePort}');
    final conn = TcpConnection(socket);
    _connections[conn.id] = conn;
    _connectionController.add(conn);
    conn.onDone.then((_) {
      _connections.remove(conn.id);
    });
  }

  /// 停止服务器
  Future<void> stop() async {
    await _server?.close();
    _server = null;
    for (final conn in _connections.values) {
      conn.close();
    }
    _connections.clear();
    await _connectionController.close();
  }
}

/// TCP 连接封装
class TcpConnection {
  final Socket socket;
  final String id;
  final DateTime connectedAt;

  final _doneCompleter = Completer<void>();
  final _frameController = StreamController<FlpFrame>.broadcast();

  Stream<FlpFrame> get onFrame => _frameController.stream;
  Future<void> get onDone => _doneCompleter.future;

  /// Raw-frame hook: invoked for FILE_DATA / FILE_META frames before CRC32.
  /// Set by [ConnectionManager] to forward raw bytes to ReceiveEngine Isolate.
  void Function(int frameType, Uint8List rawFrame)? onRawFrame;

  // Frame parse buffer using chunk list to avoid O(n²) copies
  final List<Uint8List> _chunks = [];
  int _totalLength = 0;
  bool _processingScheduled = false;

  TcpConnection(this.socket)
      : id = '${socket.remoteAddress.address}:${socket.remotePort}',
        connectedAt = DateTime.now() {
    socket.listen(
      _onData,
      onError: (error) {
        _frameController.addError(error);
        _cleanup();
      },
      onDone: _cleanup,
      cancelOnError: false,
    );
  }

  void _onData(Uint8List data) {
    _chunks.add(data);
    _totalLength += data.length;

    if (!_processingScheduled) {
      _processFrames();
    }
  }

  void _processFrames() {
    _processingScheduled = false;

    // Build contiguous buffer once per batch
    final buffer = _buildContiguous();
    int pos = 0;

    while (pos + FlpFrame.headerLength + FlpFrame.checksumLength <= buffer.length) {
      final bd = ByteData.sublistView(buffer, pos);
      final payloadLen = bd.getUint32(8, Endian.big);
      final totalFrameLen =
          FlpFrame.headerLength + payloadLen + FlpFrame.checksumLength;

      if (pos + totalFrameLen > buffer.length) break;

      // Read frame type (offset 5 in header)
      final frameType = buffer[pos + 5];

      // Intercept FILE_DATA / FILE_META frames — forward raw bytes to
      // ReceiveEngine Isolate, skipping CRC32 on the main Isolate.
      final hook = onRawFrame;
      if (hook != null &&
          (frameType == FlpMessageType.fileData ||
           frameType == FlpMessageType.fileMeta)) {
        final rawBytes = Uint8List.sublistView(buffer, pos, pos + totalFrameLen);
        hook(frameType, rawBytes);
        pos += totalFrameLen;
        continue;
      }

      try {
        final frameBytes = Uint8List.sublistView(buffer, pos, pos + totalFrameLen);
        final frame = FlpFrame.parse(frameBytes);
        _frameController.add(frame);
      } catch (e) {
        _frameController.addError(
          FormatException('Frame parse failed: $e'),
        );
      }

      pos += totalFrameLen;
    }

    // Store remaining data as single chunk (zero-copy view)
    _chunks.clear();
    _totalLength = buffer.length - pos;
    if (_totalLength > 0) {
      _chunks.add(Uint8List.sublistView(buffer, pos));
    }
  }

  Uint8List _buildContiguous() {
    if (_chunks.length == 1) return _chunks.first;
    final buffer = Uint8List(_totalLength);
    int offset = 0;
    for (final chunk in _chunks) {
      buffer.setAll(offset, chunk);
      offset += chunk.length;
    }
    _chunks.clear();
    _chunks.add(buffer);
    return buffer;
  }

  /// 发送 Frame
  void send(FlpFrame frame) {
    try {
      final bytes = frame.toBytes();
      socket.add(bytes);
    } catch (e) {
      _frameController.addError(
        FormatException('Socket write failed: $e'),
      );
    }
  }

  /// 关闭连接
  void close() {
    _cleanup();
  }

  void _cleanup() {
    if (!_doneCompleter.isCompleted) {
      _doneCompleter.complete();
    }
    try {
      socket.close();
    } catch (_) {}
  }
}

/// TCP 客户端连接
class TcpClient {
  /// 连接到指定地址和端口
  static Future<TcpConnection> connect(String host, int port) async {
    final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 5));
    return TcpConnection(socket);
  }
}
