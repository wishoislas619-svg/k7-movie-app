import 'package:flutter/material.dart';
import '../../services/cast_service.dart';
import '../widgets/cast_button.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class CastRemotePage extends StatefulWidget {
  const CastRemotePage({super.key});

  @override
  State<CastRemotePage> createState() => _CastRemotePageState();
}

class _CastRemotePageState extends State<CastRemotePage> {
  final _castService = CastService();

  @override
  void initState() {
    super.initState();
    _castService.addListener(_rebuild);
    WakelockPlus.enable(); // Evita que el dispositivo entre en modo suspensión
  }

  @override
  void dispose() {
    _castService.removeListener(_rebuild);
    WakelockPlus.disable(); // Permite ahorro de energía al salir de la remota
    super.dispose();
  }

  void _rebuild() {
    if (mounted) {
       setState(() {});
       // Si se desconecta, cerramos esta pantalla
       if (!_castService.isConnected) {
         Navigator.of(context).pop();
       }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_castService.isConnected) return const Scaffold(backgroundColor: Colors.black);

    final device = _castService.connectedDevice!;
    final position = _castService.position;
    final duration = _castService.duration;
    final progress = (duration.inSeconds > 0)
        ? position.inSeconds / duration.inSeconds
        : 0.0;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: Stack(
        children: [
          // Background Backdrop (Blurred Image)
          if (_castService.currentImageUrl != null)
            Positioned.fill(
              child: Opacity(
                opacity: 0.2,
                child: Image.network(
                  _castService.currentImageUrl!,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          
          SafeArea(
            child: Column(
              children: [
                // Top Bar with Cast Button
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const Spacer(),
                      const Text(
                        'CONTROLANDO PANTALLA',
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const Spacer(),
                      CastButton(
                        videoUrl: '', // Not used when connected
                        title: _castService.currentTitle ?? '',
                        imageUrl: _castService.currentImageUrl,
                      ),
                    ],
                  ),
                ),

                const Spacer(),

                // Cover Image
                if (_castService.currentImageUrl != null)
                  Container(
                    width: 200,
                    height: 300,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
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
                  ),

                const SizedBox(height: 30),

                // Title and Device
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Column(
                    children: [
                      Text(
                        _castService.currentTitle ?? 'Desconocido',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(device.icon, color: const Color(0xFF00FF87), size: 14),
                          const SizedBox(width: 8),
                          Text(
                            'Reproduciendo en ${device.name}',
                            style: const TextStyle(
                              color: Color(0xFF00FF87),
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const Spacer(),

                // Seek Bar
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 30),
                  child: Column(
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 4,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                          activeTrackColor: const Color(0xFF00A3FF),
                          inactiveTrackColor: Colors.white12,
                          thumbColor: Colors.white,
                        ),
                        child: Slider(
                          value: progress.clamp(0.0, 1.0),
                          onChanged: (val) {
                            final seekPos = Duration(seconds: (val * duration.inSeconds).toInt());
                            _castService.seekTo(seekPos);
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(_formatDuration(position), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                            Text(_formatDuration(duration), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                // Main Controls
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.replay_10, color: Colors.white, size: 32),
                      onPressed: () => _castService.seekTo(position - const Duration(seconds: 10)),
                    ),
                    GestureDetector(
                      onTap: () => _castService.isPlaying ? _castService.pause() : _castService.play(),
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          _castService.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                          color: Colors.black,
                          size: 50,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.forward_10, color: Colors.white, size: 32),
                      onPressed: () => _castService.seekTo(position + const Duration(seconds: 10)),
                    ),
                  ],
                ),

                const SizedBox(height: 40),

                // Volume slider
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 50),
                  child: Row(
                    children: [
                      const Icon(Icons.volume_down, color: Colors.white38, size: 20),
                      Expanded(
                        child: Slider(
                          value: 0.5, // Default volume as we can't reliably read current TV volume easily
                          activeColor: Colors.white24,
                          inactiveColor: Colors.white10,
                          onChanged: (val) => _castService.setVolume(val),
                        ),
                      ),
                      const Icon(Icons.volume_up, color: Colors.white38, size: 20),
                    ],
                  ),
                ),

                const SizedBox(height: 40),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    final h = d.inHours.toString().padLeft(2, '0');
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return d.inHours > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
