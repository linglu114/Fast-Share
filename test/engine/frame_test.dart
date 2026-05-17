import 'package:flutter_test/flutter_test.dart';
import 'package:fastshare/engine/frame.dart';
import 'dart:typed_data';

void main() {
  group('FlpFrame', () {
    test('header length should be 16', () {
      expect(FlpFrame.headerLength, 16);
    });

    test('checksum length should be 4', () {
      expect(FlpFrame.checksumLength, 4);
    });

    test('build and parse round trip', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final frame = FlpFrame(
        type: FlpMessageType.fileData,
        flags: FlpFlags.ackRequired,
        payload: payload,
      );

      final bytes = frame.toBytes();
      final parsed = FlpFrame.parse(bytes);

      expect(parsed.type, FlpMessageType.fileData);
      expect(parsed.flags, FlpFlags.ackRequired);
      expect(parsed.payload, payload);
    });

    test('parse should detect corrupted data', () {
      final payload = Uint8List.fromList([1, 2, 3, 4, 5]);
      final frame = FlpFrame(type: FlpMessageType.fileMeta, payload: payload);
      final bytes = frame.toBytes();

      bytes[21] = 0xFF;

      expect(
        () => FlpFrame.parse(bytes),
        throwsA(isA<FlpFrameException>()),
      );
    });

    test('parse should reject wrong magic', () {
      final payload = Uint8List.fromList([1, 2, 3]);
      final frame = FlpFrame(type: FlpMessageType.hello, payload: payload);
      final bytes = frame.toBytes();

      bytes[0] = 0xFF;

      expect(
        () => FlpFrame.parse(bytes),
        throwsA(isA<FlpFrameException>()),
      );
    });

    test('frame type constants should be unique', () {
      const types = [
        FlpMessageType.hello,
        FlpMessageType.helloAck,
        FlpMessageType.ping,
        FlpMessageType.pong,
        FlpMessageType.pairRequest,
        FlpMessageType.pairConfirm,
        FlpMessageType.pairResult,
        FlpMessageType.transferOffer,
        FlpMessageType.transferAccept,
        FlpMessageType.transferReject,
        FlpMessageType.transferCancel,
        FlpMessageType.transferPause,
        FlpMessageType.transferResume,
        FlpMessageType.fileMeta,
        FlpMessageType.fileData,
        FlpMessageType.fileAck,
        FlpMessageType.fileNack,
        FlpMessageType.fileComplete,
        FlpMessageType.transferComplete,
        FlpMessageType.clipboardPush,
        FlpMessageType.clipboardAck,
        FlpMessageType.error,
      ];
      expect(types.toSet().length, types.length);
    });

    test('empty payload round trip', () {
      final frame = FlpFrame(
        type: FlpMessageType.ping,
        payload: Uint8List(0),
      );
      final bytes = frame.toBytes();
      final parsed = FlpFrame.parse(bytes);

      expect(parsed.type, FlpMessageType.ping);
      expect(parsed.payload, isEmpty);
    });

    test('large payload round trip (1MB)', () {
      final payload = Uint8List(1024 * 1024);
      for (var i = 0; i < payload.length; i++) {
        payload[i] = (i % 256);
      }
      final frame = FlpFrame(type: FlpMessageType.fileData, payload: payload);
      final bytes = frame.toBytes();
      final parsed = FlpFrame.parse(bytes);

      expect(parsed.type, FlpMessageType.fileData);
      expect(parsed.payload, payload);
      expect(bytes.length, FlpFrame.headerLength + payload.length + FlpFrame.checksumLength);
    });

    test('CRC32 computation is deterministic', () {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final crc1 = crc32(data);
      final crc2 = crc32(data);
      expect(crc1, crc2);
    });
  });
}
