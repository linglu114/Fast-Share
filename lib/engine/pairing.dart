import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'frame.dart';

/// 设备配对协议 (FLP v1.2 §6)
///
/// PAIR_REQUEST → PAIR_CONFIRM → PAIR_RESULT
/// Token = SHA256(deviceIdA + deviceIdB + nonce + pairCode)
class PairingProtocol {
  static final _random = Random.secure();

  /// 生成 6 位随机配对码
  static String generatePairCode() {
    return (_random.nextInt(900000) + 100000).toString();
  }

  /// 生成 16 字节随机 nonce (Base64)
  static String generateNonce() {
    final bytes = List.generate(16, (_) => _random.nextInt(256));
    return base64Encode(bytes);
  }

  /// 构建 PAIR_REQUEST (0x10)
  static FlpFrame buildPairRequest({
    required String deviceId,
    required String deviceName,
    required String pairCode,
    required String nonce,
  }) {
    final payload = jsonEncode({
      'deviceId': deviceId,
      'deviceName': deviceName,
      'pairCode': pairCode,
      'nonce': nonce,
    });
    return FlpFrame(
      type: FlpMessageType.pairRequest,
      payload: Uint8List.fromList(utf8.encode(payload)),
    );
  }

  static Map<String, dynamic> parsePairRequest(FlpFrame frame) {
    return jsonDecode(utf8.decode(frame.payload));
  }

  /// 构建 PAIR_CONFIRM (0x11)
  static FlpFrame buildPairConfirm({
    required String pairCode,
    required String nonce,
    bool confirm = true,
  }) {
    final payload = jsonEncode({
      'pairCode': pairCode,
      'nonce': nonce,
      'confirm': confirm,
    });
    return FlpFrame(
      type: FlpMessageType.pairConfirm,
      payload: Uint8List.fromList(utf8.encode(payload)),
    );
  }

  static Map<String, dynamic> parsePairConfirm(FlpFrame frame) {
    return jsonDecode(utf8.decode(frame.payload));
  }

  /// 构建 PAIR_RESULT (0x12)
  static FlpFrame buildPairResult({
    required bool success,
    String? token,
  }) {
    final payload = jsonEncode({
      'success': success,
      if (token != null) 'token': token,
    });
    return FlpFrame(
      type: FlpMessageType.pairResult,
      payload: Uint8List.fromList(utf8.encode(payload)),
    );
  }

  static Map<String, dynamic> parsePairResult(FlpFrame frame) {
    return jsonDecode(utf8.decode(frame.payload));
  }

  /// 生成配对 Token (FLP v1.2 §6.4)
  /// token = SHA256(deviceIdA + deviceIdB + nonce + pairCode)
  static String generateToken({
    required String deviceIdA,
    required String deviceIdB,
    required String nonce,
    required String pairCode,
  }) {
    final input = '$deviceIdA$deviceIdB$nonce$pairCode';
    final bytes = utf8.encode(input);
    final digest = sha256.convert(bytes);
    return base64Encode(digest.bytes);
  }
}
