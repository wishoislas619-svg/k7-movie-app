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

  @override
  void initState() {
    super.initState();
    // El overlay escucha datos enviados desde la app principal
    FlutterOverlayWindow.overlayListener.listen((data) {
      if (data is Map && data['videoUrl'] != null) {
        _initPlayer(data);
      }
    });
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
        onTap: () => setState(() => _showControls = !_showControls),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF00A3FF), width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.6),
                blurRadius: 14,
                spreadRadius: 3,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Stack(
              children: [
                // ── Video ──────────────────────────────────────────────────
                if (_initialized && _controller != null)
                  Center(
                    child: AspectRatio(
                      aspectRatio: _controller!.value.aspectRatio,
                      child: VideoPlayer(_controller!),
                    ),
                  )
                else if (_error != null)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.error_outline, color: Colors.red, size: 28),
                          const SizedBox(height: 6),
                          Text(
                            _error!,
                            style: const TextStyle(color: Colors.white54, fontSize: 9),
                            textAlign: TextAlign.center,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF00A3FF),
                      strokeWidth: 2,
                    ),
                  ),

                // ── Controles ──────────────────────────────────────────────
                if (_showControls)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.black.withOpacity(0.75),
                            Colors.transparent,
                            Colors.transparent,
                            Colors.black.withOpacity(0.75),
                          ],
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Top bar
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                            child: Row(
                              children: [
                                const Icon(Icons.live_tv, color: Color(0xFF00A3FF), size: 13),
                                const SizedBox(width: 5),
                                Expanded(
                                  child: Text(
                                    _title ?? 'K7 Player',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                // Botón: volver a pantalla completa
                                GestureDetector(
                                  onTap: _returnToFullscreen,
                                  child: Container(
                                    padding: const EdgeInsets.all(5),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF00A3FF).withOpacity(0.2),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: const Color(0xFF00A3FF), width: 1),
                                    ),
                                    child: const Icon(Icons.open_in_full, color: Color(0xFF00A3FF), size: 14),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                // Botón: cerrar overlay
                                GestureDetector(
                                  onTap: () => FlutterOverlayWindow.closeOverlay(),
                                  child: const Icon(Icons.close, color: Colors.white54, size: 18),
                                ),
                              ],
                            ),
                          ),

                          // Controles centrales
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.replay_10, color: Colors.white, size: 24),
                                onPressed: () {
                                  final pos = _controller?.value.position ?? Duration.zero;
                                  _controller?.seekTo(pos - const Duration(seconds: 10));
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
                                onPressed: _togglePlayPause,
                              ),
                              IconButton(
                                icon: const Icon(Icons.forward_10, color: Colors.white, size: 24),
                                onPressed: () {
                                  final pos = _controller?.value.position ?? Duration.zero;
                                  _controller?.seekTo(pos + const Duration(seconds: 10));
                                },
                              ),
                            ],
                          ),

                          const SizedBox(height: 6),
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
}
