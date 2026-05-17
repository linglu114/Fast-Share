import 'package:flutter_test/flutter_test.dart';
import 'package:fastshare/util/format.dart';

void main() {
  group('formatSize', () {
    test('bytes', () {
      expect(formatSize(0), '0 B');
      expect(formatSize(512), '512 B');
      expect(formatSize(1023), '1023 B');
    });

    test('KB', () {
      expect(formatSize(1024), '1.0 KB');
      expect(formatSize(1536), '1.5 KB');
      expect(formatSize(1024 * 1023), '1023.0 KB');
    });

    test('MB', () {
      expect(formatSize(1024 * 1024), '1.0 MB');
      expect(formatSize(100 * 1024 * 1024), '100.0 MB');
    });

    test('GB', () {
      expect(formatSize(1024 * 1024 * 1024), '1.0 GB');
    });
  });

  group('formatSpeed', () {
    test('B/s', () {
      expect(formatSpeed(0), '0.0 B/s');
      expect(formatSpeed(512.0), '512.0 B/s');
    });

    test('KB/s', () {
      expect(formatSpeed(1024.0), '1.0 KB/s');
    });

    test('MB/s', () {
      expect(formatSpeed(1024 * 1024.0), '1.0 MB/s');
    });

    test('GB/s', () {
      expect(formatSpeed(1024 * 1024 * 1024.0), '1.0 GB/s');
    });
  });

  group('formatEta', () {
    test('zero speed returns empty', () {
      expect(formatEta(100, 0, 0), '');
    });

    test('seconds', () {
      expect(formatEta(100, 0, 10), '剩余 10s');
    });

    test('minutes', () {
      expect(formatEta(1024 * 1024, 0, 10240), '剩余 1min');
    });
  });

  group('formatTime', () {
    test('just now', () {
      expect(formatTime(DateTime.now()), '刚刚');
    });

    test('minutes ago', () {
      expect(
        formatTime(DateTime.now().subtract(const Duration(minutes: 5))),
        '5 分钟前',
      );
    });

    test('hours ago', () {
      expect(
        formatTime(DateTime.now().subtract(const Duration(hours: 3))),
        '3 小时前',
      );
    });
  });
}
