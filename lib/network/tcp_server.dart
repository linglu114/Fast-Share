import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../engine/frame.dart';

/// FLP TCP 服务器 (架构设计 v2.0 §2.2)
///
/// 监听指定端口，接受连接，管理连接池。
class TcpServer {
  int port;
  ServerSocket? _server;
  final _connections = <String, TcpConnection>{};
  final _connectionController = StreamController<TcpConnection>.broadcast();

  Stream<TcpConnection> get onConnection => _connectionController.stream;

  TcpServer({this.port = 34568});

  /// 启动服务器。port=0 时由系统分配可用端口。
  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, port, shared: true);
    port = _server!.port; // 记录实际绑定的端口（port=0 时由系统分配）
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

  // Single growable buffer: capacity-doubling amortizes copies to O(n) total.
  Uint8List _buffer = Uint8List(0);
  int _length = 0;

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
    _ensureCapacity(data.length);
    _buffer.setAll(_length, data);
    _length += data.length;
    _processFrames();
  }

  void _ensureCapacity(int extra) {
    final needed = _length + extra;
    if (needed <= _buffer.length) return;
    var newCap = _buffer.length == 0 ? 65536 : _buffer.length;
    while (newCap < needed) {
      newCap *= 2;
    }
    final newBuf = Uint8List(newCap);
    newBuf.setAll(0, Uint8List.sublistView(_buffer, 0, _length));
    _buffer = newBuf;
  }

  void _processFrames() {
    int pos = 0;

    while (pos + FlpFrame.headerLength + FlpFrame.checksumLength <= _length) {
      final bd = ByteData.sublistView(_buffer, pos);
      final payloadLen = bd.getUint32(8, Endian.big);
      final totalFrameLen =
          FlpFrame.headerLength + payloadLen + FlpFrame.checksumLength;

      if (pos + totalFrameLen > _length) break;

      final frameType = _buffer[pos + 5];

      // Intercept FILE_DATA / FILE_META frames — forward raw bytes to
      // ReceiveEngine Isolate, skipping CRC32 on the main Isolate.
      final hook = onRawFrame;
      if (hook != null &&
          (frameType == FlpMessageType.fileData ||
           frameType == FlpMessageType.fileMeta)) {
        final rawBytes = Uint8List.sublistView(_buffer, pos, pos + totalFrameLen);
        hook(frameType, rawBytes);
        pos += totalFrameLen;
        continue;
      }

      try {
        final frameBytes = Uint8List.sublistView(_buffer, pos, pos + totalFrameLen);
        final frame = FlpFrame.parse(frameBytes);
        _frameController.add(frame);
      } catch (e) {
        _frameController.addError(
          FormatException('Frame parse failed: $e'),
        );
      }

      pos += totalFrameLen;
    }

    // Compact remaining data to buffer start
    if (pos > 0 && pos < _length) {
      _buffer.setAll(0, Uint8List.sublistView(_buffer, pos, _length));
    }
    _length -= pos;
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
