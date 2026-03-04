import '../entities/movie.dart';

abstract class MovieRepository {
  Future<List<Movie>> getMovies();
  Future<void> addMovie(Movie movie);
  Future<void> updateMovie(Movie movie);
  Future<void> deleteMovie(String id);
  
  Future<List<VideoOption>> getVideoOptions(String movieId);
  Future<void> addVideoOption(VideoOption option);
  Future<void> updateVideoOption(VideoOption option);
  Future<void> deleteVideoOption(String id);
}
