class Movie {
  final String id;
  final String name;
  final String imagePath;
  final String? categoryId;
  final String? description;
  final String? detailsUrl;
  final int views;
  final double rating;
  final String? year;
  final String? duration;
  final String? backdrop;
  final String? backdropUrl;
  final String? subtitleUrl;
  final bool isPopular;
  final DateTime createdAt;
  final int? creditsStartTime;
  final String? tmdbId;
  final String? imdbId;

  Movie({
    required this.id,
    required this.name,
    required this.imagePath,
    this.categoryId,
    this.description,
    this.detailsUrl,
    this.backdrop,
    this.backdropUrl,
    this.views = 0,
    this.rating = 0.0,
    this.year,
    this.duration,
    this.subtitleUrl,
    this.isPopular = false,
    required this.createdAt,
    this.creditsStartTime,
    this.tmdbId,
    this.imdbId,
  });
}

class VideoOption {
  final String id;
  final String movieId;
  final String serverImagePath;
  final String resolution;
  final String videoUrl;
  final String? language;
  final int extractionAlgorithm;

  VideoOption({
    required this.id,
    required this.movieId,
    required this.serverImagePath,
    required this.resolution,
    required this.videoUrl,
    this.language,
    this.extractionAlgorithm = 1,
  });
}
class VideoQuality {
  final String resolution;
  final String url;

  VideoQuality({
    required this.resolution,
    required this.url,
  });
}
