import 'package:movie_app/core/services/supabase_service.dart';
import '../../domain/entities/series_category.dart';
import '../../domain/repositories/series_category_repository.dart';

class SeriesCategoryRepositorySupabaseImpl implements SeriesCategoryRepository {
  final _client = SupabaseService.client;

  @override
  Future<List<SeriesCategory>> getCategories() async {
    final data = await _client.from('series_categories').select().order('name');
    return (data as List)
        .map((r) => SeriesCategory(id: r['id'] as String, name: r['name'] as String))
        .toList();
  }

  @override
  Future<void> addCategory(SeriesCategory category) async {
    final row = {'name': category.name};
    if (category.id.isNotEmpty && category.id.length == 36) {
      row['id'] = category.id;
    }
    await _client.from('series_categories').insert(row);
  }

  @override
  Future<void> updateCategory(SeriesCategory category) async {
    await _client
        .from('series_categories')
        .update({'name': category.name})
        .eq('id', category.id);
  }

  @override
  Future<void> deleteCategory(String id) async {
    await _client.from('series_categories').delete().eq('id', id);
  }
}
