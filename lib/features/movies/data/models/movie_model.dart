import '../../domain/entities/movie.dart';

class MovieModel extends Movie {
  MovieModel({
    required super.id,
    required super.name,
    required super.imagePath,
    super.categoryId,
    super.description,
    super.detailsUrl,
    super.backdrop,
    super.backdropUrl,
    super.views = 0,
    super.rating = 0.0,
    super.year,
    super.duration,
    super.subtitleUrl,
    super.isPopular = false,
    required super.createdAt,
  });

  factory MovieModel.fromMap(Map<String, dynamic> map) {
    return MovieModel(
      id: map['id'],
      name: map['name'],
      imagePath: map['imagePath'],
      categoryId: map['categoryId'],
      description: map['description'],
      detailsUrl: map['detailsUrl'],
      backdrop: map['backdrop'],
      backdropUrl: map['backdropUrl'],
      views: map['views'] ?? 0,
      rating: (map['rating'] ?? 0.0).toDouble(),
      year: map['year'],
      duration: map['duration'],
      subtitleUrl: map['subtitleUrl'] ?? map['subtitleRss'],
      isPopular: map['isPopular'] == 1,
      createdAt: DateTime.parse(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'imagePath': imagePath,
      'categoryId': categoryId,
      'description': description,
      'detailsUrl': detailsUrl,
      'backdrop': backdrop,
      'backdropUrl': backdropUrl,
      'views': views,
      'rating': rating,
      'year': year,
      'duration': duration,
      'subtitleUrl': subtitleUrl,
      'isPopular': isPopular ? 1 : 0,
      'createdAt': createdAt.toIso8601String(),
    };
  }
}

class VideoOptionModel extends VideoOption {
  VideoOptionModel({
    required super.id,
    required super.movieId,
    required super.serverImagePath,
    required super.resolution,
    required super.videoUrl,
    super.language,
    super.extractionAlgorithm = 1,
  });

  factory VideoOptionModel.fromMap(Map<String, dynamic> map) {
    return VideoOptionModel(
      id: map['id'],
      movieId: map['movieId'],
      serverImagePath: map['serverImagePath'],
      resolution: map['resolution'],
      videoUrl: map['videoUrl'],
      language: map['language'],
      extractionAlgorithm: map['extraction_algorithm'] ?? 1,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'movieId': movieId,
      'serverImagePath': serverImagePath,
      'resolution': resolution,
      'videoUrl': videoUrl,
      'language': language,
      'extraction_algorithm': extractionAlgorithm,
    };
  }
}
