import 'dart:io';
import 'dart:convert';
import 'dart:async';

class A3ProxyService {
  static final A3ProxyService _instance = A3ProxyService._internal();
  factory A3ProxyService() => _instance;
  A3ProxyService._internal();

  HttpServer? _server;
  int _port = 0;
  String _localIp = '';
  final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30);

  // Caché de sesiones: ID -> { 'header_User-Agent': '...', 'base_url': '...' }
  final Map<String, Map<String, String>> _sessionCache = {};

  int get port => _port;
  String get localIp => _localIp;

  Future<void> start({String? targetIp}) async {
    if (_server != null) {
      if (targetIp != null) await _refreshLocalIp(targetIp: targetIp);
      return;
    }

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _port = _server!.port;
      await _refreshLocalIp(targetIp: targetIp);

      _server!.listen(_handleRequest, onError: (e) => print('❌ [A3_PROXY] Listener Error: $e'));
      print('🚀 [A3_PROXY] Servidor activo en http://$_localIp:$_port');
    } catch (e) {
      print('❌ [A3_PROXY] Error al iniciar: $e');
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final requestId = DateTime.now().millisecondsSinceEpoch.toString().substring(7);
    
    // 1. Soporte CORS Universal (Crítico para Chromecast/WVC)
    request.response.headers.set('Access-Control-Allow-Origin', '*');
    request.response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    request.response.headers.set('Access-Control-Allow-Headers', '*');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    final encodedUrl = request.uri.queryParameters['url'];
    final shortSegment = request.uri.queryParameters['s'];
    final encodedHeaders = request.uri.queryParameters['h'];
    final sessionId = request.uri.queryParameters['hid'];

    if (encodedUrl == null && shortSegment == null && sessionId == null) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    String normalize(String s) {
      int pad = 4 - (s.length % 4);
      if (pad < 4 && pad > 0) s += '=' * pad;
      return s;
    }

    Map<String, String> extraHeaders = {};
    String? baseUrl;

    if (sessionId != null && _sessionCache.containsKey(sessionId)) {
      final session = _sessionCache[sessionId]!;
      baseUrl = session['__BASE_URL__'];
      session.forEach((k, v) {
        if (!k.startsWith('__')) extraHeaders[k] = v;
      });
    } else if (encodedHeaders != null) {
      try {
        final decoded = jsonDecode(utf8.decode(base64Url.decode(normalize(encodedHeaders))));
        if (decoded is Map) {
          extraHeaders = decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
        }
      } catch (_) {}
    }

    String? finalUrl;
    if (shortSegment != null && baseUrl != null) {
      try {
        finalUrl = Uri.parse(baseUrl).resolve(shortSegment).toString();
      } catch (_) {}
    } else if (encodedUrl != null) {
      try {
        finalUrl = utf8.decode(base64Url.decode(normalize(encodedUrl)));
      } catch (_) {}
    } else if (sessionId != null && _sessionCache.containsKey(sessionId)) {
      // MODO SESIÓN PURA: Si no hay URL pero hay sesión, usamos la baseUrl guardada
      finalUrl = _sessionCache[sessionId]!['__BASE_URL__'];
    }

    if (finalUrl == null) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    
    final url = finalUrl;
    final lowerUrl = url.toLowerCase();
    final isM3u8 = lowerUrl.contains('.m3u8') || lowerUrl.contains('playlist');
    final isSegment = lowerUrl.contains('.ts') || 
                      lowerUrl.contains('.mp4') || 
                      lowerUrl.contains('seg-') ||
                      lowerUrl.contains('.jpg') || 
                      lowerUrl.contains('.png') || 
                      lowerUrl.contains('.jpeg') ||
                      lowerUrl.contains('.webp');

    if (shortSegment != null && baseUrl != null) {
      if (!isSegment) print('🔗 [A3_PROXY][$requestId] Segmento resuelto: $shortSegment');
    }

    if (!isSegment) {
       print('🎬 [A3_PROXY][$requestId] Solicitud (${isM3u8 ? "M3U8" : "RAW"}): $url');
    }

    try {
      final proxyReq = await _httpClient.openUrl(request.method, Uri.parse(url));
      
      request.headers.forEach((name, values) {
        final n = name.toLowerCase();
        if (isM3u8 && n == 'range') return;
        // BLOQUEO CRÍTICO: No permitimos que el reproductor pida compresión (GZIP) 
        // porque necesitamos procesar el texto del manifiesto.
        if (n != 'host' && n != 'connection' && n != 'accept-encoding') {
          proxyReq.headers.set(name, values.join(', '));
        }
      });

      extraHeaders.forEach((k, v) => proxyReq.headers.set(k, v));
      
      // Forzamos identidad para evitar GZIP a nivel de red
      proxyReq.headers.set('accept-encoding', 'identity');

      final proxyRes = await proxyReq.close();
      request.response.statusCode = proxyRes.statusCode;
      
      final upstreamContentType = proxyRes.headers.value(HttpHeaders.contentTypeHeader) ?? '';
      final isHlsBody = upstreamContentType.contains('mpegurl') || 
                         upstreamContentType.contains('application/x-mpegurl') ||
                         upstreamContentType.contains('vnd.apple.mpegurl') ||
                         isM3u8;

      proxyRes.headers.forEach((name, values) {
        final n = name.toLowerCase();
        // FILTRADO CRÍTICO: No copiar cabeceras que confunden al reproductor o al proxy
        if (n != 'content-length' && 
            n != 'access-control-allow-origin' &&
            n != 'content-encoding' &&
            n != 'transfer-encoding' &&
            n != 'connection' &&
            n != 'server') {
          values.forEach((value) => request.response.headers.add(name, value));
        }
      });
      
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS, HEAD');
      request.response.headers.set('Access-Control-Allow-Headers', '*');
      request.response.headers.set('Access-Control-Expose-Headers', '*');

      if (isHlsBody && request.method == 'GET') {
        List<int> bytes;
        try {
          bytes = await proxyRes.fold<List<int>>([], (p, e) => p..addAll(e));
        } catch (e) {
          print('❌ [A3_PROXY] Error leyendo stream: $e');
          request.response.statusCode = 500;
          await request.response.close();
          return;
        }

        String body;
        try {
          body = utf8.decode(bytes);
        } catch (_) {
          body = latin1.decode(bytes);
        }

        // ELIMINAR CARACTERES DE CONTROL: Evita corrupciones en el parseo y crashes en el reproductor
        body = body.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

        final rewritten = _rewriteM3u8(body, url, extraHeaders, sessionId);
        
        request.response.headers.contentType = ContentType.parse('application/vnd.apple.mpegurl');
        final outBytes = utf8.encode(rewritten);
        request.response.headers.contentLength = outBytes.length;
        
        print('✅ [A3_PROXY][$requestId] HLS Procesado: ${outBytes.length} bytes / ${rewritten.split('\n').length} líneas');
        
        request.response.add(outBytes);
      } else {
        // Para segmentos, asegurar que el reproductor vea VIDEO, aunque el origen diga IMAGEN
        final currentCt = request.response.headers.contentType?.toString() ?? '';
        if (currentCt.contains('image/') || currentCt.isEmpty || currentCt.contains('text/plain')) {
          if (lowerUrl.contains('.ts') || lowerUrl.contains('seg-')) {
            request.response.headers.contentType = ContentType.parse('video/mp2t');
          } else {
            // Por defecto tratamos como mp4 si no es TS
            request.response.headers.contentType = ContentType.parse('video/mp4');
          }
        }
        await request.response.addStream(proxyRes);
      }
      
      await request.response.close();
    } catch (e) {
      if (!isSegment) print('❌ [A3_PROXY][$requestId] Error: $e');
      if (request.response.headers.value(HttpHeaders.contentTypeHeader) == null) {
        request.response.statusCode = HttpStatus.internalServerError;
      }
    } finally {
      try {
        await request.response.close();
      } catch (_) {}
    }
  }

  /// Genera una URL proxied ultra-corta usando solo el ID de sesión
  String generateSessionUrl(String url, Map<String, String> headers) {
    final sid = _saveSession(headers, baseUrl: url);
    final host = _localIp.isEmpty ? '127.0.0.1' : _localIp;
    return 'http://$host:$_port/a3.m3u8?hid=$sid';
  }

  String _rewriteM3u8(String body, String url, Map<String, String>? headers, String? existingSid) {
    final lines = body.split(RegExp(r'\r\n|\r|\n'));
    final rewrittenLines = <String>[];
    final uri = Uri.parse(url);

    final String sid = existingSid ?? _saveSession(headers ?? {}, baseUrl: url);
    if (existingSid != null) _updateSessionBaseUrl(existingSid, url);

    for (var line in lines) {
      String trimmed = line.trim();
      if (trimmed.isEmpty) {
        rewrittenLines.add(line);
        continue;
      }

      if (trimmed.startsWith('#')) {
        if (trimmed.contains('URI=')) {
          final regex = RegExp(r'URI="([^"]+)"');
          final match = regex.firstMatch(trimmed);
          if (match != null) {
            final originalUri = match.group(1)!;
            try {
              final fullUrl = uri.resolve(originalUri).toString();
              final proxied = getProxiedUrl(fullUrl, null, hid: sid);
              trimmed = trimmed.replaceFirst('URI="$originalUri"', 'URI="$proxied"');
            } catch (_) {}
          }
        }
        rewrittenLines.add(trimmed);
      } else {
        // AQUÍ ESTÁ EL ACORTADOR: Si la URL es relativa o del mismo host, usamos 's='
        if (!trimmed.startsWith('http')) {
           rewrittenLines.add(getProxiedUrl(trimmed, null, hid: sid, isShort: true));
        } else {
           try {
             final segUri = Uri.parse(trimmed);
             if (segUri.host == uri.host) {
                rewrittenLines.add(getProxiedUrl(segUri.path + (segUri.hasQuery ? "?${segUri.query}" : ""), null, hid: sid, isShort: true));
             } else {
                rewrittenLines.add(getProxiedUrl(trimmed, null, hid: sid));
             }
           } catch (_) {
             rewrittenLines.add(getProxiedUrl(trimmed, null, hid: sid));
           }
        }
      }
    }

    // CIERRE FORZADO Y LIMPIEZA: Si el manifiesto está truncado, lo saneamos.
    // 1. Eliminar líneas finales que sean metadatos sin contenido (ej: un #EXTINF al final sin URL)
    while (rewrittenLines.isNotEmpty && rewrittenLines.last.trim().startsWith('#EXT')) {
      final last = rewrittenLines.last.trim();
      // Si la última línea es una etiqueta que requiere contenido debajo (como INF o KEY), la quitamos
      if (last.startsWith('#EXTINF') || last.startsWith('#EXT-X-KEY')) {
        rewrittenLines.removeLast();
      } else {
        break;
      }
    }

    // 2. Asegurar que termine en #EXT-X-ENDLIST
    bool hasEndList = rewrittenLines.any((l) => l.trim().contains('#EXT-X-ENDLIST'));
    if (!hasEndList && body.contains('#EXTM3U')) {
       rewrittenLines.add('#EXT-X-ENDLIST');
    }

    return rewrittenLines.join('\r\n');
  }

  String _saveSession(Map<String, String> headers, {String? baseUrl}) {
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    _sessionCache[id] = Map<String, String>.from(headers);
    if (baseUrl != null) _sessionCache[id]!['__BASE_URL__'] = baseUrl;
    
    if (_sessionCache.length > 100) _sessionCache.remove(_sessionCache.keys.first);
    return id;
  }

  void _updateSessionBaseUrl(String sid, String baseUrl) {
    if (_sessionCache.containsKey(sid)) {
      _sessionCache[sid]!['__BASE_URL__'] = baseUrl;
    }
  }

  Future<void> _refreshLocalIp({String? targetIp}) async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (var iface in interfaces) {
        for (var addr in iface.addresses) {
          final ip = addr.address;
          if (ip == '127.0.0.1') continue;

          if (targetIp != null) {
            final tParts = targetIp.split('.');
            final iParts = ip.split('.');
            if (tParts.length >= 3 && iParts.length >= 3) {
              if (tParts[0] == iParts[0] && tParts[1] == iParts[1] && tParts[2] == iParts[2]) {
                _localIp = ip;
                return;
              }
            }
          }
          if (ip.startsWith('192.168.')) {
            _localIp = ip;
            return;
          }
        }
      }
      
      if (_localIp.isEmpty && interfaces.isNotEmpty) {
        for (var iface in interfaces) {
          for (var addr in iface.addresses) {
            if (addr.address != '127.0.0.1') {
              _localIp = addr.address;
              return;
            }
          }
        }
      }
    } catch (_) {}
  }

  String getProxiedUrl(String url, Map<String, String>? headers, {String? hid, bool isShort = false}) {
    String? bUrl;
    if (!isShort) {
       bUrl = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
    }
    
    String? bHeaders;
    if (hid == null && headers != null && headers.isNotEmpty) {
      final essential = <String, String>{};
      headers.forEach((k, v) {
        final kl = k.toLowerCase();
        if (kl == 'user-agent' || kl == 'cookie' || kl == 'referer' || kl == 'origin') {
          essential[k] = v;
        }
      });
      bHeaders = base64Url.encode(utf8.encode(jsonEncode(essential))).replaceAll('=', '');
    }

    final lowerUrl = url.toLowerCase();
    String extension = '.mp4';
    if (lowerUrl.contains('.m3u8') || lowerUrl.contains('playlist')) {
      extension = '.m3u8';
    } else if (lowerUrl.contains('.ts') || lowerUrl.contains('seg-')) {
      extension = '.ts';
    } else if (lowerUrl.contains('.mp4')) {
      extension = '.mp4';
    }
    
    final host = _localIp.isEmpty ? '127.0.0.1' : _localIp;
    
    // Si es corta, usamos 's=', si no 'url='
    var proxyUrl = 'http://$host:$_port/a3$extension?';
    if (isShort) {
      proxyUrl += 's=${Uri.encodeComponent(url)}';
    } else {
      proxyUrl += 'url=$bUrl';
    }
    
    if (hid != null) {
      proxyUrl += '&hid=$hid';
    } else if (bHeaders != null) {
      proxyUrl += '&h=$bHeaders';
    }
    
    return proxyUrl;
  }
}
