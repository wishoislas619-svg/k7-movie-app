import 'dart:convert';

class EpisodeUrl {
  final String url;
  final String? optionId; // ID of the SeriesOption (server)
  final String? quality;

  EpisodeUrl({
    required this.url,
    this.optionId,
    this.quality,
  });

  factory EpisodeUrl.fromMap(Map<String, dynamic> map) {
    return EpisodeUrl(
      url: map['url'],
      optionId: map['optionId'],
      quality: map['quality'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'url': url,
      'optionId': optionId,
      'quality': quality,
    };
  }
}

class Episode {
  final String id;
  final String seasonId;
  final int episodeNumber;
  final String name;
  final String url;
  final List<EpisodeUrl> urls;

  Episode({
    required this.id,
    required this.seasonId,
    required this.episodeNumber,
    required this.name,
    required this.url,
    this.urls = const [],
  });

  factory Episode.fromMap(Map<String, dynamic> map) {
    List<EpisodeUrl> urlsList = [];
    if (map['urls'] != null) {
      try {
        final decoded = json.decode(map['urls']);
        if (decoded is List) {
          urlsList = decoded.map((e) => EpisodeUrl.fromMap(e)).toList();
        }
      } catch (e) {
        print('Error decoding episode urls: $e');
      }
    }

    return Episode(
      id: map['id'],
      seasonId: map['seasonId'],
      episodeNumber: map['episodeNumber'],
      name: map['name'],
      url: map['url'],
      urls: urlsList,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'seasonId': seasonId,
      'episodeNumber': episodeNumber,
      'name': name,
      'url': url,
      'urls': json.encode(urls.map((u) => u.toMap()).toList()),
    };
  }

  Episode copyWith({
    String? id,
    String? seasonId,
    int? episodeNumber,
    String? name,
    String? url,
    List<EpisodeUrl>? urls,
  }) {
    return Episode(
      id: id ?? this.id,
      seasonId: seasonId ?? this.seasonId,
      episodeNumber: episodeNumber ?? this.episodeNumber,
      name: name ?? this.name,
      url: url ?? this.url,
      urls: urls ?? this.urls,
    );
  }
}
