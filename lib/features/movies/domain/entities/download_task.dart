
enum DownloadStatus { pending, downloading, completed, error, paused }

class DownloadTask {
  final String id;
  final String movieId;
  final String movieName;
  final String imagePath;
  final String videoUrl;
  final String resolution;
  final String? savePath;
  final double progress;
  final String? speed;
  final DownloadStatus status;
  final DateTime createdAt;
  final Map<String, String>? headers;

  DownloadTask({
    required this.id,
    required this.movieId,
    required this.movieName,
    required this.imagePath,
    required this.videoUrl,
    required this.resolution,
    this.savePath,
    this.progress = 0.0,
    this.speed,
    required this.status,
    required this.createdAt,
    this.headers,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'movieId': movieId,
      'movieName': movieName,
      'imagePath': imagePath,
      'videoUrl': videoUrl,
      'resolution': resolution,
      'savePath': savePath,
      'progress': progress,
      'status': status.name,
      'createdAt': createdAt.toIso8601String(),
      'headers': headers != null ? _encodeHeaders(headers!) : null,
    };
  }

  static String _encodeHeaders(Map<String, String> h) => h.entries.map((e) => '${e.key}:${e.value}').join('|');
  static Map<String, String> _decodeHeaders(String s) {
    final Map<String, String> map = {};
    s.split('|').forEach((line) {
      final parts = line.split(':');
      if (parts.length >= 2) map[parts[0]] = parts.sublist(1).join(':');
    });
    return map;
  }

  factory DownloadTask.fromMap(Map<String, dynamic> map) {
    return DownloadTask(
      id: map['id'],
      movieId: map['movieId'],
      movieName: map['movieName'],
      imagePath: map['imagePath'],
      videoUrl: map['videoUrl'],
      resolution: map['resolution'],
      savePath: map['savePath'],
      progress: (map['progress'] ?? 0.0).toDouble(),
      status: DownloadStatus.values.byName(map['status']),
      createdAt: DateTime.parse(map['createdAt']),
      headers: map['headers'] != null ? _decodeHeaders(map['headers']) : null,
    );
  }

  DownloadTask copyWith({
    String? id,
    String? movieId,
    String? movieName,
    String? imagePath,
    String? videoUrl,
    String? resolution,
    String? savePath,
    double? progress,
    String? speed,
    DownloadStatus? status,
    DateTime? createdAt,
    Map<String, String>? headers,
  }) {
    return DownloadTask(
      id: id ?? this.id,
      movieId: movieId ?? this.movieId,
      movieName: movieName ?? this.movieName,
      imagePath: imagePath ?? this.imagePath,
      videoUrl: videoUrl ?? this.videoUrl,
      resolution: resolution ?? this.resolution,
      savePath: savePath ?? this.savePath,
      progress: progress ?? this.progress,
      speed: speed ?? this.speed,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      headers: headers ?? this.headers,
    );
  }
}
