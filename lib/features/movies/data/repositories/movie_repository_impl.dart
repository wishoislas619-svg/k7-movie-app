import '../../../../core/utils/sqlite_service.dart';
import '../../domain/entities/movie.dart';
import '../../domain/repositories/movie_repository.dart';
import '../models/movie_model.dart';
import 'package:uuid/uuid.dart';

class MovieRepositorySqliteImpl implements MovieRepository {
  final SqliteService _sqliteService;

  MovieRepositorySqliteImpl(this._sqliteService);

  @override
  Future<List<Movie>> getMovies() async {
    final db = await _sqliteService.database;
    final List<Map<String, dynamic>> maps = await db.query('movies', orderBy: 'createdAt DESC');
    return maps.map((map) => MovieModel.fromMap(map)).toList();
  }

  @override
  Future<void> addMovie(Movie movie) async {
    final db = await _sqliteService.database;
    final model = MovieModel(
      id: movie.id.isEmpty ? const Uuid().v4() : movie.id,
      name: movie.name,
      imagePath: movie.imagePath,
      categoryId: movie.categoryId,
      createdAt: movie.createdAt,
    );
    await db.insert('movies', model.toMap());
  }

  @override
  Future<void> updateMovie(Movie movie) async {
    final db = await _sqliteService.database;
    final model = MovieModel(
      id: movie.id,
      name: movie.name,
      imagePath: movie.imagePath,
      categoryId: movie.categoryId,
      createdAt: movie.createdAt,
    );
    await db.update(
      'movies',
      model.toMap(),
      where: 'id = ?',
      whereArgs: [movie.id],
    );
  }

  @override
  Future<void> deleteMovie(String id) async {
    final db = await _sqliteService.database;
    await db.delete('movies', where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<List<VideoOption>> getVideoOptions(String movieId) async {
    final db = await _sqliteService.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'video_options',
      where: 'movieId = ?',
      whereArgs: [movieId],
    );
    return maps.map((map) => VideoOptionModel.fromMap(map)).toList();
  }

  @override
  Future<void> addVideoOption(VideoOption option) async {
    final db = await _sqliteService.database;
    final model = VideoOptionModel(
      id: option.id.isEmpty ? const Uuid().v4() : option.id,
      movieId: option.movieId,
      serverImagePath: option.serverImagePath,
      resolution: option.resolution,
      videoUrl: option.videoUrl,
    );
    await db.insert('video_options', model.toMap());
  }

  @override
  Future<void> updateVideoOption(VideoOption option) async {
    final db = await _sqliteService.database;
    final model = VideoOptionModel(
      id: option.id,
      movieId: option.movieId,
      serverImagePath: option.serverImagePath,
      resolution: option.resolution,
      videoUrl: option.videoUrl,
    );
    await db.update(
      'video_options',
      model.toMap(),
      where: 'id = ?',
      whereArgs: [option.id],
    );
  }

  @override
  Future<void> deleteVideoOption(String id) async {
    final db = await _sqliteService.database;
    await db.delete('video_options', where: 'id = ?', whereArgs: [id]);
  }
}
