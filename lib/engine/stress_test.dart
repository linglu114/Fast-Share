import 'dart:async';
import 'dart:io';
import 'dart:math';

/// 压力测试工具 (第六阶段)
///
/// 大量文件生成器 + 弱网模拟参数 + 传输性能统计
class StressTestTool {
  final String tempDir;

  StressTestTool() : tempDir = Directory.systemTemp.path;

  /// 生成指定数量和大小范围的测试文件
  Future<List<String>> generateFiles({
    int count = 100,
    int minSize = 1024, // 1KB
    int maxSize = 10 * 1024 * 1024, // 10MB
  }) async {
    final dir = Directory('$tempDir/fastshare_stress_test');
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await dir.create();

    final paths = <String>[];
    final rng = Random();

    for (var i = 0; i < count; i++) {
      final size = minSize + rng.nextInt(maxSize - minSize + 1);
      final path = '${dir.path}/test_file_${i.toString().padLeft(5, '0')}.dat';
      await _createFile(path, size);
      paths.add(path);
    }

    return paths;
  }

  /// 生成包含子目录的文件夹结构
  Future<String> generateFolderStructure({
    int depth = 3,
    int filesPerDir = 20,
    int minSize = 1024,
    int maxSize = 1024 * 1024, // 1MB
  }) async {
    final root = Directory('$tempDir/fastshare_folder_test');
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
    await root.create();

    final rng = Random();

    Future<void> createDir(String path, int remaining) async {
      final dir = Directory(path);
      await dir.create(recursive: true);

      for (var i = 0; i < filesPerDir; i++) {
        final size = minSize + rng.nextInt(maxSize - minSize + 1);
        await _createFile('$path/file_$i.dat', size);
      }

      if (remaining > 0) {
        await createDir('$path/subdir', remaining - 1);
      }
    }

    await createDir('${root.path}/folder_01', depth);
    return root.path;
  }

  Future<void> _createFile(String path, int size) async {
    final file = File(path);
    // 使用固定内容快速创建
    final block = List.filled(min(1024, size), 0x41);
    final raf = await file.open(mode: FileMode.write);
    var written = 0;
    while (written < size) {
      final toWrite = min(block.length, size - written);
      await raf.writeFrom(block.sublist(0, toWrite));
      written += toWrite;
    }
    await raf.close();
  }

  /// 清理测试文件
  Future<void> cleanup() async {
    final dir = Directory('$tempDir/fastshare_stress_test');
    if (await dir.exists()) await dir.delete(recursive: true);

    final folderDir = Directory('$tempDir/fastshare_folder_test');
    if (await folderDir.exists()) {
      await folderDir.delete(recursive: true);
    }
  }

  /// 弱网模拟参数
  static WeakNetworkConfig simulateNetwork({
    double lossRate = 0.01, // 1% 丢包
    int latencyMs = 20, // 20ms 额外延迟
    int bandwidthLimit = 0, // 0 = 不限
  }) {
    return WeakNetworkConfig(
      lossRate: lossRate,
      latencyMs: latencyMs,
      bandwidthLimit: bandwidthLimit,
    );
  }
}

/// 弱网配置
class WeakNetworkConfig {
  final double lossRate;
  final int latencyMs;
  final int bandwidthLimit;

  const WeakNetworkConfig({
    this.lossRate = 0,
    this.latencyMs = 0,
    this.bandwidthLimit = 0,
  });

  /// 是否应丢弃当前包
  bool shouldDrop() => Random().nextDouble() < lossRate;
}

/// 传输性能统计
class TransferStats {
  final Stopwatch _stopwatch = Stopwatch();
  int _totalBytes = 0;
  int _totalFiles = 0;
  int _failedFiles = 0;
  double _peakSpeed = 0;
  final List<double> _speedLog = [];
  final List<String> _errors = [];

  void start() => _stopwatch.start();
  void stop() => _stopwatch.stop();

  void addFileBytes(int bytes) {
    _totalBytes += bytes;
    recordSpeed();
  }

  void fileComplete({bool success = true, String? error}) {
    _totalFiles++;
    if (!success) {
      _failedFiles++;
      if (error != null) _errors.add(error);
    }
  }

  void recordSpeed() {
    final elapsed = _stopwatch.elapsedMilliseconds;
    if (elapsed > 0) {
      final speed = _totalBytes / (elapsed / 1000.0);
      _speedLog.add(speed);
      if (speed > _peakSpeed) _peakSpeed = speed;
    }
  }

  double get averageSpeed {
    if (_speedLog.isEmpty) return 0;
    return _speedLog.reduce((a, b) => a + b) / _speedLog.length;
  }

  double get peakSpeed => _peakSpeed;
  int get totalBytes => _totalBytes;
  int get totalFiles => _totalFiles;
  int get failedFiles => _failedFiles;
  Duration get elapsed => _stopwatch.elapsed;
  double get successRate =>
      _totalFiles > 0 ? (_totalFiles - _failedFiles) / _totalFiles : 0;
  List<String> get errors => List.unmodifiable(_errors);

  Map<String, dynamic> toReport() => {
        'totalBytes': _totalBytes,
        'totalFiles': _totalFiles,
        'failedFiles': _failedFiles,
        'successRate': '${(successRate * 100).toStringAsFixed(1)}%',
        'elapsed': elapsed.toString(),
        'averageSpeed': _formatSpeed(averageSpeed),
        'peakSpeed': _formatSpeed(peakSpeed),
        'errors': _errors,
      };

  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) return '${bytesPerSecond.toStringAsFixed(1)} B/s';
    if (bytesPerSecond < 1024 * 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }
}
