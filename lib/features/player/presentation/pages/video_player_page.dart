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
  });

  @override
  ConsumerState<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends ConsumerState<VideoPlayerPage> {
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
  bool _isWebViewExtracting = true;
  List<String> _extractedQualities = [];
  String? _extractedVideoUrl;

  bool _isSwitchingStream = false;
  bool _isScrapingSubtitles = false;
  final ValueNotifier<bool> _isFetchingSubtitlesNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<List<String>> _extractedSubtitlesNotifier = ValueNotifier<List<String>>([]);
  final ValueNotifier<ClosedCaptionFile?> _captionNotifier = ValueNotifier<ClosedCaptionFile?>(null);
  String? _currentQualityLabel;
  Timer? _progressSaveTimer;
  bool _hasCheckedResume = false;
  
  bool _showSkipIntroButton = false;
  bool _showCreditsOverlay = false;
  bool _creditsDataLoaded = false;
  Episode? _nextEpisode;
  Season? _nextSeason;
  List<Movie> _movieRecommendations = [];
  List<Series> _seriesRecommendations = [];
  bool _isPushingNextEpisode = false;

  @override
  void initState() {
    super.initState();
    _currentOption = widget.videoOptions.first;
    
    if (widget.isLocal) {
      _isLoading = false;
      _isWebViewExtracting = false;
      _initializeVideoPlayer(_currentOption.videoUrl);
    } else {
      _initWebViewController();
    }
    
    _startHideTimer();
    _initSettings();
    _startProgressTimer();
    
    // Auto landscape mode
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _checkSavedSubtitle();
    WakelockPlus.enable();
  }

  void _startProgressTimer() {
    _progressSaveTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
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
      controller.play();
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
      controller.play();
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
    const jsCode = '''
      (function() {
         var results = { videoUrl: null, qualities: [], subtitles: [], highestQuality: null };
         
         function scan(win) {
            try {
               var all = win.document.querySelectorAll('*');
               for (var i=0; i<all.length; i++) {
                  var el = all[i];
                  if(el.children.length === 0 && el.textContent) {
                     var text = el.textContent.trim();
                     // Qualities
                     if (/^([0-9]{3,4}p|[0-9]{3,4}P|HD|SD|4K|FHD)\$/i.test(text)) {
                        if (results.qualities.indexOf(text) === -1) results.qualities.push(text);
                     }
                     // Subtitle Triggers
                     if (/^(español|spanish|english|inglés|latino|castellano|français|italiano|portugués|cc)\$/i.test(text)) {
                        if (results.subtitles.indexOf(text) === -1) results.subtitles.push(text);
                     }
                  }
               }
               for (var j=0; j<win.frames.length; j++) scan(win.frames[j]);
            } catch(e) {}
         }

         var v = document.querySelector('video');
         if(v) results.videoUrl = v.src;
         
         scan(window);
         
         if (results.qualities.length > 0) {
            var qSorted = [...results.qualities].sort((a, b) => {
              var numA = parseInt(a) || 0;
              var numB = parseInt(b) || 0;
              return numB - numA;
            });
            results.highestQuality = qSorted[0];
         }

         return JSON.stringify(results);
      })();
    ''';
    
    try {
      final dynamic jsResult = await _webViewController?.evaluateJavascript(source: jsCode);
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
                print("Scraper successfully found direct URL: $url");
                _isWebViewExtracting = false;
                _isSwitchingStream = false;
                _initializeVideoPlayer(url);
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
      _volume = await VolumeController.instance.getVolume();
      _brightness = await ScreenBrightness().current;
      setState(() {});
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
        _controller = VideoPlayerController.networkUrl(Uri.parse(videoUrl));
      }

      await _controller!.initialize();
      
      if (mounted) {
        setState(() {
          _isLoading = false;
          _isSwitchingStream = false;
        });
        if (lastPosition != null) {
          _controller?.seekTo(lastPosition);
        }
        _controller?.play();

        if (!_hasIncrementedView) {
          _hasIncrementedView = true;
          widget.onVideoStarted?.call();
        }

        if (_captionNotifier.value != null) {
          _controller?.setClosedCaptionFile(Future.value(_captionNotifier.value));
        }

        _controller!.addListener(_onVideoTick);

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
      setState(() {
        _showSkipIntroButton = showSkip;
        _showCreditsOverlay = showCredits;
      });
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
    _saveProgress(); // Final save
    _hideTimer?.cancel();
    _labelHideTimer?.cancel();
    _progressSaveTimer?.cancel();
    _controller?.dispose();
    VolumeController.instance.removeListener();
    if (!_isPushingNextEpisode) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    WakelockPlus.disable();
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
            // Video Player
            if (_errorMessage == null && _controller != null && _controller!.value.isInitialized)
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
              offstage: !_isScrapingSubtitles && !_isSwitchingStream,
              child: Container(
                color: Colors.black.withOpacity(0.95),
                child: SafeArea(
                  child: Stack(
                    children: [
                      // Invisible but active WebView
                      Positioned(
                        top: 0, left: 0,
                        child: SizedBox(
                          width: 0.1,
                          height: 0.1,
                          child: Opacity(
                            opacity: 0.01,
                            child: InAppWebView(
                              initialUrlRequest: URLRequest(url: WebUri(_currentOption.videoUrl)),
                              initialSettings: InAppWebViewSettings(
                                javaScriptEnabled: true,
                                domStorageEnabled: true,
                                useOnDownloadStart: true,
                                supportMultipleWindows: true,
                                javaScriptCanOpenWindowsAutomatically: true,
                                userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                              ),
                              onWebViewCreated: (controller) => _webViewController = controller,
                              onLoadStop: (controller, url) async {
                                if (_isWebViewExtracting || _isSwitchingStream) {
                                  _runScraper();
                                }
                              },
                              onDownloadStartRequest: (controller, downloadRequest) async {
                                final url = downloadRequest.url.toString();
                                if (url.contains(".srt") || url.contains(".vtt") || url.contains("/download/")) {
                                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Descarga detectada...")));
                                  try {
                                    final response = await http.get(Uri.parse(url), headers: {
                                      "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                                    }).timeout(const Duration(seconds: 20));

                                    if (response.statusCode == 200) {
                                      await _saveAndLoadLocalSubtitle(response.bodyBytes);
                                      _closeScraperSuccess();
                                    }
                                  } catch (e) {
                                    print("Download error: $e");
                                  }
                                }
                              },
                            ),
                          ),
                        ),
                      ),
                      
                      // K7 Modern Scanning UI
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
                              child: const Row(
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
            if ((_isLoading || _isWebViewExtracting) && !_isSwitchingStream)
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
            if (!_isLocked && _showControls && _errorMessage == null && !(_isLoading || _isWebViewExtracting || _isScrapingSubtitles))
              _buildSkipOverlay(),

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
            if (!_isLocked && _showControls && _errorMessage == null && !(_isLoading || _isWebViewExtracting || _isScrapingSubtitles))
              Center(
                child: IconButton(
                  iconSize: 80,
                  icon: Icon(
                    _controller?.value.isPlaying ?? false ? Icons.pause : Icons.play_arrow,
                    color: Colors.white.withOpacity(0.8),
                  ),
                  onPressed: () {
                    setState(() {
                      _controller!.value.isPlaying ? _controller!.pause() : _controller!.play();
                    });
                    _startHideTimer();
                  },
                ),
              ),

              // Skip Intro Button
              if (_showSkipIntroButton && widget.introEndTime != null)
                Positioned(
                  bottom: 40,
                  right: 50,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.black.withOpacity(0.65),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      elevation: 0,
                      side: const BorderSide(color: Colors.white30, width: 1),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: () {
                      _controller?.seekTo(Duration(seconds: widget.introEndTime!));
                    },
                    icon: const Icon(Icons.skip_next, size: 18),
                    label: const Text('Saltar Intro', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, letterSpacing: 0.5)),
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
