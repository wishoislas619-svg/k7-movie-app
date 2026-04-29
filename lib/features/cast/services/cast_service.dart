import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:dart_cast/dart_cast.dart' as dc;
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'cast_device_info.dart';
import 'media_proxy_service.dart';

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

      // Si es DLNA, extraemos URLs de control e iniciamos polling manual
      if (device.protocol == dc.CastProtocol.dlna) {
        // En dart_cast 0.4.3 para DLNA, la ubicación del XML se puede reconstruir o extraer
        // desde la información de servicio. Si no está disponible directamente, usamos la IP.
        _fetchDlnaControlUrls('http://${device.address}:${device.rawDevice.port}/');
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
      combinedHeaders['Referer'] = headers?['Referer'] ?? 'https://embed.su/';
      combinedHeaders['Origin'] = headers?['Origin'] ?? 'https://embed.su';
      combinedHeaders['Sec-Fetch-Dest'] = 'video';
      combinedHeaders['Sec-Fetch-Mode'] = 'cors';
      combinedHeaders['Sec-Fetch-Site'] = 'cross-site';
      _log('  Headers: Aplicada configuración Algoritmo 3 (Embed.su/Videasy)');
    } else if (algorithm == 2) {
      combinedHeaders['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36';
      combinedHeaders['Referer'] = headers?['Referer'] ?? url;
      combinedHeaders['Origin'] = headers?['Origin'] ?? (Uri.tryParse(url)?.origin ?? '');
      combinedHeaders['Sec-Fetch-Dest'] = 'video';
      combinedHeaders['Sec-Fetch-Mode'] = 'cors';
      combinedHeaders['Sec-Fetch-Site'] = 'cross-site';
      _log('  Headers: Aplicada configuración Algoritmo 2 (Cuevana/Vidsrc)');
    } else {
      _log('  UA: Android móvil (Estándar)');
    }

    final isDlna = _connectedDevice?.protocol == dc.CastProtocol.dlna;
    final mediaType = _detectMediaType(url);
    _log('  isDlna   : $isDlna');
    _log('  mediaType: $mediaType');

    String finalUrl = url;
    
    // --- LÓGICA DE PROXY UNIFICADO PARA CAST ---
    // 1. Si ya es una URL proxeada por MediaProxyService, verificamos si usa 127.0.0.1
    // 2. Si usa 127.0.0.1, la convertimos a IP de RED para que la TV la vea.
    final bool isLocalhost = url.contains('127.0.0.1') || url.contains('localhost');
    final bool isAlreadyProxied = url.contains('/proxy');
    
    if (isAlreadyProxied && isLocalhost) {
      _log('  CAST: Convirtiendo URL de localhost a IP de RED para la TV');
      final unproxied = MediaProxyService.tryUnproxy(url);
      if (unproxied != null) {
        finalUrl = MediaProxyService().getProxiedUrl(
          unproxied['url'], 
          unproxied['headers'], 
          useLocalhost: false, 
          algorithm: algorithm
        );
      }
    } 
    // 3. Si es Algoritmo 2 o 3 y NO está proxeada, FORZAMOS el proxy para inyectar headers
    else if ((algorithm == 2 || algorithm == 3) && !isAlreadyProxied) {
      _log('  CAST: Forzando Proxy de RED para Algoritmo $algorithm');
      await MediaProxyService().start();
      finalUrl = MediaProxyService().getProxiedUrl(url, combinedHeaders, useLocalhost: false, algorithm: algorithm);
    }
    // 4. Fallback para DLNA estándar (MP4/MKV) que requiere cabeceras
    else if (isDlna && mediaType != dc.CastMediaType.hls && !isAlreadyProxied) {
       _log('  DLNA: Proxeando video estándar para inyectar cabeceras');
       await MediaProxyService().start();
       finalUrl = MediaProxyService().getProxiedUrl(url, combinedHeaders, useLocalhost: false, algorithm: algorithm);
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
      duration: duration,
      subtitles: (subtitleUrl != null && !isDlna)
          ? [dc.CastSubtitle(url: subtitleUrl, label: 'Subtítulos', language: 'es', format: 'vtt')]
          : [],
    );

    _log('  Llamando session.loadMedia() con URL: $finalUrl');
    try {
      if (isDlna && _dlnaControlUrl != null) {
        _log('  DLNA Senior: Usando carga manual con DIDL-Lite...');
        final success = await _loadMediaDlnaSenior(
          url: finalUrl,
          title: title,
          imageUrl: imageUrl,
          duration: duration,
        );
        if (success) {
          _log('  ✅ Carga manual DLNA completada');
          await play();
          notifyListeners();
          return;
        }
      }
      
      await _session!.loadMedia(media);
      _log('  ✅ loadMedia completado (Estándar)');
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

    // Registrar el archivo en nuestro MediaProxyService unificado
    await MediaProxyService().start();
    final proxyUrl = MediaProxyService().getProxiedUrl(filePath, {}, useLocalhost: false);
    _log('  Archivo local registrado en: $proxyUrl');

    // Transmitir usando la lógica estándar de castUrl (UA móvil, stop previo, etc.)
    return castUrl(
      url: proxyUrl,
      title: title,
      imageUrl: imageUrl,
      startPosition: startPosition,
      duration: duration,
    );
  }

  // ── DLNA Polling ───────────────────────────────────────────────────────────

  Future<void> _fetchDlnaControlUrls(String location) async {
    try {
      _log('Extrayendo URLs de control desde: $location');
      final response = await http.get(Uri.parse(location)).timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final body = response.body;
        // Búsqueda simple por RegEx para evitar dependencias pesadas de XML
        final avMatch = RegExp(r'<serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>.*?<controlURL>(.*?)</controlURL>', dotAll: true).firstMatch(body);
        final renderMatch = RegExp(r'<serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>.*?<controlURL>(.*?)</controlURL>', dotAll: true).firstMatch(body);
        
        if (avMatch != null) {
          String url = avMatch.group(1)!;
          _dlnaControlUrl = _buildAbsoluteUrl(location, url);
          _log('  AVTransport Control URL: $_dlnaControlUrl');
        }
        if (renderMatch != null) {
          String url = renderMatch.group(1)!;
          _dlnaRenderingControlUrl = _buildAbsoluteUrl(location, url);
          _log('  RenderingControl URL: $_dlnaRenderingControlUrl');
        }
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
      if (_session == null || _state != CastConnectionState.connected || _dlnaControlUrl == null) {
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
          final relTime = RegExp(r'<RelTime>(.*?)</RelTime>').firstMatch(posInfo)?.group(1);
          final duration = RegExp(r'<TrackDuration>(.*?)</TrackDuration>').firstMatch(posInfo)?.group(1);
          
          if (relTime != null && relTime != 'NOT_IMPLEMENTED') {
            final newPos = _parseDlnaDuration(relTime);
            if (newPos != _position) {
              _position = newPos;
              notifyListeners();
            }
          }
          if (duration != null && duration != 'NOT_IMPLEMENTED' && duration != '0:00:00') {
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
          final state = RegExp(r'<CurrentTransportState>(.*?)</CurrentTransportState>').firstMatch(transInfo)?.group(1);
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
    final argsXml = args.entries.map((e) => '<${e.key}>${e.value}</${e.key}>').join('');
    final envelope = '''
<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:$action xmlns:u="$serviceType">
      $argsXml
    </u:$action>
  </s:Body>
</s:Envelope>
'''.trim();

    try {
      final response = await http.post(
        Uri.parse(controlUrl),
        headers: {
          'Content-Type': 'text/xml; charset="utf-8"',
          'SOAPAction': '"$serviceType#$action"',
        },
        body: envelope,
      ).timeout(const Duration(seconds: 3));
      
      if (response.statusCode == 200) return response.body;
    } catch (_) {}
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
    String? imageUrl,
    Duration? duration,
  }) async {
    if (_dlnaControlUrl == null) return false;

    final durationStr = duration != null ? _formatDurationForDlna(duration) : "0:00:00";
    final sanitizedTitle = _sanitizeTitleForDlna(title);
    
    // DIDL-Lite Metadata (Clave para Samsung/LG)
    // DLNA.ORG_OP=01 -> Habilita SEEK (Adelantar/Atrasar)
    // DLNA.ORG_CI=0  -> No es transcodificado
    // DLNA.ORG_FLAGS -> Compatibilidad general
    final metadata = '''
<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:sec="http://www.sec.co.kr/">
  <item id="0" parentID="-1" restricted="1">
    <dc:title>${_escapeXml(sanitizedTitle)}</dc:title>
    <upnp:class>object.item.videoItem</upnp:class>
    <res protocolInfo="http-get:*:video/mp4:DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000" duration="$durationStr">$url</res>
    ${imageUrl != null ? '<upnp:albumArtURI>${_escapeXml(imageUrl)}</upnp:albumArtURI>' : ''}
  </item>
</DIDL-Lite>
'''.trim();

    final success = await _sendDlnaSoapAction(
      controlUrl: _dlnaControlUrl!,
      serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
      action: 'SetAVTransportURI',
      args: {
        'InstanceID': '0',
        'CurrentURI': url,
        'CurrentURIMetaData': metadata,
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
        .replaceAll(RegExp(r'\(HLS\)', caseSensitive: false), '')
        .replaceAll(RegExp(r'Resolución\s+Auto', caseSensitive: false), '')
        .replaceAll(RegExp(r'_+'), ' ')  // guiones bajos → espacios
        .trim();

    // 3. Colapsar espacios múltiples
    title = title.replaceAll(RegExp(r'\s+'), ' ').trim();

    // 4. No escapamos XML manualmente aquí, la librería lo hará. 
    // Escapar dos veces (ej. &amp;amp;) rompe el protocolo en muchas TVs.
    title = title.replaceAll(RegExp(r'[^\x00-\x7F]+'), ''); // Solo ASCII para máxima compatibilidad

    // 5. Límite de longitud (algunos TVs ignoran títulos muy largos)
    if (title.length > 80) title = title.substring(0, 80).trim();

    return title.isEmpty ? 'Video' : title;
  }

  // ── Playback Controls ──────────────────────────────────────────────────────
  
  Future<void> play() async {
    if (_session == null) return;
    _log('play()');
    if (_connectedDevice?.protocol == dc.CastProtocol.dlna && _dlnaControlUrl != null) {
      await _sendDlnaSoapAction(
        controlUrl: _dlnaControlUrl!,
        serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
        action: 'Play',
        args: {'InstanceID': '0', 'Speed': '1'},
      );
    }
    await _session!.play();
  }

  Future<void> pause() async {
    if (_session == null) return;
    _log('pause()');
    if (_connectedDevice?.protocol == dc.CastProtocol.dlna && _dlnaControlUrl != null) {
      await _sendDlnaSoapAction(
        controlUrl: _dlnaControlUrl!,
        serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
        action: 'Pause',
        args: {'InstanceID': '0'},
      );
    }
    await _session!.pause();
  }

  Future<void> stop() async {
    if (_session == null) return;
    _log('stop()');
    if (_connectedDevice?.protocol == dc.CastProtocol.dlna && _dlnaControlUrl != null) {
      await _sendDlnaSoapAction(
        controlUrl: _dlnaControlUrl!,
        serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
        action: 'Stop',
        args: {'InstanceID': '0'},
      );
    }
    await _session!.stop();
  }

  Future<void> seekTo(Duration position) async {
    if (_session == null) return;
    _log('seekTo(${position.inSeconds}s)');
    
    if (_connectedDevice?.protocol == dc.CastProtocol.dlna && _dlnaControlUrl != null) {
      final target = _formatDurationForDlna(position);
      await _sendDlnaSoapAction(
        controlUrl: _dlnaControlUrl!,
        serviceType: 'urn:schemas-upnp-org:service:AVTransport:1',
        action: 'Seek',
        args: {
          'InstanceID': '0',
          'Unit': 'REL_TIME',
          'Target': target,
        },
      );
    }
    
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
    if (u.contains('.ts')) {
       // Muchas TVs DLNA no soportan el MIME video/mp2t que envía mpegTs.
       // Engañarlas con mp4 (video/mp4) suele funcionar si el codec es H264.
       return dc.CastMediaType.mp4;
    }
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
    _rawService?.dispose();
    super.dispose();
  }
}
