import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/repositories/movie_repository.dart';
import '../../domain/entities/movie.dart';
import '../../../../providers.dart';

final moviesProvider = StateNotifierProvider<MovieController, AsyncValue<List<Movie>>>((ref) {
  final repo = ref.watch(movieRepositoryProvider);
  return MovieController(repo);
});

class MovieController extends StateNotifier<AsyncValue<List<Movie>>> {
  final MovieRepository _repository;

  MovieController(this._repository) : super(const AsyncValue.loading()) {
    loadMovies();
  }

  Future<void> loadMovies() async {
    state = const AsyncValue.loading();
    try {
      final movies = await _repository.getMovies();
      state = AsyncValue.data(movies);
    } catch (e, s) {
      state = AsyncValue.error(e, s);
    }
  }

  Future<void> addMovie(String name, String imagePath, {String? categoryId, String? detailsUrl, String? backdropUrl, String? subtitleUrl, String? description, double rating = 0.0, String? year, int? creditsStartTime}) async {
    final movie = Movie(
      id: '',
      name: name,
      imagePath: imagePath,
      categoryId: categoryId,
      detailsUrl: detailsUrl,
      backdropUrl: backdropUrl,
      subtitleUrl: subtitleUrl,
      description: description,
      rating: rating,
      year: year,
      createdAt: DateTime.now(),
      creditsStartTime: creditsStartTime,
    );
    await _repository.addMovie(movie);
    loadMovies();
  }

  Future<void> updateMovie(Movie movie) async {
    await _repository.updateMovie(movie);
    loadMovies();
  }

  Future<void> deleteMovie(String id) async {
    await _repository.deleteMovie(id);
    loadMovies();
  }

  Future<void> incrementViews(String id) async {
    await _repository.incrementViews(id);
    loadMovies();
  }
}
