import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:movie_app/features/movies/presentation/providers/history_provider.dart';
import 'package:movie_app/features/series/domain/entities/episode.dart';
import 'package:movie_app/features/series/domain/entities/season.dart';
import 'package:movie_app/providers.dart';
import 'package:movie_app/shared/widgets/video_extractor_dialog.dart';
import '../../services/cast_service.dart';
import '../../services/cast_device_info.dart';
import '../widgets/cast_device_list_sheet.dart';

/// Pantalla de Control Remoto estilo "Web Video Caster".
/// Se muestra mientras hay una sesión de casting activa.
/// Características:
/// - Barra de progreso con seek
/// - Play / Pause / +10s / -10s
/// - Control de volumen
/// - Opción de reanudar o iniciar desde el principio
/// - Botón para cambiar de dispositivo
/// - Se cierra automáticamente cuando se desconecta
/// - Wakelock activo para no perder la transmisión
class CastRemotePage extends ConsumerStatefulWidget {
  const CastRemotePage({super.key});

  @override
  ConsumerState<CastRemotePage> createState() => _CastRemotePageState();
}

class _CastRemotePageState extends ConsumerState<CastRemotePage> {
  final _castService = CastService();
  Timer? _progressTimer;
  Timer? _uiTimer;
  double _volume = 0.5;
  bool _isSeeking = false;
  double _seekValue = 0.0;
  bool _isNavigatingAway = false;

  @override
  void initState() {
    super.initState();
    _castService.isRemotePageOpen = true;
    _castService.addListener(_onCastStateChanged);
    WakelockPlus.enable();
    _progressTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveCastProgress(),
    );
    _uiTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (mounted) setState(() {});
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadEpisodeNavIfNeeded());
  }

  Future<void> _loadEpisodeNavIfNeeded() async {
    if (_castService.currentMediaType != 'series' ||
        _castService.currentMediaId == null ||
        _castService.currentEpisodeId == null) return;
    if (_castService.hasNextEpisode || _castService.hasPreviousEpisode) return;

    final repo = ref.read(seriesRepositoryProvider);
    final seasons = await repo.getSeasonsForSeries(_castService.currentMediaId!);
    for (int i = 0; i < seasons.length; i++) {
      final s = seasons[i];
      final eps = await repo.getEpisodesForSeason(s.id);
      final idx = eps.indexWhere((e) => e.id == _castService.currentEpisodeId);
      if (idx != -1) {
        Episode? next, prev;
        Season? nextS, prevS;
        if (idx + 1 < eps.length) {
          next = eps[idx + 1];
          nextS = s;
        } else if (i + 1 < seasons.length) {
          final nextEps = await repo.getEpisodesForSeason(seasons[i + 1].id);
          if (nextEps.isNotEmpty) { next = nextEps.first; nextS = seasons[i + 1]; }
        }
        if (idx > 0) {
          prev = eps[idx - 1];
          prevS = s;
        } else if (i > 0) {
          final prevEps = await repo.getEpisodesForSeason(seasons[i - 1].id);
          if (prevEps.isNotEmpty) { prev = prevEps.last; prevS = seasons[i - 1]; }
        }
        _castService.setEpisodeNavigation(
          nextEpisode: next, nextSeason: nextS,
          previousEpisode: prev, previousSeason: prevS,
          seriesSeasons: seasons,
          currentSeasonEpisodes: eps,
          currentEpisodeIndex: idx,
        );
        break;
      }
    }
  }

  @override
  void dispose() {
    _castService.isRemotePageOpen = false;
    _castService.removeListener(_onCastStateChanged);
    _progressTimer?.cancel();
    _uiTimer?.cancel();
    _saveCastProgress();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _saveCastProgress() async {
    final mediaId = _castService.currentMediaId;
    final mediaType = _castService.currentMediaType;
    final position = _castService.position.inMilliseconds;
    if (mediaId == null || mediaType == null || position <= 0) return;

    await ref
        .read(historyProvider.notifier)
        .saveProgress(
          mediaId: mediaId,
          episodeId: _castService.currentEpisodeId,
          mediaType: mediaType,
          position: position,
          duration: _castService.duration.inMilliseconds,
          title: _castService.currentTitle ?? 'Video',
          subtitle: _castService.currentSubtitleLabel,
          imagePath: _castService.currentImageUrl ?? '',
          videoOptionId: _castService.currentVideoOptionId,
          lastCastWasCast: true,
          castDeviceName: _castService.connectedDevice?.name,
        );
  }

  void _onCastStateChanged() {
    if (!mounted) return;

    // Si se desconecta, cerramos esta pantalla UNA SOLA VEZ
    if (!_castService.isConnected && !_isNavigatingAway) {
      _isNavigatingAway = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  void _openDeviceSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CastDeviceListSheet(
        videoUrl: _castService.currentVideoUrl ?? '',
        title: _castService.currentTitle ?? '',
        imageUrl: _castService.currentImageUrl,
        // Si el usuario elige un dispositivo nuevo desde aquí, no necesitamos
        // volver a abrir el Remote (ya estamos en él)
        onCastStarted: null,
      ),
    );
  }

  Future<void> _disconnect() async {
    _isNavigatingAway = true;
    await _saveCastProgress();
    await _castService.disconnect();
    if (mounted) Navigator.of(context).pop();
  }

  void _onSeekStart(double val) {
    setState(() {
      _isSeeking = true;
      _seekValue = val;
    });
  }

  void _onSeekUpdate(double val) {
    setState(() => _seekValue = val);
  }

  void _onSeekEnd(double val) {
    final duration = _castService.duration;
    final seekPos = Duration(seconds: (val * duration.inSeconds).toInt());
    _castService.seekTo(seekPos);
    setState(() => _isSeeking = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_castService.isConnected) {
      return const Scaffold(backgroundColor: Colors.black);
    }

    final device = _castService.connectedDevice!;
    final position = _castService.position;
    final duration = _castService.duration;
    final double progress = (_isSeeking)
        ? _seekValue
        : (duration.inSeconds > 0
              ? (position.inSeconds / duration.inSeconds).clamp(0.0, 1.0)
              : 0.0);

    // Validación de imagen para evitar error "No host specified in URI file:///"
    final bool hasValidImage =
        _castService.currentImageUrl != null &&
        _castService.currentImageUrl!.startsWith('http');

    final bool isNearEnd = !_isSeeking &&
        duration.inSeconds > 60 && // Skip near-end for very short content
        position.inSeconds > (duration.inSeconds - 30) &&
        _castService.hasNextEpisode;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: Stack(
        children: [
          // Fondo con el póster desenfocado
          if (hasValidImage)
            Positioned.fill(
              child: Image.network(
                _castService.currentImageUrl!,
                fit: BoxFit.cover,
                color: Colors.black.withOpacity(0.75),
                colorBlendMode: BlendMode.darken,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),

          SafeArea(
            child: OrientationBuilder(
              builder: (context, orientation) {
                final bool isLandscape = orientation == Orientation.landscape;
                if (!isLandscape) {
                  return Column(
                    children: [
                      _buildTopBar(device),
                      const Spacer(),
                      _buildCover(isLandscape: false),
                      const SizedBox(height: 24),
                      _buildTitleSection(device),
                      const Spacer(),
                      _buildSeekBar(progress, position, duration),
                      const SizedBox(height: 8),
                      _buildEpisodeNav(),
                      const SizedBox(height: 8),
                      _buildMainControls(position, isLandscape: false),
                      const SizedBox(height: 24),
                      _buildVolumeControl(),
                      const SizedBox(height: 20),
                    ],
                  );
                } else {
                  // MODO LANDSCAPE (Horizontal)
                  return Row(
                    children: [
                      // Lado Izquierdo: Póster y Título
                      Expanded(
                        flex: 4,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _buildCover(isLandscape: true),
                            const SizedBox(height: 16),
                            _buildTitleSection(device),
                          ],
                        ),
                      ),
                      // Lado Derecho: Controles con scroll por seguridad
                      Expanded(
                        flex: 6,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _buildTopBar(device),
                              const SizedBox(height: 4),
                              _buildSeekBar(progress, position, duration),
                              const SizedBox(height: 8),
                              _buildEpisodeNav(),
                              const SizedBox(height: 8),
                              _buildMainControls(position, isLandscape: true),
                              const SizedBox(height: 16),
                              _buildVolumeControl(),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                }
              },
            ),
          ),
          // End-of-episode overlay
          if (isNearEnd)
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.of(context).padding.bottom + 100,
              child: _buildNextEpisodeBanner(),
            ),
        ],
      ),
    );
  }

  Widget _buildNextEpisodeBanner() {
    final nextEp = _castService.nextEpisode;
    final nextSeason = _castService.nextSeason;
    final duration = _castService.duration;
    final position = _castService.position;
    final secondsLeft = (duration.inSeconds - position.inSeconds).clamp(0, 999);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF0022FF), Color(0xFF00A3FF)],
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF00A3FF).withOpacity(0.3),
              blurRadius: 20,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'SIGUIENTE EPISODIO',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.7),
                      fontSize: 10,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'S${nextSeason?.seasonNumber ?? '?'} E${nextEp?.episodeNumber ?? '?'}: ${nextEp?.name ?? '...'}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'En $secondsLeft segundos...',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.6),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed: () {
                _castService.disconnect();
                _playNextEpisode();
              },
              icon: const Icon(Icons.skip_next_rounded, size: 20),
              label: const Text('VER AHORA'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(CastDeviceInfo device) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          // Botón cerrar (solo oculta el remoto, NO detiene la transmisión)
          IconButton(
            icon: const Icon(
              Icons.keyboard_arrow_down,
              color: Colors.white70,
              size: 28,
            ),
            tooltip: 'Minimizar (la transmisión continúa)',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const Spacer(),
          Column(
            children: [
              const Text(
                'REPRODUCIENDO EN',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 9,
                  letterSpacing: 1.5,
                ),
              ),
              Text(
                device.name,
                style: const TextStyle(
                  color: Color(0xFF00FF87),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const Spacer(),
          // Botón para cambiar dispositivo
          IconButton(
            icon: const Icon(Icons.cast, color: Colors.white70, size: 22),
            tooltip: 'Cambiar dispositivo',
            onPressed: _openDeviceSheet,
          ),
        ],
      ),
    );
  }

  Widget _buildCover({required bool isLandscape}) {
    final double w = isLandscape ? 120 : 160;
    final double h = isLandscape ? 160 : 220;

    // Si la URL no es válida (file:///), usamos el placeholder
    final bool hasValidImage =
        _castService.currentImageUrl != null &&
        _castService.currentImageUrl!.startsWith('http');

    if (!hasValidImage) {
      return Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(
          Icons.movie,
          color: Colors.white24,
          size: isLandscape ? 40 : 60,
        ),
      );
    }

    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
        image: DecorationImage(
          image: NetworkImage(_castService.currentImageUrl!),
          fit: BoxFit.cover,
        ),
      ),
    );
  }

  Widget _buildTitleSection(CastDeviceInfo device) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        children: [
          Text(
            _castService.currentTitle ?? 'Desconocido',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
              shadows: [Shadow(color: Colors.black, blurRadius: 8)],
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(device.icon, color: const Color(0xFF00FF87), size: 12),
              const SizedBox(width: 6),
              Text(
                device.subtitle,
                style: const TextStyle(color: Color(0xFF00FF87), fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSeekBar(double progress, Duration position, Duration duration) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              activeTrackColor: const Color(0xFF00A3FF),
              inactiveTrackColor: Colors.white12,
              thumbColor: Colors.white,
              overlayColor: Colors.white24,
            ),
            child: Slider(
              value: progress,
              onChangeStart: _onSeekStart,
              onChanged: _onSeekUpdate,
              onChangeEnd: _onSeekEnd,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _formatDuration(position),
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                Text(
                  _formatDuration(duration),
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMainControls(Duration position, {required bool isLandscape}) {
    final double playSize = isLandscape ? 60 : 72;
    final double playIconSize = isLandscape ? 36 : 44;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Reiniciar desde el principio
        _ControlButton(
          icon: Icons.skip_previous_rounded,
          size: 28,
          onTap: () => _castService.seekTo(Duration.zero),
          tooltip: 'Desde el principio',
        ),
        // Retroceder 10s
        _ControlButton(
          icon: Icons.replay_10_rounded,
          size: 32,
          onTap: () =>
              _castService.seekTo(position - const Duration(seconds: 10)),
          tooltip: '-10 segundos',
        ),
        // Play / Pause (botón grande central)
        GestureDetector(
          onTap: () => _castService.isPlaying
              ? _castService.pause()
              : _castService.play(),
          child: Container(
            width: playSize,
            height: playSize,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Color(0x4400A3FF),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(
              _castService.isPlaying
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              color: Colors.black,
              size: playIconSize,
            ),
          ),
        ),
        // Avanzar 10s
        _ControlButton(
          icon: Icons.forward_10_rounded,
          size: 32,
          onTap: () =>
              _castService.seekTo(position + const Duration(seconds: 10)),
          tooltip: '+10 segundos',
        ),
        // Detener y desconectar
        _ControlButton(
          icon: Icons.stop_circle_outlined,
          size: 28,
          color: Colors.redAccent,
          onTap: _disconnect,
          tooltip: 'Detener y desconectar',
        ),
      ],
    );
  }

  Widget _buildVolumeControl() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        children: [
          const Icon(
            Icons.volume_mute_rounded,
            color: Colors.white38,
            size: 22,
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                activeTrackColor: Colors.white60,
                inactiveTrackColor: Colors.white12,
                thumbColor: Colors.white,
              ),
              child: Slider(
                value: _volume,
                onChanged: (val) {
                  setState(() => _volume = val);
                  _castService.setVolume(val);
                },
              ),
            ),
          ),
          const Icon(Icons.volume_up_rounded, color: Colors.white38, size: 22),
        ],
      ),
    );
  }

  Widget _buildEpisodeNav() {
    if (_castService.currentMediaType != 'series') return const SizedBox.shrink();

    final hasPrev = _castService.hasPreviousEpisode;
    final hasNext = _castService.hasNextEpisode;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _EpisodeNavButton(
            label: 'ANTERIOR',
            icon: Icons.skip_previous_rounded,
            enabled: hasPrev,
            onTap: hasPrev ? _playPreviousEpisode : null,
          ),
          const SizedBox(width: 24),
          _EpisodeNavButton(
            label: 'SIGUIENTE',
            icon: Icons.skip_next_rounded,
            enabled: hasNext,
            onTap: hasNext ? _playNextEpisode : null,
          ),
        ],
      ),
    );
  }

  Future<void> _castEpisodeWithExtraction({
    required Episode episode,
    required Season season,
    required String newTitle,
  }) async {
    if (episode.urls.isEmpty) return;

    final eUrl = episode.urls.first;
    var finalUrl = eUrl.url;
    var finalHeaders = <String, String>{
      'Referer': eUrl.url,
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
    };
    var algorithm = eUrl.extractionAlgorithm;

    // --- Igual que CastButton._extractIfNeeded para películas ---
    // Siempre mostrar el extractor para alg 2 (WebView con JavaScript injection),
    // porque al igual que en películas, la URL puede necesitar interacción del usuario.
    final lower = eUrl.url.toLowerCase();
    final isDirectVideo = lower.contains('.m3u8') ||
        lower.contains('.mp4') ||
        lower.contains('.mpd') ||
        lower.contains('.mkv') ||
        eUrl.url.startsWith('http://127.0.0.1');

    if ((!isDirectVideo && algorithm > 0) || algorithm == 2) {
      if (!mounted) return;
      final result = await showDialog<VideoExtractionData>(
        context: context,
        barrierDismissible: false,
        builder: (_) => VideoExtractorDialog(
          url: eUrl.url,
          extractionAlgorithm: algorithm,
        ),
      );
      if (result == null || result.videoUrl.isEmpty) return;

      finalUrl = result.videoUrl;
      finalHeaders = {};
      if (result.headers != null) finalHeaders.addAll(result.headers!);
      if (result.cookies != null) finalHeaders['Cookie'] = result.cookies!;
      if (result.userAgent != null) {
        finalHeaders['User-Agent'] = result.userAgent!;
      }
      finalHeaders['Referer'] = eUrl.url;
    }

    try {
      await _castService.castUrl(
        url: finalUrl,
        title: newTitle,
        imageUrl: _castService.currentImageUrl,
        headers: finalHeaders,
        startPosition: Duration.zero,
        algorithm: algorithm,
      );
    } catch (e) {
      debugPrint('❌ [CAST_REMOTE] Error al transmitir episodio: $e');
      return;
    }

    _castService.setHistoryContext(
      mediaId: _castService.currentMediaId,
      episodeId: episode.id,
      mediaType: 'series',
      subtitleLabel:
          'S${season.seasonNumber} E${episode.episodeNumber}: ${episode.name}',
      imagePath: _castService.currentImageUrl,
      videoOptionId: _castService.currentVideoOptionId,
    );
    _castService.setEpisodeNavigation(
      nextEpisode: null,
      nextSeason: null,
      previousEpisode: null,
      previousSeason: null,
      seriesSeasons: null,
      currentSeasonEpisodes: null,
      currentEpisodeIndex: -1,
    );

    try {
      await _loadEpisodeNavIfNeeded();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _playNextEpisode() async {
    final nextEp = _castService.nextEpisode;
    final nextSeason = _castService.nextSeason;
    if (nextEp == null || nextSeason == null) return;

    await _saveCastProgress();

    final newTitle =
        '${_castService.currentTitle?.split(' - ').first ?? ''} - S${nextSeason.seasonNumber} E${nextEp.episodeNumber}';

    await _castEpisodeWithExtraction(
      episode: nextEp,
      season: nextSeason,
      newTitle: newTitle,
    );
  }

  Future<void> _playPreviousEpisode() async {
    final prevEp = _castService.previousEpisode;
    final prevSeason = _castService.previousSeason;
    if (prevEp == null || prevSeason == null) return;

    await _saveCastProgress();

    final newTitle =
        '${_castService.currentTitle?.split(' - ').first ?? ''} - S${prevSeason.seasonNumber} E${prevEp.episodeNumber}';

    await _castEpisodeWithExtraction(
      episode: prevEp,
      season: prevSeason,
      newTitle: newTitle,
    );
  }

  String _formatDuration(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

/// Botón de navegación de episodios con texto y animación de presión
class _EpisodeNavButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;

  const _EpisodeNavButton({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  State<_EpisodeNavButton> createState() => _EpisodeNavButtonState();
}

class _EpisodeNavButtonState extends State<_EpisodeNavButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _pressController;
  late Animation<double> _pressAnimation;

  @override
  void initState() {
    super.initState();
    _pressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _pressAnimation = Tween<double>(begin: 1.0, end: 0.92).animate(
      CurvedAnimation(parent: _pressController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pressController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final opacity = widget.enabled ? 1.0 : 0.35;
    return Opacity(
      opacity: opacity,
      child: AnimatedBuilder(
        animation: _pressAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _pressAnimation.value,
            child: GestureDetector(
              onTapDown: widget.enabled ? (_) => _pressController.forward() : null,
              onTapUp: widget.enabled
                  ? (_) {
                      _pressController.reverse();
                      widget.onTap?.call();
                    }
                  : null,
              onTapCancel: () => _pressController.reverse(),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: widget.enabled
                      ? const Color(0xFF00A3FF).withOpacity(0.15)
                      : Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: widget.enabled
                        ? const Color(0xFF00A3FF).withOpacity(0.4)
                        : Colors.white.withOpacity(0.08),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.icon, color: Colors.white, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      widget.label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Botón de control circular reutilizable
class _ControlButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback? onTap;
  final String tooltip;
  final Color color;

  const _ControlButton({
    required this.icon,
    required this.size,
    required this.onTap,
    required this.tooltip,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: size + 16,
          height: size + 16,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: size),
        ),
      ),
    );
  }
}
