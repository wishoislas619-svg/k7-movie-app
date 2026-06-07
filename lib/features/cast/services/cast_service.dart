import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:movie_app/core/constants/app_constants.dart';
import 'package:movie_app/features/series/domain/entities/episode.dart';
import 'package:movie_app/features/series/domain/entities/season.dart';
import 'package:movie_app/features/movies/domain/entities/movie.dart';
import 'package:dart_cast/dart_cast.dart' as dc;
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'cast_device_info.dart';
import 'media_proxy_service.dart';
import 'a3_proxy_service.dart';
import 'roku_ecp_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Helper para emitir logs de cast visibles en logcat con prefijo [CAST]
void _log(String msg) => debugPrint('🎬 [CAST] $msg');
void _logErr(String msg) => debugPrint('❌ [CAST] $msg');

/// Estados posibles de la sesión de transmisión
enum CastConnectionState { idle, scanning, connecting, connected, error }

/// Singleton que gestiona discovery, conexión y sesión de casting.
class CastService extends ChangeNotifier {
  static final CastService _instance = CastService._internal();
  factory CastService() => _instance;
  CastService._internal();

  dc.CastService? _rawService;
  dc.CastSession? _session;
  StreamSubscription? _discoverySubscription;
  StreamSubscription? _rokuDiscoverySubscription;
  StreamSubscription? _stateSubscription;
  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;
  Timer? _dlnaPollTimer;
  Timer? _rokuPollTimer;
  final RokuEcpService _rokuEcp = RokuEcpService();
  String? _rokuEcpBaseUrl;
  String? _dlnaControlUrl;
  String? _dlnaEventUrl;
  String? _dlnaRenderingControlUrl;
  int? _currentAlgorithm;
  Map<String, String>? _currentHeaders;
  String? _currentSubtitleUrl;

  // Fields for recast (server-side seeking)
  String? _recastUrl;
  Map<String, String>? _recastHeaders;
  int? _recastAlgorithm;
  dc.CastMediaType _recastMediaType = dc.CastMediaType.mp4;
  final dc.MediaProxy _localFileProxy = dc.MediaProxy();

  List<CastDeviceInfo> _devices = [];
  CastConnectionState _state = CastConnectionState.idle;
  CastDeviceInfo? _connectedDevice;
  String? _errorMessage;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;

  // Recast offset: when server-side seeking via stop+recast, the TV restarts
  // from position 0 of the truncated manifest. This offset is added to the
  // TV's reported position so the seek bar reflects the true content position.
  Duration _recastOffset = Duration.zero;
  bool _recastSeekActive = false;
  bool useFfmpegStreaming = false; // true = remux HLS→MKV vía FFmpeg (auto para DLNA)
  String? _currentTitle;
  String? _currentImageUrl;
  String? _currentVideoUrl;
  String? _currentMediaId;
  String? _currentEpisodeId;
  String? _currentMediaType;
  String? _currentSubtitleLabel;
  String? _currentVideoOptionId;

  // Whether the remote control page is currently visible.
  bool _isRemotePageOpen = false;

  // ── Episode Navigation ────────────────────────────────────────────────────
  List<VideoOption>? _videoOptions;
  Episode? _nextEpisode;
  Season? _nextSeason;
  Episode? _previousEpisode;
  Season? _previousSeason;
  List<Season> _seriesSeasons = [];
  List<Episode> _currentSeasonEpisodes = [];
  int _currentEpisodeIndex = -1;

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
  String? get currentMediaId => _currentMediaId;
  String? get currentEpisodeId => _currentEpisodeId;
  String? get currentMediaType => _currentMediaType;
  String? get currentSubtitleLabel => _currentSubtitleLabel;
  String? get currentVideoOptionId => _currentVideoOptionId;

  bool get isRemotePageOpen => _isRemotePageOpen;
  set isRemotePageOpen(bool value) {
    _isRemotePageOpen = value;
    notifyListeners();
  }

  List<VideoOption>? get videoOptions => _videoOptions;
  Episode? get nextEpisode => _nextEpisode;
  Season? get nextSeason => _nextSeason;
  Episode? get previousEpisode => _previousEpisode;
  Season? get previousSeason => _previousSeason;
  List<Season> get seriesSeasons => _seriesSeasons;
  List<Episode> get currentSeasonEpisodes => _currentSeasonEpisodes;
  int get currentEpisodeIndex => _currentEpisodeIndex;
  bool get hasNextEpisode => _nextEpisode != null;
  bool get hasPreviousEpisode => _previousEpisode != null;

  // ── Discovery ──────────────────────────────────────────────────────────────

  Future<void> startScan() async {
    if (_state == CastConnectionState.scanning) return;

    if (!kIsWeb) {
      final status = await [
        Permission.location,
        Permission.nearbyWifiDevices,
      ].request();

      if (status[Permission.location]?.isDenied ?? false) {
        _errorMessage =
            'Se requiere permiso de ubicación para buscar dispositivos';
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
          _mergeDiscoveredDevices(
            rawDevices.map((d) => CastDeviceInfo.fromCastDevice(d)),
          );
        },
        onError: (e) {
          _logErr('Error durante escaneo: $e');
          _errorMessage = 'Error al escanear: $e';
          _state = CastConnectionState.idle;
          notifyListeners();
        },
      );

      _rokuDiscoverySubscription?.cancel();
      _rokuDiscoverySubscription = _rokuEcp.discover().listen(
        (rawDevices) {
          _mergeDiscoveredDevices(
            rawDevices.map((d) => CastDeviceInfo.fromCastDevice(d)),
          );
        },
        onError: (e) {
          _log('Roku ECP scan ignorado: $e');
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
    _rokuDiscoverySubscription?.cancel();
    _rokuDiscoverySubscription = null;
    _rokuEcp.stop();
    if (_state == CastConnectionState.scanning) {
      _state = CastConnectionState.idle;
      notifyListeners();
    }
  }

  void setHistoryContext({
    String? mediaId,
    String? episodeId,
    String? mediaType,
    String? subtitleLabel,
    String? imagePath,
    String? videoOptionId,
  }) {
    _currentMediaId = mediaId;
    _currentEpisodeId = episodeId;
    _currentMediaType = mediaType;
    _currentSubtitleLabel = subtitleLabel;
    _currentImageUrl = imagePath ?? _currentImageUrl;
    _currentVideoOptionId = videoOptionId;
  }

  void setEpisodeNavigation({
    Episode? nextEpisode,
    Season? nextSeason,
    Episode? previousEpisode,
    Season? previousSeason,
    List<Season>? seriesSeasons,
    List<Episode>? currentSeasonEpisodes,
    int currentEpisodeIndex = -1,
    List<VideoOption>? videoOptions,
  }) {
    _nextEpisode = nextEpisode;
    _nextSeason = nextSeason;
    _previousEpisode = previousEpisode;
    _previousSeason = previousSeason;
    if (seriesSeasons != null) _seriesSeasons = seriesSeasons;
    if (currentSeasonEpisodes != null) _currentSeasonEpisodes = currentSeasonEpisodes;
    _currentEpisodeIndex = currentEpisodeIndex;
    if (videoOptions != null) _videoOptions = videoOptions;
    notifyListeners();
  }

  void _mergeDiscoveredDevices(Iterable<CastDeviceInfo> incoming) {
    final byEndpoint = <String, CastDeviceInfo>{
      for (final device in _devices) device.address: device,
    };

    for (final device in incoming) {
      final existing = byEndpoint[device.address];
      final isExistingRoku = existing?.deviceType == CastDeviceType.roku;
      final isIncomingRoku = device.deviceType == CastDeviceType.roku;

      if (existing == null || isIncomingRoku || !isExistingRoku) {
        byEndpoint[device.address] = device;
      }
    }

    _devices = byEndpoint.values.toList()
      ..sort((a, b) {
        final typeCompare = a.deviceType.index.compareTo(b.deviceType.index);
        if (a.deviceType == CastDeviceType.roku) return -1;
        if (b.deviceType == CastDeviceType.roku) return 1;
        if (typeCompare != 0) return typeCompare;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    _log('Dispositivos encontrados: ${_devices.length}');
    for (final d in _devices) {
      _log('  • ${d.name} [${d.subtitle}] proto=${d.protocol}');
    }
    notifyListeners();
  }

  // ── Connection ─────────────────────────────────────────────────────────────

  Future<void> connectTo(CastDeviceInfo device) async {
    stopScan();
    _state = CastConnectionState.connecting;
    _errorMessage = null;
    notifyListeners();
    _log('Conectando a: ${device.name} [proto=${device.protocol}]');

    try {
      if (device.deviceType == CastDeviceType.roku) {
        _rokuEcpBaseUrl =
            device.rawDevice.metadata['ecpBaseUrl'] ??
            'http://${device.address}:${RokuEcpService.ecpPort}';
        final info = await _rokuEcp.getDeviceInfo(_rokuEcpBaseUrl!);
        if (info.isEmpty) {
          throw Exception(
            'No respondió Roku ECP. Revisa que "Control por apps móviles" esté habilitado en el Roku.',
          );
        }

        _session = null;
        _connectedDevice = device;
        _state = CastConnectionState.connected;
        _isPlaying = false;
        _position = Duration.zero;
        _duration = Duration.zero;
        _startRokuPolling();
        _log('✅ Conectado a Roku por ECP: $_rokuEcpBaseUrl');
        notifyListeners();
        return;
      }

      _rawService ??= _buildCastService();
      _log('Llamando _rawService.connect()...');
      _session = await _rawService!.connect(device.rawDevice);
      _log('Sesión establecida: ${_session.runtimeType}');

      _connectedDevice = device;
      _state = CastConnectionState.connected;

      // Monitorear estado de reproducción
      _stateSubscription?.cancel();
      _stateSubscription = _session!.stateStream.listen((s) {
        if (_recastSeekActive && s == dc.SessionState.idle) return;
        _log('Estado de sesión cambió → $s');
        _isPlaying = s == dc.SessionState.playing;
        notifyListeners();
      });
      _positionSubscription?.cancel();
      _positionSubscription = _session!.positionStream.listen((pos) {
        final adjustedPos = _recastSeekActive && _recastOffset > Duration.zero
            ? pos + _recastOffset
            : pos;
        if (adjustedPos != _position && adjustedPos.inMilliseconds >= 0) {
          _position = adjustedPos;
          notifyListeners();
        }
      });
      _durationSubscription?.cancel();
      _durationSubscription = _session!.durationStream.listen((dur) {
        if (_recastSeekActive) return;
        if (dur.inSeconds > 0) {
          _duration = dur;
          notifyListeners();
        }
      });

      // Si es DLNA, extraemos URLs de control
      // PRIMERO: intentar desde los metadatos que dart_cast ya tiene del SSDP discovery
      if (device.protocol == dc.CastProtocol.dlna) {
        final meta = device.rawDevice.metadata;
        final avUrl = meta['avTransportControlUrl'];
        final rvUrl = meta['renderingControlUrl'];

        if (avUrl != null && avUrl.isNotEmpty) {
          _dlnaControlUrl = avUrl;
          _dlnaRenderingControlUrl = rvUrl;
          _log('  ✅ AVTransport URL desde metadata SSDP: $_dlnaControlUrl');
        } else {
          // Fallback: intentar fetchear el XML de descripción
          _log('  Metadata SSDP vacío, intentando HTTP...');
          await _fetchDlnaControlUrls(
            'http://${device.address}:${device.rawDevice.port}/',
          );
        }
        _startDlnaPolling();
      }

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
    _stopDlnaPolling();
    _stopRokuPolling();
    if (_connectedDevice?.deviceType == CastDeviceType.roku &&
        _rokuEcpBaseUrl != null) {
      try {
        await _rokuEcp.keypress(_rokuEcpBaseUrl!, 'Home');
      } catch (_) {}
    }
    try {
      await _session?.stop();
      await _session?.disconnect();
    } catch (e) {
      _logErr('Error durante disconnect: $e');
    }
    _session = null;
    _rokuEcpBaseUrl = null;
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
    Duration? duration,
    String? subtitleUrl,
    int? algorithm,
  }) async {
    print(
      '🔥🔥🔥🔥 CASTURL ENTRADA: duration=${duration?.inSeconds}s | device=${_connectedDevice?.deviceType} | url=$url',
    );
    if (_connectedDevice?.deviceType == CastDeviceType.roku) {
      await _castUrlToRoku(
        url: url,
        title: title,
        imageUrl: imageUrl,
        headers: headers,
        startPosition: startPosition,
        duration: duration,
        algorithm: algorithm,
      );
      return;
    }

    if (_session == null) {
      _logErr('castUrl llamado sin sesión activa');
      return;
    }

    _currentAlgorithm = algorithm;
    _currentTitle = title;
    _currentImageUrl = imageUrl;
    _currentVideoUrl = url;
    _currentHeaders = headers;
    _currentSubtitleUrl = subtitleUrl;
    _position = startPosition;
    _duration = duration ?? Duration.zero;

    final durationMin = duration != null
        ? '${(duration.inSeconds / 60).toStringAsFixed(1)} min'
        : 'desconocida';
    // 🟢 Log verde de duración ANTES del proxy local
    _log('✅ [DURACIÓN] Duración establecida: $durationMin (${duration?.inSeconds ?? 0}s)');
    _log('══════════════════════════════════════');
    _log('castUrl() iniciado');
    _log('  title    : $title');
    _log('  url      : $url');
    _log('  algorithm: $algorithm');
    _log('  duration : $durationMin');
    _log('  startPos : ${startPosition.inSeconds}s');
    _log('  subtitle : $subtitleUrl');

    // --- DESENVOLVER URL SI YA ESTÁ PROXEADA ---
    // Evita el "Doble Proxy" que genera URLs gigantescas incompatibles con TVs (SOAP 500)
    String effectiveUrl = url;
    Map<String, String>? effectiveHeaders = headers;
    int? effectiveAlgorithm = algorithm;

    final unproxied = MediaProxyService.tryUnproxy(url);
    if (unproxied != null) {
      _log('  CAST: URL ya proxeada detectada, desempaquetando...');
      final proxiedAlgorithm = int.tryParse(
        Uri.tryParse(url)?.queryParameters['a'] ?? '',
      );
      if (proxiedAlgorithm != null) {
        effectiveAlgorithm = proxiedAlgorithm;
      }
      effectiveUrl = unproxied['url'];
      effectiveHeaders = Map<String, String>.from(unproxied['headers'] ?? {});
    }

    _recastUrl = effectiveUrl;
    _recastHeaders = effectiveHeaders;
    _recastAlgorithm = effectiveAlgorithm;
    _recastSeekActive = false;
    _recastOffset = Duration.zero;

    final Map<String, String> combinedHeaders = {
      // Por defecto: UA Móvil (Algoritmo 1 / Estándar)
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36',
      'Accept': '*/*',
      'Accept-Language': 'es-ES,es;q=0.9',
      'Connection': 'keep-alive',
      ...?effectiveHeaders,
    };

    if (effectiveAlgorithm == 3 ||
        effectiveUrl.contains('embed.su') ||
        effectiveUrl.contains('videasy')) {
      combinedHeaders['User-Agent'] =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36';
      combinedHeaders['Referer'] =
          effectiveHeaders?['Referer'] ?? 'https://player.videasy.net/';
      combinedHeaders['Origin'] =
          effectiveHeaders?['Origin'] ?? 'https://player.videasy.net';
      combinedHeaders['Sec-Fetch-Dest'] = 'video';
      combinedHeaders['Sec-Fetch-Mode'] = 'cors';
      combinedHeaders['Sec-Fetch-Site'] = 'cross-site';
      _log('  Headers: Aplicada configuración Algoritmo 3 (Embed.su/Videasy)');
    } else {
      _log('  UA: Android móvil (Estándar - Algoritmo 1 y 2)');
    }

    final bool isDlna = _connectedDevice?.protocol == dc.CastProtocol.dlna;
    final bool isLocalhost =
        effectiveUrl.contains('127.0.0.1') ||
        effectiveUrl.contains('localhost');
    final bool isAlreadyProxied =
        effectiveUrl.contains('/proxy') || effectiveUrl.contains('/bridge');

    String finalUrl = effectiveUrl;
    // Usamos una variable mutable para poder cambiar el tipo si usamos el Puente
    dc.CastMediaType mediaType = _detectMediaType(effectiveUrl);

    // --- LÓGICA DE PUENTE HLS-A-MP4 (SOLO PARA ALGORITMOS ESPECÍFICOS) ---
    // El Puente convierte el manifiesto HLS en un flujo MP4 continuo con audio AAC.
    // Algoritmo 3 ahora usa Proxy estándar por petición del usuario.
    bool shouldBridgeInternal = false;

    if (shouldBridgeInternal &&
        (mediaType == dc.CastMediaType.hls ||
            effectiveUrl.contains('.m3u8') ||
            effectiveUrl.contains('master') ||
            effectiveUrl.contains('playlist'))) {
      _log('🚀 CAST: Activando PUENTE HLS-a-MP4 (Modo Bridge)');
      await MediaProxyService().start();

      mediaType = dc.CastMediaType.mp4;
      finalUrl = MediaProxyService().getProxiedUrl(
        effectiveUrl,
        combinedHeaders,
        useLocalhost: false,
        toCast: true,
        algorithm: effectiveAlgorithm,
      );

      if (duration == null || duration == Duration.zero) {
        try {
          _log(
            '⏱️ CAST: Calculando duración del puente para habilitar SEEK...',
          );
          final double dSeconds = await MediaProxyService().getHlsDuration(
            effectiveUrl,
            headers: combinedHeaders,
          );
          if (dSeconds > 0) {
            duration = Duration(milliseconds: (dSeconds * 1000).toInt());
            _log('⏱️ CAST: Duración obtenida: ${duration.inSeconds}s');
          }
        } catch (e) {
          _log('⚠️ CAST: Error al calcular duración (ignorado): $e');
        }
      }
    }
    // --- LÓGICA DE PROXY DINÁMICO (ALGORITMO 1 Y 2) ---
    else if ((effectiveAlgorithm == 1 || effectiveAlgorithm == 2) &&
        (mediaType == dc.CastMediaType.hls || effectiveUrl.contains('.m3u8'))) {
      _log(
        '🚀 CAST: Usando Modo Dinámico (HLS Nativo) para Algoritmo $effectiveAlgorithm',
      );
      if (effectiveAlgorithm == 3) {
        final deviceIp = _connectedDevice?.address;
        await A3ProxyService().start(targetIp: deviceIp);
        finalUrl = A3ProxyService().getProxiedUrl(
          effectiveUrl,
          combinedHeaders,
        );
      } else if (useFfmpegStreaming && !isDlna) {
        _log('🎬 CAST: Usando FFmpeg streaming (remux HLS→fMP4)');
        await MediaProxyService().start();
        finalUrl = await MediaProxyService().getFfmpegUrl(
          effectiveUrl,
          combinedHeaders,
        );
        mediaType = dc.CastMediaType.mp4;
        // La duración se conoce al completarse FFmpeg, no intentar calcular
        // El seek progresivo funciona via range requests sobre el fichero creciente
      } else {
        await MediaProxyService().start();
        finalUrl = MediaProxyService().getProxiedUrl(
          effectiveUrl,
          combinedHeaders,
          useLocalhost: false,
          toCast: true,
          algorithm: effectiveAlgorithm,
          remux: false,
        );
      }

      if (!useFfmpegStreaming && (duration == null || duration == Duration.zero)) {
        try {
          _log(
            '⏱️ CAST: Calculando duración HLS nativa para habilitar SEEK...',
          );
          final double dSeconds = await MediaProxyService().getHlsDuration(
            effectiveUrl,
            headers: combinedHeaders,
          );
          if (dSeconds > 0) {
            duration = Duration(milliseconds: (dSeconds * 1000).toInt());
            _log('⏱️ CAST: Duración obtenida: ${duration.inSeconds}s');
          }
        } catch (e) {
          _log('⚠️ CAST: Error al calcular duración (ignorado): $e');
        }
      }
    }
    // --- LÓGICA DE PROXY UNIFICADO PARA OTROS CASOS ---
    else if (isLocalhost ||
        (effectiveAlgorithm == 4 || effectiveAlgorithm == 5)) {
      _log(
        '  CAST: Forzando Proxy de RED para compatibilidad (Alg $effectiveAlgorithm / Localhost)',
      );
      await MediaProxyService().start();
      finalUrl = MediaProxyService().getProxiedUrl(
        effectiveUrl,
        combinedHeaders,
        useLocalhost: false,
        toCast: true,
        algorithm: effectiveAlgorithm,
      );
    }
    // 4. Fallback para DLNA estándar (MP4/MKV) que requiere cabeceras
    else if (isDlna && mediaType != dc.CastMediaType.hls && !isAlreadyProxied) {
      _log('  DLNA: Proxeando video estándar para inyectar cabeceras');
      await MediaProxyService().start();
      finalUrl = MediaProxyService().getProxiedUrl(
        url,
        combinedHeaders,
        useLocalhost: false,
        toCast: true,
        algorithm: effectiveAlgorithm,
      );
    }

    if (isDlna && _dlnaControlUrl != null) {
      _log('  DLNA: enviando Stop previo via SOAP...');
      try {
        await _sendDlnaSoapAction(
          controlUrl: _dlnaControlUrl!,
          serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
          action: 'Stop',
          args: {'InstanceID': '0'},
        );
      } catch (e) {
        _log('  DLNA Stop SOAP ignorado: $e');
      }
      await Future.delayed(const Duration(milliseconds: 600));
    }

    // Samsung TVs tienen límites estrictos de longitud de URL (SOAP 500 si es > 1024).
    final Map<String, String> minimalHeaders = {};
    if (combinedHeaders.containsKey('User-Agent'))
      minimalHeaders['User-Agent'] = combinedHeaders['User-Agent']!;
    if (combinedHeaders.containsKey('Referer'))
      minimalHeaders['Referer'] = combinedHeaders['Referer']!;
    if (combinedHeaders.containsKey('Cookie'))
      minimalHeaders['Cookie'] = combinedHeaders['Cookie']!;
    if (combinedHeaders.containsKey('Origin'))
      minimalHeaders['Origin'] = combinedHeaders['Origin']!;

    // Regenerar finalUrl con cabeceras mínimas si es proxy
    if (finalUrl.contains('/proxy') || finalUrl.contains('/bridge')) {
      final unproxiedFinal = MediaProxyService.tryUnproxy(finalUrl);
      if (unproxiedFinal != null) {
        if (effectiveAlgorithm == 3) {
          final deviceIp = _connectedDevice?.address;
          await A3ProxyService().start(targetIp: deviceIp);
          finalUrl = A3ProxyService().getProxiedUrl(
            unproxiedFinal['url'],
            minimalHeaders,
          );
        } else {
          finalUrl = MediaProxyService().getProxiedUrl(
            unproxiedFinal['url'],
            minimalHeaders,
            useLocalhost: false,
            toCast: true,
            algorithm: effectiveAlgorithm,
          );
        }
      }
    }

    // Para DLNA: codificar posición inicial en la URL para server-side seeking
    // (evita dart_cast's Seek SOAP que falla con 711 en Samsung).
    final bool usePosInUrl = isDlna &&
        startPosition > Duration.zero &&
        (finalUrl.contains('/proxy') || finalUrl.contains('/bridge'));
    if (usePosInUrl) {
      finalUrl += '&pos=${startPosition.inSeconds}';
      _log('  CAST: Server-side seek inicial (pos=${startPosition.inSeconds}s)');
    }

    // Re-aplicar _duration por si los bloques de fallback HLS (Bridge / Dinámico)
    // resolvieron la duración real después de que la establecimos inicialmente.
    _duration = duration ?? Duration.zero;

    final resolvedMin = duration != null
        ? '${(duration.inSeconds / 60).toStringAsFixed(1)} min'
        : 'desconocida';
    _log('✅ [DURACIÓN] Duración final (tras proxy): $resolvedMin');
    _log('--- [CAST_READY] URL Final: $finalUrl ---');
    _log('  Llamando session.loadMedia() con URL: $finalUrl');

    try {
      final durStr = duration != null
          ? '${duration.inHours.toString().padLeft(2, '0')}:${duration.inMinutes.remainder(60).toString().padLeft(2, '0')}:${duration.inSeconds.remainder(60).toString().padLeft(2, '0')}'
          : 'desconocida';

      // Usar dart_cast.loadMedia() siempre — su DIDL-Lite ya funciona con Samsung
      // (sin error 716) y ya incluye duration si CastMedia.duration no es nulo.
      final effectiveDuration =
          _duration != null && _duration! > Duration.zero ? _duration : null;
      final effDurStr = effectiveDuration != null
          ? '${effectiveDuration.inHours.toString().padLeft(2, '0')}:${effectiveDuration.inMinutes.remainder(60).toString().padLeft(2, '0')}:${effectiveDuration.inSeconds.remainder(60).toString().padLeft(2, '0')}'
          : 'ninguna';
      final protocolLabel = isDlna ? 'DLNA' : 'Chromecast';
      print(
        '🔥🔥🔥 [ENVIANDO_AHORA] $protocolLabel → loadMedia | duration="$effDurStr" ($effectiveDuration) | URL=$finalUrl',
      );
      _recastMediaType = mediaType;
      // Para DLNA con pos en URL: startPosition=0 para que dart_cast no intente
      // su propio Seek SOAP (falla con 711). El server-side seek via &pos= lo
      // maneja el proxy.
      final media = dc.CastMedia(
        url: finalUrl,
        title: _sanitizeTitleForDlna(title),
        type: mediaType,
        imageUrl: imageUrl,
        startPosition: usePosInUrl ? Duration.zero : startPosition,
        duration: effectiveDuration,
      );
      await _session!.loadMedia(media);

      if (usePosInUrl) {
        _recastSeekActive = true;
        _recastOffset = startPosition;
        _log('  CAST: Offset activado (${_recastOffset.inSeconds}s)');
      }
      _log('  ✅ Transmisión iniciada correctamente');
    } catch (e, stack) {
      _logErr('loadMedia falló: $e');
      _logErr('Stack: $stack');
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
    Duration? duration,
  }) async {
    _recastSeekActive = false;
    _recastOffset = Duration.zero;
    final cleanTitle = _sanitizeTitleForDlna(title);
    _currentTitle = cleanTitle;
    _currentImageUrl = imageUrl;
    _currentVideoUrl = filePath;
    _position = startPosition;
    _duration = duration ?? Duration.zero;

    final durMin = duration != null
        ? '${(duration.inSeconds / 60).toStringAsFixed(1)} min'
        : 'desconocida';
    _log('✅ [DURACIÓN] LocalFile duración establecida: $durMin (${duration?.inSeconds ?? 0}s)');

    if (_connectedDevice?.deviceType == CastDeviceType.roku) {
      final file = File(filePath);
      if (!await file.exists()) {
        throw StateError('El archivo no existe: $filePath');
      }

      final String? tvIp = _connectedDevice?.address;
      await MediaProxyService().start(targetIp: tvIp);
      final fileId = filePath.hashCode.abs().toString();
      MediaProxyService().registerLocalFile(fileId, filePath);
      final proxyUrl =
          'http://${MediaProxyService().localIp}:${MediaProxyService().port}/local/$fileId.mp4';
      await _castUrlToRoku(
        url: proxyUrl,
        title: cleanTitle,
        imageUrl: imageUrl,
        headers: null,
        startPosition: startPosition,
        duration: duration,
      );
      return;
    }

    if (_session == null) throw StateError('No hay sesión activa');

    _log('══════════════════════════════════════');
    _log('castLocalFile() iniciado');
    _log('  title original : $title');
    _log('  title DLNA     : $cleanTitle');
    _log('  path    : $filePath');
    _log('  startPos: ${startPosition.inSeconds}s');

    final file = File(filePath);
    final exists = await file.exists();
    _log('  exists  : $exists');
    if (exists) {
      final size = await file.length();
      _log('  size    : ${(size / 1024 / 1024).toStringAsFixed(2)} MB');
    } else {
      _logErr('  \u26a0\ufe0f El archivo NO existe en: $filePath');
    }

    final ext = filePath.toLowerCase().split('.').last;

    // Registrar el archivo en nuestro MediaProxyService unificado.
    // IMPORTANTE: Usamos una URL opaca para que la TV no detecte "(Streaming)" en el nombre
    // y bloquee los controles de reproducción (Samsung trata HLS/Streaming como Live = sin seek/pause).
    final String? tvIp = _connectedDevice?.address;
    await MediaProxyService().start(targetIp: tvIp);

    // Generamos un ID opaco basado en el hash del path para ocultar el nombre real
    final fileId = filePath.hashCode.abs().toString();

    String pathParaServir = filePath;

    MediaProxyService().registerLocalFile(fileId, pathParaServir);

    final host = MediaProxyService().localIp;
    final port = MediaProxyService().port;
    final proxyUrl = 'http://$host:$port/local/$fileId.mp4';

    _log('  Archivo local registrado con ID: $fileId');
    _log('  URL opaca para TV: $proxyUrl');

    _log('  ext     : .$ext');

    // Forzar mediaType=mp4 para archivos locales.
    final dc.CastMediaType forcedMediaType = dc.CastMediaType.mp4;

    if (_session == null) return;

    _log('  CastMedia type forzado a: mp4 (para habilitar controles DLNA)');

    final bool isDlna = _connectedDevice?.protocol == dc.CastProtocol.dlna;

    if (isDlna && _dlnaControlUrl != null) {
      _log('  DLNA: enviando Stop previo via SOAP...');
      try {
        await _sendDlnaSoapAction(
          controlUrl: _dlnaControlUrl!,
          serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
          action: 'Stop',
          args: {'InstanceID': '0'},
        );
      } catch (e) {
        _log('  DLNA Stop SOAP ignorado: $e');
      }
      await Future.delayed(const Duration(milliseconds: 600));
    }

    // --- MINIMIZAR CABECERAS PARA CAST (Incluso en archivos locales) ---
    final Map<String, String> minimalHeaders = {
      'User-Agent':
          'Mozilla/5.0 (Linux; Android 10; SM-G981B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/80.0.3987.162 Mobile Safari/537.36',
    };

    // --- OBTENER DURACIÓN SI ES NULL ---
    Duration? effectiveDuration = duration;

    final media = dc.CastMedia(
      url: proxyUrl,
      type: forcedMediaType,
      title: cleanTitle,
      imageUrl: imageUrl,
      startPosition: startPosition,
      duration: effectiveDuration,
    );

    _log('  Llamando session.loadMedia() con URL: $proxyUrl');
    try {
      // dart_cast.loadMedia() ya construye su propio DIDL-Lite con la
      // duración de CastMedia.duration, y envía Play automáticamente.
      await _session!.loadMedia(media);
      _log('  ✅ loadMedia local completado');
    } catch (e, stack) {
      _logErr('  loadMedia falló: $e');
    }
    _log('══════════════════════════════════════');
    notifyListeners();
  }

  // ── DLNA Polling ───────────────────────────────────────────────────────────

  Future<void> _fetchDlnaControlUrls(String location) async {
    try {
      _log('Extrayendo URLs de control desde: $location');
      final response = await http
          .get(Uri.parse(location))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final body = response.body;

        // Intento 1: parsear directamente el XML recibido
        final avMatch = RegExp(
          r'<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>.*?<controlURL>(.*?)</controlURL>',
          dotAll: true,
        ).firstMatch(body);
        final renderMatch = RegExp(
          r'<serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>.*?<controlURL>(.*?)</controlURL>',
          dotAll: true,
        ).firstMatch(body);

        if (avMatch != null) {
          String url = avMatch.group(1)!.trim();
          _dlnaControlUrl = _buildAbsoluteUrl(location, url);
          _log('  ✅ AVTransport Control URL: $_dlnaControlUrl');
        }
        if (renderMatch != null) {
          String url = renderMatch.group(1)!.trim();
          _dlnaRenderingControlUrl = _buildAbsoluteUrl(location, url);
          _log('  ✅ RenderingControl URL: $_dlnaRenderingControlUrl');
        }

        // Intento 2: buscar URLs de descripción anidadas y seguirlas
        if (_dlnaControlUrl == null) {
          _log(
            '  AVTransport no encontrado directamente. Buscando sub-servicios...',
          );
          _log(
            '  XML (primeros 800 chars): ${body.substring(0, body.length.clamp(0, 800))}',
          );

          // Buscar <descURL>, <presentationURL>, o rutas conocidas de Samsung
          final descMatches = RegExp(
            r'<(?:descURL|SCPDURL|presentationURL|url)>(.*?)</(?:descURL|SCPDURL|presentationURL|url)>',
            caseSensitive: false,
          ).allMatches(body);

          for (final match in descMatches) {
            final subPath = match.group(1)?.trim() ?? '';
            if (subPath.isEmpty) continue;
            final subUrl = _buildAbsoluteUrl(location, subPath);
            if (subUrl == location) continue;

            try {
              _log('  Siguiendo sub-URL: $subUrl');
              final subResponse = await http
                  .get(Uri.parse(subUrl))
                  .timeout(const Duration(seconds: 3));
              if (subResponse.statusCode == 200) {
                final subBody = subResponse.body;
                final subAv = RegExp(
                  r'<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>.*?<controlURL>(.*?)</controlURL>',
                  dotAll: true,
                ).firstMatch(subBody);
                if (subAv != null) {
                  _dlnaControlUrl = _buildAbsoluteUrl(
                    subUrl,
                    subAv.group(1)!.trim(),
                  );
                  _log(
                    '  ✅ AVTransport encontrado en sub-URL: $_dlnaControlUrl',
                  );
                  break;
                }
              }
            } catch (_) {}
          }

          // Intento 3: probar rutas conocidas de Samsung TV directamente
          if (_dlnaControlUrl == null) {
            final uri = Uri.parse(location);
            final base = '${uri.scheme}://${uri.host}:${uri.port}';
            final knownPaths = [
              '/upnp/control/AVTransport1',
              '/upnp/control/AVTransport',
              '/AVTransport/control',
              '/MediaRenderer/AVTransport/control',
              '/upnp/control/renderer/AVTransport',
            ];
            for (final path in knownPaths) {
              try {
                final testUrl = '$base$path';
                final testBody = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body><u:GetTransportInfo xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:GetTransportInfo></s:Body>
</s:Envelope>''';
                final testResp = await http
                    .post(
                      Uri.parse(testUrl),
                      headers: {
                        'Content-Type': 'text/xml; charset="utf-8"',
                        'SOAPAction':
                            '"urn:schemas-upnp-org:service:AVTransport:1#GetTransportInfo"',
                      },
                      body: testBody,
                    )
                    .timeout(const Duration(seconds: 2));
                if (testResp.statusCode == 200) {
                  _dlnaControlUrl = testUrl;
                  _log(
                    '  ✅ AVTransport encontrado en ruta conocida: $_dlnaControlUrl',
                  );
                  break;
                }
              } catch (_) {}
            }
          }
        }

        if (_dlnaControlUrl == null) {
          _logErr(
            '  ❌ No se pudo obtener AVTransport Control URL de: $location',
          );
        }
      } else {
        _logErr('  Error HTTP ${response.statusCode} al acceder a: $location');
      }
    } catch (e) {
      _logErr('Error extrayendo URLs DLNA: $e');
    }
  }

  String _buildAbsoluteUrl(String base, String path) {
    if (path.startsWith('http')) return path;
    final uri = Uri.parse(base);
    if (path.startsWith('/')) {
      return '${uri.scheme}://${uri.host}:${uri.port}$path';
    }
    return '${uri.scheme}://${uri.host}:${uri.port}/${path}';
  }

  void _startDlnaPolling() {
    _dlnaPollTimer?.cancel();
    _dlnaPollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (_session == null ||
          _state != CastConnectionState.connected ||
          _dlnaControlUrl == null) {
        if (_state != CastConnectionState.connected) timer.cancel();
        return;
      }

      try {
        // Polling de Posición y Duración (GetPositionInfo)
        final posInfo = await _sendDlnaSoapAction(
          controlUrl: _dlnaControlUrl!,
          serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
          action: 'GetPositionInfo',
          args: {'InstanceID': '0'},
        );

        if (posInfo != null) {
          final relTime = RegExp(
            r'<RelTime>(.*?)</RelTime>',
          ).firstMatch(posInfo)?.group(1);
          final duration = RegExp(
            r'<TrackDuration>(.*?)</TrackDuration>',
          ).firstMatch(posInfo)?.group(1);

          if (relTime != null && relTime != 'NOT_IMPLEMENTED') {
            final newPos = _parseDlnaDuration(relTime);
            final adjustedPos = _recastSeekActive && _recastOffset > Duration.zero
                ? newPos + _recastOffset
                : newPos;
            if (adjustedPos != _position) {
              _position = adjustedPos;
              notifyListeners();
            }
          }
          if (!_recastSeekActive &&
              duration != null &&
              duration != 'NOT_IMPLEMENTED' &&
              duration != '0:00:00') {
            final newDur = _parseDlnaDuration(duration);
            if (newDur != _duration) {
              _duration = newDur;
              notifyListeners();
            }
          }
        }

        // Polling de Estado (GetTransportInfo)
        final transInfo = await _sendDlnaSoapAction(
          controlUrl: _dlnaControlUrl!,
          serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
          action: 'GetTransportInfo',
          args: {'InstanceID': '0'},
        );

        if (transInfo != null) {
          final state = RegExp(
            r'<CurrentTransportState>(.*?)</CurrentTransportState>',
          ).firstMatch(transInfo)?.group(1);
          if (state != null) {
            final playing = state == 'PLAYING';
            if (playing != _isPlaying) {
              _isPlaying = playing;
              notifyListeners();
            }
          }
        }
      } catch (e) {
        _logErr('Error en polling DLNA: $e');
      }
    });
  }

  Future<String?> _sendDlnaSoapAction({
    required String controlUrl,
    required String serviceType,
    required String action,
    required Map<String, String> args,
  }) async {
    final argsXml = args.entries
        .map((e) => '<${e.key}>${e.value}</${e.key}>')
        .join('');
    final envelope =
        '''
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:$action xmlns:u="$serviceType">
      $argsXml
    </u:$action>
  </s:Body>
</s:Envelope>
'''
            .trim();

    try {
      final response = await http
          .post(
            Uri.parse(controlUrl),
            headers: {
              'Content-Type': 'text/xml; charset=utf-8',
              'SOAPAction': '"$serviceType#$action"',
              'User-Agent': 'DLNADOC/1.50',
              'Connection': 'close',
            },
            body: envelope,
          )
          .timeout(
            const Duration(seconds: 10),
          ); // Samsung TV puede tardar >3s en procesar SetAVTransportURI

      if (response.statusCode == 200) return response.body;
      _logErr(
        '⚠️ SOAP [$action] → HTTP ${response.statusCode}: ${response.body.substring(0, response.body.length.clamp(0, 300))}',
      );
    } catch (e) {
      _logErr('⚠️ SOAP [$action] → Exception: $e');
    }
    return null;
  }

  Duration _parseDlnaDuration(String time) {
    try {
      final parts = time.split(':');
      if (parts.length != 3) return Duration.zero;
      return Duration(
        hours: int.parse(parts[0]),
        minutes: int.parse(parts[1]),
        seconds: int.parse(parts[2].split('.').first),
      );
    } catch (_) {
      return Duration.zero;
    }
  }

  void _stopDlnaPolling() {
    _dlnaPollTimer?.cancel();
    _dlnaPollTimer = null;
    _stateSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
  }

  void _startRokuPolling() {
    _rokuPollTimer?.cancel();
    _rokuPollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_state != CastConnectionState.connected ||
          _connectedDevice?.deviceType != CastDeviceType.roku ||
          _rokuEcpBaseUrl == null) {
        return;
      }

      final info = await _rokuEcp.queryMediaPlayer(_rokuEcpBaseUrl!);
      final state = info['state'];
      final positionMs = int.tryParse(
        (info['position'] ?? '').replaceAll(RegExp(r'[^0-9]'), ''),
      );
      final durationMs = int.tryParse(
        (info['duration'] ?? '').replaceAll(RegExp(r'[^0-9]'), ''),
      );

      var changed = false;
      if (state != null) {
        final playing = state == 'play' || state == 'playing';
        if (_isPlaying != playing) {
          _isPlaying = playing;
          changed = true;
        }
      }
      if (positionMs != null) {
        final position = Duration(milliseconds: positionMs);
        if (_position != position) {
          _position = position;
          changed = true;
        }
      }
      if (durationMs != null && durationMs > 0) {
        final duration = Duration(milliseconds: durationMs);
        if (_duration != duration) {
          _duration = duration;
          changed = true;
        }
      }
      if (changed) notifyListeners();
    });
  }

  void _stopRokuPolling() {
    _rokuPollTimer?.cancel();
    _rokuPollTimer = null;
  }

  Future<void> _castUrlToRoku({
    required String url,
    required String title,
    String? imageUrl,
    Map<String, String>? headers,
    Duration startPosition = Duration.zero,
    Duration? duration,
    int? algorithm,
  }) async {
    final baseUrl = _rokuEcpBaseUrl;
    if (baseUrl == null) {
      throw StateError('No hay conexión ECP activa con Roku');
    }

    _currentAlgorithm = algorithm;
    _currentTitle = title;
    _currentImageUrl = imageUrl;
    _currentVideoUrl = url;
    _currentHeaders = headers;
    _position = startPosition;
    _duration = duration ?? Duration.zero;

    final durMin = duration != null
        ? '${(duration.inSeconds / 60).toStringAsFixed(1)} min'
        : 'desconocida';
    _log('✅ [DURACIÓN] Roku duración establecida: $durMin (${duration?.inSeconds ?? 0}s)');

    final combinedHeaders = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      'Accept': '*/*',
      ...?headers,
    };

    var finalUrl = url;
    final shouldProxy =
        headers?.isNotEmpty == true ||
        url.contains('127.0.0.1') ||
        url.contains('localhost') ||
        algorithm != null;

    if (shouldProxy && !url.contains('/proxy') && !url.contains('/a3/')) {
      await MediaProxyService().start(targetIp: _connectedDevice?.address);
      finalUrl = MediaProxyService().getProxiedUrl(
        url,
        combinedHeaders,
        useLocalhost: false,
        toCast: true,
        algorithm: algorithm,
      );
    }

    final isHls = finalUrl.toLowerCase().contains('.m3u8') || finalUrl.contains('playlist');
    final effectiveMediaType = _currentMediaType ?? 'movie';
    final streamFormat = isHls
        ? 'hls'
        : finalUrl.toLowerCase().contains('.mp4')
            ? 'mp4'
            : finalUrl.toLowerCase().contains('.mkv')
                ? 'mkv'
                : null;

    // Fallback HLS: resolver duración desde el manifiesto si no nos la dieron
    if (isHls && (duration == null || duration == Duration.zero)) {
      try {
        _log('⏱️ ROKU: Calculando duración HLS para habilitar SEEK...');
        final double dSeconds = await MediaProxyService().getHlsDuration(
          url,
          headers: combinedHeaders,
        );
        if (dSeconds > 0) {
          duration = Duration(milliseconds: (dSeconds * 1000).toInt());
          _log('⏱️ ROKU: Duración obtenida: ${duration.inSeconds}s');
        }
      } catch (e) {
        _log('⚠️ ROKU: Error al calcular duración (ignorado): $e');
      }
    }

    // Re-aplicar _duration por si el fallback HLS la resolvió
    _duration = duration ?? Duration.zero;

    final durationMin = duration != null
        ? '${(duration.inSeconds / 60).toStringAsFixed(1)} min'
        : 'desconocida';
    _log('Roku: duración=$durationMin, streamFormat=$streamFormat');
    _log('Roku: buscando Media Player entre las apps instaladas...');

    final apps = await _rokuEcp.queryApps(baseUrl);
    RokuAppInfo? mediaPlayer;
    for (final app in apps) {
      final name = app.name.toLowerCase();
      if (name.contains('roku media player') ||
          name == 'media player' ||
          name.contains('media player')) {
        mediaPlayer = app;
        break;
      }
    }

    // IDs conocidos del Roku Media Player: 2285 (clásico), 15536 (nuevo)
    final candidateIds = [
      if (mediaPlayer != null) mediaPlayer.id,
      '2285',
      '15536',
    ];
    String? appId;
    for (final id in candidateIds) {
      if (id == null) continue;
      _log(
        '⏱️ [DURACIÓN_ANTES_FRAGMENTO] Roku: duration=${duration?.inSeconds ?? 0}s en params launch (antes del primer fragmento proxeado)',
      );
      print(
        '🔥🔥🔥 [ENVIANDO_AHORA] Roku → launch app=$id | duration=${duration?.inSeconds ?? 0}s | URL=$finalUrl',
      );
      _log('Roku: intentando lanzar app ID $id...');
      final ok = await _rokuEcp.launch(
        baseUrl,
        id,
        params: {
          'contentId': finalUrl,
          'mediaType': 'movie',
          'title': _sanitizeTitleForDlna(title),
          if (streamFormat != null) 'streamFormat': streamFormat,
          if (duration != null && duration.inSeconds > 0)
            'duration': duration.inSeconds.toString(),
        },
      );
      if (ok) {
        appId = id;
        _log('Roku: lanzamiento exitoso con app ID $id');
        break;
      }
      // Si launch falló, intentar instalar primero (puede no estar instalado)
      _log('Roku: intentando instalar app ID $id...');
      final installed = await _rokuEcp.install(baseUrl, id);
      if (installed) {
        _log('Roku: instalado, reintentando launch en 2s...');
        await Future.delayed(const Duration(seconds: 2));
        final ok2 = await _rokuEcp.launch(
          baseUrl,
          id,
          params: {
            'contentId': finalUrl,
            'mediaType': 'movie',
            'title': _sanitizeTitleForDlna(title),
            if (streamFormat != null) 'streamFormat': streamFormat,
            if (duration != null && duration.inSeconds > 0)
              'duration': duration.inSeconds.toString(),
          },
        );
        if (ok2) {
          appId = id;
          _log('Roku: lanzamiento exitoso con app ID $id (tras instalar)');
          break;
        }
      }
    }

    if (appId == null) {
      _logErr('Roku: todos los IDs fallaron. mediaType=$effectiveMediaType, streamFormat=$streamFormat');
      throw Exception(
        'Roku rechazó la transmisión. Verifica:\n'
        '1. Roku tenga "Control por apps móviles" en Permisivo\n'
        '   (Ajustes → Sistema → Config. avanzada → Control por apps móviles)\n'
        '2. Roku y el teléfono estén en la misma red WiFi\n'
        '3. El canal Media Player esté instalado',
      );
    }

    await Future.delayed(const Duration(milliseconds: 900));
    _isPlaying = true;
    _startRokuPolling();
    notifyListeners();
  }

  /// Limpia el título para incluirlo de forma segura en XML SOAP DLNA.
  /// Samsung TV rechaza peticiones con títulos que contienen extensiones
  /// de archivo, indicadores de formato (HLS/TS) o caracteres no ASCII
  /// sin escapar en el DIDL-Lite.
  String _formatDurationForDlna(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(d.inHours);
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return "$hours:$minutes:$seconds";
  }

  String _sanitizeTitleForDlna(String title) {
    // 1. Quitar extensión de archivo
    final lastDot = title.lastIndexOf('.');
    if (lastDot > 0) title = title.substring(0, lastDot);

    // 2. Quitar artefactos de descarga HLS
    title = title
        .replaceAll(RegExp(r'\(Streaming \(HLS\)\)', caseSensitive: false), '')
        .replaceAll(RegExp(r'\(Streaming\)', caseSensitive: false), '')
        .replaceAll(RegExp(r'\(HLS\)', caseSensitive: false), '')
        .replaceAll(RegExp(r'Resolución\s+Auto', caseSensitive: false), '')
        .replaceAll(RegExp(r'_+'), ' ') // guiones bajos → espacios
        .trim();

    // 3. Colapsar espacios múltiples
    title = title.replaceAll(RegExp(r'\s+'), ' ').trim();

    // 4. No escapamos XML manualmente aquí, la librería lo hará.
    // Escapar dos veces (ej. &amp;amp;) rompe el protocolo en muchas TVs.
    title = title.replaceAll(
      RegExp(r'[^\x00-\x7F]+'),
      '',
    ); // Solo ASCII para máxima compatibilidad

    // 5. Límite de longitud (algunos TVs ignoran títulos muy largos)
    if (title.length > 80) title = title.substring(0, 80).trim();

    return title.isEmpty ? 'Video' : title;
  }

  // ── Playback Controls ──────────────────────────────────────────────────────

  Future<void> play() async {
    if (_connectedDevice?.deviceType == CastDeviceType.roku &&
        _rokuEcpBaseUrl != null) {
      _log('Roku play()');
      await _rokuEcp.keypress(_rokuEcpBaseUrl!, 'Play');
      _isPlaying = true;
      notifyListeners();
      return;
    }
    if (_session == null) return;
    _log('play()');
    if (_connectedDevice?.protocol == dc.CastProtocol.dlna &&
        _dlnaControlUrl != null) {
      try {
        await _sendDlnaSoapAction(
          controlUrl: _dlnaControlUrl!,
          serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
          action: 'Play',
          args: {'InstanceID': '0', 'Speed': '1'},
        );
      } catch (e) {
        if (e.toString().contains('701')) {
          _log('  ⚠️ TV ocupada (701). Reintentando Play en 1s...');
          await Future.delayed(const Duration(seconds: 1));
          return play();
        }
        rethrow;
      }
    }
    try {
      await _session!.play();
    } catch (_) {}
  }

  Future<void> pause() async {
    if (_connectedDevice?.deviceType == CastDeviceType.roku &&
        _rokuEcpBaseUrl != null) {
      _log('Roku pause()');
      await _rokuEcp.keypress(_rokuEcpBaseUrl!, 'Play');
      _isPlaying = false;
      notifyListeners();
      return;
    }
    if (_session == null) return;
    _log('pause()');
    if (_connectedDevice?.protocol == dc.CastProtocol.dlna &&
        _dlnaControlUrl != null) {
      try {
        await _sendDlnaSoapAction(
          controlUrl: _dlnaControlUrl!,
          serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
          action: 'Pause',
          args: {'InstanceID': '0'},
        );
      } catch (e) {
        if (e.toString().contains('701')) {
          _log('  ⚠️ TV ocupada (701). Reintentando Pause en 1s...');
          await Future.delayed(const Duration(seconds: 1));
          return pause();
        }
        rethrow;
      }
    }
    try {
      await _session!.pause();
    } catch (_) {}
  }

  Future<void> stop() async {
    if (_connectedDevice?.deviceType == CastDeviceType.roku &&
        _rokuEcpBaseUrl != null) {
      _log('Roku stop()');
      await _rokuEcp.keypress(_rokuEcpBaseUrl!, 'Home');
      _isPlaying = false;
      _position = Duration.zero;
      notifyListeners();
      return;
    }
    if (_session == null) return;
    _log('stop()');
    if (_connectedDevice?.protocol == dc.CastProtocol.dlna &&
        _dlnaControlUrl != null) {
      await _sendDlnaSoapAction(
        controlUrl: _dlnaControlUrl!,
        serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
        action: 'Stop',
        args: {'InstanceID': '0'},
      );
    }
    try {
      await _session!.stop();
    } catch (_) {}
  }

  Future<void> seekTo(Duration position) async {
    if (_connectedDevice?.deviceType == CastDeviceType.roku &&
        _rokuEcpBaseUrl != null) {
      _log('Roku seek aproximado (${position.inSeconds}s)');
      final forward = position > _position;
      final delta = (position - _position).abs();
      final presses = (delta.inSeconds / 30).clamp(1, 12).round();
      for (var i = 0; i < presses; i++) {
        await _rokuEcp.keypress(_rokuEcpBaseUrl!, forward ? 'Fwd' : 'Rev');
        await Future.delayed(const Duration(milliseconds: 120));
      }
      _position = position;
      notifyListeners();
      return;
    }
    if (_session == null) return;
    _log('seekTo(${position.inSeconds}s)');

    if (_connectedDevice?.protocol == dc.CastProtocol.dlna &&
        _dlnaControlUrl != null) {
      final target = _formatDurationForDlna(position);
      // 1. Intento con REL_TIME
      //    NOTA: _sendDlnaSoapAction NO lanza excepción en HTTP 500 — devuelve null.
      //    Por eso chequeamos el valor de retorno explícitamente.
      try {
        final r1 = await _sendDlnaSoapAction(
          controlUrl: _dlnaControlUrl!,
          serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
          action: 'Seek',
          args: {'InstanceID': '0', 'Unit': 'REL_TIME', 'Target': target},
        );
        if (r1 != null) {
          _log('  ✅ Seek REL_TIME exitoso');
          _position = position;
          notifyListeners();
          return;
        }
        throw Exception('REL_TIME seek returned null (HTTP error)');
      } catch (e) {
        if (e.toString().contains('701')) {
          _log('  ⚠️ TV ocupada (701). Reintentando Seek en 1s...');
          await Future.delayed(const Duration(seconds: 1));
          return seekTo(position);
        }
        _log('  ⚠️ Seek REL_TIME falló: ${e.toString().length > 100 ? e.toString().substring(0, 100) : e.toString()}');
      }
      // 2. Fallback con ABS_TIME (algunas TVs Samsung/LG viejas)
      try {
        final r2 = await _sendDlnaSoapAction(
          controlUrl: _dlnaControlUrl!,
          serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
          action: 'Seek',
          args: {'InstanceID': '0', 'Unit': 'ABS_TIME', 'Target': target},
        );
        if (r2 != null) {
          _log('  ✅ Seek ABS_TIME exitoso');
          _position = position;
          notifyListeners();
          return;
        }
        throw Exception('ABS_TIME seek returned null');
      } catch (e) {
        _log('  ⚠️ Seek ABS_TIME también falló');
      }
      // 3. Reintentamos ABS_TIME tras 3s (la TV puede estar ocupada)
      _log(
        '  ⏳ Seek falló (711/701). Reintentando ABS_TIME en 3s...',
      );
      await Future.delayed(const Duration(seconds: 3));
      try {
        final r3 = await _sendDlnaSoapAction(
          controlUrl: _dlnaControlUrl!,
          serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
          action: 'Seek',
          args: {'InstanceID': '0', 'Unit': 'ABS_TIME', 'Target': target},
        );
        if (r3 != null) {
          _log('  ✅ Seek diferido exitoso a ${position.inSeconds}s');
          _position = position;
          notifyListeners();
          return;
        }
      } catch (e) {
        _log('  ⚠️ Seek diferido también falló');
      }
      // 4. Stop + recast con server-side seeking (pos en la URL del proxy).
      //    El proxy reescribirá el manifiesto HLS para saltar segmentos.
      if (_recastUrl != null) {
        _log('  ⏹️ Recasteando con server-side seek (pos=${position.inSeconds}s)...');
        await stop();
        await Future.delayed(const Duration(milliseconds: 600));
        await MediaProxyService().start();

        // Usar solo cabeceras mínimas para evitar URL > 1024 chars (SOAP 500 en Samsung)
        final Map<String, String> minimalHeaders = {};
        final h = _recastHeaders ?? {};
        if (h.containsKey('User-Agent'))
          minimalHeaders['User-Agent'] = h['User-Agent']!;
        if (h.containsKey('Referer'))
          minimalHeaders['Referer'] = h['Referer']!;
        if (h.containsKey('Cookie'))
          minimalHeaders['Cookie'] = h['Cookie']!;
        if (h.containsKey('Origin'))
          minimalHeaders['Origin'] = h['Origin']!;
        if (!minimalHeaders.containsKey('User-Agent')) {
          // Fallback: mismo UA por defecto que en castUrl
          minimalHeaders['User-Agent'] =
              'Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36';
        }

        final posUrl = MediaProxyService().getProxiedUrl(
          _recastUrl!,
          minimalHeaders,
          useLocalhost: false,
          toCast: true,
          algorithm: _recastAlgorithm,
          remux: false,
          pos: position.inSeconds,
        );
        final effectiveDuration =
            _duration > Duration.zero ? _duration : null;
        try {
          // loadMedia ya envía Play internamente
          await _session!.loadMedia(dc.CastMedia(
            url: posUrl,
            title: _currentTitle ?? '',
            type: _recastMediaType,
            imageUrl: _currentImageUrl,
            startPosition: Duration.zero,
            duration: effectiveDuration,
          ));
          _recastSeekActive = true;
          _recastOffset = position;
          _position = position;
          notifyListeners();
          _log('  ✅ Recast exitoso a ${position.inSeconds}s (offset=${_recastOffset.inSeconds}s)');
        } catch (e) {
          _log('  ❌ Recast falló: $e');
          _recastSeekActive = false;
          _recastOffset = Duration.zero;
          _position = position;
          notifyListeners();
        }
      } else {
        _log('  ⚠️ Sin datos de recast. Solo UI.');
        _position = position;
        notifyListeners();
      }
    }

    try {
      await _session!.seek(position);
    } catch (_) {}
  }

  Future<void> setVolume(double volume) async {
    if (_connectedDevice?.deviceType == CastDeviceType.roku &&
        _rokuEcpBaseUrl != null) {
      await _rokuEcp.keypress(_rokuEcpBaseUrl!, 'VolumeUp');
      return;
    }
    return _session?.setVolume(volume) ?? Future.value();
  }

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
    if (u.contains('.mkv')) return dc.CastMediaType.mkv;
    if (u.contains('.ts')) {
      // Muchas TVs DLNA no soportan el MIME video/mp2t que envía mpegTs.
      // Engañarlas con mp4 (video/mp4) suele funcionar si el codec es H264.
      return dc.CastMediaType.mp4;
    }
    if (u.contains('.mp4')) return dc.CastMediaType.mp4;
    if (u.contains('.mov') ||
        u.contains('.avi') ||
        u.contains('.flv') ||
        u.contains('.wmv'))
      return dc.CastMediaType.mp4;

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
        _log(
          'sessionFactory llamado para: ${device.name} [proto=${device.protocol}]',
        );
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
              throw Exception(
                'El dispositivo DLNA no tiene metadatos AVTransportControlUrl: $e',
              );
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
    try {
      _session?.disconnect();
    } catch (_) {}
    _rawService?.dispose();
    super.dispose();
  }
}
