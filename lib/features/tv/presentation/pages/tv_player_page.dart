import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';
import '../../../../shared/widgets/marquee_text.dart';
import '../../../../core/services/ad_service.dart';
import '../../../cast/presentation/widgets/cast_button.dart';

class TvPlayerPage extends StatefulWidget {
  final List<Map<String, dynamic>> channels;
  final int initialIndex;

  const TvPlayerPage({
    super.key,
    required this.channels,
    required this.initialIndex,
  });

  @override
  State<TvPlayerPage> createState() => _TvPlayerPageState();
}

class _TvPlayerPageState extends State<TvPlayerPage> {
  VideoPlayerController? _controller;
  final ScrollController _scrollController = ScrollController();
  late int _currentIndex;
  bool _showControls = true;
  bool _isLoading = true;
  Timer? _adTimer;
  static const int adIntervalMinutes = 30;

  double _volume = 0.5;
  double _brightness = 0.5;
  bool _showVolumeLabel = false;
  bool _showBrightnessLabel = false;
  bool _isDraggingVolume = false;
  bool _isDraggingBrightness = false;
  Timer? _labelHideTimer;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _initSettings();
    _currentIndex = widget.initialIndex;
    _initializePlayer(widget.channels[_currentIndex]['stream_url']);
    _startAdTimer();
    
    // Initial scroll to current channel
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCurrentChannel();
    });
  }

  void _startAdTimer() {
    _adTimer?.cancel();
    _adTimer = Timer.periodic(const Duration(minutes: adIntervalMinutes), (timer) {
      _triggerPeriodicAd();
    });
  }

  void _triggerPeriodicAd() {
    // Pause player while ad shows
    _controller?.pause();
    
    AdService.showRewardedAd(
      ticketId: "tv_periodic_reward",
      onAdWatched: (_) {
        // Resume playback
        _controller?.play();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Gracias por ver el anuncio. Puedes seguir disfrutando de la TV.")));
      },
      onAdFailed: (error) {
        // If ad fails (no coverage), we let them continue but notify
        _controller?.play();
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
    _volume = await VolumeController.instance.getVolume();
    _brightness = await ScreenBrightness().current;
    if (mounted) setState(() {});
  }

  Future<void> _initializePlayer(String url) async {
    setState(() => _isLoading = true);
    if (_controller != null) {
      final oldController = _controller;
      _controller = null; 
      await oldController!.dispose();
    }
    _controller = VideoPlayerController.networkUrl(Uri.parse(url));
    try {
      await _controller!.initialize();
      _controller!.play();
      if (mounted) setState(() => _isLoading = false);
    } catch (e) {
      debugPrint("Error loading channel: $e");
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _changeChannel(int index) {
    if (index == _currentIndex) return;
    
    // Show rewarded ad when changing channel in-player
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

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
    if (_showControls) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToCurrentChannel());
    }
  }

  void _handleVerticalDrag(DragUpdateDetails details, bool isLeftSide) {
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
    WakelockPlus.disable();
    _labelHideTimer?.cancel();
    _adTimer?.cancel();
    _controller?.dispose();
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
          children: [
            // Creador del Video
            Positioned.fill(
              child: Center(
                child: _controller != null && _controller!.value.isInitialized
                    ? AspectRatio(
                        aspectRatio: _controller!.value.aspectRatio,
                        child: VideoPlayer(_controller!),
                      )
                    : const SizedBox(),
              ),
            ),

            if (_isLoading)
              const Center(
                child: CircularProgressIndicator(color: Color(0xFF00A3FF)),
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
                              videoUrl: widget.channels[_currentIndex]['stream_url'],
                              title: channelName,
                              imageUrl: channelLogo,
                            ),
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
    );
  }
}
