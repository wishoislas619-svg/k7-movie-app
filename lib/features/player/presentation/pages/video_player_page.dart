import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';
import '../../../movies/domain/entities/movie.dart';
import '../../data/datasources/video_service.dart';
import 'package:video_player/video_player.dart';

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

  // Internal HLS Qualities
  List<VideoQuality> _internalQualities = [];
  VideoQuality? _currentQuality;

  @override
  void initState() {
    super.initState();
    _currentOption = widget.videoOptions.first;
    _initializePlayer();
    _startHideTimer();
    _initSettings();
    
    // Auto landscape mode
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
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

  Future<void> _initializePlayer({String? specificUrl}) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      String? urlToPlay = specificUrl;
      
      if (urlToPlay == null) {
        final directUrl = await VideoService.findDirectVideoUrl(_currentOption.videoUrl);
        if (directUrl == null) {
          throw Exception('No se pudo encontrar un enlace directo de video.');
        }
        urlToPlay = directUrl;

        // Si es un HLS (.m3u8), intentamos buscar calidades internas
        if (urlToPlay.contains('.m3u8')) {
          final qualities = await VideoService.getHlsQualities(urlToPlay);
          if (mounted && qualities.isNotEmpty) {
            setState(() {
              _internalQualities = qualities;
              // Auto-seleccionar la mejor calidad (usualmente la última en la lista)
              _currentQuality = qualities.last;
              urlToPlay = _currentQuality!.url;
            });
          }
        } else {
          setState(() {
            _internalQualities = [];
            _currentQuality = null;
          });
        }
      }

      final Duration? lastPosition = _controller?.value.position;

      _controller?.dispose();
      _controller = VideoPlayerController.networkUrl(Uri.parse(urlToPlay!))
        ..initialize().then((_) {
          if (mounted) {
            setState(() => _isLoading = false);
            if (lastPosition != null) {
              _controller?.seekTo(lastPosition);
            }
            _controller?.play();
          }
        });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
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
            // Video Player
            if (!_isLoading && _errorMessage == null && _controller != null)
              Center(
                child: AspectRatio(
                  aspectRatio: _controller!.value.aspectRatio,
                  child: VideoPlayer(_controller!),
                ),
              ),

            // Loading / Error
            if (_isLoading)
              const CircularProgressIndicator(color: Color(0xFF00A3FF))
            else if (_errorMessage != null)
              _buildErrorContent(),

            // Skip Forward/Backward Buttons (ONLY if not locked)
            if (!_isLocked && _showControls && !_isLoading && _errorMessage == null)
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
            if (!_isLocked && _showControls && !_isLoading && _errorMessage == null)
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
              IconButton(
                icon: const Icon(Icons.settings, color: Colors.white),
                onPressed: () {
                  _showResolutionDialog();
                  _startHideTimer();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withOpacity(0.8), Colors.transparent],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            // LOCK BUTTON
            IconButton(
              icon: Icon(_isLocked ? Icons.lock : Icons.lock_open, color: Colors.white),
              onPressed: () {
                setState(() => _isLocked = !_isLocked);
                _startHideTimer();
              },
            ),
            const SizedBox(width: 10),
            // Progress Bar
            if (!_isLocked && _controller != null)
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Stack(
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
                            
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: FractionallySizedBox(
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
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Align(
                      alignment: Alignment.centerRight,
                      child: ValueListenableBuilder(
                        valueListenable: _controller!,
                        builder: (context, VideoPlayerValue value, child) {
                          return Text(
                            "${_formatDuration(value.position)} / ${_formatDuration(value.duration)}",
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
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
          onPressed: _initializePlayer,
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
                // INTERNAL QUALITIES SECTION (HLS)
                if (_internalQualities.isNotEmpty) ...[
                  const Text('CALIDAD DE REPRODUCCIÓN', 
                    style: TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
                  const SizedBox(height: 10),
                  ..._internalQualities.map((q) {
                    bool isSelected = _currentQuality?.url == q.url;
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(q.resolution, 
                        style: TextStyle(color: isSelected ? const Color(0xFF00A3FF) : Colors.white70)),
                      trailing: isSelected ? const Icon(Icons.check, color: Color(0xFF00A3FF), size: 20) : null,
                      onTap: () {
                        Navigator.pop(context);
                        if (!isSelected) {
                          setState(() => _currentQuality = q);
                          _initializePlayer(specificUrl: q.url);
                        }
                      },
                    );
                  }).toList(),
                  const Divider(color: Colors.white10, height: 30),
                ],

                // SERVERS SECTION
                const Text('SERVIDOR / ENLACE', 
                  style: TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1)),
                const SizedBox(height: 10),
                ...widget.videoOptions.map((opt) {
                  bool isSelected = _currentOption == opt;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(opt.resolution, 
                      style: TextStyle(color: isSelected ? const Color(0xFF00A3FF) : Colors.white70)),
                    leading: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Image.network(
                        opt.serverImagePath, 
                        width: 30, 
                        height: 30, 
                        errorBuilder: (_, __, ___) => const Icon(Icons.dns, color: Colors.blue, size: 24),
                      ),
                    ),
                    trailing: isSelected ? const Icon(Icons.check, color: Color(0xFF00A3FF), size: 20) : null,
                    onTap: () {
                      Navigator.pop(context);
                      if (!isSelected) {
                        setState(() {
                          _currentOption = opt;
                          _currentQuality = null;
                          _internalQualities = [];
                        });
                        _initializePlayer();
                      }
                    },
                  );
                }).toList(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
