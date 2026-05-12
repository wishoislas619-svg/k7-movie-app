import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;

class MediaProxyService {
  static final MediaProxyService _instance = MediaProxyService._internal();
  factory MediaProxyService() => _instance;
  MediaProxyService._internal();

  static String? lastCookies;
  static String? deviceUserAgent;

  HttpServer? _server;
  int _port = 0;
  String _localIp = '';
  final Map<String, _BridgeSession> _activeBridgeSessions = {};
  final Map<String, Map<String, String>> _pendingBridgeHeaders = {};
  final Map<String, String> _localFileRegistry = {}; // fileId → filePath
  final Map<String, String> _remuxedFiles = {}; // originalPath → remuxedPath
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
      if (!proxiedUrl.contains('/proxy') && !proxiedUrl.contains('/bridge'))
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
        if (request.uri.path.startsWith('/bridge')) {
          _handleBridgeRequest(request);
        } else if (request.uri.path.startsWith('/local/')) {
          _handleLocalFileRequest(request);
        } else if (request.uri.path.startsWith('/proxy')) {
          _handleProxyRequest(request);
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
    final bid = request.uri.queryParameters['bid']; // Bridge ID

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

    // 2. Cabeceras proxiadas (Inyectadas por el extractor)
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

    // 💡 REUPERAR HEADERS DE MEMORIA (para el puente)
    if (bid != null && _pendingBridgeHeaders.containsKey(bid)) {
      print('📥 [PROXY] Recovering headers for bridge bid: $bid');
      headers.addAll(_pendingBridgeHeaders[bid]!);
    }

    print('🔍 [PROXY][$requestId] Request: $url');

    final bool forceBridge = request.uri.queryParameters['bridge'] == '1';

    // 🌉 AUTO-BRIDGE: Ahora solo se activa si se solicita explícitamente (generalmente desde el Cast)
    if (bid == null && forceBridge) {
      print('🌉 [PROXY_BRIDGE] Activando modo Puente MP4 (Cast)...');
      if (isManifestRequest) {
        _handleBridgeRequest(request, encodedUrl, encodedHeaders);
      } else {
        final manifestUrl = _manifestUrlFromSegment(url);
        if (manifestUrl == null) {
          request.response.statusCode = HttpStatus.badRequest;
          request.response.write('Bridge requiere manifiesto HLS');
          await request.response.close();
          return;
        }
        final manifestEncoded = base64Url
            .encode(utf8.encode(manifestUrl))
            .replaceAll('=', '');
        print(
          '🔁 [PROXY_BRIDGE] Segmento convertido a manifiesto: $manifestUrl',
        );
        _handleBridgeRequest(request, manifestEncoded, encodedHeaders);
      }
      return;
    }

    if (isManifestRequest && bid != null) {
      // Si ya tiene bid, es una petición interna del bridge, no re-procesar.
    }

    // Si ya viene con un bid, es que es una petición interna del bridge,
    // por lo que debe continuar hacia el proxy estándar sin volver a disparar el bridge.

    // 📂 SERVIR ARCHIVO LOCAL: Si la URL no empieza por http, es un path de sistema
    if (!url.startsWith('http')) {
      await _serveLocalFile(request, url);
      return;
    }

    try {
      final client = http.Client();
      final proxyRequest = http.Request(request.method, Uri.parse(url));
      headers.forEach((k, v) => proxyRequest.headers[k] = v);
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
          // print('♻️ [PROXY][$requestId] Manifest Cache Hit');
        }

        if (fullBody == null) {
          fullBody = await streamedResponse.stream.bytesToString();
          _manifestCache[cacheKey] = fullBody;
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
          bid: bid,
          remux: remuxParam,
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

  String? _manifestUrlFromSegment(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;

    final segments = uri.pathSegments;
    if (segments.isEmpty) return null;

    final last = segments.last.toLowerCase();
    final looksLikeSegment =
        last.endsWith('.ts') &&
        (last.startsWith('seg-') || last.contains('-v') || last.contains('-a'));
    if (!looksLikeSegment) return null;

    final manifestSegments = [...segments]
      ..[segments.length - 1] = 'index.m3u8';
    return uri.replace(pathSegments: manifestSegments).toString();
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

    // Remuxamos fragmentos TS a MP4 para máxima compatibilidad con Smart TVs.
    // El video se mantiene en copy, el audio se transcodifica a AAC si es necesario.
    final shouldRemux = remux;

    if (shouldRemux &&
        (url.contains('.ts') ||
            url.contains('segment') ||
            upstreamContentType.contains('mp2t'))) {
      print(
        '🎬 [REMUX][$requestId] Converting fragment to MP4 for Smart TV...',
      );
      try {
        final List<int> bytes = [];
        if (firstChunk != null) bytes.addAll(firstChunk);
        await for (var chunk in stream) {
          bytes.addAll(chunk);
        }

        final tempDir = await getTemporaryDirectory();
        final inputPath = '${tempDir.path}/in_$requestId.ts';
        final outputPath = '${tempDir.path}/out_$requestId.mp4';

        await File(inputPath).writeAsBytes(bytes);

        // Re-codificamos audio a AAC para asegurar que el AudioSpecificConfig sea válido (evita fallos en Media3)
        // El video se mantiene en copy para no perder rendimiento.
        final ffmpegCommand =
            '-i "$inputPath" -c:v copy -c:a aac -b:a 128k -f mp4 -movflags frag_keyframe+empty_moov+default_base_moof -y "$outputPath"';

        final session = await FFmpegKit.execute(ffmpegCommand);
        final returnCode = await session.getReturnCode();

        if (ReturnCode.isSuccess(returnCode)) {
          final convertedBytes = await File(outputPath).readAsBytes();
          request.response.headers.set('content-type', 'video/mp4');
          request.response.headers.contentLength = convertedBytes.length;
          request.response.add(convertedBytes);
          print('✅ [REMUX][$requestId] Success! Sent as MP4');
        } else {
          request.response.headers.set('content-type', 'video/MP2T');
          request.response.add(bytes);
        }

        try {
          await File(inputPath).delete();
          await File(outputPath).delete();
        } catch (_) {}
      } catch (e) {
        print('⚠️ [REMUX][$requestId] Error: $e');
      } finally {
        await request.response.close();
        client.close();
      }
      return;
    }

    // Flujo normal para otros archivos
    if (url.toLowerCase().contains('.ts') ||
        upstreamContentType.contains('mp2t') ||
        upstreamContentType.contains('mpegts')) {
      request.response.headers.set('content-type', 'video/MP2T');
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

  // --- LÓGICA DE PUENTE (TRANSCODING STREAM COMPLETO) ---
  void _handleBridgeRequest(
    HttpRequest request, [
    String? overrideUrl,
    String? overrideHeaders,
  ]) async {
    final encodedUrl = overrideUrl ?? request.uri.queryParameters['url'];
    final encodedHeaders = overrideHeaders ?? request.uri.queryParameters['h'];

    if (encodedUrl == null) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('Falta URL');
      await request.response.close();
      return;
    }

    String normalize(String s) {
      int pad = 4 - (s.length % 4);
      if (pad < 4 && pad > 0) s += '=' * pad;
      return s;
    }

    final requestId = DateTime.now().millisecondsSinceEpoch
        .toString()
        .substring(7);
    final String hlsUrl = utf8.decode(base64Url.decode(normalize(encodedUrl)));
    final bool videoOnly = request.uri.queryParameters['videoOnly'] == '1';
    final String bridgeKey = videoOnly ? '$hlsUrl#videoOnly' : hlsUrl;

    _BridgeSession? currentSession = _activeBridgeSessions[bridgeKey];
    String? pipePath;

    if (currentSession != null) {
      print('♻️ [BRIDGE] Reusing session for: $bridgeKey');
      pipePath = currentSession.filePath;
    } else {
      final tempDir = await getTemporaryDirectory();
      pipePath = '${tempDir.path}/bridge_${requestId}.mp4';

      // 🧠 MEMORIA DE CABECERAS: Guardar para FFmpeg
      if (encodedHeaders != null) {
        try {
          final decoded = json.decode(
            utf8.decode(base64Url.decode(normalize(encodedHeaders))),
          );
          if (decoded is Map) {
            _pendingBridgeHeaders[requestId] = Map<String, String>.from(
              decoded,
            );
          }
        } catch (_) {}
      }

      // 🚀 COMANDO CORTO: Usamos la IP REAL y un ID de referencia (bid)
      // Esto evita que el comando sea demasiado largo y falle en Android.
      final localProxyUrl =
          'http://$_localIp:$_port/proxy.m3u8?url=$encodedUrl&bid=$requestId';

      FFmpegKitConfig.enableLogCallback((log) {
        final message = log.getMessage();
        if (message.contains('Error') ||
            message.contains('Invalid') ||
            message.contains('Could not') ||
            message.contains('Conversion failed') ||
            message.contains('http') ||
            message.contains('Protocol')) {
          print('🎬 [FFMPEG-LOG] $message');
        }
      });

      // Usamos MP4 fragmentado. Para ExoPlayer en algoritmo 3 podemos ignorar
      // audio corrupto del proveedor y desbloquear la imagen.
      // 🚀 OPTIMIZACIÓN FINAL: Quitamos el '?' del filtro BSF que causaba error y forzamos el formato HLS.
      final streamMapping = videoOnly
          ? '-map 0:v:0? -c:v copy -an'
          : '-analyzeduration 1000000 -probesize 1000000 -map 0:v:0? -map 0:a:0? -c:v copy -c:a copy -bsf:a aac_adtstoasc';
      
      final ffmpegCommand =
          '-fflags +genpts+discardcorrupt -err_detect ignore_err -f hls -allowed_extensions ALL -i "$localProxyUrl" $streamMapping -sn -dn -map_metadata -1 -f mp4 -movflags frag_keyframe+empty_moov+default_base_moof+frag_discont+isml -y "$pipePath"';
      print(
          '🌉 [BRIDGE][$requestId] Starting Bridge (${videoOnly ? 'Video only' : 'Audio+Video'}): $hlsUrl');
      print('🎬 [BRIDGE] Command: ffmpeg $ffmpegCommand');

      final session = await FFmpegKit.executeAsync(ffmpegCommand);
      currentSession = _BridgeSession(session, pipePath);
      _activeBridgeSessions[bridgeKey] = currentSession;
    }

    try {
      // --- CÁLCULO DE DURACIÓN PARA EL SEEK DEL RECEPTOR ---
      double totalDuration = 0;
      try {
        final Map<String, String> mHeaders = {};
        if (encodedHeaders != null) {
          final decoded = json.decode(
            utf8.decode(base64Url.decode(normalize(encodedHeaders))),
          );
          if (decoded is Map)
            mHeaders.addAll(Map<String, String>.from(decoded));
        }

        totalDuration = await getHlsDuration(hlsUrl, headers: mHeaders);

        if (totalDuration > 0) {
          print(
            '⏱️ [BRIDGE] Duración total detectada: ${totalDuration.toStringAsFixed(2)}s',
          );
        }
      } catch (e) {
        print('⚠️ [BRIDGE] No se pudo calcular la duración: $e');
      }

      request.response.headers.set('Content-Type', 'video/mp4');
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.headers.set(
        'Accept-Ranges',
        'bytes',
      ); // Habilitar bytes para que la TV intente seek
      request.response.headers.set('Connection', 'keep-alive');

      if (totalDuration > 0) {
        final durStr = totalDuration.toStringAsFixed(2);
        request.response.headers.set('X-Content-Duration', durStr);
        request.response.headers.set('Content-Duration', durStr);
        request.response.headers.set(
          'X-VOD-Duration',
          durStr,
        ); // Cabecera adicional para algunos receptores
      }

      final file = File(pipePath);
      int retry = 0;
      // Esperar hasta 8 segundos (80 * 100ms) para que el archivo empiece a tener contenido
      while (!(await file.exists() && (await file.length()) > 0) && retry < 80) {
        await Future.delayed(Duration(milliseconds: 100));
        retry++;
      }

      int lastPos = 0;
      int idleCount = 0;
      int totalSent = 0;

      while (true) {
        if (await file.exists()) {
          final currentLength = await file.length();
          if (currentLength > lastPos) {
            idleCount = 0;
            final raf = await file.open();
            await raf.setPosition(lastPos);
            final buffer = await raf.read(currentLength - lastPos);
            await raf.close();

            request.response.add(buffer);
            await request.response.flush();

            totalSent += buffer.length;
            lastPos = currentLength;

            if (lastPos % 100000 == 0) {
              // Loguear cada ~100KB para no saturar
              print(
                '📡 [BRIDGE][$requestId] Sent: ${(totalSent / 1024 / 1024).toStringAsFixed(2)} MB',
              );
            }
          } else {
            idleCount++;
            final returnCode = await currentSession.ffmpegSession
                .getReturnCode();
            if (returnCode != null && idleCount > 100) {
              print('🏁 [BRIDGE] FFmpeg finished (Code: $returnCode)');
              break;
            }
            await Future.delayed(Duration(milliseconds: 100));
          }
        } else {
          await Future.delayed(Duration(milliseconds: 100));
        }
      }
    } catch (e) {
      print('❌ [BRIDGE] Request interrupted: $e');
    } finally {
      // SOLO eliminamos la sesión del mapa si nosotros somos los dueños (el pipePath coincide con el requestId)
      if (pipePath.contains(requestId)) {
        _activeBridgeSessions.remove(bridgeKey);
        print('🏁 [BRIDGE] Main session cleaned up');
      }
      await request.response.close();
    }
  }

  String _rewriteM3u8(
    String body,
    String baseUriStr,
    Map<String, String> headers,
    String requestHost, {
    int? algorithm,
    String? bid,
    bool remux = false,
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
          final proxiedUrl = _buildProxiedUrl(
            absoluteUri.toString(),
            headers,
            requestHost,
            algorithm: algorithm,
            bid: bid,
            remux: remux,
          );
          rewrittenLines.add(trimmedLine.replaceFirst(internalUrl, proxiedUrl));
        } else {
          rewrittenLines.add(trimmedLine);
        }
      } else {
        // Es un fragmento o un sub-manifiesto
        final absoluteUri = baseUri.resolve(trimmedLine);
        final proxiedUrl = _buildProxiedUrl(
          absoluteUri.toString(),
          headers,
          requestHost,
          algorithm: algorithm,
          bid: bid,
          remux: remux,
          extensionOverride: isMasterPlaylist ? null : '.ts',
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
    String? bid,
    bool remux = false,
    bool useBridge = false,
    bool bridgeVideoOnly = false,
    String? extensionOverride,
  }) {
    final bUrl = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
    String? bHeaders;
    if (headers != null && headers.isNotEmpty) {
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

    if (extensionOverride == null && isHls && !useBridge) {
      extension = '.m3u8';
    }

    if (extensionOverride == null && useBridge) {
      extension = '.mp4';
    }

    if (extensionOverride == null &&
        !useBridge &&
        (lowerUrl.contains('.ts') || lowerUrl.contains('segment'))) {
      // Cuando FFmpeg consume un HLS reescrito por el bridge, los segmentos
      // deben conservar extensión TS. Si se anuncian como MP4, FFmpeg rechaza
      // el MPEG-TS aunque el contenido sea válido.
      extension = remux ? '.mp4' : '.ts';
    }

    var proxyUrl = 'http://$host/proxy$extension?url=$bUrl';
    if (bHeaders != null) proxyUrl += '&h=$bHeaders';
    if (algorithm != null) proxyUrl += '&a=$algorithm';
    if (bid != null) proxyUrl += '&bid=$bid';
    if (remux) proxyUrl += '&remux=1';
    if (useBridge) proxyUrl += '&bridge=1';
    if (bridgeVideoOnly) proxyUrl += '&videoOnly=1';

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

  /// Remuxea un archivo local a un MP4 fragmentado real.
  Future<String?> remuxLocalFile(String inputPath, String fileId) async {
    if (_remuxedFiles.containsKey(inputPath)) {
      final cachedPath = _remuxedFiles[inputPath]!;
      if (await File(cachedPath).exists()) {
        print('🎬 [LOCAL_REMUX] Usando archivo en caché: $cachedPath');
        return cachedPath;
      }
    }

    final tempDir = await getTemporaryDirectory();
    final outputPath = '${tempDir.path}/remux_$fileId.mp4';

    print(
      '🎬 [LOCAL_REMUX] Convirtiendo contenedor a MP4 real (H264 + AAC): $fileId',
    );

    final command =
        '-i "$inputPath" -c:v copy -c:a aac -b:a 128k -threads 0 -f mp4 -movflags faststart -y "$outputPath"';

    // Habilitar logs para diagnóstico en tiempo real
    FFmpegKitConfig.enableLogCallback((log) {
      if (log.getMessage().contains('Error') ||
          log.getMessage().contains('fail')) {
        print('🎥 [FFMPEG_LOG] ${log.getMessage()}');
      }
    });

    final session = await FFmpegKit.execute(command);
    final returnCode = await session.getReturnCode();

    if (ReturnCode.isSuccess(returnCode)) {
      print('✅ [LOCAL_REMUX] Éxito: $outputPath');
      _remuxedFiles[inputPath] = outputPath;
      return outputPath;
    } else {
      print('❌ [LOCAL_REMUX] Falló remuxing, se servirá original');
      return null;
    }
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

  /// Obtiene la duración de un archivo local en segundos usando ffprobe.
  Future<double> getFileDuration(String path) async {
    try {
      final session = await FFprobeKit.execute(
        '-v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$path"',
      );
      final output = await session.getOutput();
      if (output != null) {
        return double.tryParse(output.trim()) ?? 0;
      }
    } catch (e) {
      print('❌ [PROXY] Error obteniendo duración del archivo: $e');
    }
    return 0;
  }

  String getProxiedUrl(
    String url,
    Map<String, String>? headers, {
    bool useLocalhost = false,
    int? algorithm,
    bool remux = false,
    bool useBridge = false,
    bool bridgeVideoOnly = false,
  }) {
    String host = (useLocalhost || _localIp.isEmpty)
        ? '127.0.0.1:$_port'
        : '$_localIp:$_port';
    return _buildProxiedUrl(
      url,
      headers,
      host,
      algorithm: algorithm,
      remux: remux,
      useBridge: useBridge,
      bridgeVideoOnly: bridgeVideoOnly,
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
}

class _BridgeSession {
  final dynamic ffmpegSession;
  final String filePath;
  _BridgeSession(this.ffmpegSession, this.filePath);
}
