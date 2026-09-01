import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/tmdb_service.dart';
import '../../../../features/movies/domain/entities/movie.dart';
import '../../../../features/player/presentation/pages/video_player_page.dart';
import '../../../../providers.dart';
import '../../../../shared/utils/responsive_layout.dart';
import '../../../../shared/widgets/energy_flow_border.dart';
import '../../domain/entities/addon.dart';
import '../../domain/entities/torrent_stream.dart';
import '../providers/addons_provider.dart';
import '../../data/datasources/torrent_streaming_service.dart';
import 'addons_manager_page.dart';

class StreamListPage extends ConsumerStatefulWidget {
  const StreamListPage({
    super.key,
    required this.movieName,
    required this.poster,
    this.year,
    required this.tmdbId,
    this.isSeries = false,
  });

  final String movieName;
  final String poster;
  final String? year;
  final String tmdbId;
  final bool isSeries;

  @override
  ConsumerState<StreamListPage> createState() => _StreamListPageState();
}

class _StreamListPageState extends ConsumerState<StreamListPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String? _imdbId;
  String? _backdrop;
  bool _resolving = true;

  // Series
  List<dynamic> _seasons = [];
  List<Map<String, dynamic>> _episodes = [];
  bool _seriesTabsReady = false;
  int _currentSeasonNumber = 1;

  // Streams
  Map<int, List<TorrentStream>> _streamsByEpisode = {};
  bool _loadingStreams = false;
  String? _streamsError;
  int? _activeEpisodeNumber;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 1, vsync: this);
    _resolveImdb();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _resolveImdb() async {
    setState(() => _resolving = true);
    final imdb = widget.isSeries
        ? await TmdbService.getSeriesImdbId(widget.tmdbId)
        : await TmdbService.getImdbId(widget.tmdbId);

    String? backdrop;
    try {
      final meta = widget.isSeries
          ? await TmdbService.getSeriesMetadata(widget.tmdbId)
          : await TmdbService.getMovieMetadata(widget.tmdbId);
      backdrop = meta?['backdrop'] as String?;
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _imdbId = imdb;
      _backdrop = backdrop;
      _resolving = false;
    });
    if (widget.isSeries) {
      await _loadSeriesSeasons();
    } else {
      await _loadStreams('movie', imdb ?? '');
    }
  }

  Future<void> _loadSeriesSeasons() async {
    final seasons = await TmdbService.getSeriesSeasons(widget.tmdbId);
    if (!mounted) return;
    setState(() {
      _seasons = seasons;
      if (seasons.isNotEmpty) {
        _tabController = TabController(
            length: seasons.length, vsync: this);
      }
      _seriesTabsReady = true;
    });
    if (seasons.isNotEmpty) {
      final seasonNumber =
          (seasons.first['season_number'] as int?) ?? 1;
      await _loadEpisodes(seasonNumber);
    }
  }

  Future<void> _loadEpisodes(int seasonNumber) async {
    setState(() => _currentSeasonNumber = seasonNumber);
    final eps = await TmdbService.getSeriesEpisodes(widget.tmdbId, seasonNumber);
    if (!mounted) return;
    setState(() => _episodes = eps);
  }

  Future<void> _loadStreams(String type, String id) async {
    setState(() {
      _loadingStreams = true;
      _streamsError = null;
    });
    try {
      final controller = ref.read(addonsProvider.notifier);
      await controller.load();
      final addons = ref.read(addonsProvider).valueOrNull ?? [];
      final allStreams = <TorrentStream>[];
      for (final addon in addons) {
        final streams = await ref
            .read(addonRepositoryProvider)
            .getStreams(addon: addon, imdbId: id, type: type);
        allStreams.addAll(streams);
      }
      if (!mounted) return;
      setState(() {
        _streamsByEpisode = {_activeEpisodeNumber ?? 0: allStreams};
        _loadingStreams = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _streamsError = 'Error al obtener streams: $e';
          _loadingStreams = false;
        });
      }
    }
  }

  Future<void> _selectEpisode(int episodeNumber) async {
    if (_imdbId == null) return;
    setState(() => _activeEpisodeNumber = episodeNumber);
    await _loadStreams('series', '$_imdbId:$_currentSeasonNumber:$episodeNumber');
  }

  Future<void> _play(TorrentStream stream) async {
    String? directUrl = stream.url;
    TorrentPlaybackSession? torrentSession;

    if (directUrl == null || directUrl.isEmpty) {
      if (stream.infoHash == null || stream.infoHash!.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Este enlace no se puede reproducir (falta infohash).')),
        );
        return;
      }
      // Sin debrid: reproducimos el torrent directamente con libtorrent.
      if (!mounted) return;

      // Notifier para progreso de descarga en tiempo real.
      final progressNotifier = ValueNotifier<TorrentDownloadProgress?>(null);

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => _TorrentLoadingDialog(progress: progressNotifier),
      );

      try {
        print('TORRENT_DBG: llamando downloadAndPlay() infohash=${stream.infoHash} fileIdx=${stream.fileIdx} '
            'seeders=${stream.seeders} peers=${stream.peers} size=${stream.sizeBytes}');
        final session = await TorrentStreamingService.instance.downloadAndPlay(
          infoHash: stream.infoHash!,
          fileIndex: stream.fileIdx,
          knownSeeders: stream.seeders,
          knownPeers: stream.peers,
          knownSizeBytes: stream.sizeBytes,
          onProgress: (p) => progressNotifier.value = p,
        );
        torrentSession = session;
        directUrl = session.localPath;
        print('TORRENT_DBG: start() OK streamId=${session.streamId} localPath=${session.localPath}');
      } catch (e, st) {
        print('TORRENT_DBG: start() FALLÓ: $e\n$st');
        if (mounted) {
          Navigator.of(context, rootNavigator: true).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No se pudo reproducir el torrent: $e')),
          );
        }
        return;
      }
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      print('TORRENT_DBG: dialog cerrado, arrancando player con url=$directUrl');
    }

    final url = directUrl;
    if (url == null || url.isEmpty) return;

    final option = VideoOption(
      id: _imdbId ?? '',
      movieId: widget.tmdbId,
      serverImagePath: widget.poster,
      resolution: stream.quality ?? 'Auto',
      videoUrl: url,
      language: stream.language,
      extractionAlgorithm: 4,
    );
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(
          movieName: '${widget.movieName}${widget.isSeries && _activeEpisodeNumber != null ? ' · E${_activeEpisodeNumber}' : ''}',
          videoOptions: [option],
          mediaId: widget.tmdbId,
          mediaType: widget.isSeries ? 'series' : 'movie',
          imagePath: widget.poster,
          extractionAlgorithm: 4,
          externalSubtitles: [
            for (final s in stream.subtitles)
              SubtitleInfo(language: s.language, url: s.url)
          ],
        ),
      ),
    );
    print('TORRENT_DBG: el player cerró (devolvió). sessionToStop=${torrentSession != null}');
    final sessionToStop = torrentSession;
    if (sessionToStop != null) {
      print('TORRENT_DBG: llamando stop() para liberar el torrent');
      await TorrentStreamingService.instance.stop(sessionToStop);
      print('TORRENT_DBG: stop() hecho');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(
          widget.movieName,
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        ),
        bottom: widget.isSeries && _seriesTabsReady && _seasons.isNotEmpty
            ? TabBar(
                controller: _tabController,
                isScrollable: true,
                labelColor: const Color(0xFF00A3FF),
                unselectedLabelColor: Colors.white54,
                onTap: (i) {
                  final seasonNumber =
                      (_seasons[i]['season_number'] as int?) ?? i + 1;
                  _loadEpisodes(seasonNumber);
                },
                tabs: [
                  for (final s in _seasons)
                    Tab(text: 'T${s['season_number']}')
                ],
              )
            : null,
      ),
      body: _resolving
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF00A3FF)))
          : _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_imdbId == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No se pudo identificar la película en IMDb. Asegúrate de tener conectados tus addons.',
            style: TextStyle(color: Colors.white38),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final addons = ref.watch(addonsProvider).valueOrNull ?? [];

    return Column(
      children: [
        _buildHeader(addons),
        const Divider(color: Colors.white10),
        Expanded(
          child: widget.isSeries && _episodes.isNotEmpty
              ? _buildEpisodesList()
              : _buildStreamsSection(addons),
        ),
      ],
    );
  }

  Widget _buildHeader(List<InstalledAddon> addons) {
    final backdrop = _backdrop;
    final isLandscape = ResponsiveLayout.isLandscape(context);
    final hasBackdrop = backdrop != null && backdrop.isNotEmpty;
    final posterWidth = isLandscape ? 100.0 : 120.0;
    final posterHeight = isLandscape ? 150.0 : 180.0;

    return SizedBox(
      width: double.infinity,
      height: isLandscape ? 220 : 270,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 0. Fondo con el backdrop de TMDB (si está disponible).
          if (hasBackdrop)
            Image.network(
              backdrop,
              fit: BoxFit.cover,
              errorBuilder: (c, e, s) => const ColoredBox(
                color: Color(0xFF141414),
              ),
            )
          else
            const ColoredBox(color: Color(0xFF141414)),
          // 1. Difuminado: sólo en la parte inferior para fundir con el
          //    fondo negro de las cards de enlaces. Arriba la imagen queda nítida.
          if (hasBackdrop)
            Align(
              alignment: Alignment.bottomCenter,
              child: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: Container(
                    width: double.infinity,
                    height: (isLandscape ? 220 : 270) * 0.45,
                    color: Colors.transparent,
                  ),
                ),
              ),
            ),
          // 2. Degradado: arriba casi transparente (imagen visible) -> abajo
          //    negro sólido para conectar con las cards de enlaces.
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.25),
                  Colors.black.withValues(alpha: 0.9),
                  Colors.black,
                ],
                stops: const [0.0, 0.4, 0.85, 1.0],
              ),
            ),
          ),
          // 3. Póster (mismo diseño que en detalles) + título + addons.
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                EnergyFlowBorder(
                  borderRadius: 12,
                  borderWidth: 1.5,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: SizedBox(
                      width: posterWidth,
                      height: posterHeight,
                      child: widget.poster.isEmpty
                          ? const ColoredBox(
                              color: Color(0xFF1A1A1A),
                              child: Icon(Icons.movie_outlined,
                                  color: Colors.white24, size: 32),
                            )
                          : Image.network(
                              widget.poster,
                              fit: BoxFit.cover,
                              errorBuilder: (c, e, s) => const ColoredBox(
                                color: Color(0xFF1A1A1A),
                                child: Icon(Icons.broken_image_outlined,
                                    color: Colors.white24),
                              ),
                            ),
                    ),
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.movieName,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 24,
                          height: 1.1,
                          shadows: [
                            Shadow(
                              color: Colors.black45,
                              offset: Offset(0, 2),
                              blurRadius: 10,
                            ),
                            Shadow(color: Color(0xFF00A3FF), blurRadius: 10),
                          ],
                        ),
                      ),
                      if (widget.year != null) ...[
                        const SizedBox(height: 8),
                        Text(widget.year!,
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 14)),
                      ],
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          const Icon(Icons.extension,
                              size: 14, color: Color(0xFF00A3FF)),
                          const SizedBox(width: 4),
                          Text(
                            '${addons.length} addon(s)',
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 12),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEpisodesList() {
    return RefreshIndicator(
      color: const Color(0xFF00A3FF),
      backgroundColor: const Color(0xFF141414),
      onRefresh: _refreshEpisodes,
      child: ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
      itemCount: _episodes.length,
      itemBuilder: (context, index) {
        final ep = _episodes[index];
        final episodeNumber =
            (ep['episodeNumber'] as int?) ?? index + 1;
        final name = ep['name'] as String? ?? 'Episodio $episodeNumber';
        final image = ep['image'] as String? ?? '';

        final streams =
            _activeEpisodeNumber == episodeNumber ? _streamsByEpisode[episodeNumber] : null;
        final loading = _loadingStreams && _activeEpisodeNumber == episodeNumber;

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: ExpansionTile(
            key: ValueKey(episodeNumber),
            leading: Container(
              width: 56,
              height: 40,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                color: const Color(0xFF1A1A1A),
              ),
              clipBehavior: Clip.antiAlias,
              child: image.isEmpty
                  ? const Center(
                      child: Icon(Icons.tv, color: Colors.white24, size: 20),
                    )
                  : Image.network(image,
                      fit: BoxFit.cover,
                      errorBuilder: (c, e, s) => const Center(
                            child: Icon(Icons.tv,
                                color: Colors.white24, size: 20),
                          )),
            ),
            backgroundColor: Colors.transparent,
            collapsedBackgroundColor: Colors.transparent,
            iconColor: const Color(0xFF00A3FF),
            collapsedIconColor: Colors.white38,
            title: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            subtitle: Text(
              'Episodio $episodeNumber',
              style: const TextStyle(color: Colors.white38, fontSize: 12),
            ),
            onExpansionChanged: (expanded) {
              if (expanded) _selectEpisode(episodeNumber);
            },
            children: [
              if (loading)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator(
                      color: Color(0xFF00A3FF), strokeWidth: 2),
                )
              else if (streams != null)
                ..._buildStreamChips(streams),
            ],
          ),
        );
      },
      ),
    );
  }

  /// Recarga la lista de episodios y los streams del episodio activo.
  Future<void> _refreshEpisodes() async {
    if (_imdbId == null) return;
    await _loadEpisodes(_currentSeasonNumber);
    final ep = _activeEpisodeNumber ?? 1;
    await _loadStreams('series', '$_imdbId:$_currentSeasonNumber:$ep');
  }

  Widget _buildStreamsSection(List<InstalledAddon> addons) {
    if (addons.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.extension_off,
                  color: Colors.white24, size: 48),
              const SizedBox(height: 16),
              const Text('No tienes addons instalados.',
                  style: TextStyle(color: Colors.white38)),
              const SizedBox(height: 12),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF00A3FF)),
                onPressed: () => _openAddons(),
                child: const Text('Ir a Addons'),
              ),
            ],
          ),
        ),
      );
    }

    if (_loadingStreams) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF00A3FF)),
      );
    }
    if (_streamsError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_streamsError!,
              style: const TextStyle(color: Colors.redAccent),
              textAlign: TextAlign.center),
        ),
      );
    }

    final streams = _streamsByEpisode[_activeEpisodeNumber ?? 0] ?? [];
    if (streams.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No se encontraron streams para esta película.\n'
            'Prueba con otro addon o configura un servicio debrid en Torrentio.',
            style: const TextStyle(color: Colors.white38),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final sorted = [...streams]..sort((a, b) {
        final sa = a.seeders ?? 0;
        final sb = b.seeders ?? 0;
        return sb.compareTo(sa);
      });

    return RefreshIndicator(
      color: const Color(0xFF00A3FF),
      backgroundColor: const Color(0xFF141414),
      onRefresh: _refreshStreams,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        itemCount: sorted.length,
        itemBuilder: (context, index) =>
            _buildStreamTile(sorted[index]),
      ),
    );
  }

  /// Vuelve a cargar los streams (refresh con pull-to-refresh).
  Future<void> _refreshStreams() async {
    if (_imdbId == null) return;
    if (widget.isSeries) {
      final ep = _activeEpisodeNumber ?? 1;
      await _loadStreams('series', '$_imdbId:$_currentSeasonNumber:$ep');
    } else {
      await _loadStreams('movie', _imdbId!);
    }
  }

  List<Widget> _buildStreamChips(List<TorrentStream> streams) {
    final sorted = [...streams]..sort((a, b) {
        final sa = a.seeders ?? 0;
        final sb = b.seeders ?? 0;
        return sb.compareTo(sa);
      });
    return [for (final s in sorted) _buildStreamTile(s)];
  }

  Widget _buildStreamTile(TorrentStream stream) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: EnergyFlowBorder(
        borderRadius: 12,
        borderWidth: 1,
        duration: const Duration(seconds: 8),
        backgroundColor: const Color(0xFF141414),
        child: ListTile(
          leading: Icon(
            stream.isDebrid
                ? Icons.verified_user_outlined
                : Icons.link_outlined,
            color: stream.isDebrid
                ? const Color(0xFF00FF87)
                : Colors.white38,
          ),
          title: Row(
            children: [
              Flexible(
                child: Text(
                  stream.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (stream.flags.isNotEmpty || stream.language != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        if (stream.flags.isNotEmpty) ...[
                          Flexible(
                            child: Text(
                              stream.flags.join(' '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        if (stream.language != null)
                          Flexible(
                            child: Text(
                              stream.language!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                  ),
                if (stream.seeders != null || stream.meta.isNotEmpty)
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (stream.seeders != null)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              stream.seeders! > 0
                                  ? Icons.person
                                  : Icons.person_off,
                              size: 14,
                              color: stream.seeders! > 0
                                  ? const Color(0xFF00FF87)
                                  : const Color(0xFFFF6B6B),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${stream.seeders}',
                              style: TextStyle(
                                color: stream.seeders! > 0
                                    ? const Color(0xFF00FF87)
                                    : const Color(0xFFFF6B6B),
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      if (stream.meta.isNotEmpty)
                        Text(stream.meta,
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 12)),
                    ],
                  ),
              ],
            ),
          ),
          trailing: _canPlay(stream)
              ? const Icon(Icons.play_circle_fill, color: Color(0xFF00A3FF))
              : const Icon(Icons.downloading, color: Colors.white24),
          onTap: () => _play(stream),
        ),
      ),
    );
  }

  bool _canPlay(TorrentStream stream) =>
      (stream.url != null && stream.url!.isNotEmpty) ||
      (stream.infoHash != null && stream.infoHash!.isNotEmpty);

  void _openAddons() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddonsManagerPage()),
    );
  }
}

class _TorrentLoadingDialog extends StatefulWidget {
  final ValueNotifier<TorrentDownloadProgress?> progress;

  const _TorrentLoadingDialog({required this.progress});

  @override
  State<_TorrentLoadingDialog> createState() => _TorrentLoadingDialogState();
}

class _TorrentLoadingDialogState extends State<_TorrentLoadingDialog> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TorrentDownloadProgress?>(
      valueListenable: widget.progress,
      builder: (context, progress, _) {
        final hasProgress = progress != null;
        final percent = hasProgress ? progress.percent : 0.0;
        final downloadedMB = hasProgress ? progress.downloadedMB : 0.0;
        final totalMB = hasProgress ? progress.totalMB : 0.0;
        final speedMBps = hasProgress ? progress.speedMBps : 0.0;
        final peers = hasProgress ? progress.peers : 0;
        final seeds = hasProgress ? progress.seeds : 0;
        final state = hasProgress ? progress.state : 'connecting';
        final finished = hasProgress ? progress.finished : false;
        final isDownloading = hasProgress && !finished && (progress.state == 'downloading' || progress.state == 'checkingFiles');

        String statusText;
        if (!hasProgress) {
          statusText = 'Conectando con peers del torrent...\nEsto puede tardar unos segundos.';
        } else if (finished) {
          statusText = 'Descarga completada\nPreparando reproducción...';
        } else {
          final speedStr = speedMBps > 0 ? '${speedMBps.toStringAsFixed(1)} MB/s' : 'esperando peers...';
          final sizeStr = totalMB > 0
              ? '${downloadedMB.toStringAsFixed(1)} / ${totalMB.toStringAsFixed(1)} MB'
              : '${downloadedMB.toStringAsFixed(1)} MB descargados';
          final etaStr = speedMBps > 0 && (totalMB > downloadedMB || percent > 0)
              ? (totalMB > downloadedMB
                  ? ' · ETA ${_formatDuration((totalMB - downloadedMB) / speedMBps * 60)}'
                  : ' · ETA ${_formatDuration(((100 - percent) / percent) * (downloadedMB / speedMBps) * 60)}')
              : '';
          final pctStr = percent >= 0 ? ' (${percent.toStringAsFixed(1)}%)' : '';
          statusText = 'Descargando $sizeStr$pctStr\n'
              '$speedStr · $peers peers · $seeds seeds · $state$etaStr';
        }

        return Dialog(
          backgroundColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 70,
                      height: 70,
                      child: CircularProgressIndicator(
                        color: const Color(0xFF00A3FF),
                        strokeWidth: 5,
                        value: hasProgress && percent >= 0 ? percent / 100 : null,
                      ),
                    ),
                    if (hasProgress)
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            percent >= 0 ? '${percent.toStringAsFixed(1)}%' : '...',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 18,
                            ),
                          ),
                          if (isDownloading)
                            const Text(
                              '⬇',
                              style: TextStyle(color: Color(0xFF00A3FF), fontSize: 14),
                            ),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  statusText,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.4),
                ),
                if (isDownloading) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: percent >= 0 ? percent / 100 : null,
                    backgroundColor: Colors.white24,
                    valueColor: const AlwaysStoppedAnimation(Color(0xFF00A3FF)),
                    minHeight: 4,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatDuration(double seconds) {
    if (seconds < 60) return '${seconds.toInt()}s';
    final mins = (seconds / 60).floor();
    final secs = (seconds % 60).floor();
    if (mins < 60) return '${mins}m ${secs}s';
    final hrs = (mins / 60).floor();
    return '${hrs}h ${mins % 60}m';
  }
}
