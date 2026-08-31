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

  static Future<List<Map<String, dynamic>>> searchSeries(String query) async {
    try {
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
