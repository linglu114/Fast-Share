import 'dart:convert';
import 'dart:typed_data';
import 'frame.dart';

/// Transfer Control Layer 消息编解码 (FLP v1.2 §7)
///
/// TRANSFER_OFFER / ACCEPT / REJECT / CANCEL / PAUSE / RESUME
class TransferControlMessages {
  /// 构建 TRANSFER_OFFER (0x20)
  static FlpFrame buildOffer({
    required String transferId,
    required String senderDeviceId,
    String? senderDeviceName,
    String? batchName,
    required int totalSize,
    required int fileCount,
    bool folderMode = false,
    required List<Map<String, dynamic>> files,
  }) {
    final payload = jsonEncode({
      'transferId': transferId,
      'senderDeviceId': senderDeviceId,
      'senderDeviceName': senderDeviceName ?? senderDeviceId,
      if (batchName != null) 'batchName': batchName,
      'totalSize': totalSize,
      'fileCount': fileCount,
      'folderMode': folderMode,
      'files': files,
    });
    return FlpFrame(
      type: FlpMessageType.transferOffer,
      payload: Uint8List.fromList(utf8.encode(payload)),
    );
  }

  static Map<String, dynamic> parseOffer(FlpFrame frame) {
    return jsonDecode(utf8.decode(frame.payload));
  }

  /// 构建 TRANSFER_ACCEPT (0x21)
  static FlpFrame buildAccept({
    required String transferId,
    required String savePath,
    String overwritePolicy = 'rename',
  }) {
    final payload = jsonEncode({
      'transferId': transferId,
      'savePath': savePath,
      'overwritePolicy': overwritePolicy,
    });
    return FlpFrame(
      type: FlpMessageType.transferAccept,
      payload: Uint8List.fromList(utf8.encode(payload)),
    );
  }

  /// 构建 TRANSFER_REJECT (0x22)
  static FlpFrame buildReject({
    required String transferId,
    String reason = 'USER_REJECTED',
  }) {
    final payload = jsonEncode({
      'transferId': transferId,
      'reason': reason,
    });
    return FlpFrame(
      type: FlpMessageType.transferReject,
      payload: Uint8List.fromList(utf8.encode(payload)),
    );
  }

  /// 构建 TRANSFER_CANCEL (0x23)
  static FlpFrame buildCancel({
    required String transferId,
    String reason = 'USER_CANCEL',
  }) {
    final payload = jsonEncode({
      'transferId': transferId,
      'reason': reason,
    });
    return FlpFrame(
      type: FlpMessageType.transferCancel,
      payload: Uint8List.fromList(utf8.encode(payload)),
    );
  }

  /// 构建 TRANSFER_PAUSE (0x24)
  static FlpFrame buildPause({required String transferId}) {
    final payload = jsonEncode({'transferId': transferId});
    return FlpFrame(
      type: FlpMessageType.transferPause,
      payload: Uint8List.fromList(utf8.encode(payload)),
    );
  }

  /// 构建 TRANSFER_RESUME (0x25)
  static FlpFrame buildResume({required String transferId}) {
    final payload = jsonEncode({'transferId': transferId});
    return FlpFrame(
      type: FlpMessageType.transferResume,
      payload: Uint8List.fromList(utf8.encode(payload)),
    );
  }

  /// 构建 ERROR (0x50)
  static FlpFrame buildError({
    required String code,
    String? message,
    String? transferId,
    String? fileId,
  }) {
    final payload = jsonEncode({
      'code': code,
      if (message != null) 'message': message,
      if (transferId != null) 'transferId': transferId,
      if (fileId != null) 'fileId': fileId,
    });
    return FlpFrame(
      type: FlpMessageType.error,
      flags: FlpFlags.error,
      payload: Uint8List.fromList(utf8.encode(payload)),
    );
  }

  /// 构建 CLIPBOARD_PUSH (0x40)
  static FlpFrame buildClipboardPush({required String text}) {
    final payload = jsonEncode({
      'text': text,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    return FlpFrame(
      type: FlpMessageType.clipboardPush,
      payload: Uint8List.fromList(utf8.encode(payload)),
    );
  }
}
