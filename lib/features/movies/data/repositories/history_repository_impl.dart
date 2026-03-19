import 'package:sqflite/sqflite.dart';
import '../../../../core/utils/sqlite_service.dart';
import '../../domain/entities/watch_history.dart';
import '../../domain/repositories/history_repository.dart';

class HistoryRepositoryImpl implements HistoryRepository {
  final SqliteService _sqliteService;

  HistoryRepositoryImpl(this._sqliteService);

  @override
  Future<List<WatchHistory>> getHistory() async {
    final db = await _sqliteService.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'watch_history',
      orderBy: 'lastWatchedAt DESC',
    );
    return List.generate(maps.length, (i) => WatchHistory.fromMap(maps[i]));
  }

  @override
  Future<WatchHistory?> getHistoryById(String id) async {
    final db = await _sqliteService.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'watch_history',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isNotEmpty) {
      return WatchHistory.fromMap(maps.first);
    }
    return null;
  }

  @override
  Future<void> saveHistory(WatchHistory history) async {
    final db = await _sqliteService.database;
    await db.insert(
      'watch_history',
      history.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> removeHistory(String id) async {
    final db = await _sqliteService.database;
    await db.delete(
      'watch_history',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> clearHistory() async {
    final db = await _sqliteService.database;
    await db.delete('watch_history');
  }
}
