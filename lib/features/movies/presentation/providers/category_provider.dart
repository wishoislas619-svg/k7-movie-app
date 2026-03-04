import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/category.dart';
import '../../domain/repositories/category_repository.dart';
import '../../../../providers.dart';

final categoriesProvider = StateNotifierProvider<CategoryController, AsyncValue<List<Category>>>((ref) {
  final repository = ref.watch(categoryRepositoryProvider);
  return CategoryController(repository);
});

class CategoryController extends StateNotifier<AsyncValue<List<Category>>> {
  final CategoryRepository _repository;

  CategoryController(this._repository) : super(const AsyncValue.loading()) {
    loadCategories();
  }

  Future<void> loadCategories() async {
    state = const AsyncValue.loading();
    try {
      final categories = await _repository.getCategories();
      state = AsyncValue.data(categories);
    } catch (e, s) {
      state = AsyncValue.error(e, s);
    }
  }

  Future<void> addCategory(String name) async {
    try {
      final category = Category(id: '', name: name);
      await _repository.insertCategory(category);
      await loadCategories();
    } catch (e, s) {
      state = AsyncValue.error(e, s);
    }
  }

  Future<void> updateCategory(Category category) async {
    try {
      await _repository.updateCategory(category);
      await loadCategories();
    } catch (e, s) {
      state = AsyncValue.error(e, s);
    }
  }

  Future<void> deleteCategory(String id) async {
    try {
      await _repository.deleteCategory(id);
      await loadCategories();
    } catch (e, s) {
      state = AsyncValue.error(e, s);
    }
  }
}
