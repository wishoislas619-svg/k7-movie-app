class InstalledAddon {
  final String id;
  final String name;
  final String manifestUrl;
  final String? configUrl;
  final DateTime installedAt;

  const InstalledAddon({
    required this.id,
    required this.name,
    required this.manifestUrl,
    this.configUrl,
    required this.installedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'manifestUrl': manifestUrl,
        'configUrl': configUrl,
        'installedAt': installedAt.millisecondsSinceEpoch,
      };

  factory InstalledAddon.fromJson(Map<String, dynamic> json) => InstalledAddon(
        id: json['id'] as String,
        name: json['name'] as String,
        manifestUrl: json['manifestUrl'] as String,
        configUrl: json['configUrl'] as String?,
        installedAt:
            DateTime.fromMillisecondsSinceEpoch(json['installedAt'] as int),
      );
}
