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
  final bool lastCastWasCast;
  final String? castDeviceName;

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
    this.lastCastWasCast = false,
    this.castDeviceName,
  });

  WatchHistory copyWith({
    int? lastPosition,
    int? totalDuration,
    DateTime? lastWatchedAt,
    String? videoOptionId,
    bool? lastCastWasCast,
    String? castDeviceName,
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
      lastCastWasCast: lastCastWasCast ?? this.lastCastWasCast,
      castDeviceName: castDeviceName ?? this.castDeviceName,
    );
  }

  factory WatchHistory.fromMap(Map<String, dynamic> map) {
    final castValue = map['lastCastWasCast'];
    return WatchHistory(
      id: map['id']?.toString() ?? '',
      mediaId: map['mediaId']?.toString() ?? '',
      episodeId: map['episodeId']?.toString(),
      mediaType: map['mediaType']?.toString() ?? 'movie',
      lastPosition: map['lastPosition'] as int? ?? 0,
      totalDuration: map['totalDuration'] as int? ?? 0,
      lastWatchedAt: map['lastWatchedAt'] != null
          ? DateTime.parse(map['lastWatchedAt'])
          : DateTime.now(),
      title: map['title']?.toString() ?? 'Sin título',
      subtitle: map['subtitle']?.toString(),
      imagePath: map['imagePath']?.toString() ?? '',
      videoOptionId: map['videoOptionId']?.toString(),
      lastCastWasCast: castValue is bool
          ? castValue
          : castValue is int
          ? castValue == 1
          : false,
      castDeviceName: map['castDeviceName']?.toString(),
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
      'lastCastWasCast': lastCastWasCast ? 1 : 0,
      'castDeviceName': castDeviceName,
    };
  }
}
