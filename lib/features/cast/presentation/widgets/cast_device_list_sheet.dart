import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/cast_service.dart';
import '../../services/cast_device_info.dart';
import 'package:movie_app/core/services/ad_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../shared/widgets/marquee_text.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../pages/cast_remote_page.dart';

/// Bottom sheet que muestra los dispositivos disponibles en la red y permite conectarse.
class CastDeviceListSheet extends ConsumerStatefulWidget {
  final String videoUrl;
  final String? localFilePath;
  final String title;
  final String? imageUrl;
  final Map<String, String>? headers;
  final Duration startPosition;
  final int? algorithm; // Algoritmo de extracción para el proxy
  /// Callback disparado UNA SOLA VEZ cuando la transmisión comienza exitosamente.
  final VoidCallback? onCastStarted;

  const CastDeviceListSheet({
    super.key,
    required this.videoUrl,
    this.localFilePath,
    required this.title,
    this.imageUrl,
    this.headers,
    this.startPosition = Duration.zero,
    this.algorithm,
    this.onCastStarted,
  });

  @override
  ConsumerState<CastDeviceListSheet> createState() => _CastDeviceListSheetState();
}

class _CastDeviceListSheetState extends ConsumerState<CastDeviceListSheet> {
  final _castService = CastService();
  Timer? _scanTimer;
  bool _casting = false;
  bool _castStartedFired = false; // Guard para disparar el callback una sola vez

  @override
  void initState() {
    super.initState();
    _castService.addListener(_rebuild);
    _startScan();
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _castService.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _startScan() {
    _castService.startScan();
    _scanTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (mounted && !_castService.isConnected) _castService.startScan();
    });
  }

  Future<void> _connectAndCast(CastDeviceInfo device) async {
    setState(() => _casting = true);
    debugPrint('🎬 [SHEET] _connectAndCast() → ${device.name}');
    debugPrint('🎬 [SHEET]   localFilePath : ${widget.localFilePath}');
    debugPrint('🎬 [SHEET]   videoUrl      : ${widget.videoUrl}');
    debugPrint('🎬 [SHEET]   title         : ${widget.title}');
    debugPrint('🎬 [SHEET]   algorithm     : ${widget.algorithm}');
    debugPrint('🎬 [SHEET]   headers       : ${widget.headers}');
    debugPrint('🎬 [SHEET]   startPosition : ${widget.startPosition.inSeconds}s');

    // 1. Conectar al dispositivo
    await _castService.connectTo(device);
    if (!_castService.isConnected) {
      debugPrint('❌ [SHEET] connectTo() falló — isConnected=false. error=${_castService.errorMessage}');
      if (mounted) setState(() => _casting = false);
      return;
    }
    debugPrint('✅ [SHEET] Conectado a ${device.name}');

    // 2. Verificar Anuncio (Solo si no es VIP/Admin) usando estado de Riverpod
    final appUser = ref.read(authStateProvider);
    final role = appUser?.role.toLowerCase() ?? 'user';
    final isAdminOrVip = role == 'admin' || role == 'uservip';
    debugPrint('🎬 [SHEET] role=$role isAdminOrVip=$isAdminOrVip');

    if (!isAdminOrVip) {
      final ticketId = const Uuid().v4();
      final adCompleter = Completer<bool>();

      AdService.showRewardedAd(
        ticketId: ticketId,
        onAdWatched: (_) => adCompleter.complete(true),
        onAdFailed: (_) => adCompleter.complete(false),
        onAdDismissedIncomplete: () => adCompleter.complete(false),
      );

      final result = await adCompleter.future;
      debugPrint('🎬 [SHEET] Ad result: $result');
      if (!result) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Debes ver el anuncio para transmitir.'),
              backgroundColor: Colors.redAccent,
            ),
          );
          setState(() => _casting = false);
        }
        return;
      }
    }

    // Verificar que la sesión DLNA sigue activa después del anuncio
    // (el anuncio puede durar >30s y la TV desconecta por idle)
    if (!_castService.isConnected) {
      debugPrint('🎬 [SHEET] Sesión perdida durante el anuncio — reconectando...');
      await _castService.connectTo(device);
      if (!_castService.isConnected) {
        debugPrint('❌ [SHEET] Reconexión fallida: ${_castService.errorMessage}');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Se perdió la conexión con la TV. Intenta de nuevo.'),
              backgroundColor: Colors.redAccent,
            ),
          );
          setState(() => _casting = false);
        }
        return;
      }
      debugPrint('✅ [SHEET] Reconexión exitosa');
    }

    // 3. Cargar el contenido en el dispositivo
    try {
      if (widget.localFilePath != null) {
        debugPrint('🎬 [SHEET] Transmitiendo archivo local...');
        await _castService.castLocalFile(
          filePath: widget.localFilePath!,
          title: widget.title,
          imageUrl: widget.imageUrl,
          startPosition: widget.startPosition,
        );
      } else {
        debugPrint('🎬 [SHEET] Transmitiendo URL remota...');
        await _castService.castUrl(
          url: widget.videoUrl,
          title: widget.title,
          imageUrl: widget.imageUrl,
          headers: widget.headers,
          startPosition: widget.startPosition,
          algorithm: widget.algorithm,
        );
      }

      debugPrint('✅ [SHEET] Transmisión iniciada correctamente');
      // 4. Cerrar el sheet y disparar el callback UNA SOLA VEZ
      if (mounted && !_castStartedFired) {
        _castStartedFired = true;
        Navigator.pop(context);
        widget.onCastStarted?.call();
      }
    } catch (e, stack) {
      debugPrint('❌ [SHEET] Error al transmitir: $e');
      debugPrint('❌ [SHEET] Stack: $stack');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al transmitir: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }

    if (mounted) setState(() => _casting = false);
  }

  Future<void> _disconnect() async {
    await _castService.disconnect();
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0D0D0D),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHandle(),
          _buildHeader(),
          const Divider(color: Colors.white12, height: 1),
          Flexible(
            child: _casting
                ? _buildConnecting()
                : _castService.isConnected
                    ? _buildConnectedView()
                    : _buildDeviceList(),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildHandle() {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.white24,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          const Icon(Icons.cast, color: Color(0xFF00A3FF), size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Transmitir a pantalla',
                  style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                if (_castService.isScanning)
                  const Text(
                    'Buscando dispositivos en tu red WiFi...',
                    style: TextStyle(color: Colors.white54, fontSize: 11),
                  )
                else
                  Text(
                    '${_castService.devices.length} dispositivo(s) encontrado(s)',
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
              ],
            ),
          ),
          if (_castService.isScanning)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(Color(0xFF00A3FF)),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh_rounded, color: Color(0xFF00FF87), size: 24),
              onPressed: () {
                _castService.stopScan();
                _castService.startScan();
              },
              tooltip: 'Reiniciar búsqueda',
            ),
        ],
      ),
    );
  }

  Widget _buildDeviceList() {
    final devices = _castService.devices;
    if (devices.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 24),
        child: Column(
          children: [
            const Icon(Icons.wifi_find, color: Colors.white24, size: 48),
            const SizedBox(height: 12),
            const Text(
              'No se encontraron dispositivos',
              style: TextStyle(color: Colors.white54, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            const Text(
              'Asegúrate de estar en la misma red WiFi que tu TV o Chromecast.',
              style: TextStyle(color: Colors.white38, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            TextButton.icon(
              onPressed: () {
                _castService.stopScan();
                _castService.startScan();
              },
              icon: const Icon(Icons.refresh_rounded, color: Color(0xFF00A3FF)),
              label: const Text('Intentar de nuevo', style: TextStyle(color: Color(0xFF00A3FF))),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      itemCount: devices.length,
      itemBuilder: (context, i) => _buildDeviceTile(devices[i]),
    );
  }

  Widget _buildDeviceTile(CastDeviceInfo device) {
    return InkWell(
      onTap: () => _connectAndCast(device),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: device.accentColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: device.accentColor.withOpacity(0.3)),
              ),
              child: Icon(device.icon, color: device.accentColor, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    device.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    device.subtitle,
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white24, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildConnecting() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation(Color(0xFF00A3FF)),
          ),
          SizedBox(height: 16),
          Text(
            'Conectando y enviando video...',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectedView() {
    final device = _castService.connectedDevice!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: device.accentColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(device.icon, color: device.accentColor, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                    const Text(
                      'Transmitiendo ahora',
                      style: TextStyle(color: Color(0xFF00FF87), fontSize: 11),
                    ),
                  ],
                ),
              ),
              GestureDetector(
                onTap: _disconnect,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.red.shade900,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.close, color: Colors.white, size: 14),
                      SizedBox(width: 4),
                      Text('Desconectar', style: TextStyle(color: Colors.white, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Botón para ir al control remoto
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                Navigator.pop(context);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => CastRemotePage()),
                    );
                  }
                });
              },
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Abrir Control Remoto'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00A3FF),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
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
