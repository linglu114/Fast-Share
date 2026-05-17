import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;

/// 本地数据库初始化与管理
class AppDatabase {
  static const _dbName = 'fastshare.db';
  static const _dbVersion = 1;

  static Database? _database;
  static bool _ffiInitialized = false;

  /// 桌面端初始化 FFI
  static void initializeForDesktop() {
    if (_ffiInitialized) return;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    _ffiInitialized = true;
  }

  static Future<Database> get database async {
    if (_database != null) return _database!;

    // 所有平台启用 FFI（Android 原生 sqflite_android 与 SDK 35 不兼容）
    if (Platform.isAndroid || !Platform.isIOS) {
      initializeForDesktop();
    }

    _database = await _initDatabase();
    return _database!;
  }

  static Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, _dbName);

    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
    );
  }

  static Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE transfer_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        transferId TEXT NOT NULL,
        deviceId TEXT NOT NULL,
        deviceName TEXT NOT NULL,
        batchName TEXT,
        totalSize INTEGER NOT NULL,
        fileCount INTEGER NOT NULL,
        success INTEGER NOT NULL,
        errorMessage TEXT,
        peakSpeed REAL NOT NULL,
        avgSpeed REAL NOT NULL,
        status TEXT NOT NULL,
        timestamp INTEGER NOT NULL,
        savePath TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE trusted_devices (
        deviceId TEXT PRIMARY KEY,
        deviceName TEXT NOT NULL,
        token TEXT NOT NULL,
        autoAccept INTEGER NOT NULL DEFAULT 0,
        createdAt INTEGER NOT NULL
      )
    ''');
  }

  static Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}
