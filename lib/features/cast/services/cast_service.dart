import 'dart:async';
import 'package:dart_cast/dart_cast.dart' as dc;
import 'package:flutter/foundation.dart';
import 'cast_device_info.dart';

/// Estados posibles de la sesión de transmisión
enum CastConnectionState {
  idle,
  scanning,
  connecting,
  connected,
  error,
}

/// Singleton que gestiona discovery, conexión y sesión de casting.
class CastService extends ChangeNotifier {
  static final CastService _instance = CastService._internal();
  factory CastService() => _instance;
  CastService._internal();

  dc.CastService? _rawService;
  dc.CastSession? _session;
  StreamSubscription? _discoverySubscription;
  StreamSubscription? _stateSubscription;
  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;

  List<CastDeviceInfo> _devices = [];
  CastConnectionState _state = CastConnectionState.idle;
  CastDeviceInfo? _connectedDevice;
  String? _errorMessage;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;
  String? _currentTitle;
  String? _currentImageUrl;
  String? _currentVideoUrl;

  // ── Public Getters ─────────────────────────────────────────────────────────
  List<CastDeviceInfo> get devices => _devices;
  CastConnectionState get state => _state;
  CastDeviceInfo? get connectedDevice => _connectedDevice;
  String? get errorMessage => _errorMessage;
  bool get isConnected => _state == CastConnectionState.connected;
  bool get isScanning => _state == CastConnectionState.scanning;
  Duration get position => _position;
  Duration get duration => _duration;
  bool get isPlaying => _isPlaying;
  String? get currentTitle => _currentTitle;
  String? get currentImageUrl => _currentImageUrl;
  String? get currentVideoUrl => _currentVideoUrl;

  // ── Discovery ──────────────────────────────────────────────────────────────

  Future<void> startScan() async {
    if (_state == CastConnectionState.scanning) return;
    _devices = [];
    _state = CastConnectionState.scanning;
    _errorMessage = null;
    notifyListeners();

    try {
      _rawService?.dispose();
      _rawService = _buildCastService();

      _discoverySubscription?.cancel();
      _discoverySubscription = _rawService!.startDiscovery().listen(
        (rawDevices) {
          _devices = rawDevices.map((d) => CastDeviceInfo.fromCastDevice(d)).toList();
          notifyListeners();
        },
        onError: (e) {
          _errorMessage = 'Error al escanear: $e';
          _state = CastConnectionState.idle;
          notifyListeners();
        },
      );
    } catch (e) {
      _errorMessage = 'No se pudo iniciar el escaneo: $e';
      _state = CastConnectionState.idle;
      notifyListeners();
    }
  }

  void stopScan() {
    _discoverySubscription?.cancel();
    _discoverySubscription = null;
    if (_state == CastConnectionState.scanning) {
      _state = CastConnectionState.idle;
      notifyListeners();
    }
  }

  // ── Connection ─────────────────────────────────────────────────────────────

  Future<void> connectTo(CastDeviceInfo device) async {
    stopScan();
    _state = CastConnectionState.connecting;
    _errorMessage = null;
    notifyListeners();

    try {
      _rawService ??= _buildCastService();
      _session = await _rawService!.connect(device.rawDevice);

      _connectedDevice = device;
      _state = CastConnectionState.connected;

      // Monitorear estado de reproducción
      _stateSubscription?.cancel();
      _stateSubscription = _session!.stateStream.listen((s) {
        _isPlaying = s == dc.SessionState.playing;
        notifyListeners();
      });
      _positionSubscription?.cancel();
      _positionSubscription = _session!.positionStream.listen((pos) {
        _position = pos;
        notifyListeners();
      });
      _durationSubscription?.cancel();
      _durationSubscription = _session!.durationStream.listen((dur) {
        _duration = dur;
        notifyListeners();
      });

      notifyListeners();
    } catch (e) {
      _errorMessage = 'No se pudo conectar a ${device.name}: $e';
      _state = CastConnectionState.error;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    _stateSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    try { await _session?.disconnect(); } catch (_) {}
    _session = null;
    _connectedDevice = null;
    _state = CastConnectionState.idle;
    _position = Duration.zero;
    _duration = Duration.zero;
    _isPlaying = false;
    notifyListeners();
  }

  // ── Cast Media ─────────────────────────────────────────────────────────────

  /// Transmite un enlace remoto con headers opcionales
  Future<void> castUrl({
    required String url,
    required String title,
    String? imageUrl,
    Map<String, String>? headers,
    Duration startPosition = Duration.zero,
    String? subtitleUrl,
  }) async {
    if (_session == null) return;
    
    _currentTitle = title;
    _currentImageUrl = imageUrl;
    _currentVideoUrl = url;

    // Protocolo de compatibilidad Samsung/SmartTV
    final isDlna = _connectedDevice?.protocol == dc.CastProtocol.dlna;
    
    if (isDlna) {
      // 1. Limpiar cualquier transporte anterior que tenga atascada la TV
      try { await _session!.stop(); } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 300));
    }

    final media = dc.CastMedia(
      url: url,
      type: _detectMediaType(url),
      title: title,
      imageUrl: imageUrl,
      httpHeaders: {
        'User-Agent': 'Samsung-SmartTV/7.0 (SM-G950F)', // Hack: Fingimos ser otra TV o un cliente amigable
        if (headers != null) ...headers,
      },
      startPosition: startPosition,
      subtitles: subtitleUrl != null
          ? [dc.CastSubtitle(url: subtitleUrl, label: 'Subtítulos', language: 'es', format: 'vtt')]
          : [],
    );
    
    await _session!.loadMedia(media);

    if (isDlna) {
      // 2. Ráfaga de Play (Command Burst)
      // Samsung y LG a veces ignoran el primer Play si el buffer no ha empezado.
      // Enviamos uno tras 1 seg y otro tras 2 seg para asegurar activación de controles.
      await Future.delayed(const Duration(milliseconds: 1500));
      await _session!.play();
      await Future.delayed(const Duration(milliseconds: 1000));
      await _session!.play();
    }
    
    notifyListeners();
  }

  /// Transmite un archivo local descargado
  Future<void> castLocalFile({
    required String filePath,
    required String title,
    String? imageUrl,
    Duration startPosition = Duration.zero,
  }) async {
    if (_session == null) throw StateError('No hay sesión activa');
    
    _currentTitle = title;
    _currentImageUrl = imageUrl;
    _currentVideoUrl = filePath;

    final isDlna = _connectedDevice?.protocol == dc.CastProtocol.dlna;
    if (isDlna) {
      try { await _session!.stop(); } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 300));
    }

    final ext = filePath.toLowerCase().split('.').last;
    final mediaType = switch (ext) {
      'mkv' => dc.CastMediaType.mkv,
      'ts'  => dc.CastMediaType.mpegTs,
      _     => dc.CastMediaType.mp4,
    };

    final media = dc.CastMedia.file(
      filePath: filePath,
      type: mediaType,
      title: title,
      imageUrl: imageUrl,
      startPosition: startPosition,
    );
    
    await _session!.loadMedia(media);

    if (isDlna) {
      await Future.delayed(const Duration(milliseconds: 1500));
      await _session!.play();
    }

    notifyListeners();
  }

  // ── Playback Controls ──────────────────────────────────────────────────────
  Future<void> play()   => _session?.play()  ?? Future.value();
  Future<void> pause()  => _session?.pause() ?? Future.value();
  Future<void> stop()   => _session?.stop()  ?? Future.value();
  Future<void> seekTo(Duration position) => _session?.seek(position) ?? Future.value();
  Future<void> setVolume(double volume) => _session?.setVolume(volume) ?? Future.value();

  // ── Internal ───────────────────────────────────────────────────────────────

  dc.CastMediaType _detectMediaType(String url) {
    final u = url.toLowerCase().split('?').first;
    if (u.contains('.m3u8') || u.contains('.m3u')) return dc.CastMediaType.hls;
    if (u.contains('.mkv'))  return dc.CastMediaType.mkv;
    if (u.contains('.ts'))   return dc.CastMediaType.mpegTs;
    return dc.CastMediaType.mp4;
  }

  dc.CastService _buildCastService() {
    return dc.CastService(
      discoveryProviders: [
        dc.DlnaDiscoveryProvider(),
        dc.ChromecastDiscoveryProvider(),
        dc.AirPlayDiscoveryProvider(),
      ],
      sessionFactory: (device) {
        switch (device.protocol) {
          case dc.CastProtocol.chromecast:
            return dc.ChromecastSession(device: device);
          case dc.CastProtocol.airplay:
            return dc.AirPlaySession(device);
          case dc.CastProtocol.dlna:
            try {
              return dc.DlnaSession.fromDevice(device);
            } catch (e) {
              // Si falla fromDevice, creamos uno mock para que la factory no se rompa (no debería pasar si viene del scanner)
              // Pero preferimos lanzar excepción para que lo ataje el try/catch de connectTo()
              throw Exception('El dispositivo DLNA no tiene metadatos AVTransportControlUrl: $e');
            }
        }
      },
    );
  }

  @override
  void dispose() {
    _discoverySubscription?.cancel();
    _stateSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    try { _session?.disconnect(); } catch (_) {}
    _rawService?.dispose();
    super.dispose();
  }
}
