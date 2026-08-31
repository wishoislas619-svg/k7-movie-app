import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/addon.dart';
import '../../domain/entities/torrent_stream.dart';
import '../../domain/repositories/addon_repository.dart';
import '../datasources/torrentio_client.dart';

class AddonRepositoryImpl implements AddonRepository {
  static const _key = 'installed_addons_v1';

  @override
  Future<List<InstalledAddon>> getInstalledAddons() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => InstalledAddon.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> installAddon({
    required String name,
    required String manifestUrl,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await getInstalledAddons();
    final id = _addonId(manifestUrl);
    final exists = current.any((a) => a.id == id);
    if (exists) return;

    final addon = InstalledAddon(
      id: id,
      name: name,
      manifestUrl: manifestUrl,
      installedAt: DateTime.now(),
    );
    final updated = [...current, addon];
    await prefs.setString(_key, jsonEncode(updated.map((e) => e.toJson()).toList()));
  }

  @override
  Future<void> removeAddon(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await getInstalledAddons();
    final updated = current.where((a) => a.id != id).toList();
    await prefs.setString(_key, jsonEncode(updated.map((e) => e.toJson()).toList()));
  }

  @override
  Future<List<TorrentStream>> getStreams({
    required InstalledAddon addon,
    required String imdbId,
    required String type,
  }) {
    return TorrentioClient.fetchStreams(
      manifestUrl: addon.manifestUrl,
      type: type,
      imdbId: imdbId,
    );
  }

  String _addonId(String manifestUrl) {
    final uri = Uri.tryParse(manifestUrl);
    if (uri == null) return manifestUrl;
    return uri.host + uri.path;
  }
}
