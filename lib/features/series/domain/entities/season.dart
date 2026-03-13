class Season {
  final String id;
  final String seriesId;
  final int seasonNumber;
  final String name;

  Season({
    required this.id,
    required this.seriesId,
    required this.seasonNumber,
    required this.name,
  });

  factory Season.fromMap(Map<String, dynamic> map) {
    return Season(
      id: map['id'],
      seriesId: map['seriesId'],
      seasonNumber: map['seasonNumber'],
      name: map['name'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'seriesId': seriesId,
      'seasonNumber': seasonNumber,
      'name': name,
    };
  }
}
