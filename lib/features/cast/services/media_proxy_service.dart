import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'package:ffmpeg_kit_flutter_new_https_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_https_gpl/return_code.dart';
import 'package:ffmpeg_kit_flutter_new_https_gpl/session.dart';

class MediaProxyService {
  static final MediaProxyService _instance = MediaProxyService._internal();
  factory MediaProxyService() => _instance;
  MediaProxyService._internal();

  static String? lastCookies;
  static String? deviceUserAgent;

  HttpServer? _server;
  int _port = 0;
  String _localIp = '';
  final Map<String, _A3Entry> _a3Registry = {};
  final Map<String, _BridgeEntry> _bridgeRegistry = {};
  final Map<String, Map<String, String>> _bridgeInputHeaders = {}; // bridgeId -> headers
  final Map<String, String> _localFileRegistry = {}; // fileId → filePath
  final Map<String, String> _manifestCache = {}; // url → body
  final Map<String, DateTime> _manifestCacheTime = {}; // url → time

  /// Registra un archivo local con un ID opaco para que la TV reciba una URL limpia.
  void registerLocalFile(String fileId, String filePath) {
    _localFileRegistry[fileId] = filePath;
  }

  String get localIp => _localIp;
  int get port => _port;

  /// Calcula la duración total de un HLS sumando sus fragmentos.
  /// Soporta Master Manifests de forma recursiva.
  Future<double> getHlsDuration(
    String url, {
    Map<String, String>? headers,
  }) async {
    try {
      final res = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(Duration(seconds: 5));
      if (res.statusCode != 200) return 0;

      final body = res.body;
      final bool isManifest =
          body.contains('#EXTM3U') ||
          body.contains('#EXT-X-STREAM-INF') ||
          body.contains('#EXTINF');

      if (!isManifest) return 0;

      if (body.contains('#EXT-X-STREAM-INF')) {
        // Es un Master Manifest, buscar la variante con mayor resolución o la primera
        final lines = body.split('\n');
        for (int i = 0; i < lines.length; i++) {
          if (lines[i].contains('#EXT-X-STREAM-INF') && i + 1 < lines.length) {
            String variantUrl = lines[i + 1].trim();
            if (!variantUrl.startsWith('http')) {
              variantUrl = Uri.parse(url).resolve(variantUrl).toString();
            }
            return await getHlsDuration(variantUrl, headers: headers);
          }
        }
      }

      double duration = 0;
      final matches = RegExp(r'#EXTINF:([\d.]+),').allMatches(body);
      for (var m in matches) {
        duration += double.tryParse(m.group(1) ?? '0') ?? 0;
      }
      return duration;
    } catch (e) {
      print('⚠️ [PROXY] Error calculando duración HLS: $e');
      return 0;
    }
  }

  /// Intenta revertir una URL proxeada a su URL original y headers.
  static Map<String, dynamic>? tryUnproxy(String proxiedUrl) {
    try {
      if (!proxiedUrl.contains('/proxy'))
        return null;
      final uri = Uri.parse(proxiedUrl);
      final bUrl = uri.queryParameters['url'];
      if (bUrl == null) return null;

      String normalize(String s) {
        int pad = 4 - (s.length % 4);
        if (pad < 4 && pad > 0) s += '=' * pad;
        return s;
      }

      final url = utf8.decode(base64Url.decode(normalize(bUrl)));
      final hParam = uri.queryParameters['h'];
      Map<String, String>? headers;
      if (hParam != null) {
        final decoded = utf8.decode(base64Url.decode(normalize(hParam)));
        headers = Map<String, String>.from(json.decode(decoded));
      }
      return {'url': url, 'headers': headers};
    } catch (_) {
      return null;
    }
  }

  Future<void> start({String? targetIp}) async {
    if (_server != null) {
      if (targetIp != null) _refreshLocalIp(targetIp: targetIp);
      return;
    }
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _port = _server!.port;
      await _refreshLocalIp(targetIp: targetIp);

      _server!.listen((HttpRequest request) {
        if (request.uri.path.startsWith('/local/')) {
          _handleLocalFileRequest(request);
        } else if (request.uri.path.startsWith('/proxy')) {
          _handleProxyRequest(request);
        } else if (request.uri.path.startsWith('/a3/')) {
          _handleA3Request(request);
        } else if (request.uri.path.startsWith('/bridge/')) {
          _handleBridgeRequest(request);
        } else {
          request.response.statusCode = HttpStatus.notFound;
          request.response.close();
        }
      });

      print('🚀 [PROXY] Running at http://$_localIp:$_port');
    } catch (e) {
      print('❌ [PROXY] Error starting: $e');
    }
  }

  // --- LÓGICA DE PROXY (ALGO 1: FRAGMENTOS) ---
  Future<void> _handleProxyRequest(HttpRequest request) async {
    final encodedUrl = request.uri.queryParameters['url'];
    final encodedHeaders =
        request.uri.queryParameters['h'] ??
        request.uri.queryParameters['headers'];
    final algoParam = request.uri.queryParameters['a'];
    final remuxParam = request.uri.queryParameters['remux'] == '1';
    final castParam = request.uri.queryParameters['cast'] == '1';
    final isAudioPlaylist = request.uri.queryParameters['audio'] == '1';
    if (isAudioPlaylist) print('🔊 [PROXY] Audio segment/playlist request detected');

    if (encodedUrl == null) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    String normalize(String s) {
      int pad = 4 - (s.length % 4);
      if (pad < 4 && pad > 0) s += '=' * pad;
      return s;
    }

    final url = utf8.decode(base64Url.decode(normalize(encodedUrl)));
    final requestId = DateTime.now().millisecondsSinceEpoch
        .toString()
        .substring(7);
    final Map<String, String> headers = {};
    final bool isManifestRequest =
        url.contains('.m3u8') ||
        url.contains('playlist') ||
        url.contains('master');

    // 1. Cabeceras de la TV
    request.headers.forEach((name, values) {
      final n = name.toLowerCase();
      if (n != 'host' && n != 'connection') {
        if (isManifestRequest && n == 'range')
          return; // Quitar range solo en manifiestos
        headers[name] = values.join(', ');
      }
    });

    // 2. Cabeceras proxiadas (Inyectadas por el extractor o desde el Bridge Registry)
    final String? bridgeId = request.uri.queryParameters['bid'];
    if (bridgeId != null && _bridgeInputHeaders.containsKey(bridgeId)) {
      headers.addAll(_bridgeInputHeaders[bridgeId]!);
    }

    if (encodedHeaders != null) {
      try {
        final decoded = jsonDecode(
          utf8.decode(base64Url.decode(normalize(encodedHeaders))),
        );
        if (decoded is Map) {
          decoded.forEach((k, v) => headers[k.toString()] = v.toString());
        }
      } catch (_) {}
    }



    // 📂 SERVIR ARCHIVO LOCAL: Si la URL no empieza por http, es un path de sistema
    if (!url.startsWith('http')) {
      await _serveLocalFile(request, url);
      return;
    }

    try {
      final client = http.Client();
      final proxyRequest = http.Request(request.method, Uri.parse(url));
      headers.forEach((k, v) => proxyRequest.headers[k] = v);
      
      // Forzar 'identity' para evitar problemas de descompresión manual en el proxy
      proxyRequest.headers['accept-encoding'] = 'identity';
      proxyRequest.followRedirects = true;

      final streamedResponse = await client.send(proxyRequest);
      final upstreamContentType =
          (streamedResponse.headers['content-type'] ?? '').toLowerCase();

      print('📡 [PROXY][$requestId] Response Status: ${streamedResponse.statusCode} | Type: $upstreamContentType');

      bool isHls =
          upstreamContentType.contains('mpegurl') ||
          upstreamContentType.contains('apple.mpegurl') ||
          url.contains('.m3u8');

      if (isHls) {
        String? fullBody;
        final cacheKey = url + (headers.toString());
        final now = DateTime.now();

        if (_manifestCache.containsKey(cacheKey) &&
            _manifestCacheTime.containsKey(cacheKey) &&
            now.difference(_manifestCacheTime[cacheKey]!) <
                const Duration(seconds: 3)) {
          fullBody = _manifestCache[cacheKey];
        }

        if (fullBody == null) {
          // Leer bytes crudos
          List<int> rawBytes = await streamedResponse.stream.toBytes();
          
          // Manejar descompresión solo si es estrictamente necesario y los datos parecen comprimidos
          final encoding = streamedResponse.headers['content-encoding']?.toLowerCase();
          if (encoding == 'gzip') {
            try {
              rawBytes = GZipCodec().decode(rawBytes);
            } catch (e) {
              print('⚠️ [PROXY] Falló descompresión GZIP, quizás ya estaba descomprimido: $e');
            }
          } else if (encoding == 'deflate') {
            try {
              rawBytes = ZLibCodec().decode(rawBytes);
            } catch (e) {
              print('⚠️ [PROXY] Falló descompresión Deflate: $e');
            }
          }

          try {
            fullBody = utf8.decode(rawBytes);
          } catch (e) {
            print('⚠️ [PROXY][$requestId] No es texto válido UTF-8 o error de descompresión, sirviendo como stream binario');
            request.response.statusCode = streamedResponse.statusCode;
            streamedResponse.headers.forEach((key, value) {
              final k = key.toLowerCase();
              if (k != 'transfer-encoding' && k != 'content-encoding' && k != 'content-length') {
                request.response.headers.set(key, value);
              }
            });
            request.response.headers.set('Access-Control-Allow-Origin', '*');
            request.response.add(rawBytes);
            await request.response.close();
            client.close();
            return;
          }
          _manifestCache[cacheKey] = fullBody!;
          _manifestCacheTime[cacheKey] = now;
        }

        final requestHost =
            request.headers.value(HttpHeaders.hostHeader) ?? '$_localIp:$_port';
        final rewrittenBody = _rewriteM3u8(
          fullBody,
          url,
          headers,
          requestHost,
          algorithm: int.tryParse(algoParam ?? ''),
          remux: remuxParam,
          toCast: castParam,
          isAudioPlaylist: isAudioPlaylist,
        );

        request.response.headers.contentType = ContentType.parse(
          'application/vnd.apple.mpegurl',
        );
        request.response.add(utf8.encode(rewrittenBody));
        await request.response.close();
        client.close();
      } else {
        _serveStream(
          request,
          streamedResponse,
          null,
          streamedResponse.stream,
          algoParam,
          url,
          upstreamContentType,
          client,
          requestId,
          remux: remuxParam,
          toCast: castParam,
          isAudio: isAudioPlaylist,
        );
      }
    } catch (e, stack) {
      print('❌ [PROXY][$requestId] Error Crítico: $e');
      print('Stack: $stack');
      try {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
      } catch (_) {}
    }
  }



  void _serveStream(
    HttpRequest request,
    http.StreamedResponse response,
    List<int>? firstChunk,
    Stream<List<int>> stream,
    String? algoParam,
    String url,
    String upstreamContentType,
    http.Client client,
    String requestId, {
    bool remux = false,
    bool toCast = false,
    bool isAudio = false,
  }) async {
    request.response.statusCode = response.statusCode;

    // Copiar cabeceras base
    response.headers.forEach((key, value) {
      final k = key.toLowerCase();
      // Permitir cabeceras de rango y longitud para evitar corrupción en ExoPlayer
      if (k != 'transfer-encoding' && k != 'content-encoding') {
        request.response.headers.set(key, value);
      }
    });

    request.response.headers.set('Access-Control-Allow-Origin', '*');
    request.response.headers.set('Connection', 'keep-alive');

    // Flujo normal para otros archivos
    if (upstreamContentType.contains('image/')) {
      // El servidor disfraza el video/audio como imagen.
      // Usamos octet-stream para TODOS los segmentos (video y audio).
      // ExoPlayer del Chromecast hace byte-sniffing automático con octet-stream
      // y detecta correctamente si es MPEG-TS, fMP4, AAC, etc.
      request.response.headers.set('content-type', 'application/octet-stream');
    } else {
      request.response.headers.set('content-type', upstreamContentType);
    }
    if (firstChunk != null) request.response.add(firstChunk);
    try {
      await request.response.addStream(stream);
    } catch (e) {
      print('⚠️ [PROXY][$requestId] Stream interrupted by client/TV: $e');
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
      client.close();
    }
  }

  String _rewriteM3u8(
    String body,
    String baseUriStr,
    Map<String, String> headers,
    String requestHost, {
    int? algorithm,
    bool remux = false,
    bool toCast = false,
    bool isAudioPlaylist = false,
    String? bridgeId,
  }) {
    final baseUri = Uri.parse(baseUriStr);
    final lines = body.split('\n');
    final rewrittenLines = <String>[];
    bool hasEndList = false;
    final isMasterPlaylist = body.contains('#EXT-X-STREAM-INF');

    for (var line in lines) {
      final trimmedLine = line.trim();
      if (trimmedLine.isEmpty) continue;

      if (trimmedLine.startsWith('#')) {
        if (trimmedLine.contains('#EXT-X-ENDLIST')) hasEndList = true;
        if (trimmedLine.contains('#EXT-X-PLAYLIST-TYPE')) {
          // Ya tiene tipo de playlist, no tocar
        }

        if (trimmedLine.startsWith('#EXT-X-TARGETDURATION') &&
            !body.contains('#EXT-X-PLAYLIST-TYPE')) {
          rewrittenLines.add(trimmedLine);
          rewrittenLines.add('#EXT-X-PLAYLIST-TYPE:VOD');
          continue;
        }
        final uriMatch = RegExp(
          r'URI\s*=\s*"([^"]+)"',
          caseSensitive: false,
        ).firstMatch(trimmedLine);
        if (uriMatch != null) {
          final internalUrl = uriMatch.group(1)!;
          final absoluteUri = baseUri.resolve(internalUrl);
          // Detect if this URI is for an audio track
          final bool isAudioTrackUri = trimmedLine.contains('TYPE=AUDIO');
          final proxiedUrl = _buildProxiedUrl(
            absoluteUri.toString(),
            headers,
            requestHost,
            algorithm: algorithm,
            remux: remux,
            toCast: toCast,
            isAudioTrack: isAudioTrackUri,
            bridgeId: bridgeId,
          );
          
          String newLine = trimmedLine.replaceFirst(internalUrl, proxiedUrl);
          
          // Fuerza a que la pista de audio sea reproducida por defecto, 
          // ya que los reproductores (ExoPlayer) ignoran pistas con DEFAULT=NO
          if (newLine.contains('TYPE=AUDIO')) {
            newLine = newLine.replaceAll('DEFAULT=NO', 'DEFAULT=YES');
            newLine = newLine.replaceAll('AUTOSELECT=NO', 'AUTOSELECT=YES');
          }
          
          rewrittenLines.add(newLine);
        } else {
          rewrittenLines.add(trimmedLine);
        }
      } else {
        // Es un fragmento o un sub-manifiesto
        final absoluteUri = baseUri.resolve(trimmedLine);
        // Para segmentos: 
        //   - Video con Cast → '.ts' para que Chromecast use parser MPEG-TS
        //   - Audio con Cast → '' (sin extensión) para byte-sniffing de fMP4
        //   - Sin Cast (ExoPlayer) → '' (sin extensión, usa byte-sniffing)
        String? segExtension;
        if (!isMasterPlaylist) {
          segExtension = (toCast && !isAudioPlaylist) ? '.ts' : (toCast ? '.m4s' : '');
        }
        final proxiedUrl = _buildProxiedUrl(
          absoluteUri.toString(),
          headers,
          requestHost,
          algorithm: algorithm,
          remux: remux,
          toCast: toCast,
          isAudioTrack: isAudioPlaylist, // Propagar audio=1 a segmentos de audio
          extensionOverride: segExtension,
          bridgeId: bridgeId,
        );
        rewrittenLines.add(proxiedUrl);
      }
    }
    if (!hasEndList && !body.contains('#EXT-X-STREAM-INF')) {
      rewrittenLines.add('#EXT-X-ENDLIST');
    }
    return rewrittenLines.join('\n');
  }

  String _buildProxiedUrl(
    String url,
    Map<String, String>? headers,
    String host, {
    int? algorithm,
    bool remux = false,
    bool toCast = false,
    bool isAudioTrack = false,
    String? extensionOverride,
    String? bridgeId,
  }) {
    final bUrl = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
    String? bHeaders;
    
    // Si hay bridgeId, NUNCA meter headers en la URL (los sacaremos del registro interno)
    // Esto evita URLs gigantes que FFmpeg no puede parsear.
    if (bridgeId == null && headers != null && headers.isNotEmpty) {
      bHeaders = base64Url
          .encode(utf8.encode(jsonEncode(headers)))
          .replaceAll('=', '');
    }

    String extension = extensionOverride ?? '.mp4';
    final lowerUrl = url.toLowerCase();

    // Detección de HLS
    final bool isHls =
        lowerUrl.contains('.m3u8') ||
        lowerUrl.contains('playlist') ||
        lowerUrl.contains('master') ||
        lowerUrl.contains('cf-master') ||
        lowerUrl.contains('m3u8-proxy');

    if (extensionOverride == null && isHls) {
      extension = '.m3u8';
    }

    if (extensionOverride == null &&
        (lowerUrl.contains('.ts') || lowerUrl.contains('segment'))) {
      extension = remux ? '.mp4' : '.ts';
    }

    var proxyUrl = 'http://$host/proxy$extension?url=$bUrl';
    if (bHeaders != null) proxyUrl += '&h=$bHeaders';
    if (algorithm != null) proxyUrl += '&a=$algorithm';
    if (remux) proxyUrl += '&remux=1';
    if (toCast) proxyUrl += '&cast=1';
    if (isAudioTrack) proxyUrl += '&audio=1';
    if (bridgeId != null) proxyUrl += '&bid=$bridgeId';

    return proxyUrl;
  }

  Future<void> _handleLocalFileRequest(HttpRequest request) async {
    // Extraer el ID del path: /local/1234567890.mp4 → "1234567890"
    final segment = request.uri.path.split('/local/').last;
    final fileId = segment
        .replaceAll('.mp4', '')
        .replaceAll('.mkv', '')
        .replaceAll('.ts', '')
        .replaceAll('.m3u8', '');

    final filePath = _localFileRegistry[fileId];
    if (filePath == null) {
      print('❌ [LOCAL] ID no registrado: $fileId');
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    print('📂 [LOCAL] Sirviendo: $filePath (ID: $fileId)');
    await _serveLocalFile(request, filePath);
  }



  // --- SERVICIO DE ARCHIVOS LOCALES (Descargas) ---
  // Usa HTTP/1.0 manual para máxima compatibilidad con Smart TVs antiguas/estrictas.
  Future<void> _serveLocalFile(HttpRequest request, String path) async {
    final file = File(path);
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final size = await file.length();
    final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
    final contentType = 'video/mp4';

    // Desacoplamos el socket para escribir HTTP/1.0 manualmente
    final socket = await request.response.detachSocket(writeHeaders: false);

    try {
      int start = 0;
      int end = size - 1;
      int statusCode = 200;
      String statusText = 'OK';

      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final parts = rangeHeader.substring(6).split('-');
        start = int.parse(parts[0]);
        if (parts.length > 1 && parts[1].isNotEmpty) {
          end = int.parse(parts[1]).clamp(0, size - 1);
        }
        statusCode = 206;
        statusText = 'Partial Content';
      }

      final contentLength = end - start + 1;
      final headers = StringBuffer();
      headers.write('HTTP/1.0 $statusCode $statusText\r\n');
      headers.write('Content-Type: $contentType\r\n');
      headers.write('Content-Length: $contentLength\r\n');
      headers.write('Accept-Ranges: bytes\r\n');
      headers.write('Connection: close\r\n');
      headers.write('Access-Control-Allow-Origin: *\r\n');

      // Cabeceras DLNA optimizadas para Samsung
      headers.write(
        'contentFeatures.dlna.org: DLNA.ORG_PN=AVC_MP4_HP_HD_AAC;DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000\r\n',
      );
      headers.write('transferMode.dlna.org: Streaming\r\n');

      if (statusCode == 206) {
        headers.write('Content-Range: bytes $start-$end/$size\r\n');
      }
      headers.write('\r\n');

      socket.add(utf8.encode(headers.toString()));

      if (request.method != 'HEAD') {
        // Usamos una lectura controlada para evitar ruidos de SocketException
        try {
          await file.openRead(start, end + 1).pipe(socket);
        } catch (_) {
          // Es normal que la TV cierre la conexión abruptamente al cambiar de posición o al inicio
        }
      }
    } catch (e) {
      if (!e.toString().contains('Connection reset')) {
        print('❌ [PROXY] Error crítico en servidor HTTP/1.0: $e');
      }
    } finally {
      try {
        await socket.close();
      } catch (_) {}
    }
  }



  String getProxiedUrl(
    String url,
    Map<String, String>? headers, {
    bool useLocalhost = false,
    int? algorithm,
    bool remux = false,
    bool toCast = false,
  }) {
    if (algorithm == 3 && !toCast) {
      // Para reproducción local en algoritmo 3, devolvemos la URL original.
      // El reproductor (ExoPlayer) manejará las cabeceras directamente.
      print('⏩ [PROXY] Algoritmo 3 Detectado (Local): Bypass activo');
      return url;
    }

    String host = (useLocalhost || _localIp.isEmpty)
        ? '127.0.0.1:$_port'
        : '$_localIp:$_port';
    return _buildProxiedUrl(
      url,
      headers,
      host,
      algorithm: algorithm,
      remux: remux,
      toCast: toCast,
    );
  }

  Future<void> _refreshLocalIp({String? targetIp}) async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      String? fallbackIp;
      print('🌐 [PROXY] Escaneando interfaces de red...');

      for (var iface in interfaces) {
        for (var addr in iface.addresses) {
          final ip = addr.address;
          if (ip == '127.0.0.1') continue;
          print('  • Interfaz: ${iface.name} | IP: $ip');

          // 1. Prioridad máxima: Misma subred que la TV (ej: 192.168.1.X == 192.168.1.Y)
          if (targetIp != null) {
            final tParts = targetIp.split('.');
            final iParts = ip.split('.');
            if (tParts.length >= 3 && iParts.length >= 3) {
              if (tParts[0] == iParts[0] &&
                  tParts[1] == iParts[1] &&
                  tParts[2] == iParts[2]) {
                print('  🎯 [MATCH] IP en la misma subred que la TV: $ip');
                _localIp = ip;
                return;
              }
            }
          }

          // 2. Segunda prioridad: Redes 192.168.X.X (WiFi estándar)
          if (ip.startsWith('192.168.')) {
            _localIp = ip;
            print('  🏠 [MATCH] IP de WiFi detectada: $ip');
            return;
          }

          // 3. Tercera prioridad: Redes 172.X.X.X o 10.X.X.X
          if (ip.startsWith('172.') || ip.startsWith('10.')) {
            fallbackIp = ip;
          }
        }
      }

      if (fallbackIp != null) {
        _localIp = fallbackIp;
        print('  ⚠️ [FALLBACK] Usando IP secundaria: $fallbackIp');
      }
    } catch (e) {
      print('❌ [PROXY] Error obteniendo interfaces: $e');
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = 0;
  }

  // --- NUEVA HERRAMIENTA A3: PROXY POR REGISTRO (SIN URLS LARGAS) ---

  String registerA3(String url, Map<String, String> headers, {bool toCast = false}) {
    final id = url.hashCode.abs().toString();
    final uri = Uri.parse(url);
    var baseUrl = uri.replace(pathSegments: uri.pathSegments.take(math.max(0, uri.pathSegments.length - 1)).toList()).toString();
    if (!baseUrl.endsWith('/')) baseUrl += '/';
    
    final proxyUrl = 'http://$_localIp:$_port/a3/$id/index.m3u8';
    _a3Registry[id] = _A3Entry(url, headers, baseUrl, toCast: toCast);
    print('🆔 [A3_REGISTRY] Registrado ID: $id (toCast: $toCast)');
    print('🔗 [A3_PROXY_URL] $proxyUrl');
    return proxyUrl;
  }

  Future<void> _handleA3Request(HttpRequest request) async {
    final pathParts = request.uri.path.split('/');
    if (pathParts.length < 4) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final String id = pathParts[2];
    final String filename = pathParts.skip(3).join('/');
    final entry = _a3Registry[id];

    // 🛡️ MANEJAR CORS PRE-FLIGHT (Solo si es para Cast)
    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.headers.set('Access-Control-Allow-Methods', 'GET, HEAD, POST, OPTIONS');
      request.response.headers.set('Access-Control-Allow-Headers', '*');
      request.response.headers.set('Access-Control-Max-Age', '86400');
      await request.response.close();
      return;
    }

    if (entry == null) {
      print('❌ [A3_PROXY] ID no encontrado: $id');
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    String targetUrl;
    if (filename == 'index.m3u8' || filename.isEmpty) {
      targetUrl = entry.url;
    } else {
      targetUrl = Uri.parse(entry.baseUrl).resolve(filename).toString();
    }

    print('📡 [A3_PROXY] Solicitando: $filename -> $targetUrl');

    final Map<String, String> proxyHeaders = Map<String, String>.from(entry.headers);

    // Copiar cabeceras de la petición (Solo si NO es Cast o si no son sensibles)
    request.headers.forEach((name, values) {
      final n = name.toLowerCase();
      bool shouldCopy = true;
      if (entry.toCast) {
         // En Cast protegemos cabeceras de sesión
         if (n == 'host' || n == 'connection' || n == 'referer' || n == 'user-agent' || n == 'origin') {
            shouldCopy = false;
         }
      } else {
         // En Exoplayer copiamos casi todo
         if (n == 'host' || n == 'connection') shouldCopy = false;
      }
      
      if (shouldCopy) {
         proxyHeaders[name] = values.join(', ');
      }
    });

    final requestId = 'A3-${id.substring(math.max(0, id.length - 4))}-${DateTime.now().millisecondsSinceEpoch.toString().substring(10)}';
    // print('📡 [A3_PROXY][$requestId] -> $targetUrl');

    try {
      final client = http.Client();
      final proxyRequest = http.Request(request.method, Uri.parse(targetUrl));
      proxyHeaders.forEach((k, v) => proxyRequest.headers[k] = v);
      proxyRequest.followRedirects = true;

      final streamedResponse = await client.send(proxyRequest);
      final finalTargetUrl = streamedResponse.request?.url.toString() ?? targetUrl;
      
      // 🔄 ACTUALIZAR BASE URL SI HUBO REDIRECCIÓN (Importante para Videasy)
      if (streamedResponse.headers.containsKey('location') || (finalTargetUrl != targetUrl)) {
         final finalUri = Uri.parse(finalTargetUrl);
         var newBaseUrl = finalUri.replace(pathSegments: finalUri.pathSegments.take(math.max(0, finalUri.pathSegments.length - 1)).toList()).toString();
         if (!newBaseUrl.endsWith('/')) newBaseUrl += '/';
         
         if (entry.baseUrl != newBaseUrl && !targetUrl.contains('/s/')) {
            _a3Registry[id] = _A3Entry(entry.url, entry.headers, newBaseUrl);
            // print('🔄 [A3_PROXY] BaseUrl actualizada: $newBaseUrl');
         }
      }

      // Pasar status code (importante para 206 Partial Content)
      request.response.statusCode = streamedResponse.statusCode;
      
      // CORS universal para compatibilidad con WVC, DLNA, Chromecast
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.headers.set('Access-Control-Allow-Methods', 'GET, HEAD, POST, OPTIONS');
      request.response.headers.set('Access-Control-Allow-Headers', '*');
      request.response.headers.set('Access-Control-Expose-Headers', '*');
      // Accept-Ranges requerido por DLNA y algunos Chromecast
      request.response.headers.set('Accept-Ranges', 'bytes');
      
      // Para manifiestos: reescribir rutas relativas a URLs absolutas del proxy
      if (filename.contains('.m3u8') || filename.isEmpty) {
        request.response.headers.contentType = ContentType.parse('application/vnd.apple.mpegurl');
        final body = await streamedResponse.stream.bytesToString();
        final proxyBase = 'http://$_localIp:$_port/a3/$id/';
        final rewritten = _rewriteM3u8Segments(body, proxyBase);
        print('📝 [A3_MANIFEST] Reescrito (${rewritten.length} chars). Base: $proxyBase');
        request.response.headers.set('Content-Length', rewritten.length.toString());
        if (request.method != 'HEAD') {
          request.response.write(rewritten);
        }
        await request.response.close();
      } else {
        // Para segmentos .ts: pipe directo con content-type correcto
        request.response.headers.contentType = ContentType.parse(
            filename.endsWith('.ts') ? 'video/mp2t'
            : (streamedResponse.headers['content-type'] ?? 'application/octet-stream'));
        final contentLength = streamedResponse.headers['content-length'];
        if (contentLength != null) {
          request.response.headers.set('Content-Length', contentLength);
        }
        await request.response.addStream(streamedResponse.stream);
        await request.response.close();
      }
      client.close();
    } catch (e) {
      // print('❌ [A3_PROXY] Error en $targetUrl: $e');
      try {
        request.response.statusCode = HttpStatus.serviceUnavailable;
        await request.response.close();
      } catch (_) {}
    }
  }

  /// Reescribe las rutas relativas de segmentos en un manifiesto HLS
  /// convirtiéndolas en URLs absolutas del proxy local.
  /// Esto permite que receptores externos (Chromecast, TV) resuelvan los
  /// segmentos correctamente sin depender del base URL del manifiesto.
  String _rewriteM3u8Segments(String body, String proxyBase) {
    final lines = body.split('\n');
    final result = <String>[];
    for (final line in lines) {
      final trimmed = line.trim();
      // Líneas vacías, comentarios y directivas → sin cambio
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        result.add(line);
        continue;
      }
      // Líneas que ya son URLs absolutas → sin cambio
      if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
        result.add(line);
        continue;
      }
      // Ruta relativa de segmento → convertir a URL absoluta del proxy
      result.add('$proxyBase$trimmed');
    }
    return result.join('\n');
  }

  // --- LÓGICA DE BRIDGE (FUSIÓN VIDEO + AUDIO) ---

  String registerBridge(String videoUrl, String audioUrl, Map<String, String> headers) {
    final id = (videoUrl + audioUrl).hashCode.abs().toString();
    _bridgeRegistry[id] = _BridgeEntry(videoUrl, audioUrl, headers);
    final bridgeUrl = 'http://$_localIp:$_port/bridge/$id/stream.ts';
    print('🚀 [BRIDGE_REGISTRY] Registrado ID: $id');
    print('🔗 [BRIDGE_URL] $bridgeUrl');
    return bridgeUrl;
  }

  Future<void> _handleBridgeRequest(HttpRequest request) async {
    final pathParts = request.uri.path.split('/');
    if (pathParts.length < 3) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    final String id = pathParts[2];
    final entry = _bridgeRegistry[id];

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.headers.set('Access-Control-Allow-Methods', 'GET, HEAD, POST, OPTIONS');
      request.response.headers.set('Access-Control-Allow-Headers', '*');
      await request.response.close();
      return;
    }

    if (entry == null) {
      print('❌ [BRIDGE] ID no encontrado: $id');
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    print('🎬🎬🎬 [BRIDGE_REQUEST] RECIBIDA PETICIÓN DE FUSIÓN');
    print('   ID: $id');
    
    final videoUnproxied = MediaProxyService.tryUnproxy(entry.videoUrl);
    final audioUnproxied = MediaProxyService.tryUnproxy(entry.audioUrl);
    
    final originalVideoUrl = videoUnproxied?['url'] ?? entry.videoUrl;
    final originalAudioUrl = audioUnproxied?['url'] ?? entry.audioUrl;
    
    final Map<String, String> combinedHeaders = {};
    if (videoUnproxied != null) combinedHeaders.addAll(Map<String, String>.from(videoUnproxied['headers'] ?? {}));
    if (audioUnproxied != null) combinedHeaders.addAll(Map<String, String>.from(audioUnproxied['headers'] ?? {}));
    combinedHeaders.addAll(entry.headers);

    // Limpiar headers: Si viene un User-Agent de FFmpeg (Lavf), ignorarlo 
    // y usar uno de navegador real para no ser bloqueados.
    final String currentUA = combinedHeaders['User-Agent'] ?? combinedHeaders['user-agent'] ?? '';
    if (currentUA.contains('Lavf')) {
      combinedHeaders.remove('User-Agent');
      combinedHeaders.remove('user-agent');
    }

    // Guardar headers en el registro para el proxy
    _bridgeInputHeaders[id] = combinedHeaders;

    // Generar URLs de proxy LIMPIAS (sin cabeceras en el path) para FFmpeg
    // El proxy usará el bridgeId para recuperar las cabeceras.
    final proxiedVideoUrlForFfmpeg = _buildProxiedUrl(
      originalVideoUrl,
      null, // No inyectar headers en la URL
      '127.0.0.1:$_port',
      bridgeId: id,
    );
    final proxiedAudioUrlForFfmpeg = _buildProxiedUrl(
      originalAudioUrl,
      null, // No inyectar headers en la URL
      '127.0.0.1:$_port',
      bridgeId: id,
    );

    ServerSocket? serverSocket;
    final socketCompleter = Completer<Socket>();

    try {
      serverSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final bridgePort = serverSocket.port;
      
      serverSocket.listen((socket) {
        if (!socketCompleter.isCompleted) {
          socketCompleter.complete(socket);
        }
      }, onError: (e) {
        if (!socketCompleter.isCompleted) socketCompleter.completeError(e);
      });

      // Comando FFmpeg con URLs de proxy local cortas y limpias
      final command = '-y '
          '-protocol_whitelist file,http,tcp,https,tls,crypto '
          '-allowed_extensions ALL '
          '-i "$proxiedVideoUrlForFfmpeg" '
          '-i "$proxiedAudioUrlForFfmpeg" '
          '-c:v copy -c:a aac -b:a 192k '
          '-map 0:v:0 -map 1:a:0 '
          '-f mpegts '
          'tcp://127.0.0.1:$bridgePort';

      print('🚀 [BRIDGE] Ejecutando fusión via PROXY LOCAL: ffmpeg $command');

      FFmpegKit.executeAsync(command, (session) async {
        final state = await session.getState();
        final returnCode = await session.getReturnCode();
        
        if (!ReturnCode.isSuccess(returnCode)) {
          print('❌ [BRIDGE] FFmpeg Error (Code: $returnCode)');
          final logs = await session.getLogs();
          for (var log in logs.take(15)) {
             print('      [FFMPEG] ${log.getMessage()}');
          }
        }
        
        print('🏁 [BRIDGE] FFmpeg finalizado: $state');
        if (!socketCompleter.isCompleted) {
          socketCompleter.completeError('FFmpeg finalizó antes de conectar');
        }
        serverSocket?.close();
      });

      final ffmpegSocket = await socketCompleter.future.timeout(const Duration(seconds: 20));
      
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.headers.contentType = ContentType.parse('video/MP2T');
      request.response.headers.set('Connection', 'keep-alive');
      request.response.headers.set('Cache-Control', 'no-cache');

      await request.response.addStream(ffmpegSocket);
      await request.response.close();
      print('✅ [BRIDGE] Stream finalizado correctamente');
    } catch (e) {
      print('❌ [BRIDGE] Error en flujo: $e');
      serverSocket?.close();
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (_) {}
    }
  }
}

class _A3Entry {
  final String url;
  final Map<String, String> headers;
  final String baseUrl;
  final bool toCast;

  _A3Entry(this.url, this.headers, this.baseUrl, {this.toCast = false});
}

class _BridgeEntry {
  final String videoUrl;
  final String audioUrl;
  final Map<String, String> headers;

  _BridgeEntry(this.videoUrl, this.audioUrl, this.headers);
}


