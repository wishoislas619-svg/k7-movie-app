import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';

/// Widget ejecutado en el motor Flutter SEPARADO del OverlayService.
/// Se muestra sobre el Home y otras apps.
class ExternalOverlayWidget extends StatefulWidget {
  const ExternalOverlayWidget({super.key});

  @override
  State<ExternalOverlayWidget> createState() => _ExternalOverlayWidgetState();
}

class _ExternalOverlayWidgetState extends State<ExternalOverlayWidget> {
  VideoPlayerController? _controller;
  String? _title;
  bool _showControls = true;
  String? _error;
  bool _initialized = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _startHideTimer();
    // El overlay escucha datos enviados desde la app principal
    FlutterOverlayWindow.overlayListener.listen((data) {
      if (data is Map && data['videoUrl'] != null) {
        _initPlayer(data);
      }
    });
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() {
      _showControls = !_showControls;
    });
    if (_showControls) _startHideTimer();
  }

  void _initPlayer(Map data) {
    final url = data['videoUrl'] as String;
    _title = data['title'] as String? ?? 'K7 Player';
    final startPos = data['position'] as int? ?? 0;

    final Map<String, String> headers = {};
    final rawHeaders = data['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) => headers[k.toString()] = v.toString());
    }

    _controller?.dispose();
    setState(() {
      _initialized = false;
      _error = null;
    });

    final bool isHls = url.contains('.m3u8') ||
        url.contains('.m3u') ||
        url.contains('cf-master') ||
        url.contains('/stream/') ||
        url.contains('playlist');

    _controller = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: headers,
      formatHint: isHls ? VideoFormat.hls : null,
    )..initialize().then((_) {
        if (!mounted) return;
        _controller?.seekTo(Duration(seconds: startPos));
        _controller?.play();
        setState(() {
          _initialized = true;
          _error = null;
        });
      }).catchError((e) {
        if (!mounted) return;
        setState(() => _error = 'Error: $e');
        debugPrint('[OVERLAY] Error cargando video: $e');
      });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  /// Envía mensaje a la app principal para volver a pantalla completa
  Future<void> _returnToFullscreen() async {
    final currentPos = _controller?.value.position.inSeconds ?? 0;
    // Pausar antes de enviar para evitar doble reproducción
    _controller?.pause();
    // Enviar acción a la app principal (recibida por overlayListener en main.dart)
    await FlutterOverlayWindow.shareData({
      'action': 'return_to_fullscreen',
      'position': currentPos,
    });
    // Cerrar el overlay (la app principal tomará el control)
    await FlutterOverlayWindow.closeOverlay();
  }

  void _togglePlayPause() {
    if (_controller == null) return;
    setState(() {
      _controller!.value.isPlaying ? _controller!.pause() : _controller!.play();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: _toggleControls,
        behavior: HitTestBehavior.opaque,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF00A3FF).withOpacity(0.5), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.6),
                blurRadius: 15,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              children: [
                // ── Video y Controles (Comparten AspectRatio para estabilidad) ──────
                Center(
                  child: AspectRatio(
                    aspectRatio: _controller?.value.aspectRatio ?? 16 / 9,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_initialized && _controller != null)
                          VideoPlayer(_controller!)
                        else if (_error != null)
                          _buildErrorState()
                        else
                          _buildLoadingState(),

                        // ── Controles Overlay ──────────────────────────────────────
                        AnimatedOpacity(
                          opacity: _showControls ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 250),
                          child: IgnorePointer(
                            ignoring: !_showControls,
                            child: Container(
                              color: Colors.black45,
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  // Header (Título y Cerrar)
                                  Align(
                                    alignment: Alignment.topCenter,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                      decoration: const BoxDecoration(
                                        gradient: LinearGradient(
                                          begin: Alignment.topCenter,
                                          end: Alignment.bottomCenter,
                                          colors: [Colors.black87, Colors.transparent],
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              _title ?? 'K7 Player',
                                              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.settings, color: Colors.white, size: 16),
                                            onPressed: () => _startHideTimer(),
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(),
                                          ),
                                          const SizedBox(width: 10),
                                          GestureDetector(
                                            onTap: () => FlutterOverlayWindow.closeOverlay(),
                                            child: const Icon(Icons.close, color: Colors.white, size: 18),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),

                                  // Controles Centrales
                                  Align(
                                    alignment: Alignment.center,
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.replay_10, color: Colors.white, size: 24),
                                          onPressed: () {
                                            final pos = _controller?.value.position ?? Duration.zero;
                                            _controller?.seekTo(pos - const Duration(seconds: 10));
                                            _startHideTimer();
                                          },
                                        ),
                                        IconButton(
                                          icon: Icon(
                                            _controller?.value.isPlaying == true
                                                ? Icons.pause_circle_filled
                                                : Icons.play_circle_filled,
                                            color: const Color(0xFF00A3FF),
                                            size: 42,
                                          ),
                                          onPressed: () {
                                            _togglePlayPause();
                                            _startHideTimer();
                                          },
                                        ),
                                        IconButton(
                                          icon: const Icon(Icons.forward_10, color: Colors.white, size: 24),
                                          onPressed: () {
                                            final pos = _controller?.value.position ?? Duration.zero;
                                            _controller?.seekTo(pos + const Duration(seconds: 10));
                                            _startHideTimer();
                                          },
                                        ),
                                      ],
                                    ),
                                  ),

                                  // Botón Ampliar (Esquina inferior izquierda - SOLICITADO)
                                  Align(
                                    alignment: Alignment.bottomLeft,
                                    child: Padding(
                                      padding: const EdgeInsets.all(8.0),
                                      child: IconButton(
                                        icon: const Icon(Icons.open_in_full, color: Colors.white, size: 18),
                                        onPressed: _returnToFullscreen,
                                        padding: const EdgeInsets.all(6),
                                        style: IconButton.styleFrom(
                                          backgroundColor: Colors.black45,
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                        ),
                                      ),
                                    ),
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
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoadingState() {
    return const Center(child: CircularProgressIndicator(color: Color(0xFF00A3FF), strokeWidth: 2));
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 28),
          const SizedBox(height: 4),
          Text(_error ?? 'Error', style: const TextStyle(color: Colors.white54, fontSize: 8)),
        ],
      ),
    );
  }
}
