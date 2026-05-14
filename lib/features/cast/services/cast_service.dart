import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:movie_app/core/constants/app_constants.dart';
import 'package:dart_cast/dart_cast.dart' as dc;
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'cast_device_info.dart';
import 'media_proxy_service.dart';

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
  StreamSubscription? _stateSubscription;
  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;
  Timer? _dlnaPollTimer;
  String? _dlnaControlUrl;
  String? _dlnaEventUrl;
  String? _dlnaRenderingControlUrl;
  int? _currentAlgorithm;
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
          _devices = rawDevices
              .map((d) => CastDeviceInfo.fromCastDevice(d))
              .toList();
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
    try {
      await _session?.stop();
      await _session?.disconnect();
    } catch (e) {
      _logErr('Error durante disconnect: $e');
    }
    _session = null;
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
      _log(
        '🚀 CAST: Activando PUENTE HLS-a-MP4 (Modo Bridge)',
      );
      await MediaProxyService().start();

      mediaType = dc.CastMediaType.mp4;
      finalUrl = MediaProxyService().getProxiedUrl(
        effectiveUrl,
        combinedHeaders,
        useLocalhost: false, toCast: true,
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
        (mediaType == dc.CastMediaType.hls ||
            effectiveUrl.contains('.m3u8'))) {
      _log(
        '🚀 CAST: Usando Modo Dinámico (HLS Nativo) para Algoritmo $effectiveAlgorithm',
      );
      await MediaProxyService().start();
      finalUrl = MediaProxyService().getProxiedUrl(
        effectiveUrl,
        combinedHeaders,
        useLocalhost: false, toCast: true,
        algorithm: effectiveAlgorithm,
        remux: effectiveAlgorithm == 3,
      );

      if (duration == null || duration == Duration.zero) {
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
        useLocalhost: false, toCast: true,
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
        useLocalhost: false, toCast: true,
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
        final bool shouldBridge = effectiveAlgorithm == 3;
        finalUrl = MediaProxyService().getProxiedUrl(
          unproxiedFinal['url'],
          minimalHeaders,
          useLocalhost: false, toCast: true,
          algorithm: effectiveAlgorithm,
          remux: effectiveAlgorithm == 3 && !shouldBridge, // Priorizar bridge si está activo
          
        );
        if (shouldBridge) mediaType = dc.CastMediaType.mp4;
      }
    }

    _log('  Llamando session.loadMedia() con URL: $finalUrl');

    try {
      _log('🚀 [LOAD] Sending to TV: $finalUrl');

      // Creamos el objeto media con los datos optimizados
      final media = dc.CastMedia(
        url: finalUrl,
        title: _sanitizeTitleForDlna(title),
        type: mediaType,
        imageUrl: imageUrl,
        startPosition: startPosition,
        duration: duration,
      );

      // En dart_cast, loadMedia requiere un objeto CastMedia
      await _session!.loadMedia(media);

      // En DLNA, a veces loadMedia no dispara el Play automáticamente o falla por timeout de respuesta
      if (isDlna) {
        _log('  DLNA: Forzando Play tras loadMedia para asegurar arranque...');
        await Future.delayed(const Duration(milliseconds: 1000));
        try {
          await _session!.play();
        } catch (_) {}
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
      if (isDlna && _dlnaControlUrl != null) {
        _log(
          '  DLNA Senior: Usando carga manual con DIDL-Lite para habilitar controles...',
        );
        final success = await _loadMediaDlnaSenior(
          url: proxyUrl,
          title: title,
          mediaType: dc.CastMediaType.mp4,
          imageUrl: imageUrl,
          duration: effectiveDuration,
        );
        if (success) {
          _log('  ✅ Carga manual DLNA completada');

          // Esperar a que la TV procese la URI antes de mandar Play
          await Future.delayed(const Duration(milliseconds: 1500));

          try {
            await play();
          } catch (e) {
            if (e.toString().contains('701')) {
              _log(
                '  ⚠️ TV devolvió 701 en Play, probablemente ya está iniciando...',
              );
            } else {
              rethrow;
            }
          }

          notifyListeners();
          return;
        }
      }

      await _session!.loadMedia(media);
      _log('  ✅ loadMedia local completado');
    } catch (e, stack) {
      _logErr(
        '  loadMedia fallback falló: $e (posiblemente la TV ya tiene la URI cargada)',
      );
      // No relanzamos: si la TV ya recibió la URI via SOAP directo, está reproduciendo.
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
            if (newPos != _position) {
              _position = newPos;
              notifyListeners();
            }
          }
          if (duration != null &&
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

  /// Limpia el título para incluirlo de forma segura en XML SOAP DLNA.
  /// Samsung TV rechaza peticiones con títulos que contienen extensiones
  /// de archivo, indicadores de formato (HLS/TS) o caracteres no ASCII
  /// sin escapar en el DIDL-Lite.
  Future<bool> _loadMediaDlnaSenior({
    required String url,
    required String title,
    dc.CastMediaType? mediaType,
    String? imageUrl,
    Duration? duration,
  }) async {
    _log('🛰️ [DLNA_SENIOR] Target: $_dlnaControlUrl');
    if (_dlnaControlUrl == null) return false;

    String finalUrl = url;
    dc.CastMediaType? finalMediaType = mediaType;

    // 🌉 REFUERZO DE ÚLTIMA MILLA: Si el HLS llega aquí sin proxeat, lo capturamos
    if (url.contains('.m3u8') && !url.contains('/bridge')) {
      print(
        '🌉 [BRIDGE_FORCE] Detectado HLS en el punto de salida. Forzando Puente...',
      );
      await MediaProxyService().start();

      final String proxyBase = MediaProxyService().getProxiedUrl(
        '',
        null,
        useLocalhost: false, toCast: true,
      );
      final String host = proxyBase
          .split('/proxy')[0]
          .replaceFirst('http://', '');
      final bUrl = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
      finalUrl = 'http://$host/bridge.mp4?url=$bUrl&a=1';
      finalMediaType = dc.CastMediaType.mp4;

      print('🌉 [BRIDGE_FORCE] URL transformada: $finalUrl');
    }

    final durationStr = duration != null
        ? _formatDurationForDlna(duration)
        : "0:00:00";
    final sanitizedTitle = _sanitizeTitleForDlna(title);

    // MimeType dinámico según el contenido
    String mimeType = 'video/mp4';
    if (finalUrl.contains('/bridge')) {
      mimeType = 'video/mp2t'; // MPEG-TS es el nuevo estándar del puente
    } else if (finalMediaType == dc.CastMediaType.hls) {
      mimeType = 'application/vnd.apple.mpegurl';
    } else if (finalMediaType == dc.CastMediaType.mkv) {
      mimeType = 'video/x-matroska';
    } else if (finalMediaType == dc.CastMediaType.mpegTs) {
      mimeType = 'video/mp2t';
    }

    // DIDL-Lite: formato estándar compatible con Samsung/LG/Sony
    // DLNA.ORG_OP=01 → Habilita seek por byte-range (adelantar/atrasar)
    // DLNA.ORG_FLAGS → Bits de capacidades: Streaming + Time-based seek
    // DLNA.ORG_PN → Profile Name (Samsung lo requiere para reconocer el codec)
    String dlnaProfile = 'AVC_MP4_HP_HD_AAC';
    if (mimeType.contains('mp2t')) dlnaProfile = 'MPEG_TS_HD_NA_ISO';

    final String dlnaFlags =
        'DLNA.ORG_PN=$dlnaProfile;DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000';
    final String protocolInfo = 'http-get:*:$mimeType:$dlnaFlags';

    // El metadata DIDL-Lite DEBE estar escapado dentro del SOAP CurrentURIMetaData.
    // Samsung requiere xmlns:sec y suele fallar si falta o si hay namespaces extraños como dlna:.
    // Incluimos pv (PacketVideo) que es un estándar común en DLNA.
    final metadata =
        '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
        'xmlns:sec="http://www.sec.co.kr/" '
        'xmlns:pv="http://www.pv.com/pvns/">'
        '<item id="0" parentID="0" restricted="0">'
        '<dc:title>${_escapeXml(sanitizedTitle)}</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        '<res protocolInfo="$protocolInfo" duration="$durationStr">${_escapeXml(finalUrl)}</res>'
        '</item></DIDL-Lite>';

    _log(
      '📜 [DLNA_METADATA] Title: $sanitizedTitle | Mime: $mimeType | Duration: $durationStr',
    );

    final success = await _sendDlnaSoapAction(
      controlUrl: _dlnaControlUrl!,
      serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
      action: 'SetAVTransportURI',
      args: {
        'InstanceID': '0',
        'CurrentURI': _escapeXml(finalUrl),
        'CurrentURIMetaData': _escapeXml(metadata),
      },
    );

    return success != null;
  }

  String _formatDurationForDlna(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(d.inHours);
    final minutes = twoDigits(d.inMinutes.remainder(60));
    final seconds = twoDigits(d.inSeconds.remainder(60));
    return "$hours:$minutes:$seconds";
  }

  String _escapeXml(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
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
    if (_session == null) return;
    _log('seekTo(${position.inSeconds}s)');

    if (_connectedDevice?.protocol == dc.CastProtocol.dlna &&
        _dlnaControlUrl != null) {
      try {
        final target = _formatDurationForDlna(position);
        await _sendDlnaSoapAction(
          controlUrl: _dlnaControlUrl!,
          serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
          action: 'Seek',
          args: {'InstanceID': '0', 'Unit': 'REL_TIME', 'Target': target},
        );
      } catch (e) {
        if (e.toString().contains('701')) {
          _log('  ⚠️ TV ocupada (701). Reintentando Seek en 1s...');
          await Future.delayed(const Duration(seconds: 1));
          return seekTo(position);
        }
        rethrow;
      }
    }

    try {
      await _session!.seek(position);
    } catch (_) {}
  }

  Future<void> setVolume(double volume) =>
      _session?.setVolume(volume) ?? Future.value();

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
