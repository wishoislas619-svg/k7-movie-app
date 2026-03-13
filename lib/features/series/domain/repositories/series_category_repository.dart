import '../entities/series_category.dart';

abstract class SeriesCategoryRepository {
  Future<List<SeriesCategory>> getCategories();
  Future<void> addCategory(SeriesCategory category);
  Future<void> updateCategory(SeriesCategory category);
  Future<void> deleteCategory(String id);
}
