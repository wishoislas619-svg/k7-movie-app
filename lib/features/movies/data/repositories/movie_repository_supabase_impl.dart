import 'package:movie_app/core/services/supabase_service.dart';
import '../../domain/entities/movie.dart';
import '../../domain/repositories/movie_repository.dart';

class MovieRepositorySupabaseImpl implements MovieRepository {
  final _client = SupabaseService.client;

  // Convierte columnas snake_case de Supabase al modelo Movie
  Movie _fromRow(Map<String, dynamic> row) {
    return Movie(
      id: row['id'] as String,
      name: row['name'] as String,
      imagePath: row['image_path'] as String? ?? '',
      categoryId: row['category_id'] as String?,
      description: row['description'] as String?,
      detailsUrl: row['details_url'] as String?,
      backdropUrl: row['backdrop_url'] as String?,
      subtitleUrl: row['subtitle_url'] as String?,
      views: row['views'] as int? ?? 0,
      rating: (row['rating'] as num?)?.toDouble() ?? 0.0,
      year: row['year'] as String?,
      duration: row['duration'] as String?,
      isPopular: row['is_popular'] as bool? ?? false,
      createdAt: DateTime.parse(row['created_at'] as String),
      creditsStartTime: row['credits_start_time'] as int?,
    );
  }

  Map<String, dynamic> _toRow(Movie m) => {
        'name': m.name,
        'image_path': m.imagePath,
        'category_id': m.categoryId,
        'description': m.description,
        'details_url': m.detailsUrl,
        'backdrop_url': m.backdropUrl,
        'subtitle_url': m.subtitleUrl,
        'views': m.views,
        'rating': m.rating,
        'year': m.year,
        'duration': m.duration,
        'is_popular': m.isPopular,
        'credits_start_time': m.creditsStartTime,
      };

  @override
  Future<List<Movie>> getMovies() async {
    final data = await _client
        .from('movies')
        .select()
        .order('created_at', ascending: false);
    return (data as List).map((row) => _fromRow(row)).toList();
  }

  @override
  Future<void> addMovie(Movie movie) async {
    final row = _toRow(movie);
    // Si el id ya es un UUID válido lo mantenemos, de lo contrario Supabase genera uno
    if (movie.id.isNotEmpty && movie.id.length == 36) {
      row['id'] = movie.id;
    }
    await _client.from('movies').insert(row);
  }

  @override
  Future<void> updateMovie(Movie movie) async {
    await _client.from('movies').update(_toRow(movie)).eq('id', movie.id);
  }

  @override
  Future<void> deleteMovie(String id) async {
    await _client.from('movies').delete().eq('id', id);
  }

  @override
  Future<void> incrementViews(String id) async {
    // Incremento atómico usando una función RPC
    try {
      await _client.rpc('increment_movie_views', params: {'p_id': id});
    } catch (_) {
      // Si la función RPC no existe, hacemos una actualización normal
      final row = await _client.from('movies').select('views').eq('id', id).single();
      final current = (row['views'] as int?) ?? 0;
      await _client.from('movies').update({'views': current + 1}).eq('id', id);
    }
  }

  // ── Video Options ─────────────────────────────────────────────────────────

  VideoOption _optionFromRow(Map<String, dynamic> row) {
    return VideoOption(
      id: row['id'] as String,
      movieId: row['movie_id'] as String,
      serverImagePath: row['server_image_path'] as String? ?? '',
      resolution: row['resolution'] as String? ?? '',
      videoUrl: row['video_url'] as String? ?? '',
      language: row['language'] as String?,
    );
  }

  @override
  Future<List<VideoOption>> getVideoOptions(String movieId) async {
    final data = await _client
        .from('video_options')
        .select()
        .eq('movie_id', movieId);
    return (data as List).map((row) => _optionFromRow(row)).toList();
  }

  @override
  Future<void> addVideoOption(VideoOption option) async {
    await _client.from('video_options').insert({
      'movie_id': option.movieId,
      'server_image_path': option.serverImagePath,
      'resolution': option.resolution,
      'video_url': option.videoUrl,
      'language': option.language,
    });
  }

  @override
  Future<void> updateVideoOption(VideoOption option) async {
    await _client.from('video_options').update({
      'movie_id': option.movieId,
      'server_image_path': option.serverImagePath,
      'resolution': option.resolution,
      'video_url': option.videoUrl,
      'language': option.language,
    }).eq('id', option.id);
  }

  @override
  Future<void> deleteVideoOption(String id) async {
    await _client.from('video_options').delete().eq('id', id);
  }
}
