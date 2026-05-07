import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';

class FloatingPlayerOverlay extends StatefulWidget {
  final VideoPlayerController controller;
  final String title;
  final VoidCallback onClose;
  final VoidCallback onReturn;

  const FloatingPlayerOverlay({
    super.key,
    required this.controller,
    required this.title,
    required this.onClose,
    required this.onReturn,
  });

  @override
  State<FloatingPlayerOverlay> createState() => _FloatingPlayerOverlayState();
}

class _FloatingPlayerOverlayState extends State<FloatingPlayerOverlay> {
  Offset _position = const Offset(20, 100);
  double _width = 280;
  bool _isDragging = false;
  bool _showControls = true;
  Timer? _hideTimer;
  
  double _volume = 0.5;
  double _brightness = 0.5;

  @override
  void initState() {
    super.initState();
    _startHideTimer();
    _initSettings();
  }

  void _initSettings() async {
    _volume = await VolumeController.instance.getVolume();
    try {
      _brightness = await ScreenBrightness().current;
    } catch (_) {}
    if (mounted) setState(() {});
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final aspectRatio = widget.controller.value.aspectRatio;
    final height = _width / aspectRatio;

    // Detectar si estamos cerca de la zona "X" al fondo
    final bool isNearDeleteZone = _isDragging && _position.dy > size.height - 180;

    return Stack(
      children: [
        // Zona de eliminación (X)
        if (_isDragging)
          Positioned(
            bottom: 40,
            left: 0,
            right: 0,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: isNearDeleteZone ? 80 : 60,
                height: isNearDeleteZone ? 80 : 60,
                decoration: BoxDecoration(
                  color: isNearDeleteZone ? Colors.red : Colors.black45,
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24, width: 2),
                ),
                child: const Icon(Icons.close, color: Colors.white, size: 30),
              ),
            ),
          ),

        Positioned(
          left: _position.dx,
          top: _position.dy,
          child: GestureDetector(
            onPanStart: (_) => setState(() => _isDragging = true),
            onPanUpdate: (details) {
              setState(() {
                _position += details.delta;
                _position = Offset(
                  _position.dx.clamp(0.0, size.width - _width),
                  _position.dy.clamp(0.0, size.height - height),
                );
              });
            },
            onPanEnd: (_) {
              setState(() => _isDragging = false);
              if (isNearDeleteZone) {
                widget.onClose();
              }
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              width: _width,
              height: height,
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.5),
                    blurRadius: 20,
                    spreadRadius: 5,
                  ),
                ],
                border: Border.all(
                  color: isNearDeleteZone 
                      ? Colors.red 
                      : const Color(0xFF00A3FF).withOpacity(0.6),
                  width: 2.0,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Stack(
                  children: [
                    // Video
                    Center(
                      child: AspectRatio(
                        aspectRatio: aspectRatio,
                        child: VideoPlayer(widget.controller),
                      ),
                    ),

                    // Gestures Layer (Transparent)
                    GestureDetector(
                      onTap: () {
                        setState(() => _showControls = !_showControls);
                        if (_showControls) _startHideTimer();
                      },
                      onVerticalDragUpdate: (details) {
                        final isLeft = details.localPosition.dx < _width / 2;
                        final delta = details.primaryDelta! / -100;
                        if (isLeft) {
                          _volume = (_volume + delta).clamp(0.0, 2.0);
                          widget.controller.setVolume(_volume);
                          if (_volume <= 1.0) VolumeController.instance.setVolume(_volume);
                        } else {
                          _brightness = (_brightness + delta).clamp(0.0, 1.0);
                          ScreenBrightness().setScreenBrightness(_brightness);
                        }
                        setState(() {});
                      },
                      child: Container(color: Colors.transparent),
                    ),

                    // Controls Overlay
                    if (_showControls)
                      Container(
                        color: Colors.black.withOpacity(0.5),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            // Header
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              child: Row(
                                children: [
                                  GestureDetector(
                                    onTap: widget.onReturn,
                                    child: Container(
                                      padding: const EdgeInsets.all(4),
                                      decoration: BoxDecoration(
                                        color: Colors.white10,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: const Icon(Icons.fullscreen, color: Colors.white, size: 18),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      widget.title,
                                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: widget.onClose,
                                    child: const Icon(Icons.close, color: Colors.white70, size: 20),
                                  ),
                                ],
                              ),
                            ),

                            // Center Controls
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.replay_10, color: Colors.white, size: 24),
                                  onPressed: () => widget.controller.seekTo(
                                    widget.controller.value.position - const Duration(seconds: 10),
                                  ),
                                ),
                                IconButton(
                                  padding: EdgeInsets.zero,
                                  icon: Icon(
                                    widget.controller.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                                    color: const Color(0xFF00A3FF),
                                    size: 42,
                                  ),
                                  onPressed: () {
                                    setState(() {
                                      widget.controller.value.isPlaying
                                          ? widget.controller.pause()
                                          : widget.controller.play();
                                    });
                                  },
                                ),
                                IconButton(
                                  icon: const Icon(Icons.forward_10, color: Colors.white, size: 24),
                                  onPressed: () => widget.controller.seekTo(
                                    widget.controller.value.position + const Duration(seconds: 10),
                                  ),
                                ),
                              ],
                            ),

                            // Footer (Empty space for padding)
                            const SizedBox(height: 10),
                          ],
                        ),
                      ),
                    
                    // Indicators
                    if (_volume > 1.0 && _showControls)
                      Positioned(
                        top: 40,
                        left: 10,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'BOOST ${(_volume * 100).toInt()}%',
                            style: const TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),

                    // Resize handle
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: GestureDetector(
                        onPanUpdate: (details) {
                          setState(() {
                            _width += details.delta.dx;
                            _width = _width.clamp(180.0, size.width * 0.8);
                          });
                        },
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: const BoxDecoration(
                            color: Colors.black26,
                            borderRadius: BorderRadius.only(topLeft: Radius.circular(12)),
                          ),
                          child: const Icon(Icons.south_east, color: Colors.white54, size: 14),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
