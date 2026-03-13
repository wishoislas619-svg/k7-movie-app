import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../domain/entities/series_category.dart';
import '../../domain/repositories/series_category_repository.dart';
import '../../../../providers.dart';

final seriesCategoriesProvider = StateNotifierProvider<SeriesCategoryController, AsyncValue<List<SeriesCategory>>>((ref) {
  final repository = ref.watch(seriesCategoryRepositoryProvider);
  return SeriesCategoryController(repository);
});

class SeriesCategoryController extends StateNotifier<AsyncValue<List<SeriesCategory>>> {
  final SeriesCategoryRepository _repository;

  SeriesCategoryController(this._repository) : super(const AsyncValue.loading()) {
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
      final category = SeriesCategory(id: const Uuid().v4(), name: name);
      await _repository.addCategory(category);
      await loadCategories();
    } catch (e, s) {
      state = AsyncValue.error(e, s);
    }
  }

  Future<void> updateCategory(SeriesCategory category) async {
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
