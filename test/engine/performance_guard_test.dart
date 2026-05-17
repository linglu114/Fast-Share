import 'package:flutter_test/flutter_test.dart';
import 'package:fastshare/engine/performance_guard.dart';
import 'dart:io';

void main() {
  group('SlidingWindow', () {
    test('should allow acquire within limit', () async {
      final window = SlidingWindow(maxBytes: 1024);
      await window.acquire(512);
      expect(window.pendingBytes, 512);
      window.release(512);
      expect(window.pendingBytes, 0);
    });

    test('should block when over limit', () async {
      final window = SlidingWindow(maxBytes: 100);
      await window.acquire(100);
      expect(window.pendingBytes, 100);

      bool acquired = false;
      window.acquire(50).then((_) => acquired = true);

      await Future.delayed(const Duration(milliseconds: 50));
      expect(acquired, false);

      window.release(60);

      await Future.delayed(const Duration(milliseconds: 50));
      expect(acquired, true);
    });

    test('usage ratio', () async {
      final window = SlidingWindow(maxBytes: 1000);
      await window.acquire(300);
      expect(window.usage, 0.3);
      window.release(300);
      expect(window.usage, 0.0);
    });
  });

  group('BufferPool', () {
    test('acquire returns buffer of correct size', () {
      final pool = BufferPool(chunkSize: 256);
      final buf = pool.acquire();
      expect(buf.length, 256);
    });

    test('reuse buffers', () {
      final pool = BufferPool(chunkSize: 128);
      final buf1 = pool.acquire();
      final buf2 = pool.acquire();
      expect(identical(buf1, buf2), false);

      pool.release(buf1);
      final buf3 = pool.acquire();
      expect(identical(buf1, buf3), true);
    });

    test('hit rate tracking', () {
      final pool = BufferPool(chunkSize: 64);
      pool.acquire(); // miss
      pool.acquire(); // miss
      expect(pool.hitRate, 0.0);

      pool.release(List.filled(64, 0, growable: true));
      pool.acquire(); // hit
      expect(pool.hitRate, 1.0 / 3.0);
    });

    test('max pool size', () {
      final pool = BufferPool(chunkSize: 16);
      for (var i = 0; i < 12; i++) {
        pool.release(List.filled(16, i, growable: true));
      }
      for (var i = 0; i < 10; i++) {
        pool.acquire();
      }
      expect(pool.acquire().length, 16);
    });
  });

  group('DirectoryTreeCreator', () {
    late Directory tmpDir;

    setUp(() {
      tmpDir = Directory.systemTemp.createTempSync('fastshare_test_');
    });

    tearDown(() {
      tmpDir.deleteSync(recursive: true);
    });

    test('pre-creates directory structure', () async {
      final paths = [
        'a/b/file1.txt',
        'a/c/file2.txt',
        'x/y/z/file3.txt',
      ];

      await DirectoryTreeCreator.createDirectories(tmpDir.path, paths);

      expect(Directory('${tmpDir.path}/a/b').existsSync(), true);
      expect(Directory('${tmpDir.path}/a/c').existsSync(), true);
      expect(Directory('${tmpDir.path}/x/y/z').existsSync(), true);
    });

    test('handles files in root with no subdirectory', () async {
      final paths = ['rootfile.txt', 'another.txt'];

      await DirectoryTreeCreator.createDirectories(tmpDir.path, paths);

      // No directories should be created
      final dirs = tmpDir.listSync();
      expect(dirs, isEmpty);
    });
  });

  group('AggregateConfig', () {
    test('aggregate and parse round trip', () {
      final files = [
        AggregateFileEntry(
          relativePath: 'test/file1.txt',
          size: 5,
          hash: 12345,
          data: [1, 2, 3, 4, 5],
        ),
        AggregateFileEntry(
          relativePath: 'test/file2.txt',
          size: 3,
          hash: 67890,
          data: [6, 7, 8],
        ),
      ];

      final aggregated = AggregateConfig.aggregate(files);
      final parsed = AggregateConfig.parse(aggregated);

      expect(parsed.length, 2);
      expect(parsed[0].relativePath, 'test/file1.txt');
      expect(parsed[0].size, 5);
      expect(parsed[0].data, [1, 2, 3, 4, 5]);
      expect(parsed[1].relativePath, 'test/file2.txt');
      expect(parsed[1].size, 3);
      expect(parsed[1].data, [6, 7, 8]);
    });

    test('empty aggregate produces empty list', () {
      final aggregated = AggregateConfig.aggregate([]);
      final parsed = AggregateConfig.parse(aggregated);
      expect(parsed, isEmpty);
    });
  });

  group('DynamicConcurrency', () {
    test('should not adjust within 5 second interval', () {
      int lastValue = 4;
      final dc = DynamicConcurrency(
        initialConcurrency: 4,
        minConcurrency: 1,
        maxConcurrency: 8,
        onConcurrencyChanged: (v) => lastValue = v,
      );

      // First call: set baseline throughput to prevent auto-increment
      dc.adjust(
        currentThroughput: 100,
        diskWriteLatencyMs: 50,
        engineMemoryMB: 30,
        uiFps: 60,
      );

      // Second immediate call should be skipped (within 5s)
      dc.adjust(
        currentThroughput: 50, // degraded throughput
        diskWriteLatencyMs: 10,
        engineMemoryMB: 30,
        uiFps: 60,
      );

      // Value may have changed from first call (auto-increment from 0 baseline)
      // but the second call within 5s should not have changed it
      final afterSecond = lastValue;
      // Run a third call immediately to verify it's still the same
      dc.adjust(
        currentThroughput: 50,
        diskWriteLatencyMs: 10,
        engineMemoryMB: 30,
        uiFps: 60,
      );
      expect(lastValue, afterSecond); // no further changes within 5s
    });

    test('forceDowngrade sets to min', () {
      int lastValue = 4;
      final dc = DynamicConcurrency(
        initialConcurrency: 4,
        minConcurrency: 2,
        maxConcurrency: 8,
        onConcurrencyChanged: (v) => lastValue = v,
      );

      dc.forceDowngrade(1);
      expect(lastValue, 2);
      expect(dc.current, 2);
    });

    test('initial concurrency value', () {
      final dc = DynamicConcurrency(
        initialConcurrency: 3,
        minConcurrency: 1,
        maxConcurrency: 6,
        onConcurrencyChanged: (_) {},
      );
      expect(dc.current, 3);
    });
  });
}
