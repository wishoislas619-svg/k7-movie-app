class Movie {
  final String id;
  final String name;
  final String imagePath;
  final String? categoryId;
  final DateTime createdAt;

  Movie({
    required this.id,
    required this.name,
    required this.imagePath,
    this.categoryId,
    required this.createdAt,
  });
}

class VideoOption {
  final String id;
  final String movieId;
  final String serverImagePath;
  final String resolution;
  final String videoUrl;

  VideoOption({
    required this.id,
    required this.movieId,
    required this.serverImagePath,
    required this.resolution,
    required this.videoUrl,
  });
}
