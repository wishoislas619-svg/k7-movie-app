import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/repositories/series_repository.dart';
import '../../domain/entities/series.dart';
import '../../../../providers.dart';

final seriesListProvider = StateNotifierProvider<SeriesController, AsyncValue<List<Series>>>((ref) {
  final repo = ref.watch(seriesRepositoryProvider);
  return SeriesController(repo);
});

class SeriesController extends StateNotifier<AsyncValue<List<Series>>> {
  final SeriesRepository _repository;

  SeriesController(this._repository) : super(const AsyncValue.loading()) {
    loadSeries();
  }

  Future<void> loadSeries() async {
    state = const AsyncValue.loading();
    try {
      final series = await _repository.getSeries();
      state = AsyncValue.data(series);
    } catch (e, s) {
      state = AsyncValue.error(e, s);
    }
  }

  Future<void> addSeries(Series series) async {
    await _repository.addSeries(series);
    loadSeries();
  }

  Future<void> updateSeries(Series series) async {
    await _repository.updateSeries(series);
    loadSeries();
  }

  Future<void> deleteSeries(String id) async {
    await _repository.deleteSeries(id);
    loadSeries();
  }

  Future<void> incrementViews(String id) async {
    await _repository.incrementViews(id);
    loadSeries();
  }
}
