import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/series.dart';
import '../../domain/entities/season.dart';
import '../../domain/entities/episode.dart';
import '../../domain/entities/series_option.dart';
import '../providers/series_provider.dart';
import '../providers/series_category_provider.dart';
import '../../domain/entities/series_category.dart';
import '../../../../providers.dart';
import '../../../../shared/widgets/video_extractor_dialog.dart';
import '../../../player/presentation/pages/video_player_page.dart';
import '../../../player/data/datasources/video_service.dart';
import '../../../movies/domain/entities/download_task.dart';
import '../../../movies/presentation/providers/history_provider.dart';
import '../../../movies/domain/entities/movie.dart' show VideoOption;
import 'package:movie_app/features/movies/data/repositories/download_repository_impl.dart';
import 'package:movie_app/features/movies/domain/entities/download_task.dart';
import 'package:movie_app/shared/widgets/video_extractor_dialog.dart';
import 'package:movie_app/features/cast/presentation/widgets/cast_button.dart';
import 'package:movie_app/features/movies/presentation/widgets/cast_button_overlay.dart';
import 'package:movie_app/features/auth/presentation/providers/auth_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:movie_app/core/services/ad_service.dart';
import 'package:movie_app/shared/widgets/energy_flow_border.dart';
import 'package:movie_app/shared/utils/responsive_layout.dart';
import 'dart:async';

class SeriesDetailsPage extends ConsumerStatefulWidget {
  final Series series;
  final String? autoPlayEpisodeId;
  final String? autoPlayVideoOptionId;
  final Duration? autoPlayStartPosition;

  /// Cuando se proporciona (desde "Continuar Viendo"), la página carga la
  /// temporada del episodio y hace scroll hasta él para centrarlo.
  final String? centerOnEpisodeId;

  const SeriesDetailsPage({
    super.key,
    required this.series,
    this.autoPlayEpisodeId,
    this.autoPlayVideoOptionId,
    this.autoPlayStartPosition,
    this.centerOnEpisodeId,
  });

  @override
  ConsumerState<SeriesDetailsPage> createState() => _SeriesDetailsPageState();
}

class _SeriesDetailsPageState extends ConsumerState<SeriesDetailsPage> {
  List<Season> _seasons = [];
  Map<String, List<Episode>> _episodesMap = {};
  Season? _selectedSeason;
  List<SeriesOption>? _videoOptions;
  bool _isLoading = true;
  bool _isDescriptionExpanded = false;
  final ScrollController _scrollController = ScrollController();
  final Map<String, GlobalKey> _episodeKeys = {};
  bool _isRefreshing = false;
  bool _isAdLoading = false;
  String? _adErrorMessage;

  @override
  void initState() {
    super.initState();
    _loadSeasons().then((_) {
      // Auto-play desde "Continuar Viendo" si se proporcionan parámetros
      if (widget.autoPlayEpisodeId != null && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _autoPlayEpisode());
      }
    });
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (_scrollController.position.pixels >
        _scrollController.position.maxScrollExtent + 50) {
      if (!_isRefreshing) _onRefresh();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _onRefresh() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    await _loadSeasons();
    setState(() => _isRefreshing = false);
  }

  Future<void> _loadSeasons() async {
    final repo = ref.read(seriesRepositoryProvider);
    final seasons = await repo.getSeasonsForSeries(widget.series.id);

    final Map<String, List<Episode>> epMap = {};
    for (var s in seasons) {
      epMap[s.id] = await repo.getEpisodesForSeason(s.id);
    }

    final opts = await repo.getSeriesOptions(widget.series.id);

    if (mounted) {
      setState(() {
        _seasons = seasons;
        _episodesMap = epMap;
        _videoOptions = opts;
        if (_seasons.isNotEmpty) _selectedSeason = _seasons.first;

        // Centrar al usuario en el episodio/temporada de "Continuar Viendo".
        final centerId = widget.centerOnEpisodeId;
        if (centerId != null) {
          for (final season in seasons) {
            if ((epMap[season.id] ?? []).any((e) => e.id == centerId)) {
              _selectedSeason = season;
              break;
            }
          }
        }
        _isLoading = false;
      });

      if (widget.centerOnEpisodeId != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEpisode());
      }
    }
  }

  // Altura media estimada de una tarjeta de episodio (ListTile + márgenes).
  // Sirve para saltar a un episodio concreto en la SliverList virtualizada
  // cuando ese item aún no se ha construido (está fuera del viewport).
  static const double _episodeItemEstimate = 88.0;

  void _scrollToEpisode() {
    final centerId = widget.centerOnEpisodeId;
    if (centerId == null) return;
    // Ya construido (visible / dentro del cacheExtent): snap directo.
    final ctx = _episodeKeys[centerId]?.currentContext;
    if (ctx != null) {
      _animateToEpisode(ctx);
      return;
    }
    // Virtualizado y aún sin construir: estimamos el offset respecto al FINAL
    // de la lista (los items tienen altura casi constante) y saltamos a él;
    // un frame después el item queda dentro del cacheExtent y lo centramos.
    final eps = _episodesMap[_selectedSeason?.id] ?? const <Episode>[];
    final index = eps.indexWhere((e) => e.id == centerId);
    if (index < 0 || !_scrollController.hasClients) return;
    final position = _scrollController.position;
    final maxExtent = position.maxScrollExtent;
    var estimate = maxExtent -
        ((eps.length - index) * _episodeItemEstimate) -
        64; // trailing SizedBox(50) + margen
    if (estimate < 0) estimate = 0;
    if (estimate > maxExtent) estimate = maxExtent;
    _scrollController.jumpTo(estimate);

    WidgetsBinding.instance.addPostFrameCallback((_) => _convergeToEpisode(
          centerId,
          estimate: estimate,
          direction: 0,
        ));
  }

  /// Tras el salto estimado, si el episodio aún no se construyó, recorremos la
  /// lista en la dirección correcta hasta que entre en el cacheExtent y luego
  /// lo centramos con `Scrollable.ensureVisible`.
  void _convergeToEpisode(
    String centerId, {
    required double estimate,
    required int direction,
  }) {
    if (!mounted || !_scrollController.hasClients) return;
    final ctx = _episodeKeys[centerId]?.currentContext;
    if (ctx != null) {
      _animateToEpisode(ctx);
      return;
    }
    if (direction.abs() > 20) return; // limite de convergencia

    final eps = _episodesMap[_selectedSeason?.id] ?? const <Episode>[];
    final index = eps.indexWhere((e) => e.id == centerId);
    if (index < 0) return;
    final position = _scrollController.position;
    // De qué lado del punto estimado estamos: si no construimos y llegamos a
    // un extremo, el episodio está en el lado opuesto.
    int nextDir = direction;
    var nextEstimate = estimate;
    if (position.pixels <= position.minScrollExtent) {
      // Tocando el tope → el episodio está más abajo.
      nextDir = 1;
      nextEstimate += _episodeItemEstimate;
    } else if (position.pixels >= position.maxScrollExtent) {
      // En el final → el episodio está más arriba.
      nextDir = -1;
      nextEstimate -= _episodeItemEstimate;
    } else if (direction == 0) {
      // Estimación inicial no exacta: avanzamos un item (el target queda cerca).
      nextDir = 1;
      nextEstimate += _episodeItemEstimate;
    } else {
      nextEstimate = estimate + (_episodeItemEstimate * direction);
    }
    final clamped = nextEstimate.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    _scrollController.jumpTo(clamped);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _convergeToEpisode(centerId, estimate: clamped, direction: nextDir),
    );
  }

  void _animateToEpisode(BuildContext targetContext) {
    if (!mounted) return;
    Scrollable.ensureVisible(
      targetContext,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
      alignment: 0.5,
    );
  }

  /// Lanzamiento directo de episodio desde "Continuar Viendo"
  void _autoPlayEpisode() {
    if (!mounted || _videoOptions == null) return;

    // Buscar el episodio en todos los mapas de temporadas
    Episode? targetEp;
    Season? targetSeason;
    for (final season in _seasons) {
      final eps = _episodesMap[season.id] ?? [];
      final found = eps.cast<Episode?>().firstWhere(
        (e) => e != null && e.id == widget.autoPlayEpisodeId,
        orElse: () => null,
      );
      if (found != null) {
        targetEp = found;
        targetSeason = season;
        // Seleccionar la temporada del episodio que se va a reproducir para
        // que al volver el usuario vea ese capítulo centrado en su temporada.
        if (_selectedSeason != season) {
          setState(() => _selectedSeason = season);
        }
        break;
      }
    }

    if (targetEp == null || _videoOptions == null || _videoOptions!.isEmpty)
      return;

    // Elegir la misma opción que el usuario usó o la primera disponible
    final opt = widget.autoPlayVideoOptionId != null
        ? _videoOptions!.firstWhere(
            (o) => o.id == widget.autoPlayVideoOptionId,
            orElse: () => _videoOptions!.first,
          )
        : _videoOptions!.first;

    // Buscar la url del episodio para esa opción
    final eUrl = targetEp!.urls.firstWhere(
      (u) => u.optionId == opt.id,
      orElse: () => targetEp!.urls.first,
    );

    if (eUrl == null) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(
          movieName:
              '${widget.series.name} - S${targetSeason?.seasonNumber ?? 1} E${targetEp?.episodeNumber ?? ""}',
          mediaId: widget.series.id,
          episodeId: targetEp?.id ?? "",
          mediaType: 'series',
          imagePath: widget.series.imagePath,
          subtitleLabel:
              'S${targetSeason?.seasonNumber ?? 1} E${targetEp?.episodeNumber ?? ""}: ${targetEp?.name ?? ""}',
          startPosition: widget.autoPlayStartPosition,
          extractionAlgorithm: eUrl.extractionAlgorithm,
          videoOptions: [
            VideoOption(
              id: targetEp?.id ?? "",
              movieId: widget.series.id,
              serverImagePath: opt.serverImagePath,
              resolution: opt.resolution,
              videoUrl: eUrl.url,
              extractionAlgorithm: eUrl.extractionAlgorithm,
            ),
          ],
        ),
      ),
    );
  }

  void _playEpisode(Episode episode, EpisodeUrl eUrl) {
    if (_videoOptions == null || _videoOptions!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No hay servidores configurados')),
      );
      return;
    }

    SeriesOption? option;
    try {
      option = _videoOptions!.firstWhere((o) => o.id == eUrl.optionId);
    } catch (_) {
      option = _videoOptions!.first;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(
          movieName:
              '${widget.series.name} - S${_selectedSeason?.seasonNumber ?? 1} E${episode.episodeNumber}',
          onVideoStarted: () {
            ref
                .read(seriesListProvider.notifier)
                .incrementViews(widget.series.id);
          },
          mediaId: widget.series.id,
          episodeId: episode.id,
          mediaType: 'series',
          imagePath: widget.series.imagePath,
          subtitleLabel:
              'S${_selectedSeason?.seasonNumber ?? 1} E${episode.episodeNumber}: ${episode.name}',
          startPosition: widget.autoPlayStartPosition,
          introStartTime: episode.introStartTime,
          introEndTime: episode.introEndTime,
          creditsStartTime: episode.creditsStartTime,
          extractionAlgorithm: eUrl.extractionAlgorithm,
          videoOptions: [
            VideoOption(
              id: episode.id,
              movieId: widget.series.id,
              serverImagePath: option?.serverImagePath ?? '',
              resolution: eUrl.quality ?? option?.resolution ?? 'Auto',
              videoUrl: eUrl.url,
              extractionAlgorithm: eUrl.extractionAlgorithm,
            ),
          ],
        ),
      ),
    );
  }

  void _handleDownload(Episode episode, EpisodeUrl eUrl) async {
    // 1. Check Ad Requirement (usando authStateProvider que actualiza el role dinámicamente)
    final appUser = ref.read(authStateProvider);
    if (appUser == null) return;

    final role = appUser.role.toLowerCase();
    final isAdminOrVip = role == 'admin' || role == 'uservip';

    if (!isAdminOrVip) {
      setState(() {
        _isAdLoading = true;
        _adErrorMessage = null;
      });

      try {
        final ticketId = const Uuid().v4();
        final supabaseUser = Supabase.instance.client.auth.currentUser;
        if (supabaseUser == null) return;
        await Supabase.instance.client.from('ad_tickets').insert({
          'id': ticketId,
          'user_id': supabaseUser.id,
          'media_type': 'series',
          'media_id': widget.series.id,
        });

        final adCompleter = Completer<bool>();
        bool adWatched = false;

        AdService.showRewardedAd(
          ticketId: ticketId,
          onAdWatched: (String tid) {
            adWatched = true;
            if (!adCompleter.isCompleted) adCompleter.complete(true);
          },
          onAdFailed: (String err) {
            if (mounted) setState(() => _adErrorMessage = err);
            if (!adCompleter.isCompleted) adCompleter.complete(false);
          },
          onAdDismissedIncomplete: () {
            if (mounted) {
              setState(() {
                _isAdLoading = false;
                _adErrorMessage =
                    'Anuncio incompleto. Debes verlo para descargar.';
              });
            }
            if (!adCompleter.isCompleted) adCompleter.complete(false);
          },
        );

        final adResult = await adCompleter.future;
        print('--- [DOWNLOAD_AD] Result: $adResult, Watched: $adWatched ---');

        if (mounted) setState(() => _isAdLoading = false);

        if (!adResult || !adWatched) return;

        // 2. Poll Verification (Background)
        _pollVerification(ticketId); // Don't await
      } catch (e) {
        if (mounted) {
          setState(() {
            _isAdLoading = false;
            _adErrorMessage = 'Error al procesar el anuncio: $e';
          });
        }
        return;
      }
    }

    if (!mounted) return;

    final VideoExtractionData? result = await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => VideoExtractorDialog(
        url: eUrl.url,
        extractionAlgorithm: eUrl.extractionAlgorithm,
      ),
    );

    if (result == null) return;
    final selectedQuality = result.qualities.firstOrNull;

    if (selectedQuality != null && mounted) {
      final headers = <String, String>{};
      if (result.headers != null) headers.addAll(result.headers!);
      if (result.cookies != null) headers['Cookie'] = result.cookies!;
      if (result.userAgent != null) headers['User-Agent'] = result.userAgent!;
      headers['Referer'] = eUrl.url;
      headers['Origin'] = eUrl.url.split('/').take(3).join('/');

      final task = DownloadTask(
        id: const Uuid().v4(),
        movieId: widget.series.id,
        movieName:
            '${widget.series.name} - S${_selectedSeason?.seasonNumber ?? 1} E${episode.episodeNumber}',
        imagePath: widget.series.imagePath,
        videoUrl: selectedQuality.url,
        resolution: selectedQuality.resolution,
        status: DownloadStatus.pending,
        createdAt: DateTime.now(),
        headers: headers,
        isSeries: true,
        seasonNumber: _selectedSeason?.seasonNumber ?? 1,
        episodeNumber: episode.episodeNumber,
      );

      ref.read(downloadsListProvider.notifier).addDownload(task);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Iniciando descarga..."),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  void _showServerSelectionModal(Episode episode) {
    if (episode.urls.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Este episodio no tiene enlaces configurados'),
        ),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121212),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                episode.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Elegir Servidor',
                style: TextStyle(
                  color: Color(0xFF00A3FF),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    // --- OPCIONES MANUALES ---
                    ...List.generate(episode.urls.length, (index) {
                      final eUrl = episode.urls[index];
                      SeriesOption? opt;
                      try {
                        opt = _videoOptions?.firstWhere(
                          (o) => o.id == eUrl.optionId,
                        );
                      } catch (_) {}

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ListTile(
                          leading: opt != null && opt.serverImagePath.isNotEmpty
                              ? Image.network(
                                  opt.serverImagePath,
                                  width: 24,
                                  height: 24,
                                  errorBuilder: (_, __, ___) =>
                                      const Icon(Icons.dns, color: Colors.blue),
                                )
                              : const Icon(Icons.dns, color: Colors.blue),
                          title: Text(
                            opt != null
                                ? '${opt.resolution} (${opt.language ?? 'Latino'})'
                                : 'Servidor ${index + 1}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                          subtitle: Text(
                            eUrl.quality ?? 'Desconocido',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 12,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(
                                  Icons.download_rounded,
                                  color: Color(0xFFD400FF),
                                  size: 22,
                                ),
                                onPressed: () {
                                  Navigator.pop(context);
                                  _handleDownload(episode, eUrl);
                                },
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.cast_rounded,
                                  color: Color(0xFF00FF87),
                                  size: 20,
                                ),
                                onPressed: () {
                                  Navigator.pop(context);
                                  _showCastSelector(context, episode, eUrl);
                                },
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.play_arrow_rounded,
                                  color: Color(0xFF00A3FF),
                                  size: 24,
                                ),
                                onPressed: () {
                                  Navigator.pop(context);
                                  _playEpisode(episode, eUrl);
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showCastSelector(
    BuildContext context,
    Episode episode,
    EpisodeUrl eUrl,
  ) {
    // Para el selector de cast necesitamos los datos del video.
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => CastSelectionModal(
        videoUrl: eUrl.url,
        title:
            '${widget.series.name} - S${_selectedSeason?.seasonNumber ?? 1} E${episode.episodeNumber}',
        imageUrl: widget.series.imagePath,
        mediaId: widget.series.id,
        episodeId: episode.id,
        mediaType: 'series',
        subtitleLabel:
            'S${_selectedSeason?.seasonNumber ?? 1} E${episode.episodeNumber}: ${episode.name}',
        videoOptionId: eUrl.optionId,
        headers: {
          'Referer': eUrl.url,
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
        },
        algorithm: eUrl.extractionAlgorithm,
      ),
    );
  }

  Future<bool> _pollVerification(String ticketId) async {
    int retries = 15; // Increased to 15 (30 sec)
    while (retries > 0) {
      if (!mounted) return false;
      print(
        '--- [POLL] Checking verification for ticket: $ticketId (retries left: $retries) ---',
      );
      try {
        final response = await Supabase.instance.client.functions.invoke(
          'secure-video-link',
          body: {
            'ticket_id': ticketId,
            'media_type': 'series',
            'media_id': widget.series.id,
          },
        );
        print('--- [POLL] Response status: ${response.status} ---');
        if (response.status == 200) return true;
      } catch (e) {
        print('--- [POLL] Error: $e ---');
      }
      retries--;
      await Future.delayed(const Duration(seconds: 2));
    }
    return false;
  }

  Widget _buildMetaIcon(
    IconData icon,
    String text, {
    Color color = Colors.grey,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildRoundButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.5),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final curSeries = widget.series;
    final currentDescription =
        curSeries.description ?? 'Sin descripción disponible.';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Fixed background image with darker overlay
          Positioned.fill(
            child: Stack(
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SizedBox(
                    height: ResponsiveLayout.isLandscape(context) ? 250 : 300,
                    child: Opacity(
                      opacity: 0.99,
                      child: Image.network(
                        (curSeries.backdropUrl?.isNotEmpty == true
                                ? curSeries.backdropUrl
                                : curSeries.backdrop) ??
                            curSeries.imagePath,
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
                        errorBuilder: (_, __, ___) => const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withOpacity(0.4),
                          Colors.black,
                        ],
                        stops: const [
                          0.0,
                          0.15,
                          0.3,
                        ], // Gradient finishes within the 250px window
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          RefreshIndicator(
            onRefresh: _onRefresh,
            color: const Color(0xFF00A3FF),
            backgroundColor: const Color(0xFF1A1A1A),
            strokeWidth: 2,
            child: CustomScrollView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              cacheExtent: 600,
              slivers: [
                SliverAppBar(
                  expandedHeight: ResponsiveLayout.isLandscape(context)
                      ? 250
                      : 300,
                  pinned: true,
                  backgroundColor: Colors.transparent,
                  leading: const SizedBox.shrink(),
                  elevation: 0,
                  flexibleSpace: FlexibleSpaceBar(
                    background: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Subtle gradient purely for text readability, moved lower to not dim the image top
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withOpacity(1),
                              ],
                              stops: const [0.6, 1.0],
                            ),
                          ),
                        ),
                        Positioned(
                          bottom: 40,
                          left: 20,
                          right: 20,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              // Poster Image on the left
                              Hero(
                                tag: 'poster_${curSeries.id}',
                                child: EnergyFlowBorder(
                                  borderRadius: 12,
                                  borderWidth: 1.5,
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(11),
                                    child: Image.network(
                                      curSeries.imagePath,
                                      width:
                                          ResponsiveLayout.isLandscape(context)
                                          ? 100
                                          : 120,
                                      height:
                                          ResponsiveLayout.isLandscape(context)
                                          ? 150
                                          : 180,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, __, ___) => Container(
                                        color: Colors.white12,
                                        child: const Icon(
                                          Icons.movie,
                                          color: Colors.white24,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 20),
                              // Title and Meta
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      curSeries.name,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 28,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: -0.5,
                                        height: 1.1,
                                        shadows: [
                                          Shadow(
                                            color: Colors.black,
                                            blurRadius: 20,
                                            offset: Offset(0, 4),
                                          ),
                                          Shadow(
                                            color: Color(0xFF00A3FF),
                                            blurRadius: 10,
                                          ),
                                        ],
                                      ),
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      children: [
                                        if (curSeries.year != null)
                                          Text(
                                            curSeries.year!,
                                            style: TextStyle(
                                              color: Colors.white.withOpacity(
                                                0.6,
                                              ),
                                              fontSize: 14,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        if (curSeries.year != null &&
                                            curSeries.rating > 0)
                                          const SizedBox(width: 12),
                                        if (curSeries.rating > 0)
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            margin: const EdgeInsets.only(
                                              right: 12,
                                            ),
                                            decoration: BoxDecoration(
                                              color: Colors.amber.withOpacity(
                                                0.2,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              border: Border.all(
                                                color: Colors.amber.withOpacity(
                                                  0.5,
                                                ),
                                              ),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                  Icons.star_rounded,
                                                  color: Colors.amber,
                                                  size: 16,
                                                ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  curSeries.rating
                                                      .toStringAsFixed(1),
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 12,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        if (ResponsiveLayout.isLandscape(
                                          context,
                                        )) ...[
                                          _buildMetaIcon(
                                            Icons.remove_red_eye,
                                            '${curSeries.views}',
                                            color: Colors.white70,
                                          ),
                                          if (curSeries.categoryId != null) ...[
                                            const SizedBox(width: 12),
                                            ref
                                                .watch(seriesCategoriesProvider)
                                                .when(
                                                  data: (categories) {
                                                    final category = categories
                                                        .firstWhere(
                                                          (c) =>
                                                              c.id ==
                                                              curSeries
                                                                  .categoryId,
                                                          orElse: () =>
                                                              SeriesCategory(
                                                                id: '',
                                                                name: 'Serie',
                                                              ),
                                                        );
                                                    return _buildMetaIcon(
                                                      Icons.live_tv_outlined,
                                                      category.name,
                                                      color: Colors.white70,
                                                    );
                                                  },
                                                  loading: () =>
                                                      const SizedBox.shrink(),
                                                  error: (_, __) =>
                                                      const SizedBox.shrink(),
                                                ),
                                          ],
                                        ],
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          child: SafeArea(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16.0,
                                vertical: 8.0,
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  _buildRoundButton(
                                    Icons.arrow_back,
                                    () => Navigator.pop(context),
                                  ),
                                  CastButtonOverlay(
                                    videoUrl:
                                        _videoOptions != null &&
                                            _videoOptions!.isNotEmpty
                                        ? (_videoOptions!.first.videoUrl ?? '')
                                        : '',
                                    title: widget.series.name,
                                    imageUrl: widget.series.imagePath,
                                    algorithm:
                                        _videoOptions != null &&
                                            _videoOptions!.isNotEmpty
                                        ? _videoOptions!
                                              .first
                                              .extractionAlgorithm
                                        : 1,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Container(
                    color: Colors.transparent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20.0,
                      vertical: 0.0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!ResponsiveLayout.isLandscape(context)) ...[
                          Row(
                            children: [
                              _buildMetaIcon(
                                Icons.remove_red_eye,
                                '${curSeries.views} Views',
                              ),
                              if (curSeries.categoryId != null) ...[
                                const SizedBox(width: 20),
                                Expanded(
                                  child: ref
                                      .watch(seriesCategoriesProvider)
                                      .when(
                                        data: (categories) {
                                          final category = categories
                                              .firstWhere(
                                                (c) =>
                                                    c.id ==
                                                    curSeries.categoryId,
                                                orElse: () => SeriesCategory(
                                                  id: '',
                                                  name: 'Serie',
                                                ),
                                              );
                                          return _buildMetaIcon(
                                            Icons.live_tv_outlined,
                                            category.name,
                                          );
                                        },
                                        loading: () => const SizedBox.shrink(),
                                        error: (_, __) =>
                                            const SizedBox.shrink(),
                                      ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 25),
                        ],

                        // Description with Neon Border
                        EnergyFlowBorder(
                          borderRadius: 16,
                          borderWidth: 1.2,
                          backgroundColor: const Color(0xFF0A0A0A),
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                (!_isDescriptionExpanded &&
                                        currentDescription.length > 100)
                                    ? '${currentDescription.substring(0, 100)}...'
                                    : currentDescription,
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.9),
                                  fontSize: 15,
                                  height: 1.6,
                                ),
                              ),
                              if (currentDescription.length > 100)
                                GestureDetector(
                                  onTap: () => setState(
                                    () => _isDescriptionExpanded =
                                        !_isDescriptionExpanded,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.only(top: 8.0),
                                    child: Text(
                                      _isDescriptionExpanded
                                          ? 'Ver menos'
                                          : 'Ver más...',
                                      style: const TextStyle(
                                        color: Color(0xFF00A3FF),
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 35),
                        const Text(
                          'TEMPORADAS',
                          style: TextStyle(
                            color: Color(0xFF00A3FF),
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 16),
                        if (_isLoading)
                          const Center(child: CircularProgressIndicator())
                        else if (_seasons.isEmpty)
                          const Text(
                            'No hay temporadas disponibles.',
                            style: TextStyle(color: Colors.white54),
                          )
                        else ...[
                          // Season Selector with Neon Border
                          EnergyFlowBorder(
                            borderRadius: 12,
                            borderWidth: 1.2,
                            backgroundColor: const Color(0xFF0A0A0A),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 4,
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<Season>(
                                dropdownColor: const Color(0xFF1A1A1A),
                                value: _selectedSeason,
                                isExpanded: true,
                                icon: const Icon(
                                  Icons.keyboard_arrow_down,
                                  color: Color(0xFF00A3FF),
                                ),
                                items: _seasons
                                    .map(
                                      (s) => DropdownMenuItem(
                                        value: s,
                                        child: Text(
                                          s.name,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                                onChanged: (val) =>
                                    setState(() => _selectedSeason = val),
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                          const Text(
                            'EPISODIOS',
                            style: TextStyle(
                              color: Color(0xFF00A3FF),
                              fontWeight: FontWeight.bold,
                              letterSpacing: 2,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      childCount: _selectedSeason == null
                          ? 0
                          : (_episodesMap[_selectedSeason!.id]?.length ?? 0),
                      (context, index) {
                        final eps = _episodesMap[_selectedSeason!.id] ?? [];
                        if (index >= eps.length) {
                          return const SizedBox.shrink();
                        }
                        return _buildEpisodeItem(
                          eps[index],
                          key: _episodeKeys.putIfAbsent(
                            eps[index].id,
                            () => GlobalKey(),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SliverToBoxAdapter(
                  child: SizedBox(height: 50),
                ),
              ],
            ),
          ),
          if (_isAdLoading)
            Container(
              color: Colors.black.withOpacity(0.85),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Color(0xFF00A3FF)),
                    const SizedBox(height: 20),
                    const Text(
                      "PREPARANDO ANUNCIO...",
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      "Verifica tu sesión publicitaria para descargar",
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.6),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (_adErrorMessage != null)
            Positioned(
              bottom: 20,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.white),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _adErrorMessage!,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => setState(() => _adErrorMessage = null),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEpisodeItem(Episode episode, {GlobalKey? key}) {
    return Container(
      key: key,
      margin: const EdgeInsets.only(bottom: 12),
      child: EnergyFlowBorder(
        borderRadius: 16,
        borderWidth: 1.2,
        backgroundColor: const Color(0xFF0A0A0A),
        padding: EdgeInsets.zero,
        child: Material(
          color: Colors.transparent,
          child: Consumer(
            builder: (context, ref, child) {
              final isWatched = ref
                  .watch(historyProvider)
                  .maybeWhen(
                    data: (history) => history.any(
                      (h) =>
                          h.episodeId == episode.id &&
                          h.totalDuration > 0 &&
                          h.lastPosition >= (h.totalDuration * 0.9),
                    ), // Consider watched if >= 90%
                    orElse: () => false,
                  );
              final isPartiallyWatched = ref
                  .watch(historyProvider)
                  .maybeWhen(
                    data: (history) => history.any(
                      (h) =>
                          h.episodeId == episode.id &&
                          h.lastPosition > 10000 &&
                          h.lastPosition < (h.totalDuration * 0.9),
                    ), // At least 10s and < 90%
                    orElse: () => false,
                  );
              final isLastCastEpisode = ref
                  .watch(historyProvider)
                  .maybeWhen(
                    data: (history) {
                      for (final item in history) {
                        if (item.mediaId == widget.series.id &&
                            item.lastCastWasCast) {
                          return item.episodeId == episode.id;
                        }
                      }
                      return false;
                    },
                    orElse: () => false,
                  );

              final Color accentColor = isLastCastEpisode
                  ? const Color(0xFF00FF87)
                  : isWatched
                  ? const Color(0xFFD400FF)
                  : (isPartiallyWatched
                        ? const Color(0xFF00A3FF)
                        : const Color(0xFF00A3FF));
              final Color textColor = isLastCastEpisode
                  ? const Color(0xFF00FF87)
                  : isWatched
                  ? const Color(0xFFD400FF)
                  : (isPartiallyWatched
                        ? const Color(0xFF00A3FF)
                        : Colors.white);

              return ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                onTap: () => _showServerSelectionModal(episode),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(15),
                ),
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accentColor.withOpacity(0.1),
                    shape: BoxShape.circle,
                    border: Border.all(color: accentColor.withOpacity(0.2)),
                  ),
                  child: Center(
                    child: Text(
                      '${episode.episodeNumber}',
                      style: TextStyle(
                        color: accentColor,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
                title: Text(
                  episode.name,
                  style: TextStyle(
                    color: textColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    letterSpacing: 0.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4.0),
                  child: Text(
                    isLastCastEpisode
                        ? 'Último cast'
                        : (isWatched
                              ? 'Reproducido'
                              : (isPartiallyWatched
                                    ? 'En curso'
                                    : 'Toca para elegir servidor')),
                    style: TextStyle(
                      color: textColor.withOpacity(0.6),
                      fontSize: 11,
                    ),
                  ),
                ),
                trailing: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: accentColor,
                    size: 20,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: const Color(0xFF1E1E1E),
      child: const Center(
        child: Icon(Icons.movie, size: 80, color: Colors.white12),
      ),
    );
  }
}

// Widget auxiliar para reutilizar el modal de selección en varios sitios
class CastSelectionModal extends StatelessWidget {
  final String videoUrl;
  final String title;
  final String imageUrl;
  final Map<String, String>? headers;
  final int? algorithm;
  final String? mediaId;
  final String? episodeId;
  final String? mediaType;
  final String? subtitleLabel;
  final String? videoOptionId;

  const CastSelectionModal({
    super.key,
    required this.videoUrl,
    required this.title,
    required this.imageUrl,
    this.headers,
    this.algorithm,
    this.mediaId,
    this.episodeId,
    this.mediaType,
    this.subtitleLabel,
    this.videoOptionId,
  });

  @override
  Widget build(BuildContext context) {
    return CastButton(
      videoUrl: videoUrl,
      title: title,
      imageUrl: imageUrl,
      headers: headers,
      algorithm: algorithm ?? 1,
      mediaId: mediaId,
      episodeId: episodeId,
      mediaType: mediaType,
      subtitleLabel: subtitleLabel,
      videoOptionId: videoOptionId,
      showImmediately: true,
    );
  }
}
