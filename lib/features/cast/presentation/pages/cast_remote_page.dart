import 'dart:async';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../services/cast_service.dart';
import '../../services/cast_device_info.dart';
import '../widgets/cast_device_list_sheet.dart';

/// Pantalla de Control Remoto estilo "Web Video Caster".
/// Se muestra mientras hay una sesión de casting activa.
/// Características:
/// - Barra de progreso con seek
/// - Play / Pause / +10s / -10s
/// - Control de volumen
/// - Opción de reanudar o iniciar desde el principio
/// - Botón para cambiar de dispositivo
/// - Se cierra automáticamente cuando se desconecta
/// - Wakelock activo para no perder la transmisión
class CastRemotePage extends StatefulWidget {
  const CastRemotePage({super.key});

  @override
  State<CastRemotePage> createState() => _CastRemotePageState();
}

class _CastRemotePageState extends State<CastRemotePage> {
  final _castService = CastService();
  double _volume = 0.5; // Valor visual inicial
  bool _isSeeking = false;
  double _seekValue = 0.0;
  bool _isNavigatingAway = false; // Guard para evitar pops múltiples

  @override
  void initState() {
    super.initState();
    _castService.addListener(_onCastStateChanged);
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    _castService.removeListener(_onCastStateChanged);
    WakelockPlus.disable();
    super.dispose();
  }

  void _onCastStateChanged() {
    if (!mounted) return;

    // Si se desconecta, cerramos esta pantalla UNA SOLA VEZ
    if (!_castService.isConnected && !_isNavigatingAway) {
      _isNavigatingAway = true;
      Navigator.of(context).pop();
      return;
    }

    setState(() {});
  }

  void _openDeviceSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => CastDeviceListSheet(
        videoUrl: _castService.currentVideoUrl ?? '',
        title: _castService.currentTitle ?? '',
        imageUrl: _castService.currentImageUrl,
        // Si el usuario elige un dispositivo nuevo desde aquí, no necesitamos
        // volver a abrir el Remote (ya estamos en él)
        onCastStarted: null,
      ),
    );
  }

  Future<void> _disconnect() async {
    _isNavigatingAway = true;
    await _castService.disconnect();
    if (mounted) Navigator.of(context).pop();
  }

  void _onSeekStart(double val) {
    setState(() {
      _isSeeking = true;
      _seekValue = val;
    });
  }

  void _onSeekUpdate(double val) {
    setState(() => _seekValue = val);
  }

  void _onSeekEnd(double val) {
    final duration = _castService.duration;
    final seekPos = Duration(seconds: (val * duration.inSeconds).toInt());
    _castService.seekTo(seekPos);
    setState(() => _isSeeking = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_castService.isConnected) {
      return const Scaffold(backgroundColor: Colors.black);
    }

    final device = _castService.connectedDevice!;
    final position = _castService.position;
    final duration = _castService.duration;
    final double progress = (_isSeeking)
        ? _seekValue
        : (duration.inSeconds > 0
            ? (position.inSeconds / duration.inSeconds).clamp(0.0, 1.0)
            : 0.0);

    // Validación de imagen para evitar error "No host specified in URI file:///"
    final bool hasValidImage = _castService.currentImageUrl != null && 
                               _castService.currentImageUrl!.startsWith('http');

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: Stack(
        children: [
          // Fondo con el póster desenfocado
          if (hasValidImage)
            Positioned.fill(
              child: Image.network(
                _castService.currentImageUrl!,
                fit: BoxFit.cover,
                color: Colors.black.withOpacity(0.75),
                colorBlendMode: BlendMode.darken,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),

          SafeArea(
            child: OrientationBuilder(
              builder: (context, orientation) {
                final bool isLandscape = orientation == Orientation.landscape;
                if (!isLandscape) {
                  return Column(
                    children: [
                      _buildTopBar(device),
                      const Spacer(),
                      _buildCover(isLandscape: false),
                      const SizedBox(height: 24),
                      _buildTitleSection(device),
                      const Spacer(),
                      _buildSeekBar(progress, position, duration),
                      const SizedBox(height: 8),
                      _buildMainControls(position, isLandscape: false),
                      const SizedBox(height: 24),
                      _buildVolumeControl(),
                      const SizedBox(height: 20),
                    ],
                  );
                } else {
                  // MODO LANDSCAPE (Horizontal)
                  return Row(
                    children: [
                      // Lado Izquierdo: Póster y Título
                      Expanded(
                        flex: 4,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _buildCover(isLandscape: true),
                            const SizedBox(height: 16),
                            _buildTitleSection(device),
                          ],
                        ),
                      ),
                      // Lado Derecho: Controles con scroll por seguridad
                      Expanded(
                        flex: 6,
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _buildTopBar(device),
                              const SizedBox(height: 4),
                              _buildSeekBar(progress, position, duration),
                              const SizedBox(height: 8),
                              _buildMainControls(position, isLandscape: true),
                              const SizedBox(height: 16),
                              _buildVolumeControl(),
                            ],
                          ),
                        ),
                      ),
                    ],
                  );
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(CastDeviceInfo device) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          // Botón cerrar (solo oculta el remoto, NO detiene la transmisión)
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, color: Colors.white70, size: 28),
            tooltip: 'Minimizar (la transmisión continúa)',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const Spacer(),
          Column(
            children: [
              const Text(
                'REPRODUCIENDO EN',
                style: TextStyle(color: Colors.white38, fontSize: 9, letterSpacing: 1.5),
              ),
              Text(
                device.name,
                style: const TextStyle(
                  color: Color(0xFF00FF87),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const Spacer(),
          // Botón para cambiar dispositivo
          IconButton(
            icon: const Icon(Icons.cast, color: Colors.white70, size: 22),
            tooltip: 'Cambiar dispositivo',
            onPressed: _openDeviceSheet,
          ),
        ],
      ),
    );
  }

  Widget _buildCover({required bool isLandscape}) {
    final double w = isLandscape ? 120 : 160;
    final double h = isLandscape ? 160 : 220;
    
    // Si la URL no es válida (file:///), usamos el placeholder
    final bool hasValidImage = _castService.currentImageUrl != null && 
                               _castService.currentImageUrl!.startsWith('http');

    if (!hasValidImage) {
      return Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(Icons.movie, color: Colors.white24, size: isLandscape ? 40 : 60),
      );
    }

    return Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 20, offset: const Offset(0, 10)),
        ],
        image: DecorationImage(
          image: NetworkImage(_castService.currentImageUrl!),
          fit: BoxFit.cover,
        ),
      ),
    );
  }

  Widget _buildTitleSection(CastDeviceInfo device) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 40),
      child: Column(
        children: [
          Text(
            _castService.currentTitle ?? 'Desconocido',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
              shadows: [Shadow(color: Colors.black, blurRadius: 8)],
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(device.icon, color: const Color(0xFF00FF87), size: 12),
              const SizedBox(width: 6),
              Text(
                device.subtitle,
                style: const TextStyle(color: Color(0xFF00FF87), fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSeekBar(double progress, Duration position, Duration duration) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
              activeTrackColor: const Color(0xFF00A3FF),
              inactiveTrackColor: Colors.white12,
              thumbColor: Colors.white,
              overlayColor: Colors.white24,
            ),
            child: Slider(
              value: progress,
              onChangeStart: _onSeekStart,
              onChanged: _onSeekUpdate,
              onChangeEnd: _onSeekEnd,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
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
    );
  }

  Widget _buildMainControls(Duration position, {required bool isLandscape}) {
    final double playSize = isLandscape ? 60 : 72;
    final double playIconSize = isLandscape ? 36 : 44;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Reiniciar desde el principio
        _ControlButton(
          icon: Icons.skip_previous_rounded,
          size: 28,
          onTap: () => _castService.seekTo(Duration.zero),
          tooltip: 'Desde el principio',
        ),
        // Retroceder 10s
        _ControlButton(
          icon: Icons.replay_10_rounded,
          size: 32,
          onTap: () => _castService.seekTo(position - const Duration(seconds: 10)),
          tooltip: '-10 segundos',
        ),
        // Play / Pause (botón grande central)
        GestureDetector(
          onTap: () => _castService.isPlaying ? _castService.pause() : _castService.play(),
          child: Container(
            width: playSize,
            height: playSize,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: Color(0x4400A3FF), blurRadius: 20, spreadRadius: 2)],
            ),
            child: Icon(
              _castService.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: Colors.black,
              size: playIconSize,
            ),
          ),
        ),
        // Avanzar 10s
        _ControlButton(
          icon: Icons.forward_10_rounded,
          size: 32,
          onTap: () => _castService.seekTo(position + const Duration(seconds: 10)),
          tooltip: '+10 segundos',
        ),
        // Detener y desconectar
        _ControlButton(
          icon: Icons.stop_circle_outlined,
          size: 28,
          color: Colors.redAccent,
          onTap: _disconnect,
          tooltip: 'Detener y desconectar',
        ),
      ],
    );
  }

  Widget _buildVolumeControl() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        children: [
          const Icon(Icons.volume_mute_rounded, color: Colors.white38, size: 22),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                activeTrackColor: Colors.white60,
                inactiveTrackColor: Colors.white12,
                thumbColor: Colors.white,
              ),
              child: Slider(
                value: _volume,
                onChanged: (val) {
                  setState(() => _volume = val);
                  _castService.setVolume(val);
                },
              ),
            ),
          ),
          const Icon(Icons.volume_up_rounded, color: Colors.white38, size: 22),
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

/// Botón de control circular reutilizable
class _ControlButton extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback onTap;
  final String tooltip;
  final Color color;

  const _ControlButton({
    required this.icon,
    required this.size,
    required this.onTap,
    required this.tooltip,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: size + 16,
          height: size + 16,
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.08),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: size),
        ),
      ),
    );
  }
}
