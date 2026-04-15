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
        };
      }
    } catch (e) {
      print('TMDB Error: $e');
    }
    return null;
  }
}
