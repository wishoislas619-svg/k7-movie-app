class Series {
  final String id;
  final String name;
  final String imagePath;
  final String? categoryId;
  final String? description;
  final String? detailsUrl;
  final String? backdrop;
  final String? backdropUrl;
  final int views;
  final double rating;
  final String? year;
  final bool isPopular;
  final DateTime createdAt;

  Series({
    required this.id,
    required this.name,
    required this.imagePath,
    this.categoryId,
    this.description,
    this.detailsUrl,
    this.backdrop,
    this.backdropUrl,
    this.views = 0,
    this.rating = 0.0,
    this.year,
    this.isPopular = false,
    required this.createdAt,
  });

  factory Series.fromMap(Map<String, dynamic> map) {
    return Series(
      id: map['id'],
      name: map['name'],
      imagePath: map['imagePath'],
      categoryId: map['categoryId'],
      description: map['description'],
      detailsUrl: map['detailsUrl'],
      backdrop: map['backdrop'],
      backdropUrl: map['backdropUrl'],
      views: map['views'] ?? 0,
      rating: map['rating']?.toDouble() ?? 0.0,
      year: map['year'],
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
      'isPopular': isPopular ? 1 : 0,
      'createdAt': createdAt.toIso8601String(),
    };
  }
}
