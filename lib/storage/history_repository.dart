import 'package:sqflite/sqflite.dart';
import '../models/history_record.dart';
import 'database.dart';

/// 传输历史记录存储
class HistoryRepository {
  Future<Database> get _db => AppDatabase.database;

  /// 插入一条历史记录
  Future<int> insert(HistoryRecord record) async {
    final db = await _db;
    return db.insert('transfer_history', record.toMap()..remove('id'));
  }

  /// 获取所有历史记录，按时间倒序
  Future<List<HistoryRecord>> getAll({int limit = 50}) async {
    final db = await _db;
    final maps = await db.query(
      'transfer_history',
      orderBy: 'timestamp DESC',
      limit: limit,
    );
    return maps.map(HistoryRecord.fromMap).toList();
  }

  /// 按传输 ID 查找
  Future<HistoryRecord?> findByTransferId(String transferId) async {
    final db = await _db;
    final maps = await db.query(
      'transfer_history',
      where: 'transferId = ?',
      whereArgs: [transferId],
    );
    if (maps.isEmpty) return null;
    return HistoryRecord.fromMap(maps.first);
  }

  /// 删除指定记录
  Future<int> delete(int id) async {
    final db = await _db;
    return db.delete('transfer_history', where: 'id = ?', whereArgs: [id]);
  }

  /// 清空所有历史记录
  Future<int> clearAll() async {
    final db = await _db;
    return db.delete('transfer_history');
  }
}
