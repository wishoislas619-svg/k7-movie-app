import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:ffmpeg_kit_flutter_new_https_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_https_gpl/return_code.dart';
import 'package:path_provider/path_provider.dart';

class MediaProxyService {
  static final MediaProxyService _instance = MediaProxyService._internal();
  factory MediaProxyService() => _instance;
  MediaProxyService._internal();

  static String? lastCookies;
  static String? deviceUserAgent;
  String _sessionCookies = ''; // cookies seteadas por el CDN (Set-Cookie)
  String _lastOriginCookie = ''; // cookie del extractor para re-combinar


  // --- Streaming FFmpeg (progresivo) ---
  final Map<String, _FfmpegStream> _activeStreams = {};
  String? _streamsDir;

  Future<String> _ensureStreamsDir() async {
    if (_streamsDir != null) return _streamsDir!;
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/streams');
    if (!await dir.exists()) await dir.create(recursive: true);
    _streamsDir = dir.path;
    return dir.path;
  }

  /// Inicia FFmpeg para remuxear HLS → MKV progresivo.
  /// Retorna inmediatamente con el ID del stream (no espera a que FFmpeg produzca datos).
  Future<String> startFfmpegStream(
    String url,
    Map<String, String> headers,
  ) async {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final outDir = await _ensureStreamsDir();
    final outputPath = '$outDir/$id.mp4';

    // Construir cabeceras HTTP para FFmpeg (-headers)
    final headerLines = <String>[];
    for (final key in ['User-Agent', 'Referer', 'Cookie', 'Origin', 'Accept', 'Accept-Language']) {
      final val = headers[key];
      if (val != null && val.isNotEmpty) {
        headerLines.add('$key: $val');
      }
    }
    final headerStr = headerLines.join('\\r\\n');

    // FFmpeg: remux HLS → MP4 fragmentado (streaming progresivo, soporte universal)
    // -movflags +frag_keyframe+empty_moov crea un MP4 que se puede leer mientras se escribe
    final cmd = '-y -headers "$headerStr\\r\\n" -i "$url" -c copy -f mp4 -movflags +frag_keyframe+empty_moov "$outputPath"';
    print('🎬 [FFMPEG] Starting stream $id: $cmd');

    _activeStreams[id] = _FfmpegStream(
      id: id,
      outputPath: outputPath,
    );

    FFmpegKit.executeAsync(cmd, (session) async {
      final rc = await session.getReturnCode();
      final isOk = ReturnCode.isSuccess(rc);
      print('🎬 [FFMPEG] Stream $id ended: rc=$rc success=$isOk');
      final entry = _activeStreams[id];
      if (entry != null) {
        entry.isComplete = true;
        entry.completer.complete();
      }
    });

    return id;
  }

  Future<void> _handleFfmpegStream(HttpRequest request) async {
    final id = request.uri.pathSegments.last;
    final entry = _activeStreams[id];
    if (entry == null) {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }

    final file = File(entry.outputPath);
    final rangeHeader = request.headers.value('range');

    try {
      // Responder inmediatamente al TV (el SetAVTransportURI espera respuesta HTTP
      // rápida, no puede bloquear esperando a FFmpeg).
      request.response.statusCode = 200;
      request.response.headers.set('Content-Type', 'video/mp4');
      request.response.headers.set('Accept-Ranges', 'bytes');
      request.response.headers.set('Connection', 'keep-alive');
      request.response.headers.set('transferMode.dlna.org', 'Streaming');

      // Sin Content-Length → chunked encoding (stream progresivo)

      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final parts = rangeHeader.substring(6).split('-');
        final start = int.parse(parts[0]);

        // Esperar a que FFmpeg tenga datos hasta start
        while (true) {
          final currentSize = await file.length();
          if (currentSize > start || entry.isComplete) {
            final newSize = await file.length();
            final end = (parts.length > 1 && parts[1].isNotEmpty)
                ? int.parse(parts[1]).clamp(start, newSize - 1)
                : newSize - 1;
            final contentLength = end - start + 1;
            request.response.statusCode = 206;
            request.response.headers.set('Content-Length', contentLength.toString());
            request.response.headers.set('Content-Range', 'bytes $start-$end/$newSize');
            await file.openRead(start, end + 1).pipe(request.response);
            break;
          }
          await Future.delayed(const Duration(milliseconds: 200));
        }
      } else {
        // Sin Range: stream progresivo chunked
        // Esperar primer chunk de FFmpeg
        const chunkSize = 64 * 1024;
        int offset = 0;
        while (!entry.isComplete || offset < await file.length()) {
          final currentSize = await file.length();
          if (currentSize > offset) {
            final end = (offset + chunkSize).clamp(0, currentSize);
            final chunk = await file.openRead(offset, end).toList();
            for (final data in chunk) {
              request.response.add(data);
            }
            await request.response.flush();
            offset = end;
          } else {
            if (entry.isComplete) break;
            await Future.delayed(const Duration(milliseconds: 200));
          }
        }
      }

      await request.response.close();
    } catch (e) {
      print('⚠️ [FFMPEG] Stream $id error: $e');
      try { await request.response.close(); } catch (_) {}
    }
  }

  HttpServer? _server;
  int _port = 0;
  String _localIp = '';
  final Map<String, _A3Entry> _a3Registry = {};
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
        } else if (request.uri.path.startsWith('/ffstream/')) {
          _handleFfmpegStream(request);
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
    final posParam = request.uri.queryParameters['pos'];
    int? pos = int.tryParse(posParam ?? '');

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

    // Cabeceras proxiadas (extraídas del navegador por el extractor).
    // NO reenviar cabeceras de la TV (DLNA manda Accept, User-Agent,
    // transferMode.dlna.org, etc.) porque el CDN detecta que no es un
    // navegador real y sirve placeholders PNG en vez de segmentos de vídeo.
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

    // Re-combinar cookies de sesión: las del extractor (auth del sitio) más
    // las cookies que el CDN haya seteado durante la sesión (Set-Cookie).
    if (_sessionCookies.isNotEmpty) {
      final extractorCookie = headers['Cookie'] ?? '';
      final merged = extractorCookie.isEmpty
          ? _sessionCookies
          : '$extractorCookie; $_sessionCookies';
      headers['Cookie'] = merged;
    }
    if (_lastOriginCookie.isEmpty && headers.containsKey('Cookie')) {
      _lastOriginCookie = headers['Cookie'] ?? '';
    }

    // Refrescar cookies desde el WebView (usa el mismo almacén de cookies que
    // Chrome/WebView del dispositivo, manteniendo la sesión activa).
    try {
      final webCookies = await CookieManager.instance().getCookies(
        url: WebUri(url),
      );
      if (webCookies.isNotEmpty) {
        final webCookieStr =
            webCookies.map((c) => '${c.name}=${c.value}').join('; ');
        final existing = headers['Cookie'] ?? '';
        headers['Cookie'] =
            existing.isEmpty ? webCookieStr : '$existing; $webCookieStr';
        print('🍪 [PROXY][$requestId] Refreshed ${webCookies.length} cookies from WebView');
      }
    } catch (_) {
      // CookieManager puede fallar si no hay WebView activo, ignorar
    }

    // Añadir cabeceras típicas de navegador que faltan (el Dart HTTP client no las
    // envía por defecto, y algunos CDNs las requieren para servir segmentos reales).
    headers.putIfAbsent('Accept', () => '*/*');
    headers.putIfAbsent('Accept-Language', () => 'es-ES,es;q=0.9,en;q=0.8');
    headers.putIfAbsent('Sec-Fetch-Dest', () => 'empty');
    headers.putIfAbsent('Sec-Fetch-Mode', () => 'cors');
    headers.putIfAbsent('Sec-Fetch-Site', () => 'cross-site');

    // Reenviar solo Range del cliente (para búsqueda/seek por rango)
    final tvRange = request.headers.value('range');
    if (tvRange != null) headers['Range'] = tvRange;



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

      // Capturar Set-Cookie del CDN para mantener sesión entre peticiones
      final setCookie = streamedResponse.headers['set-cookie'];
      if (setCookie != null && setCookie.isNotEmpty) {
        print('🍪 [PROXY][$requestId] Set-Cookie from CDN: "$setCookie"');
        // Almacenar para próximas peticiones
        _sessionCookies = setCookie;
      }

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
          remux: remuxParam,
          startPos: (pos != null && pos > 0) ? pos.toDouble() : null,
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



  /// Desenvuelve un PNG que contiene datos de video reales (anti-leeching de TikTok).
  ///
  /// TikTok envuelve segmentos TS legítimos en contenedores PNG. El PNG puede
  /// tener los datos de video en chunks IDAT (comprimidos con zlib) o simplemente
  /// con un prefijo PNG. Esta función extrae los bytes de video reales.
  Uint8List _unwrapPng(Uint8List data) {
    if (data.length < 8) return data;
    // Verificar firma PNG: 89 50 4E 47 0D 0A 1A 0A
    if (data[0] != 0x89 || data[1] != 0x50 || data[2] != 0x4E || data[3] != 0x47) {
      return data;
    }

    // Método 1: parsear chunks PNG válidos y extraer/decomprimir IDAT
    int offset = 8;
    final idatChunks = <Uint8List>[];
    bool foundIend = false;
    int? iendEnd;

    while (offset + 8 <= data.length) {
      final len = (data[offset] << 24) |
          (data[offset + 1] << 16) |
          (data[offset + 2] << 8) |
          data[offset + 3];
      if (len < 0 || offset + 12 + len > data.length) break;

      final type = String.fromCharCodes(data.sublist(offset + 4, offset + 8));

      if (type == 'IDAT') {
        idatChunks.add(data.sublist(offset + 8, offset + 8 + len));
      } else if (type == 'IEND') {
        foundIend = true;
        iendEnd = offset + 12 + len;
        break;
      }

      offset += 12 + len;
    }

    final idatTotal = idatChunks.fold(0, (s, c) => s + c.length);
    final idatBytes = Uint8List(idatTotal);
    {
      int pos = 0;
      for (final chunk in idatChunks) {
        idatBytes.setRange(pos, pos + chunk.length, chunk);
        pos += chunk.length;
      }
    }

    // Intentar descompresión zlib (estándar PNG)
    if (idatBytes.isNotEmpty) {
      try {
        final decompressed = zlib.decoder.convert(idatBytes);
        if (decompressed.length > 100) return Uint8List.fromList(decompressed);
      } catch (_) {
        // Si falla la descompresión, los datos podrían no estar comprimidos
        if (idatBytes.length > 100) return idatBytes;
      }
    }

    // Método 2: si hay IEND, servir datos posteriores (algunos CDNs concatenan
    // TS después del marcador IEND del PNG)
    if (foundIend && iendEnd != null && iendEnd < data.length) {
      final trailing = data.sublist(iendEnd);
      // Verificar sync byte MPEG-TS (0x47) en los primeros bytes
      if (trailing.length > 100) {
        return trailing;
      }
    }

    // No se pudo desenvolver; devolver datos originales
    return data;
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
    // Detectar respuesta PNG (TikTok envuelve TS real en contenedor PNG)
    if (upstreamContentType.contains('image/png')) {
      try {
        final chunks = <List<int>>[];
        if (firstChunk != null) chunks.add(firstChunk);
        await for (final chunk in stream) {
          chunks.add(chunk);
        }
        final totalLen = chunks.fold(0, (s, c) => s + c.length);
        final body = Uint8List(totalLen);
        {
          int pos = 0;
          for (final chunk in chunks) {
            body.setRange(pos, pos + chunk.length, chunk);
            pos += chunk.length;
          }
        }
        final unwrapped = _unwrapPng(body);

        request.response.statusCode = response.statusCode;
        request.response.headers.set('Content-Type', 'video/MP2T');
        request.response.headers.set('Access-Control-Allow-Origin', '*');
        request.response.headers.set('Connection', 'keep-alive');
        request.response.add(unwrapped);
        await request.response.close();
      } catch (e) {
        print('⚠️ [PROXY][$requestId] PNG unwrap error: $e');
        request.response.statusCode = 500;
        await request.response.close();
      } finally {
        client.close();
      }
      return;
    }

    request.response.statusCode = response.statusCode;

    // Copiar cabeceras base. Dart valida la codificación de cada valor y los
    // servidores de streams (p.ej. Addon Latam) envían Content-Disposition con
    // filenames
    // no-ASCII ("El Hombre Araña 2 (2004) 720p" con Ñ) que lanzan
    // FormatException en HttpHeaders.set. Si una cabecera no es válida, se
    // omite: el reproductor no la necesita para reproducir el vídeo.
    response.headers.forEach((key, value) {
      final k = key.toLowerCase();
      // Permitir cabeceras de rango y longitud para evitar corrupción en ExoPlayer
      if (k != 'transfer-encoding' && k != 'content-encoding') {
        try {
          request.response.headers.set(key, value);
        } catch (e) {
          print('⚠️ [PROXY][$requestId] Header omitido (valor inválido): $key = $e');
        }
      }
    });

    request.response.headers.set('Access-Control-Allow-Origin', '*');
    request.response.headers.set('Connection', 'keep-alive');

    // Content-Type real. Forzar video/MP2T a ciegas rompe el audio en TVs/WVC:
    // si el stream real es un MKV/MP4 (p.ej. Addon Latam -> video/x-matroska),
    // el receptor hace demux MPEG-TS y no encuentra las pistas de audio ->
    // llega SIN AUDIO en la TV mientras en la app (media_kit sniféa el
    // contenido real) se escucha bien. Solo forzamos MP2T cuando el contenido
    // es realmente MPEG-TS (los PNG envoltorios de TikTok se resuelven antes).
    final lowerUrl = url.toLowerCase();
    final bool isMpegTs =
        upstreamContentType.contains('mp2t') ||
        upstreamContentType.contains('video/mpeg') ||
        lowerUrl.endsWith('.ts');
    String realContentType = isMpegTs
        ? 'video/MP2T'
        : upstreamContentType.isNotEmpty
            ? upstreamContentType
            : (lowerUrl.endsWith('.mkv')
                ? 'video/x-matroska'
                : (lowerUrl.endsWith('.mp4') || lowerUrl.endsWith('.m4v')
                    ? 'video/mp4'
                    : 'video/MP2T'));
    request.response.headers.set('content-type', realContentType);
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
    double? startPos,
  }) {
    final baseUri = Uri.parse(baseUriStr);
    final baseQuery = baseUri.query; // preservar para segmentos (CDN token)
    final lines = body.split('\n');
    final rewrittenLines = <String>[];
    bool hasEndList = false;
    final isMasterPlaylist = body.contains('#EXT-X-STREAM-INF');
    final bool shouldSkip = startPos != null && startPos > 0 && !isMasterPlaylist;
    double cumulativeDuration = 0;
    double? pendingExtinf;

    for (var line in lines) {
      final trimmedLine = line.trim();
      if (trimmedLine.isEmpty) continue;

      if (trimmedLine.startsWith('#')) {
        if (shouldSkip) {
          final extinfMatch = RegExp(r'#EXTINF:([\d.]+)').firstMatch(trimmedLine);
          if (extinfMatch != null) {
            pendingExtinf = double.tryParse(extinfMatch.group(1) ?? '0') ?? 0;
            continue;
          }
        }

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
          var absoluteUri = baseUri.resolve(internalUrl);
          if (baseQuery.isNotEmpty && absoluteUri.query.isEmpty) {
            absoluteUri = absoluteUri.replace(query: baseQuery);
          }
          final proxiedUrl = _buildProxiedUrl(
            absoluteUri.toString(),
            headers,
            requestHost,
            algorithm: algorithm,
            remux: remux,
          );
          rewrittenLines.add(trimmedLine.replaceFirst(internalUrl, proxiedUrl));
        } else {
          rewrittenLines.add(trimmedLine);
        }
      } else {
        // URL line — segment or sub-manifest
        if (shouldSkip && pendingExtinf != null) {
          final segmentEnd = cumulativeDuration + pendingExtinf;
          if (segmentEnd < startPos!) {
            cumulativeDuration = segmentEnd;
            pendingExtinf = null;
            continue;
          }
          if (cumulativeDuration < startPos!) {
            final offset = startPos! - cumulativeDuration;
            final remaining = pendingExtinf - offset;
            if (remaining > 0) {
              rewrittenLines.add('#EXTINF:${remaining.toStringAsFixed(1)},');
            } else {
              rewrittenLines.add('#EXTINF:${pendingExtinf.toStringAsFixed(1)},');
            }
          } else {
            rewrittenLines.add('#EXTINF:${pendingExtinf.toStringAsFixed(1)},');
          }
          cumulativeDuration += pendingExtinf;
          pendingExtinf = null;
        }

        var absoluteUri = baseUri.resolve(trimmedLine);
        if (baseQuery.isNotEmpty && absoluteUri.query.isEmpty) {
          absoluteUri = absoluteUri.replace(query: baseQuery);
        }
        final proxiedUrl = _buildProxiedUrl(
          absoluteUri.toString(),
          headers,
          requestHost,
          algorithm: algorithm,
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
    bool remux = false,
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
    final ext = path.toLowerCase().split('.').last;
    final contentType = switch (ext) {
      'mkv' => 'video/x-matroska',
      'ts' => 'video/mp2t',
      'm3u8' => 'application/x-mpegURL',
      'webm' => 'video/webm',
      'avi' => 'video/x-msvideo',
      _ => 'video/mp4',
    };

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
    int? pos,
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
    var proxyUrl = _buildProxiedUrl(
      url,
      headers,
      host,
      algorithm: algorithm,
      remux: remux,
    );
    if (pos != null && pos > 0) {
      proxyUrl += '&pos=$pos';
    }
    return proxyUrl;
  }

  /// Crea un stream progresivo FFmpeg (remux HLS→MKV) y retorna URL local.
  /// El stream se sirve en /ffstream/$id y puede reproducirse mientras FFmpeg
  /// sigue descargando (progresivo). Soporta range requests del TV.
  Future<String> getFfmpegUrl(
    String url,
    Map<String, String>? headers, {
    bool useLocalhost = false,
  }) async {
    String host = (useLocalhost || _localIp.isEmpty)
        ? '127.0.0.1:$_port'
        : '$_localIp:$_port';

    final id = await startFfmpegStream(url, headers ?? {});
    final streamUrl = 'http://$host/ffstream/$id';
    print('🎬 [FFMPEG] fMP4 stream URL: $streamUrl');
    return streamUrl;
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
}

class _A3Entry {
  final String url;
  final Map<String, String> headers;
  final String baseUrl;
  final bool toCast;

  _A3Entry(this.url, this.headers, this.baseUrl, {this.toCast = false});
}

class _FfmpegStream {
  final String id;
  final String outputPath;
  final Completer<void> completer = Completer<void>();
  bool isComplete = false;

  _FfmpegStream({required this.id, required this.outputPath});
}


