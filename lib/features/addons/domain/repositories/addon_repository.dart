import '../../domain/entities/addon.dart';
import '../../domain/entities/torrent_stream.dart';

abstract class AddonRepository {
  Future<List<InstalledAddon>> getInstalledAddons();
  Future<void> installAddon({
    required String name,
    required String manifestUrl,
  });
  Future<void> removeAddon(String id);
  Future<List<TorrentStream>> getStreams({
    required InstalledAddon addon,
    required String imdbId,
    required String type,
  });
}
