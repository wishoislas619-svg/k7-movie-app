import 'dart:async';
import 'dart:io';
import 'package:dart_cast/dart_cast.dart' as dc;
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'cast_device_info.dart';

/// Helper para emitir logs de cast visibles en logcat con prefijo [CAST]
void _log(String msg) => debugPrint('🎬 [CAST] $msg');
void _logErr(String msg) => debugPrint('❌ [CAST] $msg');

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
  final dc.MediaProxy _localFileProxy = dc.MediaProxy();

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
  int? _currentAlgorithm;

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
    
    if (!kIsWeb) {
      final status = await [
        Permission.location,
        Permission.nearbyWifiDevices,
      ].request();
      
      if (status[Permission.location]?.isDenied ?? false) {
        _errorMessage = 'Se requiere permiso de ubicación para buscar dispositivos';
        _state = CastConnectionState.idle;
        notifyListeners();
        return;
      }
    }

    _devices = [];
    _state = CastConnectionState.scanning;
    _errorMessage = null;
    notifyListeners();
    _log('Iniciando escaneo de dispositivos...');

    try {
      _rawService?.dispose();
      _rawService = _buildCastService();

      _discoverySubscription?.cancel();
      _discoverySubscription = _rawService!.startDiscovery().listen(
        (rawDevices) {
          _devices = rawDevices.map((d) => CastDeviceInfo.fromCastDevice(d)).toList();
          _log('Dispositivos encontrados: ${_devices.length}');
          for (final d in _devices) {
            _log('  • ${d.name} [${d.subtitle}] proto=${d.protocol}');
          }
          notifyListeners();
        },
        onError: (e) {
          _logErr('Error durante escaneo: $e');
          _errorMessage = 'Error al escanear: $e';
          _state = CastConnectionState.idle;
          notifyListeners();
        },
      );
    } catch (e) {
      _logErr('No se pudo iniciar el escaneo: $e');
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
    _log('Conectando a: ${device.name} [proto=${device.protocol}]');

    try {
      _rawService ??= _buildCastService();
      _log('Llamando _rawService.connect()...');
      _session = await _rawService!.connect(device.rawDevice);
      _log('Sesión establecida: ${_session.runtimeType}');

      _connectedDevice = device;
      _state = CastConnectionState.connected;

      // Monitorear estado de reproducción
      _stateSubscription?.cancel();
      _stateSubscription = _session!.stateStream.listen((s) {
        _log('Estado de sesión cambió → $s');
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

      _log('✅ Conectado a ${device.name}');
      notifyListeners();
    } catch (e, stack) {
      _logErr('Fallo al conectar a ${device.name}: $e');
      _logErr('Stack: $stack');
      _errorMessage = 'No se pudo conectar a ${device.name}: $e';
      _state = CastConnectionState.error;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    _log('Desconectando...');
    _stateSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
    try { 
      await _session?.stop();
      await _session?.disconnect(); 
    } catch (e) {
      _logErr('Error durante disconnect: $e');
    }
    _session = null;
    _localFileProxy.stop();
    _connectedDevice = null;
    _state = CastConnectionState.idle;
    _position = Duration.zero;
    _duration = Duration.zero;
    _isPlaying = false;
    _log('Desconectado.');
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
    int? algorithm,
  }) async {
    if (_session == null) {
      _logErr('castUrl llamado sin sesión activa');
      return;
    }

    _currentAlgorithm = algorithm;
    _currentTitle = title;
    _currentImageUrl = imageUrl;
    _currentVideoUrl = url;

    _log('══════════════════════════════════════');
    _log('castUrl() iniciado');
    _log('  title    : $title');
    _log('  url      : $url');
    _log('  algorithm: $algorithm');
    _log('  startPos : ${startPosition.inSeconds}s');
    _log('  subtitle : $subtitleUrl');

    // Construir headers con excepciones por algoritmo
    final Map<String, String> combinedHeaders = {
      // Por defecto: UA Móvil (Algoritmo 1 / Estándar)
      'User-Agent': 'Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36',
      'Accept': '*/*',
      'Accept-Language': 'es-ES,es;q=0.9',
      'Connection': 'keep-alive',
      ...?headers,
    };

    if (algorithm == 3 || url.contains('embed.su') || url.contains('videasy')) {
      combinedHeaders['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36';
      combinedHeaders['Referer'] = 'https://embed.su/';
      combinedHeaders['Origin'] = 'https://embed.su';
      combinedHeaders['Sec-Fetch-Dest'] = 'video';
      combinedHeaders['Sec-Fetch-Mode'] = 'cors';
      combinedHeaders['Sec-Fetch-Site'] = 'cross-site';
      _log('  Headers: Excepción Algoritmo 3 (Embed.su)');
    } else if (algorithm == 2) {
      combinedHeaders['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36';
      combinedHeaders['Sec-Fetch-Dest'] = 'video';
      combinedHeaders['Sec-Fetch-Mode'] = 'cors';
      combinedHeaders['Sec-Fetch-Site'] = 'cross-site';
      _log('  Headers: Excepción Algoritmo 2');
    } else {
      _log('  UA: Android móvil (Estándar)');
    }

    final isDlna = _connectedDevice?.protocol == dc.CastProtocol.dlna;
    final mediaType = _detectMediaType(url);
    _log('  isDlna   : $isDlna');
    _log('  mediaType: $mediaType');

    String finalUrl = url;
    
    // --- LÓGICA DE PROXY PARA DLNA ---
    // En DLNA, si el video es un archivo estándar (MP4/MKV), la librería no suele proxearlo.
    // Esto hace que la TV pida el enlace directo SIN los headers que necesitamos.
    // Forzamos el uso de nuestro proxy local para inyectar Referer/UA/Origin.
    if (isDlna && mediaType != dc.CastMediaType.hls) {
      _log('  DLNA: Forzando proxy local para inyectar cabeceras en video estándar');
      try {
        await _localFileProxy.stop();
        await _localFileProxy.start(targetDeviceIp: _connectedDevice?.address);
        finalUrl = _localFileProxy.registerMedia(url, headers: combinedHeaders);
        _log('  URL original proxied a: $finalUrl');
      } catch (e) {
        _logErr('  Error al registrar en proxy local: $e');
      }
    }

    if (isDlna) {
      _log('  DLNA: enviando Stop previo...');
      try { await _session!.stop(); } catch (e) { _log('  DLNA Stop ignorado: $e'); }
      // Pausa un poco más larga para TVs que tardan en liberar el socket
      await Future.delayed(const Duration(milliseconds: 600));
    }

    final media = dc.CastMedia(
      url: finalUrl,
      type: mediaType,
      title: _sanitizeTitleForDlna(title),
      imageUrl: imageUrl,
      httpHeaders: combinedHeaders,
      startPosition: startPosition,
      subtitles: (subtitleUrl != null && !isDlna)
          ? [dc.CastSubtitle(url: subtitleUrl, label: 'Subtítulos', language: 'es', format: 'vtt')]
          : [],
    );

    _log('  Llamando session.loadMedia() con URL: $finalUrl');
    try {
      await _session!.loadMedia(media);
      _log('  ✅ loadMedia completado');
    } catch (e, stack) {
      _logErr('  loadMedia falló: $e');
      _logErr('  Stack: $stack');
      rethrow;
    }
    _log('══════════════════════════════════════');
    notifyListeners();
  }

  Future<void> castLocalFile({
    required String filePath,
    required String title,
    String? imageUrl,
    Duration startPosition = Duration.zero,
  }) async {
    if (_session == null) throw StateError('No hay sesión activa');

    final cleanTitle = _sanitizeTitleForDlna(title);
    _currentTitle = cleanTitle;
    _currentImageUrl = imageUrl;
    _currentVideoUrl = filePath;

    _log('══════════════════════════════════════');
    _log('castLocalFile() iniciado');
    _log('  title original : $title');
    _log('  title DLNA     : $cleanTitle');
    _log('  path    : $filePath');
    _log('  startPos: ${startPosition.inSeconds}s');

    // Verificar que el archivo existe antes de intentar transmitirlo
    final file = File(filePath);
    final exists = await file.exists();
    _log('  exists  : $exists');
    if (exists) {
      final size = await file.length();
      _log('  size    : ${(size / 1024 / 1024).toStringAsFixed(2)} MB');
    } else {
      _logErr('  ⚠️ El archivo NO existe en: $filePath');
    }

    final ext = filePath.toLowerCase().split('.').last;
    final mediaType = switch (ext) {
      'mkv' => dc.CastMediaType.mkv,
      'ts'  => dc.CastMediaType.mpegTs,
      _     => dc.CastMediaType.mp4,
    };
    _log('  ext     : .$ext → mediaType=$mediaType');

    // Iniciar el servidor local de archivos (Proxy directo)
    // Detenemos cualquier instancia previa para liberar el puerto
    await _localFileProxy.stop();
    await _localFileProxy.start(targetDeviceIp: _connectedDevice?.address);
    
    // Registrar el archivo para obtener una URL http:// accesible para la TV
    // Esto sirve el archivo crudo vía HTTP/1.0 sin transformaciones HLS
    final proxyUrl = _localFileProxy.registerFile(filePath);
    _log('  Archivo local registrado en: $proxyUrl');

    // Transmitir usando la lógica estándar de castUrl (UA móvil, stop previo, etc.)
    return castUrl(
      url: proxyUrl,
      title: title,
      imageUrl: imageUrl,
      startPosition: startPosition,
    );
  }

  /// Limpia el título para incluirlo de forma segura en XML SOAP DLNA.
  /// Samsung TV rechaza peticiones con títulos que contienen extensiones
  /// de archivo, indicadores de formato (HLS/TS) o caracteres no ASCII
  /// sin escapar en el DIDL-Lite.
  String _sanitizeTitleForDlna(String title) {
    // 1. Quitar extensión de archivo
    final lastDot = title.lastIndexOf('.');
    if (lastDot > 0) title = title.substring(0, lastDot);

    // 2. Quitar artefactos de descarga HLS
    title = title
        .replaceAll(RegExp(r'\(Streaming \(HLS\)\)', caseSensitive: false), '')
        .replaceAll(RegExp(r'\(HLS\)', caseSensitive: false), '')
        .replaceAll(RegExp(r'Resolución\s+Auto', caseSensitive: false), '')
        .replaceAll(RegExp(r'_+'), ' ')  // guiones bajos → espacios
        .trim();

    // 3. Colapsar espacios múltiples
    title = title.replaceAll(RegExp(r'\s+'), ' ').trim();

    // 4. Escapar caracteres especiales XML
    title = title
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');

    // 5. Límite de longitud (algunos TVs ignoran títulos muy largos)
    if (title.length > 80) title = title.substring(0, 80).trim();

    return title.isEmpty ? 'Video' : title;
  }

  // ── Playback Controls ──────────────────────────────────────────────────────
  
  Future<void> play() async {
    if (_session == null) return;
    _log('play()');
    await _session!.play();
  }

  Future<void> pause() async {
    if (_session == null) return;
    _log('pause()');
    await _session!.pause();
  }

  Future<void> stop() async {
    if (_session == null) return;
    _log('stop()');
    await _session!.stop();
  }

  Future<void> seekTo(Duration position) async {
    if (_session == null) return;
    _log('seekTo(${position.inSeconds}s)');
    await _session!.seek(position);
  }

  Future<void> setVolume(double volume) => _session?.setVolume(volume) ?? Future.value();

  // ── Internal ───────────────────────────────────────────────────────────────

  dc.CastMediaType _detectMediaType(String url) {
    final u = url.toLowerCase().split('?').first;
    if (u.contains('.m3u8') || 
        u.contains('.m3u') || 
        u.contains('.txt') || 
        u.contains('/stream/') || 
        u.contains('cf-master') ||
        u.contains('/live/') ||
        u.contains('/hls/') ||
        u.contains('playlist')) {
      return dc.CastMediaType.hls;
    }
    if (u.contains('.mkv'))  return dc.CastMediaType.mkv;
    if (u.contains('.ts'))   return dc.CastMediaType.mpegTs;
    if (u.contains('.mp4'))  return dc.CastMediaType.mp4;
    if (u.contains('.mov') || u.contains('.avi') || u.contains('.flv') || u.contains('.wmv')) return dc.CastMediaType.mp4;
    
    if (RegExp(r':\d+/\w+').hasMatch(url)) {
      return dc.CastMediaType.hls; 
    }
    if (u.contains('master') || u.contains('playlist')) {
      return dc.CastMediaType.hls;
    }

    return dc.CastMediaType.mp4;
  }

  dc.CastService _buildCastService() {
    _log('Construyendo CastService con providers: DLNA, Chromecast, AirPlay');
    return dc.CastService(
      discoveryProviders: [
        dc.DlnaDiscoveryProvider(),
        dc.ChromecastDiscoveryProvider(),
        dc.AirPlayDiscoveryProvider(),
      ],
      sessionFactory: (device) {
        _log('sessionFactory llamado para: ${device.name} [proto=${device.protocol}]');
        switch (device.protocol) {
          case dc.CastProtocol.chromecast:
            _log('  → ChromecastSession');
            return dc.ChromecastSession(device: device);
          case dc.CastProtocol.airplay:
            _log('  → AirPlaySession');
            return dc.AirPlaySession(device);
          case dc.CastProtocol.dlna:
            try {
              _log('  → DlnaSession.fromDevice()');
              final session = dc.DlnaSession.fromDevice(device);
              _log('  → DlnaSession creado OK');
              return session;
            } catch (e) {
              _logErr('  DlnaSession.fromDevice() falló: $e');
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
    _localFileProxy.stop();
    _rawService?.dispose();
    super.dispose();
  }
}
