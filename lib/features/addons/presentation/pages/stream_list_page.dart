import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:uuid/uuid.dart';

import '../../../../core/services/foreground_service.dart';
import '../../../../core/services/tmdb_service.dart';
import '../../../../core/services/ad_gate.dart';
import '../../../../features/movies/domain/entities/movie.dart';
import '../../../../features/movies/domain/entities/download_task.dart';
import '../../../../features/movies/data/repositories/download_repository_impl.dart';
import '../../../../features/player/presentation/pages/video_player_page.dart';
import '../../../../providers.dart';
import '../../../../shared/utils/responsive_layout.dart';
import '../../../../shared/widgets/energy_flow_border.dart';
import '../../../../shared/widgets/torrent_loading_dialog.dart';
import '../../domain/entities/addon.dart';
import '../../domain/entities/torrent_stream.dart';
import '../providers/addons_provider.dart';
import '../../data/datasources/torrent_streaming_service.dart';
import '../../../cast/services/media_proxy_service.dart';
import 'addons_manager_page.dart';

class StreamListPage extends ConsumerStatefulWidget {
  const StreamListPage({
    super.key,
    required this.movieName,
    required this.poster,
    this.year,
    required this.tmdbId,
    this.isSeries = false,
    this.seriesEpisodeKey,
  });

  final String movieName;
  final String poster;
  final String? year;
  final String tmdbId;
  final bool isSeries;

  /// Cuando se abre UN episodio concreto de una serie (desde el selector
  /// temporadas/capítulos), `seasonNumber:episodeNumber`. En ese modo la
  /// página NO muestra el selector; resuelve el imdbId y carga DIRECTAMENTE
  /// los streams del addon para ese capítulo (`series/{imdb}:{S}:{E}`).
  final String? seriesEpisodeKey;

  /// ¿Esta instancia está en modo "episodio dedicado"?
  bool get isEpisodeMode => isSeries && seriesEpisodeKey != null;

  @override
  ConsumerState<StreamListPage> createState() => _StreamListPageState();
}

class _StreamListPageState extends ConsumerState<StreamListPage>
    with TickerProviderStateMixin {
  late TabController _tabController;
  String? _imdbId;
  String? _backdrop;
  bool _resolving = true;

  // Metadatos TMDB mostrados en el header.
  double? _rating;
  String? _overview;

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
    double? rating;
    String? overview;
    try {
      final meta = widget.isSeries
          ? await TmdbService.getSeriesMetadata(widget.tmdbId)
          : await TmdbService.getMovieMetadata(widget.tmdbId);
      backdrop = meta?['backdrop'] as String?;
      rating = (meta?['rating'] as num?)?.toDouble();
      overview = meta?['description'] as String?;
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _imdbId = imdb;
      _backdrop = backdrop;
      _rating = rating;
      _overview = overview;
      _resolving = false;
    });
    if (widget.isEpisodeMode) {
      // Modo "episodio dedicado": el selector temporadas/capítulos ya se vio;
      // aquí cargamos los enlaces del capítulo específico con el addon.
      await _loadEpisodeStreams();
    } else if (widget.isSeries) {
      await _loadSeriesSeasons();
    } else {
      await _loadStreams('movie', imdb ?? '');
    }
  }

  /// Carga los streams del addon para el capítulo exacto
  /// (`series/{imdb}:{season}:{episode}`) en modo episodio dedicado.
  Future<void> _loadEpisodeStreams() async {
    final key = widget.seriesEpisodeKey;
    final imdb = _imdbId;
    if (key == null || imdb == null) {
      if (mounted) {
        setState(() {
          _streamsError =
              'No se pudo identificar el episodio en IMDb. Verifica que tengas conectados tus addons.';
        });
      }
      return;
    }
    await _loadStreams('series', '$imdb:$key');
  }

  Future<void> _loadSeriesSeasons() async {
    final seasons = await TmdbService.getSeriesSeasons(widget.tmdbId);
    if (!mounted) return;
    setState(() {
      _seasons = seasons;
      if (seasons.isNotEmpty) {
        _tabController.dispose();
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

  Future<void> _play(TorrentStream stream) async {
    String? directUrl = stream.url;
    TorrentPlaybackSession? torrentSession;
    TorrentStreamingHandle? torrentHandle;

    final isTorrent =
        stream.infoHash != null && stream.infoHash!.isNotEmpty;
    final willUseTorrent =
        isTorrent && (stream.url == null || stream.url!.isEmpty);
    print('🎬 [STREAM_PLAY] stream.name=${stream.name} isTorrent=$isTorrent hasUrl=${stream.url != null && stream.url!.isNotEmpty} willUseTorrent=$willUseTorrent');
    if (willUseTorrent) {
      // Anuncio recompensado ANTES de empezar la descarga del torrent.
      final adOk = await requireRewardedAdForTorrent(
        context,
        ref,
        mediaId: widget.tmdbId,
        mediaType: widget.isSeries ? 'series' : 'movie',
      );
      if (!adOk || !mounted) return;
    }

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
        builder: (_) => TorrentLoadingDialog(progress: progressNotifier),
      );

      try {
        print('TORRENT_DBG: llamando startStreaming() infohash=${stream.infoHash} fileIdx=${stream.fileIdx} '
            'seeders=${stream.seeders} peers=${stream.peers} size=${stream.sizeBytes}');
        final handle = await TorrentStreamingService.instance.startStreaming(
          infoHash: stream.infoHash!,
          fileIndex: stream.fileIdx,
          knownSizeBytes: stream.sizeBytes,
          progressToReport: progressNotifier,
          resumeFromCache: true,
        );
        torrentSession = handle.session;
        torrentHandle = handle;
        directUrl = handle.session.localPath;
        // Conecta el progreso real del torrent al círculo giratorio del diálogo,
        // igual que hace _launchWvcCast. Así el % (medido contra el torrent
        // completo vía piezas nativas) se ve mientras se pone en marcha.
        handle.progress.addListener(() => progressNotifier.value = handle.progress.value);
        print('TORRENT_DBG: startStreaming() OK streamId=${handle.session.streamId} '
            'localPath=${handle.session.localPath} (descarga continúa en 2º plano)');
      } catch (e, st) {
        print('TORRENT_DBG: start() FALLÓ: $e\n$st');
        // El torrent fue liberado porque se tocó OTRO enlace mientras este
        // seguía descargando. El diálogo de ESE flow ya no está (el usuario lo
        // cerró para tocar el nuevo); solo volvemos sin pop ni error para no
        // interferir con la sesión nueva.
        if (e is TorrentReleasedException) return;
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

    // Algoritmo 4 = stream local de libtorrent (infoHash SIN URL directa).
    // Algoritmo 5 = stream http directo (Addon Latam / debrid con URL).
    // 1, 2 y 3 quedan intactos para los flujos de scraper que los usan.
    final algo = willUseTorrent ? 4 : 5;
    print('🎬 [STREAM_PLAY] URL=$url computed algo=$algo (willUseTorrent=$willUseTorrent)');

    final option = VideoOption(
      id: _imdbId ?? '',
      movieId: widget.tmdbId,
      serverImagePath: widget.poster,
      resolution: stream.quality ?? 'Auto',
      videoUrl: url,
      language: stream.language,
      extractionAlgorithm: algo,
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
          extractionAlgorithm: algo,
          torrentDownloadProgress: torrentHandle,
          skipAd: willUseTorrent,
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
          child: widget.isEpisodeMode
              ? _buildStreamsSection(addons)
              : widget.isSeries
              ? (!_seriesTabsReady
                    ? const Center(
                        child: CircularProgressIndicator(
                            color: Color(0xFF00A3FF)),
                      )
                    : _buildEpisodesList())
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
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          widget.poster.isEmpty
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
                          if ((_overview ?? '').isNotEmpty)
                            Positioned(
                              top: 6,
                              right: 6,
                              child: GestureDetector(
                                onTap: () => _showSynopsis(),
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF00A3FF),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: Colors.white38, width: 1),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF00A3FF)
                                            .withValues(alpha: 0.45),
                                        blurRadius: 8,
                                        spreadRadius: 1,
                                      ),
                                    ],
                                  ),
                                  child: const Icon(
                                    Icons.info,
                                    color: Colors.white,
                                    size: 14,
                                  ),
                                ),
                              ),
                            ),
                        ],
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
                      if (widget.year != null || (_rating != null && _rating! > 0)) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            if (widget.year != null) ...[
                              Text(widget.year!,
                                  style: const TextStyle(
                                      color: Colors.white54, fontSize: 14)),
                              if (_rating != null && _rating! > 0) ...[
                                const SizedBox(width: 8),
                                Container(
                                  width: 1,
                                  height: 12,
                                  color: Colors.white24,
                                ),
                                const SizedBox(width: 8),
                              ],
                            ],
                            if (_rating != null && _rating! > 0)
                              Row(
                                children: [
                                  const Icon(Icons.star_rounded,
                                      color: Colors.amber, size: 16),
                                  const SizedBox(width: 4),
                                  Text(
                                    '${_rating!.toStringAsFixed(1)} / 10',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
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

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: EnergyFlowBorder(
            borderRadius: 12,
            borderWidth: 1,
            duration: const Duration(seconds: 8),
            backgroundColor: const Color(0xFF141414),
            child: ListTile(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => StreamListPage(
                      movieName:
                          '${widget.movieName} · S$_currentSeasonNumber E$episodeNumber',
                      poster: image.isEmpty ? widget.poster : image,
                      year: widget.year,
                      tmdbId: widget.tmdbId,
                      isSeries: true,
                      seriesEpisodeKey:
                          '$_currentSeasonNumber:$episodeNumber',
                    ),
                  ),
                );
              },
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
              title: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              subtitle: Row(
                children: [
                  Text(
                    'Episodio $episodeNumber',
                    style: const TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                  const Spacer(),
                  const Icon(Icons.chevron_right,
                      color: Color(0xFF00A3FF), size: 20),
                ],
              ),
            ),
          ),
        );
      },
      ),
    );
  }

  /// Recarga la lista de episodios de la temporada actual.
  Future<void> _refreshEpisodes() async {
    if (_imdbId == null) return;
    await _loadEpisodes(_currentSeasonNumber);
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
    if (widget.isEpisodeMode) {
      await _loadEpisodeStreams();
    } else if (widget.isSeries) {
      final ep = _activeEpisodeNumber ?? 1;
      await _loadStreams('series', '$_imdbId:$_currentSeasonNumber:$ep');
    } else {
      await _loadStreams('movie', _imdbId!);
    }
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
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_canPlay(stream))
                Tooltip(
                  message: 'Transmitir por Web Video Caster',
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: const Icon(
                      Icons.cast,
                      color: Color(0xFFFFFFFF),
                    ),
                    onPressed: () => _launchWvcCast(stream),
                  ),
                ),
              if ((stream.infoHash != null && stream.infoHash!.isNotEmpty) ||
                  (stream.url != null && stream.url!.isNotEmpty))
                Tooltip(
                  message: 'Descargar a Descargas/K7-MOVIE',
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    icon: const Icon(
                      Icons.download,
                      color: Color(0xFF00FF87),
                    ),
                    onPressed: () => _downloadFull(stream),
                  ),
                ),
              const SizedBox(width: 12),
              _canPlay(stream)
                  ? const Icon(Icons.play_circle_fill,
                      color: Color(0xFF00A3FF))
                  : const Icon(Icons.downloading, color: Colors.white24),
            ],
          ),
          onTap: () => _play(stream),
        ),
      ),
    );
  }

  bool _canPlay(TorrentStream stream) =>
      (stream.url != null && stream.url!.isNotEmpty) ||
      (stream.infoHash != null && stream.infoHash!.isNotEmpty);

  TorrentStreamingHandle? _activeWvcHandle;

  /// "Transmitir por Web Video Caster": descarga el torrent hasta ~10%, obtiene
  /// la URL del stream HTTP y la abre en Web Video Caster, siguiendo la
  /// descarga en 2º plano mientras tanto.
  Future<void> _launchWvcCast(TorrentStream stream) async {
    // Si es un torrente (infoHash), SIEMPRE descargar el archivo completo a
    // disco primero (startStreaming espera al 100%) y transmitir ese `file://`.
    // Ignoramos `stream.url` para torrents: transmitir una URL/HTTP parcial o
    // un proxy sin el archivo completo falla en Web Video Caster.
    final isTorrent =
        stream.infoHash != null && stream.infoHash!.isNotEmpty;
    if (!isTorrent && (stream.url == null || stream.url!.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Este enlace no se puede transmitir (falta infohash).'),
        ),
      );
      return;
    }

    String? url;
    TorrentStreamingHandle? handle;

    if (isTorrent) {
      // Anuncio recompensado ANTES de empezar la descarga del torrent.
      final adOk = await requireRewardedAdForTorrent(
        context,
        ref,
        mediaId: widget.tmdbId,
        mediaType: widget.isSeries ? 'series' : 'movie',
      );
      if (!adOk || !mounted) return;
      final progressNotifier = ValueNotifier<TorrentDownloadProgress?>(null);
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => TorrentLoadingDialog(progress: progressNotifier),
      );
      try {
        handle = await TorrentStreamingService.instance.startStreaming(
          infoHash: stream.infoHash!,
          fileIndex: stream.fileIdx,
          knownSizeBytes: stream.sizeBytes,
          progressToReport: progressNotifier,
          resumeFromCache: true,
        );
        final TorrentStreamingHandle h = handle;
        // WVC es una app externa y NO puede leer rutas privadas file:// de
        // nuestra sandbox. Servimos el archivo COMPLETO por HTTP (localhost)
        // vía MediaProxyService, igual que hace el cross-cast de descargas.
        final rawPath = h.session.localPath.replaceFirst('file://', '');
        await MediaProxyService().start();
        final fileId = rawPath.hashCode.abs().toString();
        MediaProxyService().registerLocalFile(fileId, rawPath);
        url = 'http://127.0.0.1:${MediaProxyService().port}/local/$fileId.mkv';
        _activeWvcHandle = h;
        h.progress.addListener(() {
          progressNotifier.value = h.progress.value;
        });
        if (mounted) Navigator.of(context, rootNavigator: true).pop();
        // Mantener el stream vivo mientras WVC reproduce.
        await ForegroundService.start(
          title: 'Transmitiendo a Web Video Caster',
          text: 'Manteniendo la descarga del torrent',
        );
      } catch (e) {
        print('TORRENT_DBG: _launchWvcCast startStreaming FALLÓ: $e');
        if (e is TorrentReleasedException) return;
        if (mounted) {
          Navigator.of(context, rootNavigator: true).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No se pudo transmitir el torrent: $e')),
          );
        }
        return;
      }
    } else {
      url = stream.url;
    }

    final videoUrl = url;
    if (videoUrl == null || videoUrl.isEmpty) return;
    await _openInWebVideoCaster(videoUrl, stream.title);
  }

  Future<void> _openInWebVideoCaster(String videoUrl, String title) async {
    // Esquema de URL oficial de Web Video Caster (instantbits).
    try {
      final encodedUrl = Uri.encodeComponent(videoUrl);
      final encodedTitle = Uri.encodeComponent(title);
      final Uri wvcSchemeUri = Uri.parse(
        'wvc-x-callback://open?url=$encodedUrl&title=$encodedTitle',
      );
      final bool launchedScheme = await launchUrl(
        wvcSchemeUri,
        mode: LaunchMode.externalApplication,
      );
      if (launchedScheme) return;
    } catch (_) {}

    try {
      final intent = AndroidIntent(
        action: 'android.intent.action.VIEW',
        data: videoUrl,
        package: 'com.instantbits.cast.webvideo',
        arguments: {'title': title, 'secure_uri': true},
      );
      await intent.launch();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No se pudo abrir Web Video Caster. Instálala desde la Play Store.',
            ),
          ),
        );
      }
    }
  }

  void _openAddons() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddonsManagerPage()),
    );
  }

  /// Muestra la sinopsis de la película/serie (metadatos de TMDB).
  void _showSynopsis() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: EnergyFlowBorder(
            borderRadius: 20,
            borderWidth: 1.8,
            duration: const Duration(seconds: 8),
            backgroundColor: const Color(0xFF101010),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.movieName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close, color: Colors.white54),
                    ),
                  ],
                ),
                if (_rating != null && _rating! > 0) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.star_rounded,
                          color: Colors.amber, size: 18),
                      const SizedBox(width: 4),
                      Text(
                        '${_rating!.toStringAsFixed(1)} / 10',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _overview ?? 'Sin sinopsis disponible.',
                    maxLines: 12,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 15,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Descarga el torrent COMPLETO a `Descargas/K7-MOVIE/<película>/`.
  /// Si el enlace es un stream http directo (Addon Latam / sin infohash),
  /// lo descarga con un DownloadTask normal a la misma carpeta pública.
  Future<void> _downloadFull(TorrentStream stream) async {
    if ((stream.infoHash == null || stream.infoHash!.isEmpty) &&
        (stream.url == null || stream.url!.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Este enlace no se puede descargar (falta URL).'),
        ),
      );
      return;
    }

    // Stream http directo (Addon Latam): descarga HTTP normal.
    if (stream.infoHash == null || stream.infoHash!.isEmpty) {
      await _downloadDirectHttp(stream);
      return;
    }
    if (!mounted) return;

    // Anuncio recompensado ANTES de empezar la descarga completa del torrent.
    final adOk = await requireRewardedAdForTorrent(
      context,
      ref,
      mediaId: widget.tmdbId,
      mediaType: widget.isSeries ? 'series' : 'movie',
    );
    if (!adOk || !mounted) return;

    final progressNotifier = ValueNotifier<TorrentDownloadProgress?>(null);
    // Dialog de progreso no cancelable (descarga completa hasta el 100%).
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => TorrentLoadingDialog(progress: progressNotifier),
    );
    print('TORRENT_DBG: _downloadFull infohash=${stream.infoHash} movie=${widget.movieName}');
    try {
      final dest = await TorrentStreamingService.instance.downloadComplete(
        infoHash: stream.infoHash!,
        movieName: widget.movieName,
        knownSizeBytes: stream.sizeBytes,
        onProgress: (p) => progressNotifier.value = p,
      );
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Descargado en: $dest'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      print('TORRENT_DBG: _downloadFull FALLÓ: $e');
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo descargar el torrent: $e')),
        );
      }
    }
  }

  /// Descarga un stream HTTP directo (Addon Latam / debrid) mediante
  /// `DownloadTask` → `Downloads/K7-MOVIE/`. Misma infraestructura que
  /// las descargas normales de película (background_downloader + shared storage).
  Future<void> _downloadDirectHttp(TorrentStream stream) async {
    final url = stream.url;
    if (url == null || url.isEmpty) return;
    if (!mounted) return;

    // Anuncio recompensado (mismo gate que torrent descarga).
    final adOk = await requireRewardedAdForTorrent(
      context,
      ref,
      mediaId: widget.tmdbId,
      mediaType: widget.isSeries ? 'series' : 'movie',
    );
    if (!adOk || !mounted) return;

    // Headers mínimos para CDNs que validan Referer/UA.
    final referer = Uri.parse(url).origin;
    final headers = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      'Referer': referer,
      'Origin': referer,
      'Accept': '*/*',
    };

    final task = DownloadTask(
      id: const Uuid().v4(),
      movieId: widget.tmdbId,
      movieName: widget.movieName,
      imagePath: widget.poster,
      videoUrl: url,
      resolution: stream.quality ?? 'Auto',
      status: DownloadStatus.pending,
      createdAt: DateTime.now(),
      headers: headers,
      isSeries: widget.isSeries,
      episodeNumber: _activeEpisodeNumber,
    );

    ref.read(downloadsListProvider.notifier).addDownload(task);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Iniciando descarga en Descargas/K7-MOVIE...'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }
}
