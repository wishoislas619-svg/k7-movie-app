import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:android_intent_plus/android_intent.dart';
import 'package:android_intent_plus/flag.dart';
import 'cast_device_list_sheet.dart';
import '../../services/cast_service.dart';
import '../pages/cast_remote_page.dart';
import '../../../../core/services/foreground_service.dart';
import '../../../../shared/widgets/video_extractor_dialog.dart';
import '../../services/media_proxy_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../../core/services/ad_service.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';

/// Botón de Cast que aparece en la barra de controles del reproductor.
/// Muestra el estado de conexión y abre el selector de dispositivos o el control remoto.
class CastButton extends ConsumerStatefulWidget {
  final String videoUrl;
  final String? localFilePath;
  final String title;
  final String? imageUrl;
  final Map<String, String>? headers;
  final int algorithm;
  final Duration currentPosition;
  final Duration? duration;
  final bool showImmediately;

  const CastButton({
    super.key,
    required this.videoUrl,
    this.localFilePath,
    required this.title,
    this.imageUrl,
    this.currentPosition = Duration.zero,
    this.duration,
    this.headers,
    this.algorithm = 1,
    this.showImmediately = false,
  });

  @override
  ConsumerState<CastButton> createState() => _CastButtonState();
}

class _CastButtonState extends ConsumerState<CastButton> with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  final _castService = CastService();

  @override
  void initState() {
    super.initState();
    _castService.addListener(_onCastStateChanged);

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    if (widget.showImmediately) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openCastSelection();
      });
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _castService.removeListener(_onCastStateChanged);
    super.dispose();
  }

  void _onCastStateChanged() {
    if (mounted) setState(() {});
  }

  void _openCastSelection() {
    if (widget.videoUrl.isEmpty && widget.localFilePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Espera a que el video comience a reproducirse para transmitir.')),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      isScrollControlled: true, // Permite que el sheet crezca si es necesario
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 20),
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.8, // Límite de seguridad
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(height: 24),
              const Text(
                '¿Cómo quieres transmitir?',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Elige tu reproductor favorito para proyectar',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
              const SizedBox(height: 28),
              _buildSelectionOption(
                icon: _castService.isConnected ? Icons.settings_remote : Icons.cast,
                title: _castService.isConnected ? 'Control Remoto (K7-MOVIE)' : 'Cast Interno (K7-MOVIE)',
                subtitle: _castService.isConnected ? 'Controlar reproducción en la TV' : 'Protocolos DLNA, Chromecast y AirPlay',
                color: const Color(0xFF00A3FF),
                onTap: () {
                  Navigator.pop(context);
                  if (_castService.isConnected) {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const CastRemotePage()),
                    );
                  } else {
                    _checkAdAndProceed(() => _openCastSheet());
                  }
                },
              ),
              const SizedBox(height: 16),
              _buildSelectionOption(
                icon: Icons.launch_rounded,
                title: 'Web Video Caster',
                subtitle: 'App externa altamente eficiente',
                color: const Color(0xFF00FF87),
                onTap: () {
                  Navigator.pop(context);
                  _checkAdAndProceed(() => _launchWebVideoCaster());
                },
              ),
              SizedBox(height: 16 + MediaQuery.of(context).padding.bottom),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSelectionOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: color.withOpacity(0.15), shape: BoxShape.circle),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white24),
          ],
        ),
      ),
    );
  }

  Future<String?> _extractIfNeeded(String url) async {
    // Si la URL ya es un video directo (m3u8, mp4, etc) o ya está proxeada, no extraemos
    final lower = url.toLowerCase();
    final isDirectVideo = lower.contains('.m3u8') || 
                         lower.contains('.mp4') || 
                         lower.contains('.mpd') || 
                         lower.contains('.mkv') ||
                         url.startsWith('http://127.0.0.1');

    if (isDirectVideo || widget.algorithm <= 0) {
      // Si ya es video pero queremos proxearlo para limpiar anuncios
      if (!url.startsWith('http://127.0.0.1') && !url.startsWith('https://127.0.0.1')) {
         await MediaProxyService().start();
         return MediaProxyService().getProxiedUrl(url, widget.headers);
      }
      return url;
    }

    // Si llegamos aquí, necesitamos extraer
    print('--- [CAST] URL de página detectada, iniciando extractor ---');
    final VideoExtractionData? result = await showDialog<VideoExtractionData>(
      context: context,
      barrierDismissible: false,
      builder: (_) => VideoExtractorDialog(
        url: url,
        extractionAlgorithm: widget.algorithm,
      ),
    );

    if (result == null || result.videoUrl.isEmpty) return null;

    // Proxear el resultado para que WVC o el Cast interno reciban el video limpio
    final headers = <String, String>{};
    if (result.headers != null) headers.addAll(result.headers!);
    if (result.cookies != null) headers['Cookie'] = result.cookies!;
    if (result.userAgent != null) headers['User-Agent'] = result.userAgent!;
    headers['Referer'] = url;

    await MediaProxyService().start();
    return MediaProxyService().getProxiedUrl(result.videoUrl, headers, algorithm: widget.algorithm);
  }

  Future<void> _checkAdAndProceed(VoidCallback onDone) async {
    final appUser = ref.read(authStateProvider);
    final role = appUser?.role.toLowerCase() ?? 'user';
    final isAdminOrVip = role == 'admin' || role == 'uservip';

    if (isAdminOrVip) {
      onDone();
      return;
    }

    // Mostrar diálogo de carga de anuncio
    final loadingDialogContext = Completer<BuildContext>();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        if (!loadingDialogContext.isCompleted) loadingDialogContext.complete(ctx);
        return Center(
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: Color(0xFF00A3FF)),
                SizedBox(height: 16),
                Text('Cargando anuncio...', style: TextStyle(color: Colors.white, fontSize: 14)),
              ],
            ),
          ),
        );
      },
    ).then((_) {
      if (!loadingDialogContext.isCompleted) loadingDialogContext.completeError("Dialog dismissed or failed");
    });

    // Timeout de seguridad para el contexto del diálogo (2 segundos)
    Timer(const Duration(seconds: 2), () {
      if (!loadingDialogContext.isCompleted) loadingDialogContext.completeError("Dialog timeout");
    });

    final ticketId = const Uuid().v4();
    final adCompleter = Completer<bool>();

    AdService.showRewardedAd(
      ticketId: ticketId,
      onAdWatched: (_) {
        if (!adCompleter.isCompleted) adCompleter.complete(true);
      },
      onAdFailed: (err) {
        if (!adCompleter.isCompleted) adCompleter.complete(false);
      },
      onAdDismissedIncomplete: () {
        if (!adCompleter.isCompleted) adCompleter.complete(false);
      },
    );

    final result = await adCompleter.future;
    
    // Cerrar el diálogo usando su propio context para asegurar que cerramos el correcto
    try {
      final ctxToClose = await loadingDialogContext.future;
      if (Navigator.canPop(ctxToClose)) {
        Navigator.pop(ctxToClose);
      }
    } catch (e) {
      debugPrint("No se pudo cerrar el diálogo de carga (posiblemente no se mostró): $e");
    }

    if (result) {
      onDone();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Debes ver el anuncio completo para usar la función de Cast.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  Future<void> _launchWebVideoCaster() async {
    final String? finalUrl = await _extractIfNeeded(widget.videoUrl);
    if (finalUrl == null || !mounted) return;

    final String videoUrl = finalUrl;
    // El nombre de paquete correcto es .webvideo, no .browser
    const String wvcPackage = 'com.instantbits.cast.webvideo';

    try {
      // 🚀 ACTIVAR SERVICIO DE PRIMER PLANO
      // Esto evita que Android mate el proxy local cuando la app va a segundo plano
      await ForegroundService.start(
        title: 'Transmitiendo video',
        text: 'Manteniendo conexión con Web Video Caster',
      );

      // MÉTODO 1: Esquema de URL oficial de WVC (Recomendado para apps externas)
      final encodedUrl = Uri.encodeComponent(videoUrl);
      final encodedTitle = Uri.encodeComponent(widget.title);
      final Uri wvcSchemeUri = Uri.parse('wvc-x-callback://open?url=$encodedUrl&title=$encodedTitle');

      final bool launchedScheme = await launchUrl(
        wvcSchemeUri,
        mode: LaunchMode.externalApplication,
      );

      if (launchedScheme) return;

      // MÉTODO 2: Intent de Android con el paquete oficial correcto
      final intent = AndroidIntent(
        action: 'android.intent.action.VIEW',
        data: videoUrl,
        package: wvcPackage,
        arguments: {
          'title': widget.title,
          'secure_uri': true,
        },
      );
      
      await intent.launch();
    } catch (e) {
      print('--- [WVC_ERROR] Error lanzando WVC: $e ---');
      
      // Fallback: Intentar con el tipo de video si lo anterior falla
      try {
        final intentFallback = AndroidIntent(
          action: 'android.intent.action.VIEW',
          data: videoUrl,
          package: wvcPackage,
          type: videoUrl.contains('.m3u8') ? 'application/x-mpegURL' : 'video/*',
        );
        await intentFallback.launch();
      } catch (e2) {
        if (mounted) {
          _showInstallWvcDialog();
        }
      }
    }
  }

  void _showInstallWvcDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Web Video Caster no instalada', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Para usar esta opción necesitas descargar Web Video Caster desde la Play Store. ¿Deseas ir ahora?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('CANCELAR', style: TextStyle(color: Colors.white38)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              final Uri playStoreUri = Uri.parse('https://play.google.com/store/apps/details?id=com.instantbits.cast.webvideo');
              launchUrl(
                playStoreUri,
                mode: LaunchMode.externalApplication,
              );
            },
            child: const Text('DESCARGAR', style: TextStyle(color: Color(0xFF00FF87), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _openCastSheet() async {
    final String? finalUrl = await _extractIfNeeded(widget.videoUrl);
    if (finalUrl == null || !mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => CastDeviceListSheet(
        videoUrl: finalUrl,
        localFilePath: widget.localFilePath,
        title: widget.title,
        imageUrl: widget.imageUrl,
        headers: widget.headers,
        algorithm: widget.algorithm,
        startPosition: widget.currentPosition,
        duration: widget.duration,
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
            onPressed: _openCastSelection,
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
