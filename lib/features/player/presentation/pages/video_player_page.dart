import 'package:movie_app/core/services/ad_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../../movies/domain/entities/movie.dart';
import '../../data/datasources/video_service.dart';
import 'package:video_player/video_player.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:movie_app/features/movies/presentation/providers/history_provider.dart';
import 'package:movie_app/features/movies/domain/entities/watch_history.dart';
import 'package:movie_app/providers.dart';
import 'package:movie_app/features/series/domain/entities/series.dart';
import 'package:movie_app/features/series/domain/entities/season.dart';
import 'package:movie_app/features/series/domain/entities/episode.dart';
import 'package:movie_app/features/series/domain/entities/series_option.dart';
import 'package:movie_app/features/series/presentation/providers/series_provider.dart';
import 'package:movie_app/features/movies/presentation/pages/movie_details_page.dart';
import 'package:movie_app/features/series/presentation/pages/series_details_page.dart';

class VideoPlayerPage extends ConsumerStatefulWidget {
  final String movieName;
  final List<VideoOption> videoOptions;
  final String? subtitleUrl;
  final bool isLocal;
  final VoidCallback? onVideoStarted;
  
  // New history fields
  final String mediaId;
  final String? episodeId;
  final String mediaType; // 'movie' or 'series'
  final String imagePath;
  final String? subtitleLabel; // e.g. "S1 E5: Episode Name"

  /// Si se provee, el reproductor saltará directamente a esta posición sin preguntar.
  final Duration? startPosition;

  final int? introStartTime;
  final int? introEndTime;
  final int? creditsStartTime;
  final int extractionAlgorithm;

  const VideoPlayerPage({
    super.key, 
    required this.movieName, 
    required this.videoOptions,
    required this.mediaId,
    this.episodeId,
    required this.mediaType,
    required this.imagePath,
    this.subtitleLabel,
    this.subtitleUrl,
    this.isLocal = false,
    this.onVideoStarted,
    this.startPosition,
    this.introStartTime,
    this.introEndTime,
    this.creditsStartTime,
    this.extractionAlgorithm = 1,
    this.initialVolume,
    this.initialBrightness,
  });

  final double? initialVolume;
  final double? initialBrightness;

  @override
  ConsumerState<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends ConsumerState<VideoPlayerPage> {
  // --- Monetización ---
  bool _isAdVerified = false;
  bool _isLoadingAd = false;
  String? _adError;
  bool _isMidrollShown = false;
  // Segundos REALES vistos (no posición). Para no disparar el midroll al hacer seek.
  int _realWatchedSeconds = 0;
  DateTime? _lastTickTime;

  VideoPlayerController? _controller;
  bool _isLoading = true;
  String? _errorMessage;
  late VideoOption _currentOption;
  bool _showControls = true;
  Timer? _hideTimer;

  // New features
  bool _isLocked = false;
  double _volume = 0.5;
  double _brightness = 0.5;
  double? _initialVolume;
  double? _initialBrightness;
  bool _showVolumeLabel = false;
  bool _showBrightnessLabel = false;
  bool _isDraggingVolume = false;
  bool _isDraggingBrightness = false;
  Timer? _labelHideTimer;

  // Internal HLS Qualities & Subtitles
  List<VideoQuality> _internalQualities = [];
  VideoQuality? _currentQuality;
  
  List<SubtitleInfo> _internalSubtitles = [];
  SubtitleInfo? _currentSubtitle;
  bool _hasIncrementedView = false;

  InAppWebViewController? _webViewController;
  final GlobalKey _webViewKey = GlobalKey();
  bool _isWebViewExtracting = true;
  List<String> _extractedQualities = [];
  Map<String, String> _qualityToUrl = {};
  bool _isQualityMenuOpen = false;
  bool _hasInitialUrl = false;
  bool _hasAttemptedQualityOptimization = false;
  String? _extractedVideoUrl;
  static const _webviewTouchChannel = MethodChannel('com.luis.movieapp/webview_touch');

  bool _isSwitchingStream = false;
  bool _isScrapingSubtitles = false;
  final ValueNotifier<bool> _isFetchingSubtitlesNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<List<String>> _extractedSubtitlesNotifier = ValueNotifier<List<String>>([]);
  final ValueNotifier<ClosedCaptionFile?> _captionNotifier = ValueNotifier<ClosedCaptionFile?>(null);
  String? _currentQualityLabel;
  Timer? _progressSaveTimer;
  bool _hasCheckedResume = false;
  bool _isInitialLoading = true;
  
  bool _showSkipIntroButton = false;
  bool _showCreditsOverlay = false;
  bool _creditsDataLoaded = false;
  Episode? _nextEpisode;
  Season? _nextSeason;
  List<Movie> _movieRecommendations = [];
  List<Series> _seriesRecommendations = [];
  bool _isPushingNextEpisode = false;
  Timer? _scraperTimer;
  int _autoClickCount = 0;
  double _skipIntroOpacity = 1.0;
  Timer? _skipFadeTimer;

  @override
  void initState() {
    super.initState();
    _initialVolume = widget.initialVolume;
    _initialBrightness = widget.initialBrightness;
    if (widget.videoOptions.isNotEmpty) {
      _currentOption = widget.videoOptions.first;
    } else {
      // Evitar crash si la lista está vacía
      _errorMessage = "No hay opciones de video disponibles para este contenido.";
      _isLoading = false;
    }
    
    // Auto landscape mode
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    if (widget.isLocal) {
      _isWebViewExtracting = false;
      _isLoading = false;
      _isInitialLoading = false;
    }

    _initSettings();
    _checkAdRequirement();
  }

  Future<void> _checkAdRequirement() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) {
      if (mounted) Navigator.pop(context);
      return;
    }
    
    final role = user.userMetadata?['role']?.toString().toLowerCase() ?? 'user';
    if (role == 'admin' || role == 'uservip') {
      _startPlayback();
      return;
    }

    if (mounted) {
      setState(() {
        _isLoadingAd = true;
        _controller?.pause(); // Pausar si ya estaba reproduciendo
      });
      // Poner pantalla completa total (ocultar notificaciones/hora)
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      
      // Detener el audio del controlador si ya existía
      if (_controller != null && _controller!.value.isPlaying) {
        _controller!.pause();
      }
    }
    
    try {
      final ticketId = const Uuid().v4();
      await Supabase.instance.client.from('ad_tickets').insert({
        'id': ticketId,
        'user_id': user.id,
        'media_type': widget.mediaType,
        'media_id': widget.mediaId,
      });

      print('--- [AD_DEBUG] TICKET_ID: $ticketId ---');
      AdService.showRewardedAd(
        ticketId: ticketId,
        onAdWatched: (String completedTicketId) {
          if (mounted) {
            setState(() {
              _isLoadingAd = false;
              _isAdVerified = true;
              _adError = null;
            });
            // AUTO-PLAY INMEDIATO
            if (_controller != null && _controller!.value.isInitialized) {
              _controller!.play();
              _startHideTimer();
            } else {
              _startPlayback();
            }
            _pollVerification(completedTicketId);
          }
        },
        onAdFailed: (String error) {
          if (mounted) {
            setState(() {
              _isLoadingAd = false;
              _adError = error;
            });
            _pollVerification(ticketId);
          }
        },
        onAdDismissedIncomplete: () {
          if (mounted) {
            setState(() {
              _isLoadingAd = false;
              _isAdVerified = false;
              _adError = 'Cancelaste el anuncio. Debes verlo completo para desbloquear el video.';
            });
            // Restaurar modo inmersivo cinemático (por si se salió)
            SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
          }
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingAd = false;
          _adError = 'Error generando el ticket de sesión publicitaria.';
        });
      }
    }
  }

  Future<void> _pollVerification(String ticketId) async {
    int retries = 15; // Un poco más de paciencia (30 seg total)
    while (retries > 0) {
      if (!mounted) return;
      try {
        final response = await Supabase.instance.client.functions.invoke(
          'secure-video-link',
          body: {
            'ticket_id': ticketId,
            'media_type': widget.mediaType,
            'media_id': widget.mediaId,
          },
        );

        if (response.status == 200) {
          if (mounted) {
            setState(() {
              _isAdVerified = true;
              _isLoadingAd = false;
              _adError = null;
            });
            // Reanudar o iniciar según el caso
            if (_isMidrollShown) {
               _controller?.play();
            } else {
               // Si ya está inicializado, dar play. Si no, iniciar proceso.
               if (_controller != null && _controller!.value.isInitialized) {
                 _controller!.play();
               } else {
                 _startPlayback();
               }
            }
          }
          return;
        }
      } catch (e) {
        // 403 suele significar "Aun no validado por AdMob"
        if (e is FunctionException && e.status == 403) {
          retries--;
          if (retries == 0) return; // Se rinde pero deja el mensaje de error anterior
          await Future.delayed(const Duration(seconds: 2));
        } else {
          return; // Error fatal, paramos polling
        }
      }
    }
  }

  Future<void> _showMidrollAd() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null) {
      final role = user.userMetadata?['role']?.toString().toLowerCase() ?? 'user';
      if (role == 'admin' || role == 'uservip') return;
    }
    
    _isMidrollShown = true;
    _controller?.pause();
    
    if (mounted) {
      setState(() {
         _isAdVerified = false;
         _isLoadingAd = true;
      });
      // Poner pantalla completa total
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }

    try {
      final ticketId = const Uuid().v4();
      await Supabase.instance.client.from('ad_tickets').insert({
        'id': ticketId,
        'user_id': user?.id,
        'media_type': widget.mediaType,
        'media_id': widget.mediaId,
      });

      AdService.showRewardedAd(
        ticketId: ticketId,
        onAdWatched: (String ct) {
          if (mounted) {
            setState(() {
              _isLoadingAd = false;
              _isAdVerified = true;
              _adError = null;
            });
            // AUTO-PLAY INMEDIATO
            if (_controller != null && _controller!.value.isInitialized) {
              _controller!.play();
              _startHideTimer();
            }
            _pollVerification(ct);
          }
        },
        onAdFailed: (String error) {
          if (mounted) {
            setState(() {
              _isLoadingAd = false;
              _adError = error;
            });
            _pollVerification(ticketId);
          }
        },
        onAdDismissedIncomplete: () {
          if (mounted) {
            setState(() {
              _isLoadingAd = false;
              _isAdVerified = false;
              _adError = 'Cancelaste el anuncio. Debes verlo completo para continuar.';
            });
          }
        },
      );
    } catch(e) {
      if (mounted) setState(() { _isLoadingAd = false; _adError = 'Error de red en medio del video.'; });
    }
  }

  void _startPlayback() {
    _isAdVerified = true;
    // Asegurar modo inmersivo al empezar la peli
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    
    final videoUrl = _currentOption.videoUrl;
    final isDirect = videoUrl.contains('.mp4') || 
                   videoUrl.contains('.m3u8') || 
                   videoUrl.contains('.m3u') ||
                   (videoUrl.contains('cf-master') && videoUrl.contains('.txt'));

    if (widget.isLocal || isDirect) {
      _isLoading = false;
      _isInitialLoading = false;
      _initializeVideoPlayer(videoUrl);
    } else {
      _initWebViewController();
    }
    
    _startHideTimer();
    _initSettings();
    _startProgressTimer();
    
    _checkSavedSubtitle();
    WakelockPlus.enable();
  }

  void _startProgressTimer() {
    _progressSaveTimer?.cancel();
    _progressSaveTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      _saveProgress();
    });
  }

  Future<void> _saveProgress() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    
    final position = _controller!.value.position.inMilliseconds;
    final duration = _controller!.value.duration.inMilliseconds;
    
    if (position <= 0) return;

    ref.read(historyProvider.notifier).saveProgress(
      mediaId: widget.mediaId,
      episodeId: widget.episodeId,
      mediaType: widget.mediaType,
      position: position,
      duration: duration,
      title: widget.movieName.split(' - ').first, // Get base title
      subtitle: widget.subtitleLabel,
      imagePath: widget.imagePath,
      videoOptionId: _currentOption.id,
    );
  }

  Future<void> _checkResume(VideoPlayerController controller) async {
    if (_hasCheckedResume) return;
    _hasCheckedResume = true;

    // Si venimos desde "Continuar Viendo" con posición inyectada, reproducir directo sin diálogo
    if (widget.startPosition != null && widget.startPosition!.inMilliseconds > 0) {
      await controller.seekTo(widget.startPosition!);
      if (!_isLoadingAd && _isAdVerified) {
        controller.play();
        _startHideTimer();
      }
      return;
    }

    final history = await ref.read(historyProvider.notifier).getProgress(widget.episodeId ?? widget.mediaId);
    
    if (history != null && history.lastPosition > 10000) { // More than 10 seconds
      // Pause immediately to ask
      controller.pause();
      
      if (!mounted) return;

      final resume = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text("Continuar Viendo", style: TextStyle(color: Colors.white)),
          content: Text(
            "¿Quieres retomar desde donde te quedaste? (${_formatDuration(Duration(milliseconds: history.lastPosition))})",
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text("Desde el inicio", style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00A3FF),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: const Text("Reanudar", style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );

      if (resume == true) {
        await controller.seekTo(Duration(milliseconds: history.lastPosition));
      }
      
      // SOLO dar play si NO hay un anuncio cargándose y está verificado
      if (!_isLoadingAd && _isAdVerified && mounted) {
        controller.play();
        _startHideTimer();
      }
    } else {
      // Si no hay historial y ya pasaron los checks de anuncios
      if (!_isLoadingAd && _isAdVerified && mounted) {
        controller.play();
        _startHideTimer();
      }
    }
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) {
      return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
    }
    return "$twoDigitMinutes:$twoDigitSeconds";
  } 

  void _initWebViewController() {
    // No specific initialization needed for InAppWebView controller as it's provided in onWebViewCreated
  }

  Future<void> _runScraper() async {
    if (!mounted || _webViewController == null || !_isWebViewExtracting) return;
    
    // --- ALGORITMO 2: EXTRACCIÓN ORIGINAL (CLICKS NATIVOS + PASIVO) ---
    // Este es el algoritmo que funcionaba perfecto antes de intentar buscar calidades.
    if (widget.extractionAlgorithm == 2) {
       try {
         final dpr = MediaQuery.of(context).devicePixelRatio;
         final box = _webViewKey.currentContext?.findRenderObject() as RenderBox?;
         if (box != null) {
           final offset = box.localToGlobal(Offset.zero);
           final w = box.size.width;
           final h = box.size.height;
           
           print("🤖 ALGORITMO 2 (MODO NATIVO): Simulando interacciones humanas...");
           
           // Secuencia de 4 clicks en cruz/centro para asegurar que se quiten Ads y se active el video
           final points = [
              Offset(w/2, h/2),
              Offset(w/2 + 20, h/2),
              Offset(w/2, h/2 + 20),
              Offset(w/2, h/2)
           ];

           for (var p in points) {
              await _webviewTouchChannel.invokeMethod('tapAt', {
                'x': (offset.dx + p.dx) * dpr,
                'y': (offset.dy + p.dy) * dpr
              });
              await Future.delayed(const Duration(milliseconds: 400));
           }

           // Escaneo ultra-simple: ¿Hay video ya?
           final script = r'''
              (function() {
                 var v = document.querySelector('video');
                 if (v && v.src && v.src.length > 10) return v.src;
                 var sources = document.querySelectorAll('source');
                 for (var s of sources) { if (s.src) return s.src; }
                 return null;
              })();
           ''';
           
           final result = await _webViewController?.evaluateJavascript(source: script);
           if (result != null) {
              String vUrl = result.toString();
              if (vUrl.startsWith('"') && vUrl.endsWith('"')) vUrl = vUrl.substring(1, vUrl.length - 1);
              if (vUrl.startsWith('http') || vUrl.startsWith('blob:')) {
                  print("🎯 ALGORITMO 2 ÉXITO: $vUrl");
                  _hasInitialUrl = true;
                  setState(() {
                    _isInitialLoading = false;
                    _isWebViewExtracting = false;
                  });
                  _initializeVideoPlayer(vUrl);
                  return;
              }
           }
         }
       } catch(e) { print("Log: Error Algoritmo 2: $e"); }
       return; // El Algoritmo 2 no continúa hacia la lógica de calidades (Algoritmo 1)
    }

    // --- ALGORITMO 1: BUSQUEDA INTELIGENTE DE CALIDADES (MODERNO) ---
    print('🔵 DEBUG: _runScraper() llamado (Algoritmo 1), autoClickCount=$_autoClickCount');
    
    // Step 1: Detect and return coordinates for interaction targets
    // Note: We use _hasInitialUrl to decide if we should look for Play or Qualities
    final bool lookingForInitial = !_hasInitialUrl;
    
    final String coordsJs = r'''
      (function() {
        var isInitial = ''' + lookingForInitial.toString() + r''';
        
        // --- PHASE 1: INITIAL PLAY ---
        if (isInitial) {
           var v = document.querySelector('video');
           if (!v || v.paused) {
              var playSelectors = ['media-play-button', '.vds-play-button', '.vjs-big-play-button', '.play-button', '[aria-label="Play"]', '.plyr__control--overlaid'];
              for (var s of playSelectors) {
                 var btn = document.querySelector(s);
                 if (btn && btn.offsetParent !== null) {
                    var r = btn.getBoundingClientRect();
                    return JSON.stringify({ x: r.left + r.width/2, y: r.top + r.height/2, found: true, type: 'play' });
                 }
              }
           }
           return JSON.stringify({ found: false });
        }

        // --- PHASE 2: QUALITY OPTIMIZATION ---
        // Plan A: Buscar por etiquetas de calidad conocidas
        var all = document.querySelectorAll('button, div, span, a');
        var qualityItems = [];

        for (var i=0; i<all.length; i++) {
           var el = all[i];
           if (el.offsetParent !== null) {
              var text = (el.innerText || el.textContent || "").trim();
              if (/^([0-9]{3,4}p|HD|SD|4K|FHD)$/i.test(text)) {
                 var r = el.getBoundingClientRect();
                 if (r.width > 0 && r.height > 0) {
                    qualityItems.push({ label: text, x: r.left + r.width/2, y: r.top + r.height/2, top: r.top });
                 }
              }
           }
        }

        if (qualityItems.length > 0) {
           if (qualityItems.length === 1) {
              var q = qualityItems[0];
              return JSON.stringify({ x: q.x, y: q.y, found: true, type: 'open-menu', label: q.label });
           } else {
              qualityItems.sort((a, b) => {
                  var valA = parseInt(a.label) || (a.label.toLowerCase().includes('hd') ? 720 : 0);
                  var valB = parseInt(b.label) || (b.label.toLowerCase().includes('hd') ? 720 : 0);
                  return valB - valA;
              });
              var top = qualityItems[0];
              return JSON.stringify({ x: top.x, y: top.y, found: true, type: 'select-quality', label: top.label });
           }
        }
        
        // Plan B: Buscar el ícono del engranaje si no encontramos etiquetas
        var gearSelectors = ['media-menu-button', '.vds-menu-button', '.gear-icon', '[aria-label="Settings"]', '.vjs-settings-control', '.icon-settings'];
        for (var s of gearSelectors) {
           var gear = document.querySelector(s);
           if (gear && gear.offsetParent !== null) {
              var r = gear.getBoundingClientRect();
              return JSON.stringify({ x: r.left + r.width/2, y: r.top + r.height/2, found: true, type: 'open-menu', label: 'Gear Settings' });
           }
        }
        
        return JSON.stringify({ found: false });
      })();
    ''';
    
    try {
      if (!mounted || _webViewController == null) return;
      final dynamic coordsResult = await _webViewController!.evaluateJavascript(source: coordsJs);
      if (coordsResult != null) {
        String raw = coordsResult is String ? coordsResult : coordsResult.toString();
        // Limpiar comillas si el resultado viene envuelto
        if (raw.startsWith('"') && raw.endsWith('"')) {
          raw = raw.substring(1, raw.length - 1).replaceAll(r'\"', '"');
        }
        
        final data = jsonDecode(raw);
        if (data != null && data['found'] == true) {
          final String targetType = data['type'] ?? 'unknown';
          final String? label = data['label'];

          if (targetType == 'select-quality' && _autoClickCount > 15) {
             print('💡 INFO: Max auto-clicks reached for quality.');
             return;
          }

          final jsX = data['x'];
          final jsY = data['y'];
          
          if (jsX == null || jsY == null) return;

          final double dx = (jsX as num).toDouble();
          final double dy = (jsY as num).toDouble();
          
          final RenderBox? box = _webViewKey.currentContext?.findRenderObject() as RenderBox?;
          if (box != null && dx > 0 && dy > 0) {
            final Offset offset = box.localToGlobal(Offset.zero);
            // Uso flexible de dpr para evitar errores tras desmontar
            final double dpr = View.of(context).devicePixelRatio;
            final double screenX = (offset.dx + dx) * dpr;
            final double screenY = (offset.dy + dy) * dpr;
            
            print('🎯 AUTO-ACTION [$targetType]: ${label ?? ""} at ($screenX, $screenY)');
            
            if (targetType == 'select-quality') _hasAttemptedQualityOptimization = true;

            await _webviewTouchChannel.invokeMethod('tapAt', { 'x': screenX, 'y': screenY });
            
            if (targetType == 'open-menu') {
               await Future.delayed(const Duration(milliseconds: 1500));
               _runScraper();
            }
          }
        }
      }
    } catch (e) {
      print('⚠️ Scraper execution error: $e');
    }

    // Step 2: Get video URL for interception
    const videoJs = r'''
      (function() {
        var results = { videoUrl: null, qualities: [], subtitles: [], highestQuality: null };
        
        function scan(win) {
          try {
            // Find video directly
            var v = win.document.querySelector('video');
            if (v && v.src && !results.videoUrl) results.videoUrl = v.src;
            
            // Scan for quality and subtitle labels
            var all = win.document.querySelectorAll('*');
            for (var i=0; i<all.length; i++) {
              var el = all[i];
              if(el.children.length === 0 && el.textContent) {
                var text = el.textContent.trim();
                // Match quality tags
                if (/^([0-9]{3,4}p|HD|SD|4K|FHD)$/i.test(text)) {
                   if (results.qualities.indexOf(text) === -1) results.qualities.push(text);
                }
                // Match subtitle labels (roughly English, Spanish, etc.)
                if (/^(English|Spanish|Español|Castellano|Italian|French|German|Portuguese|Latino)$/i.test(text)) {
                   if (results.subtitles.indexOf(text) === -1) results.subtitles.push(text);
                }
              }
            }
            // Recursive scan iframes
            for (var j=0; j<win.frames.length; j++) scan(win.frames[j]);
          } catch(e) {}
        }

        scan(window);

        if (results.qualities.length > 0) {
          var qSorted = [...results.qualities].sort((a, b) => (parseInt(b) || 0) - (parseInt(a) || 0));
          results.highestQuality = qSorted[0];
        }
        return JSON.stringify(results);
      })();
    ''';
    
    try {
      // Step A: Target detection and native interaction
      final dynamic coordsResult = await _webViewController?.evaluateJavascript(source: coordsJs);
      if (coordsResult != null) {
        String raw = coordsResult is String ? coordsResult : coordsResult.toString();
        if (raw.startsWith('"') && raw.endsWith('"')) {
          raw = raw.substring(1, raw.length - 1).replaceAll(r'\"', '"');
        }
        final data = jsonDecode(raw);
        if (data['found'] == true) {
          final double jsX = (data['x'] as num).toDouble();
          final double jsY = (data['y'] as num).toDouble();
          final String targetType = data['type'] ?? 'unknown';
          final String? label = data['label'];

          final RenderBox? box = _webViewKey.currentContext?.findRenderObject() as RenderBox?;
          if (box != null && jsX > 0 && jsY > 0) {
            final Offset offset = box.localToGlobal(Offset.zero);
            final double dpr = MediaQueryData.fromView(View.of(context)).devicePixelRatio;
            final double screenX = (offset.dx + jsX) * dpr;
            final double screenY = (offset.dy + jsY) * dpr;
            
            print('🎯 AUTO-ACTION: $targetType ${label ?? ""} at ($screenX, $screenY)');
            
            try {
              await _webviewTouchChannel.invokeMethod('tapAt', {'x': screenX, 'y': screenY});
            } catch (e) {
              print('⚠️ MethodChannel error: $e');
            }
          }
        }
      }

      // Step B: Data scraping and extraction logic
      final dynamic jsResult = await _webViewController?.evaluateJavascript(source: videoJs);
      if (jsResult != null) {
        Map<String, dynamic> data;
        
        if (jsResult is String) {
          String cleanedJsonStr = jsResult;
          if (cleanedJsonStr.startsWith('"') && cleanedJsonStr.endsWith('"')) {
            cleanedJsonStr = cleanedJsonStr.substring(1, cleanedJsonStr.length - 1).replaceAll(r'\"', '"');
          }
          data = jsonDecode(cleanedJsonStr);
        } else if (jsResult is Map) {
          data = Map<String, dynamic>.from(jsResult);
        } else {
          return;
        }

        final url = data['videoUrl'] as String?;
        final hq = data['highestQuality'] as String?;
        
        if (_currentQualityLabel == null && hq != null && _isWebViewExtracting) {
            _onQualitySelected(hq);
            return; 
        }

        if (mounted) {
          setState(() {
            _extractedQualities = List<String>.from(data['qualities'] ?? []);
            _extractedSubtitlesNotifier.value = List<String>.from(data['subtitles'] ?? []);
            
            if (url != null && url.isNotEmpty) {
                bool isSameBase = false;
                if (_controller != null && _controller!.dataSource.isNotEmpty) {
                    final currentBase = _controller!.dataSource.split('?').first;
                    final newBase = url.split('?').first;
                    isSameBase = currentBase == newBase;
                }
                
                if (!_hasInitialUrl || (!isSameBase && !url.contains('.ts'))) {
                    print("🎯 Scraper URL encontrada: $url");
                    _hasInitialUrl = true; // Phase 1 Complete
                    _isInitialLoading = false;
                    _isSwitchingStream = false;
                    _initializeVideoPlayer(url);
                }
            }
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => _isSwitchingStream = false);
    }
  }

  void _onSubtitleSelected(String label) async {
     final jsCode = '''
      (async function() {
         var targetLabel = "$label";
         var triggerRegex = /^(español|spanish|english|inglés|latino|castellano|français|italiano|portugués|cc|off|subtítulos|subtitles)\$/i;

         function findAndClick(win, label) {
            try {
               var all = win.document.querySelectorAll('*');
               for (var i=0; i<all.length; i++) {
                  if (all[i].textContent.trim() === label && all[i].offsetParent !== null) {
                     all[i].click();
                     all[i].dispatchEvent(new MouseEvent('click', {bubbles:true}));
                     return true;
                  }
               }
               for (var j=0; j<win.frames.length; j++) {
                  if (findAndClick(win.frames[j], label)) return true;
               }
            } catch(e) {}
            return false;
         }

         function findAndClickTrigger(win) {
            try {
               var all = win.document.querySelectorAll('*');
               for (var i=0; i<all.length; i++) {
                  var t = all[i].textContent.trim();
                  if (triggerRegex.test(t) && all[i].offsetParent !== null) {
                     all[i].click();
                     all[i].dispatchEvent(new MouseEvent('click', {bubbles:true}));
                     return true;
                  }
               }
               for (var j=0; j<win.frames.length; j++) {
                  if (findAndClickTrigger(win.frames[j])) return true;
               }
            } catch(e) {}
            return false;
         }

         if (findAndClick(window, targetLabel)) return true;
         if (findAndClickTrigger(window)) {
            await new Promise(r => setTimeout(r, 1000));
            return findAndClick(window, targetLabel);
         }
         return false;
      })();
     ''';
     setState(() { 
       _isSwitchingStream = true; 
       _captionNotifier.value = null; // Clear external when choosing web
       _controller?.setClosedCaptionFile(null);
     });
     await _webViewController?.evaluateJavascript(source: jsCode);
     await Future.delayed(const Duration(seconds: 2));
     _runScraper();
  }

  void _onQualitySelected(String label) async {
     final jsCode = '''
      (function() {
         var elements = document.querySelectorAll('*');
         for (var i=0; i<elements.length; i++) {
            if(elements[i].children.length === 0 && elements[i].textContent) {
               if (elements[i].textContent.trim() === "$label") {
                  elements[i].click();
                  return true;
               }
            }
         }
         return false;
      })();
     ''';
     setState(() { 
       _isSwitchingStream = true; 
       _currentQualityLabel = label;
     });
     await _webViewController?.evaluateJavascript(source: jsCode);
     await Future.delayed(const Duration(seconds: 2));
     _runScraper();
  }

  void _initSettings() async {
    try {
      // Hide system volume UI
      VolumeController.instance.showSystemUI = false;
      
      final vol = await VolumeController.instance.getVolume();
      final bright = await ScreenBrightness().current;
      
      if (mounted) {
        setState(() {
          _volume = vol;
          _brightness = bright;
          _initialVolume ??= vol;
          _initialBrightness ??= bright;
        });
      }
    } catch (_) {}
    
    // Listen to volume changes (ignore if we are currently dragging to avoid feedback jumps)
    VolumeController.instance.addListener((vol) {
      if (mounted && !_isDraggingVolume) {
        setState(() => _volume = vol);
      }
    });
  }

  Future<ClosedCaptionFile> _loadCaptions(String url) async {
    return WebVTTCaptionFile("");
  }

  Future<void> _initializeVideoPlayer(String videoUrl) async {
    // Ya no cancelamos el scraper aquí para permitir que siga buscando calidades en segundo plano.
    // _scraperTimer solo se cancela tras el timeout de clics o éxito total.
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final Duration? lastPosition = _controller?.value.position;

      _controller?.dispose();

      if (widget.isLocal) {
        _controller = VideoPlayerController.file(File(videoUrl));
      } else {
        // Intercept 4meplayer (.txt but it is HLS)
        final isHls = videoUrl.contains('cf-master') || videoUrl.contains('.m3u8');
        _controller = VideoPlayerController.networkUrl(
          Uri.parse(videoUrl),
          formatHint: isHls ? VideoFormat.hls : null,
          httpHeaders: {
            'Referer': _currentOption.videoUrl.split('#')[0],
            'Origin': (Uri.tryParse(_currentOption.videoUrl)?.hasScheme ?? false) 
                ? Uri.tryParse(_currentOption.videoUrl)!.origin 
                : '',
            'User-Agent': "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
          },
        );
      }

      if (_controller != null) {
        await _controller!.initialize();
      }
      
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isSwitchingStream = false;
        });
        if (lastPosition != null) {
          _controller?.seekTo(lastPosition);
        }
        
        // SOLO dar play si NO hay un anuncio cargándose y está verificado
        if (!_isLoadingAd && _isAdVerified) {
          _controller?.play();
        }

        if (!_hasIncrementedView) {
          _hasIncrementedView = true;
          // Increment views in Supabase
          if (widget.mediaType == 'series') {
            ref.read(seriesRepositoryProvider).incrementViews(widget.mediaId);
          } else {
            ref.read(movieRepositoryProvider).incrementViews(widget.mediaId);
          }
          widget.onVideoStarted?.call();
        }

        if (_captionNotifier.value != null) {
          _controller?.setClosedCaptionFile(Future.value(_captionNotifier.value));
        }

        _controller?.addListener(_onVideoTick);

        // Pre-carga inmediata de episodio siguiente/recomendaciones para autoplay
        if (widget.mediaType == 'series' && !_creditsDataLoaded) {
          _creditsDataLoaded = true;
          _loadCreditsData();
        }

        // Iniciar el temporizador para guardar progreso automáticamente
        _startProgressTimer();

        // Check for resume after initialization
        _checkResume(_controller!);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isSwitchingStream = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  void _onVideoTick() {
    if (_controller == null || !_controller!.value.isInitialized) return;

    final posSecs = _controller!.value.position.inSeconds;
    final isPlaying = _controller!.value.isPlaying;

    // Acumular tiempo REAL de reproducción (excluye seek y pausa)
    if (isPlaying && !_isLoadingAd) {
      final now = DateTime.now();
      if (_lastTickTime != null) {
        final elapsed = now.difference(_lastTickTime!).inSeconds;
        if (elapsed >= 1 && elapsed < 5) { // Evitar saltos grandes por seek
          _realWatchedSeconds += elapsed;
        }
      }
      _lastTickTime = now;
    } else {
      _lastTickTime = null;
    }

    // Disparar midroll al llegar a la mitad del tiempo REAL visto (no posición)
    if (widget.mediaType == 'movie' && !_isMidrollShown && _controller!.value.duration.inSeconds > 0) {
      final halfDuration = _controller!.value.duration.inSeconds ~/ 2;
      if (_realWatchedSeconds >= halfDuration) {
        _showMidrollAd();
        return;
      }
    }

    bool showSkip = false;
    bool showCredits = false;

    if (widget.introStartTime != null && widget.introEndTime != null) {
      if (posSecs >= widget.introStartTime! && posSecs < widget.introEndTime!) {
        showSkip = true;
      }
    }

    if (widget.creditsStartTime != null && posSecs >= widget.creditsStartTime!) {
        showCredits = true;
        if (!_creditsDataLoaded) {
          _creditsDataLoaded = true;
          _loadCreditsData();
        }
    }

    if (_showSkipIntroButton != showSkip || _showCreditsOverlay != showCredits) {
      if (mounted) {
        setState(() {
          if (showSkip && !_showSkipIntroButton) {
            _skipIntroOpacity = 1.0;
            _startSkipFadeTimer();
          }
          _showSkipIntroButton = showSkip;
          _showCreditsOverlay = showCredits;
        });
      }
    }

    // --- AUTOPLAY LOGIC ---
    if (!_isPushingNextEpisode && widget.mediaType == 'series' && _controller!.value.isInitialized) {
      final duration = _controller!.value.duration;
      final position = _controller!.value.position;
      
      // We consider it finished if it's within 500ms of the end or position >= duration
      final bool reachedEnd = position >= duration || (duration.inMilliseconds > 0 && (duration.inMilliseconds - position.inMilliseconds) < 500);

      if (reachedEnd && position.inMilliseconds > 0) {
        _isPushingNextEpisode = true; 
        print('🕒 [AUTOPLAY] Ep. finalizado. Buscando siguiente paso...');
        
        if (_nextEpisode != null) {
          print('🕒 [AUTOPLAY] Iniciando: ${_nextEpisode!.name}');
          _playNextEpisode();
        } else if (_seriesRecommendations.isNotEmpty) {
          print('🕒 [AUTOPLAY] Final de serie. Cargando recomendación: ${_seriesRecommendations.first.name}');
          final item = _seriesRecommendations.first;
          _controller?.pause();
          _saveProgress();
          
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => SeriesDetailsPage(series: item),
            ),
          );
        }
      }
    }
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() => _showControls = false);
        // Hide bars (time, wifi, battery, android navigation)
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      }
    });
  }

  void _startSkipFadeTimer() {
    _skipFadeTimer?.cancel();
    _skipFadeTimer = Timer(const Duration(seconds: 10), () {
      if (mounted) {
        setState(() => _skipIntroOpacity = 0.0);
      }
    });
  }

  void _toggleControls() {
    if (_isLocked) {
      setState(() => _showControls = !_showControls);
      _startHideTimer();
      return;
    }

    final newShow = !_showControls;
    setState(() {
      _showControls = newShow;
    });
    
    if (newShow) {
      if (_showSkipIntroButton) {
        _skipIntroOpacity = 1.0;
        _startSkipFadeTimer();
      }
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      _startHideTimer();
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  void _skip(int seconds) {
    if (_controller == null || !_controller!.value.isInitialized) return;
    final currentPosition = _controller!.value.position;
    final newPosition = currentPosition + Duration(seconds: seconds);
    _controller!.seekTo(newPosition);
    _startHideTimer();
  }

  void _handleVerticalDrag(DragUpdateDetails details, bool isLeftSide) {
    if (_isLocked) return;
    
    // Use a smaller sensitivity for more precision, mimicking high-end players
    final delta = details.primaryDelta! / -250; 
    
    if (isLeftSide) {
      _isDraggingVolume = true;
      _volume = (_volume + delta).clamp(0.0, 1.0);
      _showVolumeLabel = true;
      _showBrightnessLabel = false;
      VolumeController.instance.showSystemUI = false;
      VolumeController.instance.setVolume(_volume);
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
      if (mounted) setState(() {
        _showVolumeLabel = false;
        _showBrightnessLabel = false;
      });
    });
  }

  @override
  void dispose() {
    _saveProgress(); // Guardar progreso final al salir
    _progressSaveTimer?.cancel();
    _hideTimer?.cancel();
    _labelHideTimer?.cancel();
    _controller?.removeListener(_onVideoTick);
    _controller?.dispose();
    _webViewController = null;
    
    // Restore initial volume and brightness
    if (_initialVolume != null) {
      VolumeController.instance.setVolume(_initialVolume!);
    }
    if (_initialBrightness != null) {
      ScreenBrightness().setScreenBrightness(_initialBrightness!);
    }
    VolumeController.instance.showSystemUI = true;
    VolumeController.instance.removeListener();
    WakelockPlus.disable();
    
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
        },
        behavior: HitTestBehavior.opaque,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (!_isAdVerified)
              Container(
                color: Colors.black,
                width: double.infinity,
                height: double.infinity,
                child: Center(
                  child: _isLoadingAd
                     ? const Column(
                         mainAxisAlignment: MainAxisAlignment.center,
                         children: [
                           CircularProgressIndicator(color: Color(0xFF00A3FF)),
                           SizedBox(height: 16),
                           Text('Cargando anuncio para el video...', style: TextStyle(color: Colors.white70))
                         ],
                       )
                     : Column(
                         mainAxisAlignment: MainAxisAlignment.center,
                         children: [
                           const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
                           const SizedBox(height: 16),
                           Text(_adError ?? 'Error desconocido', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
                           const SizedBox(height: 24),
                           ElevatedButton(
                             onPressed: () {
                               if (!_isMidrollShown) {
                                 _checkAdRequirement();
                               } else {
                                 _showMidrollAd();
                               }
                             },
                             style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A3FF)),
                             child: const Text('Reintentar', style: TextStyle(color: Colors.white)),
                           ),
                           const SizedBox(height: 8),
                           TextButton(
                             onPressed: () => Navigator.pop(context),
                             child: const Text('Salir', style: TextStyle(color: Colors.white54)),
                           )
                         ],
                       ),
                ),
              ),

            // Video Player
            if (_isAdVerified && _errorMessage == null && _controller != null && _controller!.value.isInitialized)
              Center(
                child: AspectRatio(
                  aspectRatio: _controller!.value.aspectRatio,
                  child: Stack(
                    alignment: Alignment.bottomCenter,
                    children: [
                      VideoPlayer(_controller!),
                      
                      // Subtitle Overlay (Manual Rendering)
                      if (_controller != null)
                        ValueListenableBuilder(
                          valueListenable: _controller!,
                          builder: (context, VideoPlayerValue value, _) {
                            if (value.caption.text.isEmpty) return const SizedBox.shrink();
                            return Positioned(
                              bottom: 40,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.6),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  value.caption.text,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
              ),
            ),

            // The InAppWebView: Hidden by default, visible ONLY for subtitle scraping or if manually requested
            Offstage(
              offstage: !_isScrapingSubtitles && !_isSwitchingStream && !_isWebViewExtracting,
              child: Container(
                color: _hasInitialUrl ? Colors.transparent : Colors.black.withOpacity(0.95),
                child: SafeArea(
                  child: Stack(
                    children: [
                      // Invisible but active WebView (Now visible for debugging)
                      
                      // K7 Modern Scanning UI
                      if (!_hasInitialUrl)
                        Center(
                          child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(colors: [Color(0xFF00A3FF), Color(0xFFD400FF)]),
                                borderRadius: BorderRadius.circular(16),
                                boxShadow: [BoxShadow(color: const Color(0xFF00A3FF).withOpacity(0.4), blurRadius: 20)],
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text('K7', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 22)),
                                  SizedBox(width: 12),
                                  Text('ANÁLISIS INTELIGENTE', style: TextStyle(color: Colors.white, fontSize: 13, letterSpacing: 2, fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                            const SizedBox(height: 40),
                            const CircularProgressIndicator(color: Color(0xFF00A3FF), strokeWidth: 3),
                            const SizedBox(height: 25),
                            const Text("Buscando la mejor calidad y subtítulos...", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500)),
                            const SizedBox(height: 8),
                            const Text("Este proceso es automático y seguro", style: TextStyle(color: Colors.white38, fontSize: 12)),
                            const SizedBox(height: 50),
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  _isScrapingSubtitles = false;
                                  _isSwitchingStream = false;
                                  _controller?.play();
                                });
                              },
                              child: const Text("CANCELAR", style: TextStyle(color: Colors.white24, fontWeight: FontWeight.bold)),
                            )
                          ],
                        ),
                      ),


                    ],
                  ),
                ),
              ),
            ),

            // Loading / Error Overlay
            if (_isLoading && !_isWebViewExtracting && !_isSwitchingStream)
              Container(
                color: Colors.black,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const CircularProgressIndicator(color: Color(0xFF00A3FF)),
                      const SizedBox(height: 20),
                      Text(_isWebViewExtracting ? "Analizando origen de video..." : "Cargando video...", 
                          style: const TextStyle(color: Colors.white70)),
                    ],
                  ),
                ),
              )
            else if (_errorMessage != null)
              _buildErrorContent(),

            // Skip Forward/Backward Buttons (ONLY if not locked)
            if (!_isLocked && _errorMessage == null && !_isInitialLoading)
              AnimatedOpacity(
                duration: const Duration(milliseconds: 300),
                opacity: _showControls ? 1.0 : 0.0,
                child: IgnorePointer(
                  ignoring: !_showControls,
                  child: _buildSkipOverlay(),
                ),
              ),

            // Gesture Indicators (Volume / Brightness)
            _buildGestureIndicators(),

            // Top Menu Bar Overlay
            if (!_isLocked)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 300),
                  opacity: _showControls ? 1.0 : 0.0,
                  child: _showControls ? _buildTopMenu() : const SizedBox.shrink(),
                ),
              ),

            // Bottom Controls (Seek Bar & Lock)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 300),
                opacity: _showControls ? 1.0 : 0.0,
                child: _showControls ? _buildBottomControls() : const SizedBox.shrink(),
              ),
            ),

            // Play/Pause Sync
            if (!_isLocked && _errorMessage == null && !_isInitialLoading)
              Center(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 300),
                  opacity: _showControls ? 1.0 : 0.0,
                  child: IgnorePointer(
                    ignoring: !_showControls,
                    child: IconButton(
                  iconSize: 80,
                  icon: Icon(
                    _controller?.value.isPlaying ?? false ? Icons.pause : Icons.play_arrow,
                    color: Colors.white.withOpacity(0.8),
                  ),
                  onPressed: () {
                    if (_controller != null && _controller!.value.isInitialized) {
                      setState(() {
                        _controller!.value.isPlaying ? _controller!.pause() : _controller!.play();
                      });
                    }
                    _startHideTimer();
                  },
                ),
                ),
              ),
              ),

              // Skip Intro Button
              if (_showSkipIntroButton && widget.introEndTime != null)
                Positioned(
                  bottom: 40,
                  right: 50,
                  child: AnimatedOpacity(
                    opacity: _skipIntroOpacity,
                    duration: const Duration(milliseconds: 500),
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black.withOpacity(0.65),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        elevation: 0,
                        side: const BorderSide(color: Colors.white30, width: 1),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onPressed: _skipIntroOpacity < 0.1 ? null : () {
                        _controller?.seekTo(Duration(seconds: widget.introEndTime!));
                      },
                      icon: const Icon(Icons.skip_next, size: 18),
                      label: const Text('Saltar Intro', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, letterSpacing: 0.5)),
                    ),
                  ),
                ),

              // Credits / Recommendations / Next Episode Overlay
              if (_showCreditsOverlay)
                Positioned(
                  bottom: 40,
                  right: 50,
                  child: _nextEpisode != null
                      ? ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.black.withOpacity(0.65),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            elevation: 0,
                            side: const BorderSide(color: Colors.white30, width: 1),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: () {
                            // Navigator.pop and push Next Episode
                            _playNextEpisode();
                          },
                          icon: const Icon(Icons.fast_forward, size: 18),
                          label: Text('Siguiente Episodio (${_nextEpisode!.episodeNumber})', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, letterSpacing: 0.5)),
                        )
                      : _buildRecommendationsCarousel(),
                ),
            // Extractor Interactivo para Depuración (Visible en la capa más externa)
            if (_isWebViewExtracting || _isScrapingSubtitles)
               Positioned(
                 top: 40, 
                 left: 20,
                 right: 20,
                 child: IgnorePointer(
                   ignoring: !_isInitialLoading,
                   child: AnimatedOpacity(
                     duration: const Duration(milliseconds: 300),
                     opacity: _isInitialLoading ? 1.0 : 0.0,
                     child: Column(
                       children: [
                         Container(
                           width: double.infinity,
                       padding: EdgeInsets.all(8),
                       decoration: BoxDecoration(
                          color: Color(0xFF00A3FF), 
                          borderRadius: BorderRadius.vertical(top: Radius.circular(12))
                       ),
                       child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                             Icon(Icons.bug_report, color: Colors.white, size: 16),
                             SizedBox(width: 8),
                              Expanded(child: Text("VISTA TECNICA")), IconButton(icon: Icon(Icons.close, color: Colors.white, size: 16), padding: EdgeInsets.zero, constraints: BoxConstraints(), onPressed: () => setState(() { _isInitialLoading = false; _isWebViewExtracting = false; })),
                          ],
                       ),
                     ),
                     Container(
                       height: 250,
                       decoration: BoxDecoration(
                         border: Border.all(color: Color(0xFF00A3FF), width: 2),
                         borderRadius: BorderRadius.vertical(bottom: Radius.circular(12)),
                         color: Colors.black,
                       ),
                       child: InAppWebView(
                          key: _webViewKey,
                          initialUrlRequest: URLRequest(
                            url: WebUri(_currentOption.videoUrl),
                            headers: {
                              'Referer': _currentOption.videoUrl.split('#')[0],
                              'Origin': (Uri.tryParse(_currentOption.videoUrl)?.hasScheme ?? false) 
                                  ? Uri.tryParse(_currentOption.videoUrl)!.origin 
                                  : '',
                            },
                          ),
                          onWebViewCreated: (controller) async {
                            _webViewController = controller;
                            // Limpiamos caché y cookies previas para evitar bloqueos por sesión
                            await controller.clearCache();
                            await CookieManager.instance().deleteAllCookies();
                          },
                         initialSettings: InAppWebViewSettings(
                           javaScriptEnabled: true,
                           domStorageEnabled: true,
                           useOnDownloadStart: true,
                           supportMultipleWindows: false,
                           javaScriptCanOpenWindowsAutomatically: false,
                           allowsInlineMediaPlayback: true,
                           mediaPlaybackRequiresUserGesture: false,
                           userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                         ),
                         onCreateWindow: (controller, action) async => false,
                         shouldOverrideUrlLoading: (controller, navigationAction) async {
                           var uri = navigationAction.request.url;
                           if (uri != null && navigationAction.isForMainFrame) {
                             final initialHost = Uri.tryParse(_currentOption.videoUrl)?.host ?? '';
                             final host = uri.host.toLowerCase();
                             bool isSafe = host == initialHost || host.contains('google') || host.contains('facebook') || host.contains('cloudflare') || host.contains('jsdelivr');
                             if (!isSafe) return NavigationActionPolicy.CANCEL;
                           }
                           return NavigationActionPolicy.ALLOW;
                         },
                          // --- ALGORITMO HIBRIDO (REPO + CLICKS) ---
                         onLoadResource: (controller, resource) {
                           final url = resource.url?.toString() ?? '';
                           final lcUrl = url.toLowerCase();
                           bool isJunk = lcUrl.contains('analytics') || lcUrl.contains('google-analytics') || lcUrl.contains('doubleclick') || lcUrl.contains('collect?') || lcUrl.contains('facebook.com/tr/') || lcUrl.contains('yandex') || lcUrl.contains('yastatic') || lcUrl.contains('loading.mp4') || lcUrl.contains('mc.yandex.ru') || lcUrl.contains('hotjar') || lcUrl.contains('/pixel') || lcUrl.contains('popads') || lcUrl.contains('mixpanel');
                           if (isJunk) return;
                           bool hasVideoExt = lcUrl.contains('.mp4?') || lcUrl.endsWith('.mp4') || lcUrl.contains('.m3u8?') || lcUrl.endsWith('.m3u8') || lcUrl.contains('.m3u?') || lcUrl.endsWith('.m3u') || lcUrl.contains('.webm') || lcUrl.contains('.ts') || lcUrl.contains('.mov') || lcUrl.contains('.avi') || lcUrl.contains('.mkv');
                           bool is4meStream = lcUrl.contains('cf-master') && lcUrl.contains('.txt');
                            if ((hasVideoExt || is4meStream) && (_isWebViewExtracting || _isSwitchingStream)) {
                              print("🎯 VIDEO_DETECTADO: $url");
                              if (!_hasInitialUrl) {
                                  _hasInitialUrl = true; 
                                   setState(() { 
                                     _isInitialLoading = false; 
                                     if (widget.extractionAlgorithm == 2) {
                                       _isWebViewExtracting = false; 
                                     }
                                   }); // Cerramos pantalla de carga para ver el video inicial
                                  _initializeVideoPlayer(url);
                              } else {
                                  bool isSameBase = false;
                                  if (_controller != null && _controller!.dataSource.isNotEmpty) {
                                      final currentBase = _controller!.dataSource.split('?').first;
                                      final newBase = url.split('?').first;
                                      isSameBase = currentBase == newBase;
                                  }
                                  if (!isSameBase && !url.contains('.ts')) {
                                      _initializeVideoPlayer(url); // Actualizamos a mayor calidad si aparece
                                  }
                              }
                            }
                         },
                         onLoadStop: (controller, url) async {
                           if (_isWebViewExtracting || _isSwitchingStream) {
                             _autoClickCount = 0;
                             _scraperTimer?.cancel();
                              _scraperTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
                                if (!_isWebViewExtracting && !_isSwitchingStream) { timer.cancel(); return; }
                                if (_autoClickCount < 4) {
                                   _webViewController?.evaluateJavascript(source: "(function(){ var v=document.querySelector('video'); return (v && v.src) ? v.src : null; })();").then((v) {
                                      if (v != null && v.toString().startsWith('http')) {
                                          final foundUrl = v.toString();
                                          bool isSameBase = false;
                                          if (_controller != null && _controller!.dataSource.isNotEmpty) {
                                              final currentBase = _controller!.dataSource.split('?').first;
                                              final newBase = foundUrl.split('?').first;
                                              isSameBase = currentBase == newBase;
                                          }
                                          if (!_hasInitialUrl || (!isSameBase && !foundUrl.contains('.ts'))) {
                                              _hasInitialUrl = true;
                                              setState(() { _isInitialLoading = false; });
                                              _initializeVideoPlayer(foundUrl);
                                          }
                                      }
                                   });
                                } else {
                                   _runScraper();
                                }
                                _autoClickCount++;
                              });
                            }
                          },
                         onDownloadStartRequest: (controller, downloadRequest) async {
                           final url = downloadRequest.url.toString();
                           if (url.contains(".srt") || url.contains(".vtt") || url.contains("/download/")) {
                             try {
                               final response = await http.get(Uri.parse(url), headers: { "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1" }).timeout(const Duration(seconds: 20));
                               if (response.statusCode == 200) { await _saveAndLoadLocalSubtitle(response.bodyBytes); _closeScraperSuccess(); }
                             } catch (e) { print("Download error: $e"); }
                           }
                         },
                       ),
                     ),
                   ],
                 ),
               ),
             ),
           ),
            // Pantalla negra que oculta la vista técnica al usuario
            if ((_isWebViewExtracting || _isScrapingSubtitles) && _isInitialLoading)
              Positioned.fill(
                child: Container(
                  color: Colors.black,
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(color: Color(0xFF00A3FF)),
                        SizedBox(height: 20),
                        Text(
                          'Cargando video...',
                          style: TextStyle(color: Colors.white70, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadCreditsData() async {
    if (widget.mediaType == 'series' && widget.episodeId != null) {
      final repo = ref.read(seriesRepositoryProvider);
      final series = await repo.getSeriesById(widget.mediaId);
      final seasons = await repo.getSeasonsForSeries(widget.mediaId);
      
      String? currentSeasonId;
      bool isFinale = false;
      for (var s in seasons) {
        final eps = await repo.getEpisodesForSeason(s.id);
        final idx = eps.indexWhere((e) => e.id == widget.episodeId);
        if (idx != -1) {
          if (eps[idx].isSeriesFinale) {
            isFinale = true;
            break;
          }
          currentSeasonId = s.id;
          if (idx + 1 < eps.length) {
            _nextEpisode = eps[idx + 1];
            _nextSeason = s;
            break;
          } else {
            // Next season
            final sIdx = seasons.indexWhere((se) => se.id == s.id);
            if (sIdx != -1 && sIdx + 1 < seasons.length) {
              final nextS = seasons[sIdx + 1];
              final nextEps = await repo.getEpisodesForSeason(nextS.id);
              if (nextEps.isNotEmpty) {
                _nextEpisode = nextEps.first;
                _nextSeason = nextS;
              }
            }
            break;
          }
        }
      }

      if (isFinale || _nextEpisode == null) {
        _nextEpisode = null; // Ensure no next episode button appears
        // No more episodes, load series recommendations
        if (series?.categoryId != null) {
          final allSeries = await repo.getSeries();
          _seriesRecommendations = allSeries.where((s) => s.categoryId == series!.categoryId && s.id != series.id).take(10).toList();
        }
      }
    } else {
      // Movie
      final repo = ref.read(movieRepositoryProvider);
      final allMovies = await repo.getMovies();
      final thisMovie = allMovies.where((m) => m.id == widget.mediaId).firstOrNull;
      if (thisMovie?.categoryId != null) {
        _movieRecommendations = allMovies.where((m) => m.categoryId == thisMovie!.categoryId && m.id != thisMovie.id).take(10).toList();
      }
    }
    if (mounted) setState(() {});
  }

  void _playNextEpisode() async {
    if (_nextEpisode == null || _nextSeason == null) return;
    
    // Increment views
    ref.read(seriesListProvider.notifier).incrementViews(widget.mediaId);

    // Save history manually to be sure
    await _saveProgress();

    // Find option
    final repo = ref.read(seriesRepositoryProvider);
    final options = await repo.getSeriesOptions(widget.mediaId);
    
    SeriesOption? option;
    if (_nextEpisode!.urls.isNotEmpty) {
      try {
        option = options.firstWhere((o) => o.id == _nextEpisode!.urls.first.optionId);
      } catch (_) {
        if (options.isNotEmpty) option = options.first;
      }
    }

    if (option == null && options.isNotEmpty) {
      option = options.first;
    }

    if (!mounted) return;

    _isPushingNextEpisode = true;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(
          movieName: '${widget.movieName.split(' - ').first} - S${_nextSeason!.seasonNumber} E${_nextEpisode!.episodeNumber}',
          onVideoStarted: () {},
          mediaId: widget.mediaId,
          episodeId: _nextEpisode!.id,
          mediaType: 'series',
          imagePath: widget.imagePath,
          subtitleLabel: 'S${_nextSeason!.seasonNumber} E${_nextEpisode!.episodeNumber}: ${_nextEpisode!.name}',
          introStartTime: _nextEpisode!.introStartTime,
          introEndTime: _nextEpisode!.introEndTime,
          creditsStartTime: _nextEpisode!.creditsStartTime,
          initialVolume: _initialVolume,
          initialBrightness: _initialBrightness,
          videoOptions: [
            if (_nextEpisode!.urls.isNotEmpty)
              VideoOption(
                id: _nextEpisode!.id,
                movieId: widget.mediaId,
                serverImagePath: option?.serverImagePath ?? '',
                resolution: _nextEpisode!.urls.first.quality ?? option?.resolution ?? 'Auto',
                videoUrl: _nextEpisode!.urls.first.url,
              )
          ],
        ),
      ),
    );
  }

  Widget _buildRecommendationsCarousel() {
    final bool isMovie = widget.mediaType == 'movie';
    final int count = isMovie ? _movieRecommendations.length : _seriesRecommendations.length;
    
    if (count == 0) return const SizedBox.shrink();

    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: 450,
          height: 200,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.4),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white24, width: 1),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 20, spreadRadius: 5),
            ],
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Tal vez, te interese ver...', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: count,
                  itemBuilder: (context, index) {
                    final dynamic item = isMovie ? _movieRecommendations[index] : _seriesRecommendations[index];
                    return GestureDetector(
                      onTap: () {
                        _controller?.pause();
                        _saveProgress();
                        
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                            builder: (_) => isMovie ? MovieDetailsPage(movie: item) : SeriesDetailsPage(series: item),
                          ),
                        );
                      },
                      child: Container(
                        width: 100,
                        margin: const EdgeInsets.only(right: 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.white12, width: 1),
                          image: DecorationImage(image: NetworkImage(item.imagePath), fit: BoxFit.cover),
                        ),
                      ),
                    );
                  },
                ),
              )
            ],
          ),
        ),
      ),
    );
  }

  void _handleCreditsAction() {
    Navigator.pop(context);
  }

  Widget _buildSkipOverlay() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.replay_10, color: Colors.white, size: 50),
          onPressed: () => _skip(-10),
        ),
        const SizedBox(width: 150),
        IconButton(
          icon: const Icon(Icons.forward_10, color: Colors.white, size: 50),
          onPressed: () => _skip(10),
        ),
      ],
    );
  }

  Widget _buildGestureIndicators() {
    return Stack(
      children: [
        // Volume Slider (Left)
        Positioned(
          left: 60,
          top: MediaQuery.of(context).size.height / 2 - 80,
          child: AnimatedOpacity(
            opacity: (_showVolumeLabel || (_showControls && !_isLocked)) ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 300),
            child: _buildSliderOverlay(Icons.volume_up, '${(_volume * 15).toInt()}', _volume, true),
          ),
        ),
        // Brightness Slider (Right)
        Positioned(
          right: 60,
          top: MediaQuery.of(context).size.height / 2 - 80,
          child: AnimatedOpacity(
            opacity: (_showBrightnessLabel || (_showControls && !_isLocked)) ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 300),
            child: _buildSliderOverlay(Icons.brightness_medium, '${(_brightness * 100).toInt()}%', _brightness, false),
          ),
        ),
      ],
    );
  }

  Widget _buildSliderOverlay(IconData icon, String label, double value, bool isLeft) {
    return SizedBox(
      width: 50, 
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 24),
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
                height: 100 * value.clamp(0.0, 1.0),
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
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopMenu() {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black.withOpacity(0.7), Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.movieName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Setting gear removed from top bar
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withOpacity(0.9), Colors.transparent],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
             if (!_isLocked && _controller != null)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ValueListenableBuilder(
                    valueListenable: _controller!,
                    builder: (context, VideoPlayerValue value, child) {
                      return Text(
                        _formatDuration(value.position),
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                      );
                    },
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Stack(
                      alignment: Alignment.centerLeft,
                      children: [
                        // Background Bar (Thick gray part)
                        Container(
                          height: 7.0,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                        // Invisible indicator for scrubbing logic
                        VideoProgressIndicator(
                          _controller!,
                          allowScrubbing: true,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          colors: const VideoProgressColors(
                            playedColor: Colors.transparent,
                            bufferedColor: Colors.white24,
                            backgroundColor: Colors.transparent,
                          ),
                        ),
                        // Iridescent Progress Bar
                        ValueListenableBuilder(
                          valueListenable: _controller!,
                          builder: (context, VideoPlayerValue value, child) {
                            final duration = value.duration.inMilliseconds;
                            final position = value.position.inMilliseconds;
                            if (duration == 0) return const SizedBox.shrink();
                            
                            return FractionallySizedBox(
                              widthFactor: (position / duration).clamp(0.0, 1.0),
                              child: Container(
                                height: 7.0,
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [Color(0xFF00A3FF), Color(0xFFD400FF)],
                                  ),
                                  borderRadius: BorderRadius.circular(5),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF00A3FF).withOpacity(0.4),
                                      blurRadius: 10,
                                      offset: const Offset(0, 0),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 15),
                  ValueListenableBuilder(
                    valueListenable: _controller!,
                    builder: (context, VideoPlayerValue value, child) {
                      return Text(
                        _formatDuration(value.duration),
                        style: const TextStyle(color: Colors.white54, fontSize: 13, fontWeight: FontWeight.bold),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 5),

              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                   IconButton(
                     icon: Icon(_isLocked ? Icons.lock : Icons.lock_open, color: Colors.white),
                     onPressed: () {
                       setState(() => _isLocked = !_isLocked);
                       _startHideTimer();
                     },
                   ),
                   if (!_isLocked)
                     Row(
                       children: [
                           IconButton(
                             icon: const Icon(Icons.subtitles, color: Colors.white),
                             onPressed: () {
                               _loadAndShowSubtitles();
                               _startHideTimer();
                             },
                           ),
                           Row(
                             mainAxisSize: MainAxisSize.min,
                             children: [
                               IconButton(
                                 icon: const Icon(Icons.settings, color: Colors.white),
                                 padding: EdgeInsets.zero,
                                 constraints: const BoxConstraints(),
                                 onPressed: () {
                                   _showResolutionDialog();
                                   _startHideTimer();
                                 },
                               ),
                               const SizedBox(width: 5),
                               Text(
                                 _currentQualityLabel ?? "Auto",
                                 style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                               ),
                             ],
                           ),
                       ],
                     ),
                ],
              )
          ],
        ),
      ),
    );
  }

  Widget _buildErrorContent() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(Icons.error, color: Colors.orange, size: 60),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Text(
            _errorMessage!,
            style: const TextStyle(color: Colors.grey),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF00A3FF),
          ),
          onPressed: () {
            setState(() { _isWebViewExtracting = true; _errorMessage = null; });
            _webViewController?.reload();
          },
          child: const Text('Reintentar'),
        ),
      ],
    );
  }

  void _showResolutionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF151515),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.settings, color: Color(0xFF00A3FF)),
            const SizedBox(width: 10),
            const Text('Ajustes de Video', style: TextStyle(color: Colors.white, fontSize: 18)),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_extractedQualities.isNotEmpty) ...[
                  const Text('CALIDAD DE REPRODUCCIÓN', 
                    style: TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
                  const SizedBox(height: 10),
                  ..._extractedQualities.map((q) {
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(q, style: const TextStyle(color: Colors.white70)),
                      onTap: () {
                        Navigator.pop(context);
                        _onQualitySelected(q);
                      },
                    );
                  }).toList(),
                ] else ...[
                   const Padding(
                     padding: EdgeInsets.symmetric(vertical: 20),
                     child: Text("No se encontraron calidades seleccionables en este reproductor", style: TextStyle(color: Colors.white54)),
                   ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _loadAndShowSubtitles() async {
    _extractedSubtitlesNotifier.value = [];
    _isFetchingSubtitlesNotifier.value = true;
    
    _showSubtitlesDialog();

    // PROFESSIONAL SCRAPER (Browser extraction)
    const jsCode = '''
      (async function() {
         var results = [];
         var triggerRegex = /^(español|spanish|english|inglés|latino|castellano|français|italiano|portugués|cc|subtítulos|subtitles)\$/i;
         
         function scanAPI(win) {
            try {
               // JWPlayer API
               if (win.jwplayer && typeof win.jwplayer === 'function') {
                  var tracks = win.jwplayer().getCaptionsList();
                  if (tracks) {
                     tracks.forEach(t => { if(t.label) results.push(t.label); });
                  }
               }
               // VideoJS API
               if (win.videojs) {
                  var players = win.videojs.getPlayers();
                  for (var p in players) {
                     var tracks = players[p].textTracks();
                     for (var i=0; i<tracks.length; i++) {
                        if(tracks[i].label) results.push(tracks[i].label);
                     }
                  }
               }
            } catch(e) {}
         }

         function findAndClickTrigger(win) {
            try {
               var all = win.document.querySelectorAll('*');
               for (var i=0; i<all.length; i++) {
                  var t = all[i].textContent.trim();
                  if (t.length > 0 && t.length < 30 && triggerRegex.test(t)) {
                     if (all[i].offsetParent !== null) {
                        all[i].click();
                        all[i].dispatchEvent(new MouseEvent('click', {bubbles:true}));
                        return true;
                     }
                  }
               }
               for (var j=0; j<win.frames.length; j++) {
                  if (findAndClickTrigger(win.frames[j])) return true;
               }
            } catch(e) {}
            return false;
         }

         function scanDOM(win) {
            try {
               var all = win.document.querySelectorAll('*');
               for (var i=0; i<all.length; i++) {
                  var t = all[i].textContent.trim();
                  if (t.length > 1 && t.length < 40 && all[i].offsetParent !== null) {
                     if (triggerRegex.test(t) || /^[A-Z][A-Za-z\s]+\$/.test(t)) {
                        if (results.indexOf(t) === -1) results.push(t);
                     }
                  }
               }
               for (var j=0; j<win.frames.length; j++) scanDOM(win.frames[j]);
            } catch(e) {}
         }

         // Try APIs first (Fast)
         scanAPI(window);
         for(var f=0; f<window.frames.length; f++) scanAPI(window.frames[f]);
         
         if (results.length === 0) {
            // Fallback to Click & Scan
            findAndClickTrigger(window);
            await new Promise(r => setTimeout(r, 1500));
            scanDOM(window);
         }

         return JSON.stringify(results);
      })();
    ''';

    try {
      final dynamic jsResult = await _webViewController?.evaluateJavascript(source: jsCode);
      String cleaned = jsResult?.toString() ?? "[]";
      if (cleaned.startsWith('"') && cleaned.endsWith('"')) {
        cleaned = cleaned.substring(1, cleaned.length - 1).replaceAll(r'\"', '"');
      }
      
      final dynamic decoded = jsonDecode(cleaned);
      if (decoded is List) {
        if (mounted) {
           _extractedSubtitlesNotifier.value = List<String>.from(decoded);
        }
      }
    } catch (e) {
      print("Pro subtitle scan error: $e");
    } finally {
      if (mounted) {
        _isFetchingSubtitlesNotifier.value = false;
      }
    }
  }

  void _showSubtitlesDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF151515),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.subtitles, color: Color(0xFF00A3FF)),
            const SizedBox(width: 10),
            const Text('Subtítulos', style: TextStyle(color: Colors.white, fontSize: 18)),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Professional Section: AI and Online Search
                _buildProfessionalSection(),
                const Divider(color: Colors.white12, height: 30),
                const Text('EXTRAER DE LA PÁGINA', 
                  style: TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
                const SizedBox(height: 10),
                
                ValueListenableBuilder<bool>(
                  valueListenable: _isFetchingSubtitlesNotifier,
                  builder: (context, isFetching, _) {
                    return ValueListenableBuilder<List<String>>(
                      valueListenable: _extractedSubtitlesNotifier,
                      builder: (context, extracted, _) {
                        if (isFetching && extracted.isEmpty) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 20),
                            child: Center(child: CircularProgressIndicator(color: Color(0xFF00A3FF))),
                          );
                        }
                        
                        if (extracted.isEmpty && _internalSubtitles.isEmpty) {
                          return const Padding(
                            padding: EdgeInsets.symmetric(vertical: 20),
                            child: Text("No se detectaron subtítulos web.", style: TextStyle(color: Colors.white54)),
                          );
                        }

                        return Column(
                          children: [
                            // Option to Disable Subtitles
                            ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.subtitles_off, 
                                color: _currentSubtitle == null ? const Color(0xFF00A3FF) : Colors.white38),
                              title: Text("Desactivado", 
                                style: TextStyle(color: _currentSubtitle == null ? const Color(0xFF00A3FF) : Colors.white70)),
                              trailing: _currentSubtitle == null ? const Icon(Icons.check, color: Color(0xFF00A3FF), size: 18) : null,
                              onTap: () {
                                Navigator.pop(context);
                                setState(() {
                                  _currentSubtitle = null;
                                  _captionNotifier.value = null;
                                  _controller?.setClosedCaptionFile(null);
                                });
                              },
                            ),
                            const Divider(color: Colors.white10),
                            ...extracted.map((sub) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.language, color: Colors.white38, size: 20),
                              title: Text(sub, style: const TextStyle(color: Colors.white70)),
                              onTap: () {
                                Navigator.pop(context);
                                _onSubtitleSelected(sub);
                              },
                            )),
                            if (isFetching) 
                              const LinearProgressIndicator(backgroundColor: Colors.transparent, color: Color(0xFF00A3FF)),
                          ],
                        );
                      },
                    );
                  },
                ),
                
                if (_internalSubtitles.isNotEmpty) ...[
                  const Divider(color: Colors.white12),
                  ..._internalSubtitles.map((sub) {
                    bool isSelected = _currentSubtitle?.url == sub.url;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(sub.language, style: TextStyle(color: isSelected ? const Color(0xFF00A3FF) : Colors.white70)),
                      trailing: isSelected ? const Icon(Icons.check, color: Color(0xFF00A3FF)) : null,
                      onTap: () {
                        Navigator.pop(context);
                        setState(() => _currentSubtitle = sub);
                      },
                    );
                  }),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProfessionalSection() {
    return Column(
      children: [
        _buildSubtitleAction(
          icon: Icons.cloud_download, 
          title: "Descargar Subtítulos (Web)", 
          subtitle: "Procesar desde la URL configurada",
          onTap: () {
            Navigator.pop(context);
            _manualScrapeSubtitles();
          }
        ),
      ],
    );
  }

  Future<void> _manualScrapeSubtitles() async {
    if (widget.subtitleUrl == null || widget.subtitleUrl!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No hay una URL de subtítulos configurada."))
      );
      return;
    }

    setState(() {
      _isScrapingSubtitles = true;
      _controller?.pause();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Iniciando descarga manual..."))
    );

    try {
      print("Manual Scrape: loading ${widget.subtitleUrl}");
      
      // Clear before loading to ensure a fresh session
      await _webViewController?.loadUrl(
        urlRequest: URLRequest(
          url: WebUri(widget.subtitleUrl!),
          headers: {
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
          }
        )
      );
      
      // Wait for the user to solve captcha or the page to load
      await Future.delayed(const Duration(seconds: 12));

      // Try several times every 5 seconds if not found
      for (int i=0; i<3; i++) {
        print("Scraper attempt ${i+1}...");
        const jsTrigger = '''
          (async function() {
             function findByText(text, selector = '*') {
               const items = document.querySelectorAll(selector);
               for(let i=0; i<items.length; i++) {
                 let elText = items[i].textContent.trim().toUpperCase();
                 if(elText === text.toUpperCase() || elText.includes(text.toUpperCase())) return items[i];
               }
               return null;
             }

             const mfBtn = document.querySelector('#downloadButton') || 
                          document.querySelector('.download_link') || 
                          findByText('Download', 'a, div, button');
             
             if (mfBtn) {
               mfBtn.scrollIntoView();
               mfBtn.click();
               return "CLICKED";
             }
             return "NOT_FOUND";
          })();
        ''';

        final result = await _webViewController?.evaluateJavascript(source: jsTrigger);
        print("JS Trigger Result: $result");
        if (result == "CLICKED") break;
        await Future.delayed(const Duration(seconds: 8));
      }
      
      // Keep it open to allow manual interaction if JS trigger fails
      await Future.delayed(const Duration(seconds: 15));
      
    } catch (e) {
      print("Scrape error: $e");
    }
  }

  void _closeScraperSuccess() {
    if(mounted) {
      setState(() {
        _isScrapingSubtitles = false;
        _controller?.play();
      });
      _webViewController?.loadUrl(
        urlRequest: URLRequest(url: WebUri(_currentOption.videoUrl))
      );
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Subtítulos descargados con éxito.")));
    }
  }

  Future<void> _saveAndLoadLocalSubtitle(dynamic content) async {
    try {
      String decodedContent;
      if (content is List<int>) {
        decodedContent = _decodeSubtitleBytes(content);
      } else {
        decodedContent = content.toString();
      }

      // Remove BOM if present (Fixes the "A with arrow" at the start)
      if (decodedContent.startsWith('\uFEFF')) {
        decodedContent = decodedContent.substring(1);
      }

      final directory = await getApplicationDocumentsDirectory();
      final fileName = "sub_${widget.movieName.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}.srt";
      final file = File('${directory.path}/$fileName');
      
      await file.writeAsString(decodedContent);
      _loadExternalSubtitleFromContent(decodedContent);
      
      if(mounted) {
        if (!_internalSubtitles.any((s) => s.url == "local_file")) {
          setState(() {
            _internalSubtitles.add(SubtitleInfo(language: "Subtítulo Guardado", url: "local_file"));
          });
        }
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Subtítulo guardado y aplicado correctamente.")));
      }
    } catch (e) {
      print("Save error: $e");
    }
  }

  String _decodeSubtitleBytes(List<int> bytes) {
    try {
      // Try UTF-8 first
      return utf8.decode(bytes);
    } catch (_) {
      try {
        // Fallback to Latin-1
        return latin1.decode(bytes);
      } catch (_) {
        // Ultimate fallback
        return String.fromCharCodes(bytes);
      }
    }
  }

  Future<void> _checkSavedSubtitle() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final fileName = "sub_${widget.movieName.replaceAll(RegExp(r'[^a-zA-r0-9]'), '_')}.srt";
      final file = File('${directory.path}/$fileName');
      
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        String content = _decodeSubtitleBytes(bytes);
        
        if (content.startsWith('\uFEFF')) {
          content = content.substring(1);
        }

        _loadExternalSubtitleFromContent(content);
        if(mounted) {
          setState(() {
            if (!_internalSubtitles.any((s) => s.url == "local_file")) {
              _internalSubtitles.add(SubtitleInfo(language: "Subtítulo Guardado", url: "local_file"));
            }
          });
        }
      }
    } catch (e) {
      print("Check saved error: $e");
    }
  }

  void _loadExternalSubtitleFromContent(String content) {
    try {
      ClosedCaptionFile captionFile;
      if (content.contains('WEBVTT')) {
        captionFile = WebVTTCaptionFile(content);
      } else {
        captionFile = SubRipCaptionFile(content);
      }
      
      _captionNotifier.value = captionFile;
      _controller?.setClosedCaptionFile(Future.value(captionFile));
    } catch (e) {
      print("Parse error: $e");
    }
  }

  Widget _buildSubtitleAction({required IconData icon, required String title, required String subtitle, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF00A3FF), size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  Text(subtitle, style: const TextStyle(color: Colors.grey, fontSize: 11)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white24),
          ],
        ),
      ),
    );
  }
}
