import 'package:sqflite/sqflite.dart';
import '../../../../core/utils/sqlite_service.dart';
import '../../domain/entities/series_category.dart';
import '../../domain/repositories/series_category_repository.dart';

class SeriesCategoryRepositoryImpl implements SeriesCategoryRepository {
  final SqliteService _sqliteService;

  SeriesCategoryRepositoryImpl(this._sqliteService);

  @override
  Future<List<SeriesCategory>> getCategories() async {
    final db = await _sqliteService.database;
    final maps = await db.query('series_categories');
    return maps.map((map) => SeriesCategory.fromMap(map)).toList();
  }

  @override
  Future<void> addCategory(SeriesCategory category) async {
    final db = await _sqliteService.database;
    await db.insert('series_categories', category.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> updateCategory(SeriesCategory category) async {
    final db = await _sqliteService.database;
    await db.update('series_categories', category.toMap(), where: 'id = ?', whereArgs: [category.id]);
  }

  @override
  Future<void> deleteCategory(String id) async {
    final db = await _sqliteService.database;
    await db.delete('series_categories', where: 'id = ?', whereArgs: [id]);
  }
}
