import 'package:movie_app/core/services/supabase_service.dart';
import '../../domain/entities/category.dart';
import '../../domain/repositories/category_repository.dart';

class CategoryRepositorySupabaseImpl implements CategoryRepository {
  final _client = SupabaseService.client;

  @override
  Future<List<Category>> getCategories() async {
    final data = await _client.from('categories').select().order('name');
    return (data as List)
        .map((r) => Category(id: r['id'] as String, name: r['name'] as String))
        .toList();
  }

  @override
  Future<void> insertCategory(Category category) async {
    final row = {'name': category.name};
    if (category.id.isNotEmpty && category.id.length == 36) {
      row['id'] = category.id;
    }
    await _client.from('categories').insert(row);
  }

  @override
  Future<void> updateCategory(Category category) async {
    await _client
        .from('categories')
        .update({'name': category.name})
        .eq('id', category.id);
  }

  @override
  Future<void> deleteCategory(String id) async {
    await _client.from('categories').delete().eq('id', id);
  }
}
