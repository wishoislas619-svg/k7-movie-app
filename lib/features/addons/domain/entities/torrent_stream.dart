class SubtitleItem {
  final String language;
  final String url;
  const SubtitleItem({required this.language, required this.url});
}

class TorrentStream {
  final String name;
  final String title;
  final String? url;
  final String? infoHash;
  final String? magnet;
  final int? fileIdx;
  final bool isDebrid;
  final String? quality;
  final int? sizeBytes;
  final String? sizeHuman;
  final int? seeders;
  final int? peers;
  final String? language;
  final List<String> flags;
  final List<SubtitleItem> subtitles;

  const TorrentStream({
    required this.name,
    required this.title,
    this.url,
    this.infoHash,
    this.magnet,
    this.fileIdx,
    this.isDebrid = false,
    this.quality,
    this.sizeBytes,
    this.sizeHuman,
    this.seeders,
    this.peers,
    this.language,
    this.flags = const [],
    this.subtitles = const [],
  });

  bool get isPlayable => url != null && url!.isNotEmpty;

  String get shortLabel {
    final q = quality == null || quality!.isEmpty ? title : '$title · $quality';
    return q;
  }

  String get meta {
    final parts = <String>[];
    if (quality != null && quality!.isNotEmpty) parts.add(quality!);
    if (sizeHuman != null) parts.add(sizeHuman!);
    if (seeders != null) parts.add('👤 $seeders');
    if (peers != null) parts.add('↕ $peers');
    return parts.join('  ·  ');
  }
}
