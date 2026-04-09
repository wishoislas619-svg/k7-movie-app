import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/cast_service.dart';
import '../../services/cast_device_info.dart';
import 'package:movie_app/core/services/ad_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Bottom sheet que muestra los dispositivos disponibles en la red y permite conectarse.
class CastDeviceListSheet extends StatefulWidget {
  final String videoUrl;
  final String? localFilePath;
  final String title;
  final String? imageUrl;
  final Map<String, String>? headers;
  final Duration startPosition;

  const CastDeviceListSheet({
    super.key,
    required this.videoUrl,
    this.localFilePath,
    required this.title,
    this.imageUrl,
    this.headers,
    this.startPosition = Duration.zero,
  });

  @override
  State<CastDeviceListSheet> createState() => _CastDeviceListSheetState();
}

class _CastDeviceListSheetState extends State<CastDeviceListSheet> {
  final _castService = CastService();
  Timer? _scanTimer;
  bool _casting = false;

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
    // Re-escanear cada 8 segundos para encontrar nuevos dispositivos
    _scanTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (mounted && !_castService.isConnected) _castService.startScan();
    });
  }

  Future<void> _connectAndCast(CastDeviceInfo device) async {
    // 1. Conectar al dispositivo
    setState(() => _casting = true);
    await _castService.connectTo(device);
    if (!_castService.isConnected) {
      setState(() => _casting = false);
      return;
    }

    // 2. Verificar Anuncio antes de transmitir (Solo si no es VIP)
    final user = Supabase.instance.client.auth.currentUser;
    final role = user?.userMetadata?['role']?.toString().toLowerCase() ?? 'user';
    final isAdminOrVip = role == 'admin' || role == 'uservip';

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
       if (!result) {
         if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(
             const SnackBar(content: Text('Debes ver el anuncio para transmitir.'), backgroundColor: Colors.redAccent)
           );
           setState(() => _casting = false);
         }
         return;
       }
    }

    // 3. Cargar Media
    try {
      if (widget.localFilePath != null) {
        await _castService.castLocalFile(
          filePath: widget.localFilePath!,
          title: widget.title,
          imageUrl: widget.imageUrl,
          startPosition: widget.startPosition,
        );
      } else {
        await _castService.castUrl(
          url: widget.videoUrl,
          title: widget.title,
          imageUrl: widget.imageUrl,
          headers: widget.headers,
          startPosition: widget.startPosition,
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
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
          // Handle
          _buildHandle(),
          // Header
          _buildHeader(),
          const Divider(color: Colors.white12, height: 1),
          // Content
          if (_casting)
            _buildConnecting()
          else if (_castService.isConnected)
            _buildConnectedView()
          else
            _buildDeviceList(),
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
              icon: const Icon(Icons.refresh, color: Colors.white54, size: 20),
              onPressed: _castService.startScan,
              tooltip: 'Volver a escanear',
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
            Icon(Icons.wifi_find, color: Colors.white24, size: 48),
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
          ],
        ),
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 350),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: devices.length,
        itemBuilder: (context, i) => _buildDeviceTile(devices[i]),
      ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: const [
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
    final position = _castService.position;
    final duration = _castService.duration;
    final progress = (duration.inSeconds > 0)
        ? position.inSeconds / duration.inSeconds
        : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        children: [
          // Device row
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
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.red.shade900,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: GestureDetector(
                  onTap: _disconnect,
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
          const SizedBox(height: 20),
          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              backgroundColor: Colors.white12,
              valueColor: const AlwaysStoppedAnimation(Color(0xFF00A3FF)),
              minHeight: 4,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_formatDuration(position), style: const TextStyle(color: Colors.white54, fontSize: 11)),
              Text(_formatDuration(duration), style: const TextStyle(color: Colors.white54, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 16),
          // Controls
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _RemoteButton(
                icon: Icons.replay_10,
                label: '-10s',
                onTap: () => _castService.seekTo(position - const Duration(seconds: 10)),
              ),
              _RemoteButton(
                icon: _castService.isPlaying ? Icons.pause : Icons.play_arrow,
                label: _castService.isPlaying ? 'Pausa' : 'Play',
                primary: true,
                onTap: () => _castService.isPlaying ? _castService.pause() : _castService.play(),
              ),
              _RemoteButton(
                icon: Icons.forward_10,
                label: '+10s',
                onTap: () => _castService.seekTo(position + const Duration(seconds: 10)),
              ),
            ],
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

class _RemoteButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool primary;

  const _RemoteButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: primary ? 56 : 44,
            height: primary ? 56 : 44,
            decoration: BoxDecoration(
              color: primary ? const Color(0xFF00A3FF) : Colors.white12,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: primary ? 28 : 22),
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 10)),
        ],
      ),
    );
  }
}
