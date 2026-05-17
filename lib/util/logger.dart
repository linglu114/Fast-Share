import 'dart:async';
import 'dart:io';

/// Simple file logger for debugging. Writes to fastshare_debug.log in the user's temp directory.
class Logger {
  static File? _file;
  static final _buffer = <String>[];
  static Timer? _flushTimer;
  static String? _logPath;

  static String get path => _logPath ?? '';

  static void init({String suffix = ''}) {
    try {
      final dirPath = Platform.environment['TEMP'] ?? Platform.environment['TMP'] ?? '.';
      final name = suffix.isEmpty ? 'fastshare_debug.log' : 'fastshare_debug$suffix.log';
      _logPath = '$dirPath${Platform.pathSeparator}$name';
      _file = File(_logPath!);
      _file!.writeAsStringSync('=== FastShare Debug Log ${DateTime.now()} ===\n', mode: FileMode.append);
    } catch (_) {
      _file = null;
    }
  }

  static void log(String message) {
    final ts = DateTime.now().toIso8601String();
    final line = '[$ts] $message';
    _buffer.add(line);
    _scheduleFlush();
  }

  static void _scheduleFlush() {
    _flushTimer ??= Timer(const Duration(milliseconds: 500), () {
      _flushTimer = null;
      _flush();
    });
  }

  static void _flush() {
    try {
      if (_file != null && _buffer.isNotEmpty) {
        final batch = _buffer.join('\n') + '\n';
        _file!.writeAsStringSync(batch, mode: FileMode.append);
        _buffer.clear();
      }
    } catch (_) {}
  }

  static void flushSync() {
    _flushTimer?.cancel();
    _flushTimer = null;
    _flush();
  }
}
