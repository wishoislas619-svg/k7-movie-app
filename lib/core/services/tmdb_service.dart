import 'dart:convert';
import 'package:http/http.dart' as http;

class TmdbService {
  static const String _apiKey = '5417ea29b2d6b3990c6c39542d210455'; 
  static const String _baseUrl = 'https://api.themoviedb.org/3';

  static Future<Map<String, dynamic>?> getMovieMetadata(String tmdbId) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/movie/$tmdbId?api_key=$_apiKey&language=es-MX&append_to_response=images'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'name': data['title'],
          'description': data['overview'],
          'year': (data['release_date'] as String).split('-').first,
          'rating': (data['vote_average'] as num).toDouble(),
          'image': 'https://image.tmdb.org/t/p/w500${data['poster_path']}',
          'backdrop': 'https://image.tmdb.org/t/p/original${data['backdrop_path']}',
        };
      } else {
        print('TMDB Error Movie: Status ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      print('TMDB Error: $e');
    }
    return null;
  }

  /// Duración real de una película (TMDB `runtime`, en minutos).
  /// Se usa como duración autoritativa mientras un torrent progresivo aún
  /// está incompleto: el probe del player sobre un stream parcial puede
  /// reportar una duración corta y falsa (p. ej. 1:56 en vez de 1:55:41).
  /// Devuelve null si no hay runtime o falla la petición.
  static Future<Duration?> getMovieRuntime(String tmdbId) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/movie/$tmdbId?api_key=$_apiKey&language=es-MX'),
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final runtime = data['runtime'];
        if (runtime is num && runtime > 0) {
          return Duration(minutes: runtime.toInt());
        }
      }
    } catch (e) {
      print('TMDB Runtime Error: $e');
    }
    return null;
  }

  /// Key de YouTube del tráiler oficial (pelis `movie`, series `tv`).
  /// Prioriza: Trailer oficial YouTube en español → Trailer YouTube
  /// cualquiera → Teaser YouTube. Reintenta en inglés si no hay nada en
  /// español. Devuelve null si no hay video utilizable.
  static Future<Map<String, String>?> getTrailer(
    String tmdbId, {
    bool isSeries = false,
  }) async {
    try {
      final kind = isSeries ? 'tv' : 'movie';
      for (final lang in ['es-MX', 'en-US']) {
        final response = await http.get(
          Uri.parse('$_baseUrl/$kind/$tmdbId/videos?api_key=$_apiKey&language=$lang'),
        ).timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) continue;
        final results =
            (json.decode(response.body)['results'] as List? ?? [])
                .whereType<Map<String, dynamic>>()
                .where((v) => v['site'] == 'YouTube' && v['key'] != null)
                .toList();
        if (results.isEmpty) continue;
        Map<String, dynamic>? pick;
        // 1. Trailer oficial en español.
        pick = results.where((v) =>
            v['type'] == 'Trailer' &&
            (v['official'] == true) &&
            (v['iso_639_1'] == 'es')).isNotEmpty
            ? results.firstWhere((v) =>
                v['type'] == 'Trailer' &&
                (v['official'] == true) &&
                (v['iso_639_1'] == 'es'))
            : null;
        // 2. Trailer oficial cualquiera.
        pick ??= results.where((v) =>
            v['type'] == 'Trailer' && (v['official'] == true)).isNotEmpty
            ? results.firstWhere((v) =>
                v['type'] == 'Trailer' && (v['official'] == true))
            : null;
        // 3. Cualquier Trailer.
        pick ??= results.where((v) => v['type'] == 'Trailer').isNotEmpty
            ? results.firstWhere((v) => v['type'] == 'Trailer')
            : null;
        // 4. Teaser como último recurso.
        pick ??= results.where((v) => v['type'] == 'Teaser').isNotEmpty
            ? results.firstWhere((v) => v['type'] == 'Teaser')
            : null;
        if (pick != null) {
          return {
            'key': pick['key'] as String,
            'name': (pick['name'] as String?) ?? 'Tráiler',
          };
        }
      }
    } catch (e) {
      print('TMDB Trailer Error: $e');
    }
    return null;
  }

  /// Director + elenco (top 12 con foto) de peli/serie.
  /// Devuelve {'director': {'name':, 'photo':}? , 'cast': [{'name':, 'character':, 'photo':}]}.
  /// `photo` es URL completa o null.
  static Future<Map<String, dynamic>> getCredits(
    String tmdbId, {
    bool isSeries = false,
  }) async {
    try {
      final kind = isSeries ? 'tv' : 'movie';
      final response = await http.get(
        Uri.parse('$_baseUrl/$kind/$tmdbId/credits?api_key=$_apiKey&language=es-MX'),
      ).timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        Map<String, String?>? director;
        final crew = (data['crew'] as List? ?? []).whereType<Map<String, dynamic>>();
        for (final c in crew) {
          if (c['job'] == 'Director') {
            final path = c['profile_path'] as String?;
            director = {
              'name': (c['name'] as String?) ?? '',
              'photo': path == null
                  ? null
                  : 'https://image.tmdb.org/t/p/w185$path',
            };
            break;
          }
        }
        final cast = (data['cast'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .take(12)
            .map((c) {
          final path = c['profile_path'] as String?;
          return {
            'name': (c['name'] as String?) ?? '',
            'character': (c['character'] as String?) ?? '',
            'photo': path == null
                ? null
                : 'https://image.tmdb.org/t/p/w185$path',
          };
        }).toList();
        return {'director': director, 'cast': cast};
      }
    } catch (e) {
      print('TMDB Credits Error: $e');
    }
    return {'director': null, 'cast': <Map<String, String?>>[]};
  }

  static Future<List<Map<String, dynamic>>> searchMovies(String query) async {
    try {
      final uri = Uri.parse(
        '$_baseUrl/search/movie?api_key=$_apiKey&language=es-MX&query=${Uri.encodeQueryComponent(query)}&include_adult=false',
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final results = (data['results'] as List<dynamic>? ?? []);
        return results.map<Map<String, dynamic>>((r) {
          final map = r as Map<String, dynamic>;
          return {
            'tmdbId': map['id'],
            'name': map['title'],
            'image':
                'https://image.tmdb.org/t/p/w500${map['poster_path'] ?? ''}',
            'backdrop':
                'https://image.tmdb.org/t/p/original${map['backdrop_path'] ?? ''}',
            'year':
                ((map['release_date'] as String?) ?? '').split('-').first,
            'rating': (map['vote_average'] as num?)?.toDouble() ?? 0.0,
            'overview': map['overview'] ?? '',
            'mediaType': 'movie',
          };
        }).toList();
      }
    } catch (e) {
      print('TMDB Search Error: $e');
    }
    return [];
  }

  /// Estrenos de cine: en cartelera (MX), ordenados por popularidad.
  static Future<List<Map<String, dynamic>>> getNowPlayingMovies(
      {int limit = 20}) async {
    try {
      final out = <Map<String, dynamic>>[];
      for (var page = 1; page <= 2 && out.length < limit; page++) {
        final uri = Uri.parse(
          '$_baseUrl/movie/now_playing?api_key=$_apiKey&language=es-MX&region=MX&page=$page',
        );
        final response = await http.get(uri);
        if (response.statusCode != 200) break;
        final data = json.decode(response.body);
        final results = (data['results'] as List<dynamic>? ?? []);
        for (final r in results) {
          final map = r as Map<String, dynamic>;
          if (map['poster_path'] == null) continue;
          out.add({
            'tmdbId': map['id'],
            'name': map['title'],
            'image':
                'https://image.tmdb.org/t/p/w500${map['poster_path']}',
            'backdrop':
                'https://image.tmdb.org/t/p/original${map['backdrop_path'] ?? ''}',
            'year':
                ((map['release_date'] as String?) ?? '').split('-').first,
            'rating': (map['vote_average'] as num?)?.toDouble() ?? 0.0,
            'overview': map['overview'] ?? '',
            'popularity': (map['popularity'] as num?)?.toDouble() ?? 0.0,
            'mediaType': 'movie',
          });
          if (out.length >= limit * 2) break;
        }
      }
      out.sort((a, b) =>
          (b['popularity'] as double).compareTo(a['popularity'] as double));
      return out.take(limit).toList();
    } catch (e) {
      print('TMDB NowPlaying Error: $e');
    }
    return [];
  }

  /// Estrenos de series: al aire (MX), ordenadas por popularidad.
  static Future<List<Map<String, dynamic>>> getOnAirSeries(
      {int limit = 20}) async {
    try {
      final out = <Map<String, dynamic>>[];
      for (var page = 1; page <= 2 && out.length < limit * 2; page++) {
        final uri = Uri.parse(
          '$_baseUrl/tv/on_the_air?api_key=$_apiKey&language=es-MX&page=$page',
        );
        final response = await http.get(uri);
        if (response.statusCode != 200) break;
        final data = json.decode(response.body);
        final results = (data['results'] as List<dynamic>? ?? []);
        for (final r in results) {
          final map = r as Map<String, dynamic>;
          if (map['poster_path'] == null) continue;
          out.add({
            'tmdbId': map['id'],
            'name': map['name'],
            'image':
                'https://image.tmdb.org/t/p/w500${map['poster_path']}',
            'backdrop':
                'https://image.tmdb.org/t/p/original${map['backdrop_path'] ?? ''}',
            'year':
                ((map['first_air_date'] as String?) ?? '').split('-').first,
            'rating': (map['vote_average'] as num?)?.toDouble() ?? 0.0,
            'overview': map['overview'] ?? '',
            'popularity': (map['popularity'] as num?)?.toDouble() ?? 0.0,
            'mediaType': 'series',
          });
          if (out.length >= limit * 2) break;
        }
      }
      out.sort((a, b) =>
          (b['popularity'] as double).compareTo(a['popularity'] as double));
      return out.take(limit).toList();
    } catch (e) {
      print('TMDB OnTheAir Error: $e');
    }
    return [];
  }

  /// Fetcher genérico de listados TMDB con el mapa que usa la app.
  static Future<List<Map<String, dynamic>>> _fetchTmdbList({
    required String path,
    required Map<String, String> params,
    required bool isSeries,
    int limit = 20,
    bool sortByPopularity = false,
  }) async {
    try {
      final out = <Map<String, dynamic>>[];
      for (var page = 1; page <= 2 && out.length < limit * 2; page++) {
        final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: {
          'api_key': _apiKey,
          'language': 'es-MX',
          ...params,
          'page': '$page',
        });
        final response = await http.get(uri);
        if (response.statusCode != 200) break;
        final data = json.decode(response.body);
        final results = (data['results'] as List<dynamic>? ?? []);
        for (final r in results) {
          final map = r as Map<String, dynamic>;
          if (map['poster_path'] == null) continue;
          out.add({
            'tmdbId': map['id'],
            'name': isSeries ? map['name'] : map['title'],
            'image':
                'https://image.tmdb.org/t/p/w500${map['poster_path']}',
            'backdrop':
                'https://image.tmdb.org/t/p/original${map['backdrop_path'] ?? ''}',
            'year': (((isSeries
                            ? map['first_air_date']
                            : map['release_date']) as String?) ??
                        '')
                    .split('-')
                    .first,
            'rating': (map['vote_average'] as num?)?.toDouble() ?? 0.0,
            'overview': map['overview'] ?? '',
            'popularity': (map['popularity'] as num?)?.toDouble() ?? 0.0,
            'mediaType': isSeries ? 'series' : 'movie',
          });
          if (out.length >= limit * 2) break;
        }
      }
      if (sortByPopularity) {
        out.sort((a, b) => (b['popularity'] as double)
            .compareTo(a['popularity'] as double));
      }
      return out.take(limit).toList();
    } catch (e) {
      print('TMDB List Error ($path): $e');
    }
    return [];
  }

  /// Mejor valoradas por la crítica.
  static Future<List<Map<String, dynamic>>> getTopRatedMovies(
          {int limit = 20}) =>
      _fetchTmdbList(
          path: '/movie/top_rated', params: {}, isSeries: false, limit: limit);

  static Future<List<Map<String, dynamic>>> getTopRatedSeries(
          {int limit = 20}) =>
      _fetchTmdbList(
          path: '/tv/top_rated', params: {}, isSeries: true, limit: limit);

  /// Clásicas por género (estrenadas hasta 2000, con votos mínimos).
  static Future<List<Map<String, dynamic>>> getClassicMoviesByGenre(
    String genreId, {
    int limit = 20,
  }) =>
      _fetchTmdbList(
        path: '/discover/movie',
        params: {
          'with_genres': genreId,
          'sort_by': 'vote_average.desc',
          'vote_count.gte': '200',
          'primary_release_date.lte': '2000-12-31',
          'include_adult': 'false',
        },
        isSeries: false,
        limit: limit,
      );

  static Future<List<Map<String, dynamic>>> getClassicSeriesByGenre(
    String genreId, {
    int limit = 20,
  }) =>
      _fetchTmdbList(
        path: '/discover/tv',
        params: {
          'with_genres': genreId,
          'sort_by': 'vote_average.desc',
          'vote_count.gte': '100',
          'first_air_date.lte': '2000-12-31',
          'include_adult': 'false',
        },
        isSeries: true,
        limit: limit,
      );

  static Future<List<Map<String, dynamic>>> searchSeries(String query) async {    try {
      final uri = Uri.parse(
        '$_baseUrl/search/tv?api_key=$_apiKey&language=es-MX&query=${Uri.encodeQueryComponent(query)}&include_adult=false',
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final results = (data['results'] as List<dynamic>? ?? []);
        return results.map<Map<String, dynamic>>((r) {
          final map = r as Map<String, dynamic>;
          return {
            'tmdbId': map['id'],
            'name': map['name'],
            'image':
                'https://image.tmdb.org/t/p/w500${map['poster_path'] ?? ''}',
            'backdrop':
                'https://image.tmdb.org/t/p/original${map['backdrop_path'] ?? ''}',
            'year':
                ((map['first_air_date'] as String?) ?? '').split('-').first,
            'rating': (map['vote_average'] as num?)?.toDouble() ?? 0.0,
            'overview': map['overview'] ?? '',
            'mediaType': 'series',
          };
        }).toList();
      }
    } catch (e) {
      print('TMDB Series Search Error: $e');
    }
    return [];
  }

  /// Resuelve el IMDb id (tt...) a partir del id de TMDB, necesario para Torrentio.
  static Future<String?> getImdbId(String tmdbId) async {
    try {
      final uri = Uri.parse(
        '$_baseUrl/movie/$tmdbId/external_ids?api_key=$_apiKey',
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['imdb_id'] as String?;
      }
    } catch (e) {
      print('TMDB ImdbId Error: $e');
    }
    return null;
  }

  static Future<String?> getSeriesImdbId(String tmdbId) async {
    try {
      final uri = Uri.parse(
        '$_baseUrl/tv/$tmdbId/external_ids?api_key=$_apiKey',
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return data['imdb_id'] as String?;
      }
    } catch (e) {
      print('TMDB Series ImdbId Error: $e');
    }
    return null;
  }

  /// Devuelve las temporadas de una serie (para las pestañas de temporada).
  static Future<List<dynamic>> getSeriesSeasons(String tmdbId) async {
    try {
      final uri = Uri.parse(
        '$_baseUrl/tv/$tmdbId?api_key=$_apiKey&language=es-MX',
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final seasons = data['seasons'] as List<dynamic>? ?? [];
        return seasons
            .where((s) => (s['season_number'] as num?)?.toInt() != 0)
            .toList();
      }
    } catch (e) {
      print('TMDB Series Seasons Error: $e');
    }
    return [];
  }

  /// Devuelve los episodios de una temporada de TMDB.
  static Future<List<Map<String, dynamic>>> getSeriesEpisodes(
    String tmdbId,
    int seasonNumber,
  ) async {
    try {
      final uri = Uri.parse(
        '$_baseUrl/tv/$tmdbId/season/$seasonNumber?api_key=$_apiKey&language=es-MX',
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final eps = data['episodes'] as List<dynamic>? ?? [];
        return eps.map<Map<String, dynamic>>((e) {
          final map = e as Map<String, dynamic>;
          return {
            'episodeNumber': map['episode_number'],
            'name': map['name'] ?? '',
            'overview': map['overview'] ?? '',
            'image':
                'https://image.tmdb.org/t/p/w500${map['still_path'] ?? ''}',
          };
        }).toList();
      }
    } catch (e) {
      print('TMDB Series Episodes Error: $e');
    }
    return [];
  }

  static Future<Map<String, dynamic>?> getSeriesMetadata(String tmdbId) async {
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/tv/$tmdbId?api_key=$_apiKey&language=es-MX'),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        return {
          'name': data['name'],
          'description': data['overview'],
          'year': (data['first_air_date'] as String).split('-').first,
          'rating': (data['vote_average'] as num).toDouble(),
          'image': 'https://image.tmdb.org/t/p/w500${data['poster_path']}',
          'backdrop': 'https://image.tmdb.org/t/p/original${data['backdrop_path']}',
          'seasons': data['seasons'], // Basic info of all seasons
          'num_seasons': data['number_of_seasons'],
        };
      }
    } catch (e) {
      print('TMDB Error: $e');
    }
    return null;
  }
}
