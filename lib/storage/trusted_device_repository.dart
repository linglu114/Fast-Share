import 'package:sqflite/sqflite.dart';
import 'database.dart';

/// 信任设备存储 (需求 §8, §12)
///
/// 管理已知设备列表、配对 Token、自动接受开关
class TrustedDeviceRepository {
  Future<Database> get _db => AppDatabase.database;

  /// 添加/更新信任设备
  Future<void> upsert({
    required String deviceId,
    required String deviceName,
    required String token,
    bool autoAccept = false,
  }) async {
    final db = await _db;
    await db.insert(
      'trusted_devices',
      {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'token': token,
        'autoAccept': autoAccept ? 1 : 0,
        'createdAt': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 获取所有信任设备
  Future<List<TrustedDevice>> getAll() async {
    final db = await _db;
    final maps = await db.query('trusted_devices');
    return maps.map(TrustedDevice.fromMap).toList();
  }

  /// 按 deviceId 查找
  Future<TrustedDevice?> findByDeviceId(String deviceId) async {
    final db = await _db;
    final maps = await db.query(
      'trusted_devices',
      where: 'deviceId = ?',
      whereArgs: [deviceId],
    );
    if (maps.isEmpty) return null;
    return TrustedDevice.fromMap(maps.first);
  }

  /// 验证 Token
  Future<bool> verifyToken(String deviceId, String token) async {
    final device = await findByDeviceId(deviceId);
    return device?.token == token;
  }

  /// 更新自动接受开关
  Future<void> setAutoAccept(String deviceId, bool autoAccept) async {
    final db = await _db;
    await db.update(
      'trusted_devices',
      {'autoAccept': autoAccept ? 1 : 0},
      where: 'deviceId = ?',
      whereArgs: [deviceId],
    );
  }

  /// 删除信任设备
  Future<void> remove(String deviceId) async {
    final db = await _db;
    await db.delete(
      'trusted_devices',
      where: 'deviceId = ?',
      whereArgs: [deviceId],
    );
  }
}

/// 信任设备实体
class TrustedDevice {
  final String deviceId;
  final String deviceName;
  final String token;
  final bool autoAccept;
  final DateTime createdAt;

  const TrustedDevice({
    required this.deviceId,
    required this.deviceName,
    required this.token,
    required this.autoAccept,
    required this.createdAt,
  });

  factory TrustedDevice.fromMap(Map<String, dynamic> map) => TrustedDevice(
        deviceId: map['deviceId'] as String,
        deviceName: map['deviceName'] as String,
        token: map['token'] as String,
        autoAccept: (map['autoAccept'] as int) == 1,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
      );
}
