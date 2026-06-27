import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;

/// 本地数据库初始化与管理
class AppDatabase {
  static const _dbName = 'fastshare.db';
  static const _dbVersion = 2;

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

    // 桌面端使用 FFI；移动端使用原生 sqflite 实现
    if (!Platform.isAndroid && !Platform.isIOS) {
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
      onUpgrade: _onUpgrade,
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
        savePath TEXT NOT NULL,
        folderMode INTEGER NOT NULL DEFAULT 0
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

  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE transfer_history ADD COLUMN folderMode INTEGER NOT NULL DEFAULT 0',
      );
    }
  }

  static Future<void> close() async {
    final db = _database;
    if (db != null) {
      await db.close();
      _database = null;
    }
  }
}
