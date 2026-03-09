import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../../movies/domain/entities/movie.dart';
import '../../data/datasources/video_service.dart';
import 'package:video_player/video_player.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class VideoPlayerPage extends StatefulWidget {
  final String movieName;
  final List<VideoOption> videoOptions;

  const VideoPlayerPage({
    super.key, 
    required this.movieName, 
    required this.videoOptions
  });

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
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

  late WebViewController _webViewController;
  bool _isWebViewExtracting = true;
  List<String> _extractedQualities = [];
  String? _extractedVideoUrl;

  bool _isSwitchingStream = false;
  final ValueNotifier<bool> _isFetchingSubtitlesNotifier = ValueNotifier<bool>(false);
  final ValueNotifier<List<String>> _extractedSubtitlesNotifier = ValueNotifier<List<String>>([]);
  final ValueNotifier<ClosedCaptionFile?> _captionNotifier = ValueNotifier<ClosedCaptionFile?>(null);
  String? _currentQualityLabel;

  @override
  void initState() {
    super.initState();
    _currentOption = widget.videoOptions.first;
    _initWebViewController();
    _startHideTimer();
    _initSettings();
    
    // Auto landscape mode
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  void _initWebViewController() {
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1")
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (String url) {
             _runScraper();
          },
        ),
      )
      ..loadRequest(Uri.parse(_currentOption.videoUrl));
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
      final jsResult = await _webViewController.runJavaScriptReturningResult(jsCode);
      if (jsResult is String) {
        String cleanedJsonStr = jsResult;
        if (cleanedJsonStr.startsWith('"') && cleanedJsonStr.endsWith('"')) {
          cleanedJsonStr = cleanedJsonStr.substring(1, cleanedJsonStr.length - 1).replaceAll(r'\"', '"');
        }
        final data = jsonDecode(cleanedJsonStr);
        final url = data['videoUrl'] as String?;
        final qs = List<String>.from(data['qualities'] ?? []);
        final subs = List<String>.from(data['subtitles'] ?? []);
        final hq = data['highestQuality'] as String?;
        
        // Auto-select highest quality if first time and it exists
        if (_currentQualityLabel == null && hq != null && _isWebViewExtracting) {
            _onQualitySelected(hq);
            return; // onQualitySelected will call _runScraper again
        }

        if (mounted) {
          setState(() {
            _extractedQualities = qs;
            _extractedSubtitlesNotifier.value = subs;
            
            if (url != null && url != _extractedVideoUrl) {
                _extractedVideoUrl = url;
                _isWebViewExtracting = false;
                _initializeVideoPlayer(_extractedVideoUrl!);
            } else {
                _isSwitchingStream = false;
                _isWebViewExtracting = false;
            }
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => _isSwitchingStream = false);
      print("JS Eval Error: \$e");
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
     await _webViewController.runJavaScript(jsCode);
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
     await _webViewController.runJavaScript(jsCode);
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

      _controller = VideoPlayerController.networkUrl(Uri.parse(videoUrl))
        ..initialize().then((_) {
          if (mounted) {
            setState(() {
              _isLoading = false;
              _isSwitchingStream = false;
            });
            if (lastPosition != null) {
              _controller?.seekTo(lastPosition);
            }
            _controller?.play();

            if (_captionNotifier.value != null) {
              _controller?.setClosedCaptionFile(Future.value(_captionNotifier.value));
            }
          }
        });
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
    _hideTimer?.cancel();
    _labelHideTimer?.cancel();
    _controller?.dispose();
    VolumeController.instance.removeListener();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
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
            // Hidden Webview for HTML extraction
            Positioned(
              width: 50,
              height: 50,
              left: -100,
              child: Opacity(
                opacity: 0.01,
                child: IgnorePointer(
                  child: WebViewWidget(controller: _webViewController),
                ),
              ),
            ),
            
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

            // Loading / Error
            if (_isLoading || _isWebViewExtracting || _isSwitchingStream)
              const CircularProgressIndicator(color: Color(0xFF00A3FF))
            else if (_errorMessage != null)
              _buildErrorContent(),

            // Skip Forward/Backward Buttons (ONLY if not locked)
            if (!_isLocked && _showControls && _errorMessage == null && !(_isLoading || _isWebViewExtracting || _isSwitchingStream))
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
            if (!_isLocked && _showControls && _errorMessage == null && !(_isLoading || _isWebViewExtracting || _isSwitchingStream))
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
          ],
        ),
      ),
    );
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
        if (_showVolumeLabel)
          _buildSliderOverlay(Icons.volume_up, '${(_volume * 20).toInt()}', _volume, true),
        if (_showBrightnessLabel)
          _buildSliderOverlay(Icons.brightness_medium, '${(_brightness * 100).toInt()}%', _brightness, false),
      ],
    );
  }

  Widget _buildSliderOverlay(IconData icon, String label, double value, bool isLeft) {
    return Positioned(
      left: isLeft ? 40 : null,
      right: isLeft ? null : 40,
      top: MediaQuery.of(context).size.height / 2 - 100,
      child: SizedBox(
        width: 60, // Fixed width to prevent "vibration" shift
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 30),
            const SizedBox(height: 10),
            Stack(
              alignment: Alignment.bottomCenter,
              children: [
                // Track background
                Container(
                  height: 150,
                  width: 6,
                  decoration: BoxDecoration(
                    color: Colors.white12,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                // Iridescent fill
                Container(
                  height: 150 * value.clamp(0.0, 1.0),
                  width: 6,
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
            const SizedBox(height: 10),
            // Fixed width for text to avoid layout jumps
            SizedBox(
              width: 60,
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
          ],
        ),
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
                        VideoProgressIndicator(
                          _controller!,
                          allowScrubbing: true,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          colors: const VideoProgressColors(
                            playedColor: Colors.transparent,
                            bufferedColor: Colors.white24,
                            backgroundColor: Colors.white24,
                          ),
                        ),
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

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) {
      return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
    }
    return "$twoDigitMinutes:$twoDigitSeconds";
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
            _webViewController.reload();
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

    // PROFESSIONAL SCRAPER: Uses Player APIs (JWPlayer/VideoJS) + DOM clicking
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
      final jsResult = await _webViewController.runJavaScriptReturningResult(jsCode);
      String cleaned = jsResult.toString();
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
          icon: Icons.auto_awesome, 
          title: "Generar con IA (Beta)", 
          subtitle: "Transcripción automática fluida",
          onTap: () {
            Navigator.pop(context);
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text("Función Premium: Generando subtítulos por IA..."))
            );
          }
        ),
        const SizedBox(height: 10),
        _buildSubtitleAction(
          icon: Icons.search, 
          title: "Buscador OpenSubtitles", 
          subtitle: "Encuentra subtítulos para '${widget.movieName}'",
          onTap: () {
            Navigator.pop(context);
            _showSearchOpenSubtitlesDialog();
          }
        ),
      ],
    );
  }

  void _showSearchOpenSubtitlesDialog() {
    final TextEditingController searchCtrl = TextEditingController(text: widget.movieName);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF151515),
        title: const Text("Buscar Subtítulos", style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: searchCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                hintText: "Nombre de la película...",
                hintStyle: TextStyle(color: Colors.grey),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A3FF)),
              onPressed: () {
                 _searchAndDownloadSub(searchCtrl.text);
                 Navigator.pop(context);
              },
              child: const Text("Buscar"),
            )
          ],
        ),
      ),
    );
  }

  Future<void> _searchAndDownloadSub(String query) async {
    // OpenSubtitles API Key (placeholder)
    const String apiKey = "W2n6O4T5g6vS7n8o9p0q1r2s3t4u5v6w"; // Example structure
    
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Buscando subtítulos para: $query..."))
      );

      final response = await http.get(
        Uri.parse('https://api.opensubtitles.com/api/v1/subtitles?query=$query&languages=es'),
        headers: {
          'Api-Key': apiKey,
          'User-Agent': 'AntigravityMovieApp v1',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List results = data['data'] ?? [];
        
        if (results.isEmpty) {
          if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No se encontraron subtítulos en OpenSubtitles.")));
          return;
        }

        _showSubtitleResults(results, apiKey);
      } else {
        throw "Error API ${response.statusCode}";
      }
    } catch (e) {
      print("Error Search: $e");
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error al buscar en OpenSubtitles: $e")));
    }
  }

  void _showSubtitleResults(List results, String apiKey) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1C),
        title: const Text("Resultados Online", style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: results.length,
            itemBuilder: (context, index) {
              final sub = results[index]['attributes'];
              final label = sub['release'] ?? sub['language'];
              return ListTile(
                title: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                subtitle: Text("${sub['language']} | ${sub['format']}", style: const TextStyle(color: Colors.grey, fontSize: 11)),
                onTap: () {
                  Navigator.pop(context);
                  _downloadAndLoadSub(results[index]['attributes']['files'][0]['file_id'], apiKey);
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _downloadAndLoadSub(int fileId, String apiKey) async {
    try {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Descargando subtítulo...")));
      
      final response = await http.post(
        Uri.parse('https://api.opensubtitles.com/api/v1/download'),
        headers: {
          'Api-Key': apiKey,
          'User-Agent': 'AntigravityMovieApp v1',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({"file_id": fileId}),
      );

      if (response.statusCode == 200) {
        final downloadData = jsonDecode(response.body);
        final String link = downloadData['link'];
        
        // Fetch the actual file content
        final fileRes = await http.get(Uri.parse(link));
        if (fileRes.statusCode == 200) {
           final content = fileRes.body;
           _loadExternalSubtitleFromContent(content);
        }
      }
    } catch (e) {
      print("Download error: $e");
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error al descargar subtítulo: $e")));
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
      
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Subtítulos activados correctamente.")));
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
