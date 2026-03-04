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

  Future<void> addMovie(String name, String imagePath, {String? categoryId}) async {
    final movie = Movie(
      id: '',
      name: name,
      imagePath: imagePath,
      categoryId: categoryId,
      createdAt: DateTime.now(),
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
}
