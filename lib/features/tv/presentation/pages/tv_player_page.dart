import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'dart:convert';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../shared/widgets/marquee_text.dart';
import '../../../../core/services/ad_service.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../cast/presentation/widgets/cast_button.dart';
import '../../../../core/services/storage_service.dart';
import '../../../cast/services/media_proxy_service.dart';
import '../../../../core/constants/app_constants.dart';

class TvPlayerPage extends ConsumerStatefulWidget {
  final List<Map<String, dynamic>> channels;
  final int initialIndex;

  const TvPlayerPage({
    super.key,
    required this.channels,
    required this.initialIndex,
  });

  @override
  ConsumerState<TvPlayerPage> createState() => _TvPlayerPageState();
}

class _TvPlayerPageState extends ConsumerState<TvPlayerPage> {
  static const _audioBoostChannel = MethodChannel(
    'com.luis.movieapp/audio_boost',
  );
  Player? _player;
  VideoController? _videoController;
  final ScrollController _scrollController = ScrollController();
  late int _currentIndex;
  bool _showControls = true;
  bool _isLoading = true;
  String? _errorMessage;
  Timer? _adTimer;
  static const int adIntervalMinutes = 30;

  double _volume = 0.5;
  double _brightness = 0.5;
  // Calidad elegida: 'auto' (mínima, la que siempre funciona), 'mid' o
  // 'high'. Se conserva al zappear. El cambio REABRE el stream (un cambio
  // en caliente rompe la línea de tiempo y congela el video).
  String _quality = 'auto';
  Timer? _stallTimer;
  int _completedReopens = 0;
  bool _showVolumeLabel = false;
  bool _showBrightnessLabel = false;
  bool _isDraggingVolume = false;
  bool _isDraggingBrightness = false;
  Timer? _labelHideTimer;

  // Pluto TV: mecanismo copiado de las apps open-source que sí lo
  // reproducen (p.ej. plugin PlutoTV Enigma2): sesión fresca vía API
  // oficial en cada reproducción + User-Agent Mozilla/5.0. Guardar URLs
  // con jwt en DB no sirve: mueren en el servidor (playlist vacía).
  static const _plutoBootUrl = 'https://boot.pluto.tv/v4/start';
  static const _plutoAppVersion =
      '8.0.0-111b2b9dc00bd0bea9030b30662159ed9e7c8bc6';
  static const _plutoHeaders = {
    'origin': 'https://pluto.tv',
    'referer': 'https://pluto.tv/',
    'accept': '*/*',
    'user-agent':
        'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
  };

  bool _isPluto(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase() ?? '';
    return host.contains('pluto.tv');
  }

  /// Token fresco de Pluto vía API oficial (copiado de las apps open-source
  /// que sí lo reproducen). Null si falla.
  Future<String?> _plutoBootToken() async {
    try {
      final params = {
        'appName': 'web',
        'appVersion': _plutoAppVersion,
        'deviceVersion': '122.0.0',
        'deviceModel': 'web',
        'deviceMake': 'chrome',
        'deviceType': 'web',
        'clientID': const Uuid().v4(),
        'clientModelNumber': '1.0.0',
        'serverSideAds': 'false',
        'drmCapabilities': 'widevine:L3',
        'blockingMode': '',
      };
      final bootRes = await http
          .get(
            Uri.parse(_plutoBootUrl).replace(queryParameters: params),
            headers: _plutoHeaders,
          )
          .timeout(const Duration(seconds: 10));
      if (bootRes.statusCode != 200) return null;
      final token =
          (jsonDecode(bootRes.body) as Map)['sessionToken'] as String?;
      return (token == null || token.isEmpty) ? null : token;
    } catch (_) {
      return null;
    }
  }

  static String? _plutoChannelId(String url) =>
      RegExp(r'/channel/([0-9a-f]{24})').firstMatch(url)?.group(1);

  /// URL del master sintético (una variante + audio) servido por el proxy
  /// local, con sesión fresca. Null si algo falla (se usa el master
  /// guardado proxiado como antes).
  Future<String?> _plutoSyntheticUrl(String url) async {
    final id = _plutoChannelId(url);
    if (id == null) return null;
    final token = await _plutoBootToken();
    if (token == null) return null;
    print('🔄 [TV] Sesión Pluto nueva para el canal $id (calidad $_quality)');
    return MediaProxyService()
        .getPlutoUrl(id, token, quality: _quality);
  }

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge); // Controls are initially shown
    _initSettings();
    _currentIndex = widget.initialIndex;
    // Reproductor mpv directo (media_kit): NO se usa VideoPlayerController
    // porque su initialize() exige duration > 0 y los vivos reportan 0
    // (se quedaba colgado para siempre en todos los canales en vivo).
    _player = Player();
    _videoController = VideoController(_player!);
    // Telemetría del motor mpv (permanece en el código): sin esto los fallos
    // de apertura son invisibles (el log solo muestra ruido del decodificador).
    _player!.stream.error.listen((e) {
      if (e.isNotEmpty) print('🎬 [TV][MPV-ERROR] $e');
    });
    _player!.stream.tracks.listen((t) {
      print('🎬 [TV] tracks video=${t.video.length} '
          'audio=${t.audio.length} sub=${t.subtitle.length}');
    });
    _player!.stream.buffering.listen((b) {
      print('🎬 [TV] buffering=$b');
      // Watchdog anti-congelado: si lleva 60s buferizando sin un solo
      // respiro, se reabre solo (equivale a salir y volver al canal).
      if (!mounted) return;
      if (b) {
        _stallTimer?.cancel();
        _stallTimer = Timer(const Duration(seconds: 60), () {
          if (!mounted) return;
          print('🎬 [TV] 60s buferizando: reabriendo solo');
          _initializePlayer(widget.channels[_currentIndex]['stream_url']);
        });
      } else {
        _stallTimer?.cancel();
      }
    });
    // Un vivo no debería terminar nunca: si mpv lo da por completado,
    // se reabre solo (máx 2 veces seguidas para no entrar en bucle).
    _player!.stream.completed.listen((c) {
      if (!c || !mounted) return;
      if (_completedReopens >= 2) return;
      _completedReopens++;
      print('🎬 [TV] fin inesperado: reabriendo solo');
      _initializePlayer(widget.channels[_currentIndex]['stream_url']);
    });
    _player!.stream.playing.listen((p) {
      print('🎬 [TV] playing=$p');
    });
    _player!.stream.videoParams.listen((v) {
      print('🎬 [TV] video=${v.dw}x${v.dh}');
    });
    _initializePlayer(widget.channels[_currentIndex]['stream_url']);
    _startAdTimer();
    
    // Initial scroll to current channel
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCurrentChannel();
    });
  }

  void _startAdTimer() {
    // Si es VIP o Admin, no activamos el temporizador de anuncios periódicos
    final user = ref.read(authStateProvider);
    final role = user?.role.toLowerCase() ?? 'user';
    if (role == AppConstants.roleAdmin || role == AppConstants.roleUserVip) return;

    _adTimer?.cancel();
    _adTimer = Timer.periodic(const Duration(minutes: adIntervalMinutes), (timer) {
      _triggerPeriodicAd();
    });
  }

  void _triggerPeriodicAd() {
    // Pause player while ad shows
    _player?.pause();
    
    AdService.showRewardedAd(
      ticketId: "tv_periodic_reward",
      onAdWatched: (_) {
        // Resume playback
        _player?.play();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Gracias por ver el anuncio. Puedes seguir disfrutando de la TV.")));
      },
      onAdFailed: (error) {
        // If ad fails (no coverage), we let them continue but notify
        _player?.play();
      },
      onAdDismissedIncomplete: () {
        // User didn't watch - kick out
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Debes ver el anuncio para seguir viendo TV.")));
      }
    );
  }

  void _scrollToCurrentChannel() {
    if (_scrollController.hasClients) {
      final double itemWidth = 136.0; // 120 width + 16 margin
      _scrollController.animateTo(
        _currentIndex * itemWidth,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    }
  }

  void _initSettings() async {
    try {
      // NOTA: el volumen del sistema NO se toca al abrir un canal.
      // Se respeta el nivel que ya tenga el dispositivo y el reproductor
      // arranca en neutro (software a 1.0). Solo los gestos manuales
      // cambian el volumen del sistema.
      final storedBright = await StorageService.getStoredBrightness();

      final vol = await VolumeController.instance.getVolume();
      final bright = storedBright ?? await ScreenBrightness().current;

      if (mounted) {
        setState(() {
          _volume = vol.clamp(0.0, 3.0);
          _brightness = bright;
        });

        // Aplicar SOLO el volumen software/booster, sin tocar el sistema.
        // mpv usa escala 0..100 (100 = neutro).
        try {
          _player?.setVolume(100.0);
        } catch (_) {}
        ScreenBrightness().setScreenBrightness(_brightness);
      }
    } catch (_) {}
  }

  Future<void> _applyVolumeBoost(double targetVolume) async {
    final clamped = targetVolume.clamp(0.0, 3.0);
    final baseVolume = clamped <= 1.0 ? clamped : 1.0;

    // Volumen software neutro: el nivel 0..1 lo controla el sistema.
    // mpv usa escala 0..100 (100 = neutro).
    try {
      _player?.setVolume(100.0);
    } catch (_) {}
    await VolumeController.instance.setVolume(baseVolume);

    if (Platform.isAndroid) {
      try {
        await _audioBoostChannel.invokeMethod('setBoost', {
          'boost': clamped <= 1.0 ? 1.0 : clamped,
        });
      } catch (_) {}
    }
  }

  Future<void> _initializePlayer(String url) async {
    final player = _player;
    if (player == null) return;
    // Nueva apertura: se reinicia el conteo de auto-recuperaciones y el
    // watchdog (la calidad elegida por el usuario se conserva al zappear).
    _stallTimer?.cancel();
    _completedReopens = 0;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final isPluto = _isPluto(url);
    // Todo por el proxy local. En Pluto se usa el master sintético (una
    // variante + audio, sesión fresca): mpv se atraganta con el master
    // original multi-rendimiento.
    await MediaProxyService().start();
    // TV en vivo: lógica TV separada del Algo 1 de pelis/series.
    String effectiveUrl = MediaProxyService()
        .getProxiedUrl(url, {}, useLocalhost: true, liveTv: true);
    if (isPluto) {
      effectiveUrl = await _plutoSyntheticUrl(url) ?? effectiveUrl;
    }

    try {
      // Sin subtítulos en TV en vivo: la cadena de subtítulos (playlist +
      // segmentos vtt) puede enredar la apertura del vivo en mpv y no hay
      // selector de subtítulos en esta pantalla.
      try {
        await player.setSubtitleTrack(SubtitleTrack.no());
      } catch (_) {}
      // Calidad automática al abrir cada canal (el usuario puede fijar otra
      // desde el selector; mpv conservaría la anterior si no se resetea).
      try {
        await player.setVideoTrack(VideoTrack.auto());
      } catch (_) {}
      // mpv abre el vivo sin exigir duración (VideoPlayerController se
      // quedaba colgado porque espera duration > 0 y los vivos dan 0).
      await player
          .open(Media(effectiveUrl))
          .timeout(const Duration(seconds: 45));
      // Volumen software neutro: respetar el volumen del sistema sin
      // subidas automáticas. Re-aplicar boost solo si el usuario lo activó.
      try {
        await player.setVolume(100.0);
      } catch (_) {}
      if (_volume > 1.0 && Platform.isAndroid) {
        try {
          await _audioBoostChannel.invokeMethod('setBoost', {
            'boost': _volume.clamp(0.0, 3.0),
          });
        } catch (_) {}
      }
      await player.play();
      // Apertura sana: el watchdog parte de cero (no debe matar una
      // apertura lenta pero sana que aún está buferizando lo inicial).
      _stallTimer?.cancel();
      if (mounted) setState(() => _isLoading = false);
    } catch (e) {
      debugPrint("Error loading channel: $e");
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage =
              'No se pudo reproducir este canal. Revisa tu conexión o prueba con otro canal.';
        });
      }
    }
  }

  void _changeChannel(int index) {
    if (index == _currentIndex) return;
    
    final user = ref.read(authStateProvider);
    final role = user?.role.toLowerCase() ?? 'user';

    // Si es VIP o Admin, cambiamos de canal de inmediato
    if (role == AppConstants.roleAdmin || role == AppConstants.roleUserVip) {
      setState(() {
        _currentIndex = index;
      });
      _initializePlayer(widget.channels[index]['stream_url']);
      _scrollToCurrentChannel();
      return;
    }

    // Show rewarded ad when changing channel in-player for regular users
    AdService.showRewardedAd(
      ticketId: "tv_change_channel",
      onAdWatched: (_) {
        setState(() {
          _currentIndex = index;
        });
        _initializePlayer(widget.channels[index]['stream_url']);
        _scrollToCurrentChannel();
        // Reset the 30-minute timer when a channel is manually changed with an ad
        _startAdTimer();
      },
      onAdFailed: (error) {
        // If ad fails to load, we allow the change but notify
        setState(() {
          _currentIndex = index;
        });
        _initializePlayer(widget.channels[index]['stream_url']);
        _scrollToCurrentChannel();
      },
      onAdDismissedIncomplete: () {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Debes ver el anuncio completo para cambiar de canal."))
        );
      }
    );
  }

  /// Abre el canal en una app externa (VLC): escape si el motor interno
  /// no logra con un origen concreto. En Pluto usa el master sintético
  /// (sesión fresca) igual que el reproductor interno.
  Future<void> _openExternal() async {
    final stored = widget.channels[_currentIndex]['stream_url']?.toString();
    if (stored == null || stored.isEmpty) return;
    try {
      await _player?.pause();
      var url = stored;
      if (_isPluto(stored)) {
        url = await _plutoSyntheticUrl(stored) ?? stored;
      }
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo abrir en otra app')),
        );
        await _player?.play();
      }
    } catch (_) {
      if (mounted) await _player?.play();
    }
  }

  /// Etiqueta de la calidad actual para el tooltip del botón.
  String get _qualityLabel {
    switch (_quality) {
      case 'high':
        return 'Alta';
      case 'mid':
        return 'Media';
      default:
        return 'Auto';
    }
  }

  /// Tramos de calidad: el cambio REABRE el stream en ese tramo (un cambio
  /// en caliente entre variantes rompe la línea de tiempo y congela el
  /// video con PTS negativos).
  List<({String id, String label, String hint})> _qualityOptions() => const [
        (id: 'auto', label: 'Automática', hint: 'La que siempre funciona'),
        (id: 'mid', label: 'Media', hint: 'Equilibrio'),
        (id: 'high', label: 'Alta', hint: 'Mejor imagen si la red lo permite'),
      ];

  /// Hoja inferior para que el usuario elija la calidad que quiera.
  Future<void> _showQualitySheet() async {
    final options = _qualityOptions();
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => SafeArea(
        child: Container(
          decoration: const BoxDecoration(
            color: Color(0xFF141414),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.85,
          ),
          child: Material(
            color: Colors.transparent,
            child: SingleChildScrollView(
              child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Center(
                child: Text(
                  'Calidad de video',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              for (final o in options)
                Builder(builder: (_) {
                  final selected = o.id == _quality;
                  return ListTile(
                    dense: true,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 8),
                    leading: Icon(
                      o.id == 'auto'
                          ? Icons.auto_awesome_outlined
                          : Icons.high_quality_outlined,
                      color: selected
                          ? const Color(0xFF00A3FF)
                          : Colors.white54,
                    ),
                    title: Text(
                      o.label,
                      style: TextStyle(
                        color:
                            selected ? Colors.white : Colors.white70,
                        fontWeight: selected
                            ? FontWeight.bold
                            : FontWeight.normal,
                      ),
                    ),
                    subtitle: Text(
                      o.hint,
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 12),
                    ),
                    trailing: selected
                        ? const Icon(Icons.check,
                            color: Color(0xFF00A3FF))
                        : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      if (o.id == _quality) return;
                      // Reabre en ese tramo con línea de tiempo limpia
                      // (cambiar en caliente congela el video).
                      print('🎬 [TV] calidad elegida: ${o.label}');
                      setState(() => _quality = o.id);
                      _initializePlayer(
                          widget.channels[_currentIndex]['stream_url']);
                    },
                  );
                }),
            ],
          ),
          ),
        ),
      ),
      ),
    );
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
    if (_showControls) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrentChannel());
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  void _handleVerticalDrag(DragUpdateDetails details, bool isLeftSide) {
    final delta = details.primaryDelta! / -250; 
    
    if (isLeftSide) {
      _isDraggingVolume = true;
      _volume = (_volume + delta).clamp(0.0, 3.0);
      _showVolumeLabel = true;
      _showBrightnessLabel = false;
      VolumeController.instance.showSystemUI = false;
      _applyVolumeBoost(_volume);
    } else {
      _isDraggingBrightness = true;
      _brightness = (_brightness + delta).clamp(0.0, 1.0);
      ScreenBrightness().setScreenBrightness(_brightness);
      _showBrightnessLabel = true;
      _showVolumeLabel = false;
    }
    
    setState(() {});
    
    _labelHideTimer?.cancel();
    _labelHideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _showVolumeLabel = false;
          _showBrightnessLabel = false;
          _isDraggingVolume = false;
          _isDraggingBrightness = false;
        });
      }
    });
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WakelockPlus.disable();
    _labelHideTimer?.cancel();
    _adTimer?.cancel();
    _stallTimer?.cancel();
    if (Platform.isAndroid) {
      _audioBoostChannel.invokeMethod('releaseBoost');
    }
    _player?.dispose();
    _videoController = null;
    _scrollController.dispose();
    VolumeController.instance.showSystemUI = true;
    VolumeController.instance.removeListener();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentChannel = widget.channels[_currentIndex];
    final String channelName = currentChannel['name'] ?? 'Canal Desconocido';
    final String channelLogo = currentChannel['logo_url'] ?? '';

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _toggleControls,
        onVerticalDragUpdate: (details) {
          final width = MediaQuery.of(context).size.width;
          _handleVerticalDrag(details, details.localPosition.dx < width / 2);
        },
        onVerticalDragEnd: (details) {
          setState(() {
            _isDraggingVolume = false;
            _isDraggingBrightness = false;
          });
          // Persistir los valores cuando el usuario suelta el control
          StorageService.saveVolume(_volume);
          StorageService.saveBrightness(_brightness);
        },
        behavior: HitTestBehavior.opaque,
        child: Stack(
          children: [
            // Reproductor de video (mpv directo, sin puerta de duración)
            Positioned.fill(
              child: Center(
                child: _videoController != null
                    ? Video(controller: _videoController!)
                    : const SizedBox(),
              ),
            ),

            if (_isLoading)
              const Center(
                child: CircularProgressIndicator(color: Color(0xFF00A3FF)),
              ),

            // Error al cargar el canal (origen caído, sin conexión, etc.)
            if (!_isLoading && _errorMessage != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.tv_off_rounded,
                          color: Colors.white24, size: 56),
                      const SizedBox(height: 16),
                      Text(
                        _errorMessage!,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 14),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF00A3FF)),
                        onPressed: () => _initializePlayer(
                            widget.channels[_currentIndex]['stream_url']),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Reintentar'),
                      ),
                    ],
                  ),
                ),
              ),

            // Indicadores Hapticos de Volumen y Brillo
            if (_showVolumeLabel || _showBrightnessLabel)
              Positioned(
                top: MediaQuery.of(context).size.height / 2 - 80,
                left: _showVolumeLabel ? 40 : null,
                right: _showBrightnessLabel ? 40 : null,
                child: SizedBox(
                   width: 50, 
                   child: Column(
                     mainAxisSize: MainAxisSize.min,
                     children: [
                       Icon(_showVolumeLabel ? Icons.volume_up : Icons.brightness_medium, color: Colors.white, size: 24),
                       const SizedBox(height: 8),
                       Stack(
                         alignment: Alignment.bottomCenter,
                         children: [
                           // Track background
                           Container(
                             height: 100,
                             width: 5,
                             decoration: BoxDecoration(
                               color: Colors.white12,
                               borderRadius: BorderRadius.circular(10),
                             ),
                           ),
                           // Gradient fill
                           Container(
                             height: 100 * (_showVolumeLabel ? _volume : _brightness).clamp(0.0, 1.0),
                             width: 5,
                             decoration: BoxDecoration(
                               gradient: const LinearGradient(
                                 colors: [Color(0xFF00A3FF), Color(0xFFD400FF)],
                                 begin: Alignment.bottomCenter,
                                 end: Alignment.topCenter,
                               ),
                               borderRadius: BorderRadius.circular(10),
                               boxShadow: [
                                 BoxShadow(
                                   color: const Color(0xFF00A3FF).withOpacity(0.3),
                                   blurRadius: 4,
                                   offset: const Offset(0, 0),
                                 ),
                               ],
                             ),
                           ),
                         ],
                       ),
                       const SizedBox(height: 8),
                       Text(
                         '${((_showVolumeLabel ? _volume : _brightness) * 100).toInt()}%',
                         style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                       ),
                     ],
                   ),
                 )
              ),

            // Controles y Lista de Canales
            if (_showControls)
              Positioned.fill(
                child: Column(
                  children: [
                    // Header
                    Container(
                      padding: const EdgeInsets.only(top: 40.0, left: 16, right: 16, bottom: 20),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                           colors: [Colors.black.withOpacity(0.8), Colors.transparent],
                           begin: Alignment.topCenter,
                           end: Alignment.bottomCenter
                        )
                      ),
                      child: Row(
                          children: [
                            IconButton(
                              icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white),
                              onPressed: () => Navigator.pop(context),
                            ),
                            const SizedBox(width: 8),
                            if (channelLogo.isNotEmpty)
                              Image.network(
                                channelLogo,
                                width: 40,
                                height: 40,
                                fit: BoxFit.contain,
                                errorBuilder: (_, __, ___) => const Icon(Icons.tv, color: Colors.white38),
                              )
                            else
                              const Icon(Icons.tv, color: Colors.white38, size: 40),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                channelName.toUpperCase(),
                                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            CastButton(
                              videoUrl: MediaProxyService().getProxiedUrl(
                                widget.channels[_currentIndex]['stream_url'],
                                {},
                                useLocalhost: false,
                                // Cast de canal en vivo: lógica TV separada.
                                liveTv: true,
                              ),
                              title: channelName,
                              imageUrl: channelLogo,
                            ),
                            IconButton(
                              tooltip: 'Abrir en otra app (VLC)',
                              icon: const Icon(Icons.open_in_new_rounded,
                                  color: Colors.white70),
                              onPressed: _openExternal,
                            ),
                            IconButton(
                              tooltip: 'Calidad: $_qualityLabel',
                              icon: const Icon(
                                  Icons.high_quality_outlined,
                                  color: Colors.white70),
                              onPressed: _showQualitySheet,
                            ),
                            const SizedBox(width: 20),
                          ],
                        ),
                      ),
                      const Spacer(),
                      
                      // Bottom Channels List
                      Container(
                        height: 140,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [Colors.black.withOpacity(0.9), Colors.transparent],
                          ),
                        ),
                        child: ListView.builder(
                          controller: _scrollController,
                          scrollDirection: Axis.horizontal,
                          itemCount: widget.channels.length,
                          itemBuilder: (context, index) {
                            final channel = widget.channels[index];
                            final bool isSelected = index == _currentIndex;
                            return GestureDetector(
                              onTap: () => _changeChannel(index),
                              child: Container(
                                width: 120,
                                margin: const EdgeInsets.only(left: 16),
                                decoration: BoxDecoration(
                                  color: isSelected ? const Color(0xFF00A3FF).withOpacity(0.2) : Colors.white.withOpacity(0.05),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isSelected ? const Color(0xFF00A3FF) : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    if ((channel['logo_url'] ?? '').isNotEmpty)
                                      Expanded(
                                        child: Padding(
                                          padding: const EdgeInsets.all(8.0),
                                          child: Image.network(
                                            channel['logo_url'],
                                            fit: BoxFit.contain,
                                            errorBuilder: (_, __, ___) => const Icon(Icons.tv, color: Colors.white38),
                                          ),
                                        ),
                                      )
                                    else
                                      const Expanded(
                                        child: Icon(Icons.tv, color: Colors.white38, size: 30),
                                      ),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 8.0),
                                      child: Text(
                                        channel['name'] ?? 'Canal',
                                        style: TextStyle(
                                          color: isSelected ? Colors.white : Colors.white70,
                                          fontSize: 12,
                                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
              ),
          ],
        ),
      ),
    ),
  );
}
}
