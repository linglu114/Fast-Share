import 'dart:async';
import 'dart:io';

/// Simple file logger for debugging. Writes to fastshare_debug.log in the user's temp directory.
///
/// Uses async file writes to avoid blocking the caller's thread.
class Logger {
  static File? _file;
  static final _buffer = <String>[];
  static Timer? _flushTimer;
  static String? _logPath;
  static bool _flushing = false;

  static String get path => _logPath ?? '';

  static void init({String suffix = ''}) {
    try {
      final dirPath = Platform.environment['TEMP'] ?? Platform.environment['TMP'] ?? '.';
      final name = suffix.isEmpty ? 'fastshare_debug.log' : 'fastshare_debug$suffix.log';
      _logPath = '$dirPath${Platform.pathSeparator}$name';
      _file = File(_logPath!);
      _file!.writeAsString('=== FastShare Debug Log ${DateTime.now()} ===\n', mode: FileMode.append);
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
    _flushTimer ??= Timer(const Duration(seconds: 2), () {
      _flushTimer = null;
      _flush();
    });
  }

  static Future<void> _flush() async {
    if (_flushing || _buffer.isEmpty) return;
    _flushing = true;
    try {
      if (_file != null) {
        final batch = _buffer.join('\n') + '\n';
        _buffer.clear();
        await _file!.writeAsString(batch, mode: FileMode.append);
      }
    } catch (_) {} finally {
      _flushing = false;
    }
  }

  static Future<void> flushSync() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    await _flush();
  }
}
