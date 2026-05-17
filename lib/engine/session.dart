import 'dart:convert';
import 'dart:typed_data';
import 'package:uuid/uuid.dart';
import 'frame.dart';

/// Session Layer 消息编解码 (FLP v1.2 §5)
///
/// 负责 HELLO / HELLO_ACK / PING / PONG 的 JSON 序列化与 Frame 封装。
class SessionMessages {
  static const uuid = Uuid();

  /// 构建 HELLO Frame (0x01)
  static FlpFrame buildHello({
    required String deviceId,
    required String sessionId,
    required String deviceName,
    required String platform,
    required String appVersion,
    int protocolVersion = 1,
    List<int>? supportedVersions,
    String? authToken,
    Map<String, bool>? capabilities,
  }) {
    final payload = jsonEncode({
      'deviceId': deviceId,
      'sessionId': sessionId,
      'deviceName': deviceName,
      'platform': platform,
      'appVersion': appVersion,
      'protocolVersion': protocolVersion,
      'supportedVersions': supportedVersions ?? [protocolVersion],
      if (authToken != null) 'authToken': authToken,
      'capabilities': capabilities ??
          {'resume': true, 'clipboard': true, 'aggregate': true},
    });
    return FlpFrame(
      type: FlpMessageType.hello,
      payload: Uint8List.fromList(utf8.encode(payload)),
    );
  }

  /// 解析 HELLO Frame
  static Map<String, dynamic> parseHello(FlpFrame frame) {
    _assertType(frame, FlpMessageType.hello);
    return jsonDecode(utf8.decode(frame.payload));
  }

  /// 构建 HELLO_ACK Frame (0x02) — 接受
  static FlpFrame buildHelloAck({
    required String deviceId,
    required String sessionId,
    int negotiatedVersion = 1,
  }) {
    final payload = jsonEncode({
      'deviceId': deviceId,
      'sessionId': sessionId,
      'accepted': true,
      'negotiatedVersion': negotiatedVersion,
      'message': 'ok',
    });
    return FlpFrame(
      type: FlpMessageType.helloAck,
      payload: Uint8List.fromList(utf8.encode(payload)),
    );
  }

  /// 构建 HELLO_ACK Frame (0x02) — 拒绝
  static FlpFrame buildHelloNack({required String reason}) {
    final payload = jsonEncode({
      'accepted': false,
      'reason': reason,
    });
    return FlpFrame(
      type: FlpMessageType.helloAck,
      payload: Uint8List.fromList(utf8.encode(payload)),
    );
  }

  /// 解析 HELLO_ACK Frame
  static Map<String, dynamic> parseHelloAck(FlpFrame frame) {
    _assertType(frame, FlpMessageType.helloAck);
    return jsonDecode(utf8.decode(frame.payload));
  }

  /// 构建 PING Frame (0x03)
  static FlpFrame buildPing() {
    final payload = jsonEncode({
      'timestamp':
          DateTime.now().millisecondsSinceEpoch,
    });
    return FlpFrame(
      type: FlpMessageType.ping,
      payload: Uint8List.fromList(utf8.encode(payload)),
    );
  }

  /// 构建 PONG Frame (0x04)
  static FlpFrame buildPong({required int timestamp}) {
    final payload = jsonEncode({
      'timestamp': timestamp,
    });
    return FlpFrame(
      type: FlpMessageType.pong,
      payload: Uint8List.fromList(utf8.encode(payload)),
    );
  }

  /// 解析 PING/PONG Frame
  static Map<String, dynamic> parsePingPong(FlpFrame frame) {
    return jsonDecode(utf8.decode(frame.payload));
  }

  static void _assertType(FlpFrame frame, int expectedType) {
    if (frame.type != expectedType) {
      throw FlpFrameException(
          'Expected type 0x${expectedType.toRadixString(16)}, got 0x${frame.type.toRadixString(16)}');
    }
  }
}
