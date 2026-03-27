class SeriesOption {
  final String id;
  final String seriesId;
  final String serverImagePath;
  final String resolution;
  final String videoUrl;
  final String? language;

  SeriesOption({
    required this.id,
    required this.seriesId,
    required this.serverImagePath,
    required this.resolution,
    required this.videoUrl,
    this.language,
    this.extractionAlgorithm = 1,
  });

  final int extractionAlgorithm;

  factory SeriesOption.fromMap(Map<String, dynamic> map) {
    return SeriesOption(
      id: map['id'],
      seriesId: map['seriesId'],
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
      'seriesId': seriesId,
      'serverImagePath': serverImagePath,
      'resolution': resolution,
      'videoUrl': videoUrl,
      'language': language,
      'extraction_algorithm': extractionAlgorithm,
    };
  }
}
