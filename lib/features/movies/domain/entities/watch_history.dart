class WatchHistory {
  final String id;
  final String mediaId;
  final String? episodeId;
  final String mediaType; // 'movie' or 'series'
  final int lastPosition; // in milliseconds
  final int totalDuration; // in milliseconds
  final DateTime lastWatchedAt;
  final String title;
  final String? subtitle; // e.g., "S1 E5: Episode Name"
  final String imagePath;
  final String? videoOptionId; // Enlace/servidor que el usuario eligió

  WatchHistory({
    required this.id,
    required this.mediaId,
    this.episodeId,
    required this.mediaType,
    required this.lastPosition,
    required this.totalDuration,
    required this.lastWatchedAt,
    required this.title,
    this.subtitle,
    required this.imagePath,
    this.videoOptionId,
  });

  WatchHistory copyWith({
    int? lastPosition,
    int? totalDuration,
    DateTime? lastWatchedAt,
    String? videoOptionId,
  }) {
    return WatchHistory(
      id: id,
      mediaId: mediaId,
      episodeId: episodeId,
      mediaType: mediaType,
      lastPosition: lastPosition ?? this.lastPosition,
      totalDuration: totalDuration ?? this.totalDuration,
      lastWatchedAt: lastWatchedAt ?? this.lastWatchedAt,
      title: title,
      subtitle: subtitle,
      imagePath: imagePath,
      videoOptionId: videoOptionId ?? this.videoOptionId,
    );
  }

  factory WatchHistory.fromMap(Map<String, dynamic> map) {
    return WatchHistory(
      id: map['id'],
      mediaId: map['mediaId'],
      episodeId: map['episodeId'],
      mediaType: map['mediaType'],
      lastPosition: map['lastPosition'],
      totalDuration: map['totalDuration'],
      lastWatchedAt: DateTime.parse(map['lastWatchedAt']),
      title: map['title'],
      subtitle: map['subtitle'],
      imagePath: map['imagePath'],
      videoOptionId: map['videoOptionId'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'mediaId': mediaId,
      'episodeId': episodeId,
      'mediaType': mediaType,
      'lastPosition': lastPosition,
      'totalDuration': totalDuration,
      'lastWatchedAt': lastWatchedAt.toIso8601String(),
      'title': title,
      'subtitle': subtitle,
      'imagePath': imagePath,
      'videoOptionId': videoOptionId,
    };
  }
}
