import 'package:flutter/material.dart';
import 'cast_device_list_sheet.dart';
import '../../services/cast_service.dart';
import '../pages/cast_remote_page.dart';

/// Botón de Cast que aparece en la barra de controles del reproductor.
/// Muestra el estado de conexión y abre el selector de dispositivos o el control remoto.
class CastButton extends StatefulWidget {
  final String videoUrl;
  final String? localFilePath;
  final String title;
  final String? imageUrl;
  final Map<String, String>? headers;
  final int? algorithm;
  final Duration currentPosition;

  const CastButton({
    super.key,
    required this.videoUrl,
    this.localFilePath,
    required this.title,
    this.imageUrl,
    this.headers,
    this.algorithm,
    this.currentPosition = Duration.zero,
  });

  @override
  State<CastButton> createState() => _CastButtonState();
}

class _CastButtonState extends State<CastButton> with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  final _castService = CastService();

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
    // Solo actualizamos el estado visual, nunca navegamos desde aquí
    _castService.addListener(_onCastStateChanged);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _castService.removeListener(_onCastStateChanged);
    super.dispose();
  }

  void _onCastStateChanged() {
    // Solo actualizamos la UI del botón (color, animación, etc.)
    // La navegación al CastRemotePage se hace exclusivamente desde _openCastSheet()
    if (mounted) setState(() {});
  }

  void _openCastSheet() {
    if (_castService.isConnected) {
      // Si ya está conectado, abre directamente el control remoto
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const CastRemotePage()),
      );
      return;
    }

    // Si no está conectado, muestra la hoja de selección de dispositivos
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // Al cerrar el sheet, si ya conectó, navegamos al remoto
      builder: (_) => CastDeviceListSheet(
        videoUrl: widget.videoUrl,
        localFilePath: widget.localFilePath,
        title: widget.title,
        imageUrl: widget.imageUrl,
        headers: widget.headers,
        algorithm: widget.algorithm,
        startPosition: widget.currentPosition,
        onCastStarted: () {
          // Navegar al control remoto una sola vez, después del pop del sheet
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _castService.isConnected) {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CastRemotePage()),
              );
            }
          });
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = _castService.isConnected;
    final isScanning = _castService.isScanning;
    final isConnecting = _castService.state == CastConnectionState.connecting;

    Color iconColor;
    if (isConnected) {
      iconColor = const Color(0xFF00A3FF);
    } else if (isScanning || isConnecting) {
      iconColor = Colors.amber;
    } else {
      iconColor = Colors.white.withOpacity(0.85);
    }

    return AnimatedBuilder(
      animation: _pulseAnimation,
      builder: (context, child) {
        final scale = (isScanning || isConnecting) ? _pulseAnimation.value : 1.0;
        return Transform.scale(
          scale: scale,
          child: IconButton(
            onPressed: _openCastSheet,
            tooltip: isConnected
                ? 'Controlando: ${_castService.connectedDevice?.name}'
                : 'Transmitir a pantalla',
            icon: Stack(
              alignment: Alignment.center,
              children: [
                Icon(
                  isConnected ? Icons.cast_connected : Icons.cast,
                  color: iconColor,
                  size: 26,
                ),
                if (isConnected)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: const BoxDecoration(
                        color: Color(0xFF00FF87),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
