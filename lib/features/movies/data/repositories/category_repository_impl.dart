import 'package:uuid/uuid.dart';
import '../../../../core/utils/sqlite_service.dart';
import '../../domain/entities/category.dart';
import '../../domain/repositories/category_repository.dart';

class CategoryRepositorySqliteImpl implements CategoryRepository {
  final SqliteService _sqliteService;

  CategoryRepositorySqliteImpl(this._sqliteService);

  @override
  Future<List<Category>> getCategories() async {
    final db = await _sqliteService.database;
    final List<Map<String, dynamic>> maps = await db.query('categories');
    return maps.map((map) => Category.fromMap(map)).toList();
  }

  @override
  Future<void> insertCategory(Category category) async {
    final db = await _sqliteService.database;
    final row = category.toMap();
    if (row['id'] == null || (row['id'] as String).isEmpty) {
      row['id'] = const Uuid().v4();
    }
    await db.insert('categories', row);
  }

  @override
  Future<void> updateCategory(Category category) async {
    final db = await _sqliteService.database;
    await db.update(
      'categories',
      category.toMap(),
      where: 'id = ?',
      whereArgs: [category.id],
    );
  }

  @override
  Future<void> deleteCategory(String id) async {
    final db = await _sqliteService.database;
    await db.delete(
      'categories',
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
