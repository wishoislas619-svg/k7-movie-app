import '../../domain/entities/movie.dart';

class MovieModel extends Movie {
  MovieModel({
    required super.id,
    required super.name,
    required super.imagePath,
    super.categoryId,
    required super.createdAt,
  });

  factory MovieModel.fromMap(Map<String, dynamic> map) {
    return MovieModel(
      id: map['id'],
      name: map['name'],
      imagePath: map['imagePath'],
      categoryId: map['categoryId'],
      createdAt: DateTime.parse(map['createdAt']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'imagePath': imagePath,
      'categoryId': categoryId,
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
  });

  factory VideoOptionModel.fromMap(Map<String, dynamic> map) {
    return VideoOptionModel(
      id: map['id'],
      movieId: map['movieId'],
      serverImagePath: map['serverImagePath'],
      resolution: map['resolution'],
      videoUrl: map['videoUrl'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'movieId': movieId,
      'serverImagePath': serverImagePath,
      'resolution': resolution,
      'videoUrl': videoUrl,
    };
  }
}
