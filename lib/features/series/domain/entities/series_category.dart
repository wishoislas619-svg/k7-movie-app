class SeriesCategory {
  final String id;
  final String name;

  SeriesCategory({required this.id, required this.name});

  factory SeriesCategory.fromMap(Map<String, dynamic> map) {
    return SeriesCategory(
      id: map['id'],
      name: map['name'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
    };
  }
}
