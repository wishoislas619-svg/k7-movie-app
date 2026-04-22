import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;

class MediaProxyService {
  static final MediaProxyService _instance = MediaProxyService._internal();
  factory MediaProxyService() => _instance;
  MediaProxyService._internal();

  HttpServer? _server;
  int _port = 0;
  String _localIp = '';

  int get port => _port;
  String get localIp => _localIp;

  Future<void> start() async {
    if (_server != null) return;

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _port = _server!.port;
      
      // Encontrar la IP local (WiFi / Hotspot) — cubrimos todos los rangos privados RFC-1918
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      outer:
      for (var iface in interfaces) {
        for (var addr in iface.addresses) {
          final ip = addr.address;
          // Rangos RFC-1918: 192.168.x.x | 10.x.x.x | 172.16-31.x.x
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              RegExp(r'^172\.(1[6-9]|2[0-9]|3[0-1])\.').hasMatch(ip)) {
            _localIp = ip;
            break outer;
          }
        }
      }

      print('🎬 [PROXY] Servidor iniciado en http://$_localIp:$_port');

      _server!.listen((HttpRequest request) async {
        try {
          if (request.uri.path == '/proxy') {
            await _handleProxyRequest(request);
          } else {
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
          }
        } catch (e) {
          print('❌ [PROXY] Error manejando petición: $e');
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        }
      });
    } catch (e) {
      print('❌ [PROXY] No se pudo iniciar el servidor: $e');
    }
  }

  Future<void> _handleProxyRequest(HttpRequest request) async {
    final encodedUrl = request.uri.queryParameters['url'];
    final encodedHeaders = request.uri.queryParameters['headers'];

    if (encodedUrl == null) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    final url = utf8.decode(base64Url.decode(encodedUrl));
    Map<String, String> headers = {};
    if (encodedHeaders != null) {
      headers = Map<String, String>.from(json.decode(utf8.decode(base64Url.decode(encodedHeaders))));
    }

    // Log de diagnóstico: ¿Qué nos está pidiendo el reproductor?
    final incomingHeaders = <String, String>{};
    request.headers.forEach((key, value) => incomingHeaders[key] = value.join(', '));
    print('📥 [PROXY_REQ] Cabeceras entrantes: $incomingHeaders');

    print('🚀 [PROXY] Redirigiendo a: $url');

    // Aplicar cabeceras por defecto solo si no vienen en la petición original
    if (url.contains('videasy') || url.contains('embed.su') || url.contains('mdisk')) {
       headers['Referer'] ??= 'https://embed.su/';
       headers['Origin'] ??= 'https://embed.su';
    }
    
    // SPOOFING: Si es Algoritmo 1, nos hacemos pasar por un celular (Android)
    // Muchos servidores de Algoritmo 1 bloquean si el User-Agent parece una TV o Desktop
    final isAlgo1 = headers['X-Proxy-Algorithm'] == '1' || (url.contains('m3u8') && !url.contains('embed.su') && !url.contains('videasy'));
    final isAlgo2Or3 = headers['X-Proxy-Algorithm'] == '2' || headers['X-Proxy-Algorithm'] == '3' || url.contains('videasy') || url.contains('embed.su');

    // 🎭 SUPER SPOOFING: Nos hacemos pasar por el reproductor nativo de Android (Dalvik/ExoPlayer)
    // Esto es lo que el worker espera ver para soltar el video real y no publicidad.
    headers['User-Agent'] = 'Dalvik/2.1.0 (Linux; U; Android 13; SM-S918B Build/TP1A.220624.014)';
    headers['Connection'] ??= 'Keep-Alive';
    headers['Accept-Encoding'] ??= 'gzip';
    
    // Pasar cabeceras importantes del reproductor original (ej: VLC) al servidor de video
    if (incomingHeaders.containsKey('range')) {
      headers['Range'] = incomingHeaders['range']!;
    }

    if (isAlgo1) {
      print('📱 [PROXY] Usando perfil Dalvik/Android para Algo 1');
    } else if (isAlgo2Or3) {
      headers['Sec-Fetch-Dest'] ??= 'video';
      headers['Sec-Fetch-Mode'] ??= 'cors';
      headers['Sec-Fetch-Site'] ??= 'cross-site';
      print('💻 [PROXY] Aplicando cabeceras extendidas Algo 2/3');
    }
    
    // Limpiar headers internos de control antes de enviar al upstream
    headers.remove('X-Proxy-Algorithm');

    try {
      final client = http.Client();
      final proxyRequest = http.Request('GET', Uri.parse(url))
        ..headers.addAll(headers)
        ..followRedirects = true;

      final response = await client.send(proxyRequest);

      final statusCode = response.statusCode;
      final contentType = response.headers['content-type']?.toLowerCase() ?? '';
      final isM3u8 = contentType.contains('mpegurl') || url.toLowerCase().contains('.m3u8');

      print('📥 [PROXY] Upstream respondió: $statusCode ($contentType)');

      // Copiar headers de respuesta (importante para Content-Type y Rangos)
      request.response.statusCode = statusCode;
      response.headers.forEach((key, value) {
        final k = key.toLowerCase();
        // Omitimos headers que cambian al reescribir o que maneja el servidor automáticamente
        if (k != 'transfer-encoding' && k != 'content-encoding') {
          if (isM3u8 && k == 'content-length') return; 
          request.response.headers.set(key, value);
        }
      });

      // Habilitar CORS para el dispositivo receptor
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.headers.set('Access-Control-Allow-Methods', 'GET, OPTIONS');
      request.response.headers.set('Access-Control-Allow-Headers', '*');

      if (isM3u8) {
        // 📝 REESCRITURA DE M3U8: Leemos la lista y proxiamos cada enlace interno
        final requestHost = request.headers.value(HttpHeaders.hostHeader) ?? '$_localIp:$_port';
        final body = await response.stream.bytesToString();
        final rewrittenBody = _rewriteM3u8(body, url, headers, requestHost);
        
        // Debug: Inspección de integridad (inicio y fin)
        final allLines = LineSplitter.split(rewrittenBody).toList();
        final firstLines = allLines.take(5).join('\n');
        final lastLines = allLines.length > 5 ? allLines.skip(allLines.length - 5).join('\n') : '';
        print('🔍 [DEBUG] M3U8 reescrito - Inicio:\n$firstLines');
        print('🔍 [DEBUG] M3U8 reescrito - Fin:\n$lastLines');

        // Importante: Enviar el nuevo Content-Length y MIME Type correcto
        final bytes = utf8.encode(rewrittenBody);
        request.response.headers.contentType = ContentType.parse('application/vnd.apple.mpegurl');
        request.response.headers.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
        print('♻️ [PROXY] Lista M3U8 reescrita (${bytes.length} bytes) para host: $requestHost');
      } else {
        // Streaming directo para segmentos (.ts) o archivos MP4
        if (response.contentLength != null && response.contentLength! > 0) {
           request.response.headers.contentLength = response.contentLength!;
        }
        await request.response.addStream(response.stream);
        await request.response.close();
      }
    } catch (e) {
      print('❌ [PROXY] Error en upstream: $e');
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
    }
  }

  String _rewriteM3u8(String content, String baseUrl, Map<String, String> originalHeaders, String host) {
    final lines = LineSplitter.split(content);
    final rewrittenLines = <String>[];
    final baseUri = Uri.parse(baseUrl);

    for (var line in lines) {
      final trimmedLine = line.trim();
      if (trimmedLine.isEmpty) {
        rewrittenLines.add(line);
        continue;
      }

      // 🛡️ FILTRO DE PUBLICIDAD: Si la línea parece un anuncio de TikTok, la saltamos
      if (trimmedLine.contains('tiktok') || trimmedLine.contains('.image')) {
        // Si la línea anterior era un #EXTINF, tenemos que quitarla también
        if (rewrittenLines.isNotEmpty && rewrittenLines.last.startsWith('#EXTINF')) {
          rewrittenLines.removeLast();
        }
        continue;
      }

      if (trimmedLine.startsWith('#')) {
        // Buscar URIs dentro de tags (ej: #EXT-X-KEY:METHOD=AES-128,URI="...")
        var newLine = trimmedLine;
        final uriRegex = RegExp(r'URI="([^"]+)"');
        final match = uriRegex.firstMatch(trimmedLine);
        if (match != null) {
          final internalUrl = match.group(1)!;
          final absoluteUri = baseUri.resolve(internalUrl);
          final proxiedUrl = _buildProxiedUrl(absoluteUri.toString(), originalHeaders, host);
          newLine = trimmedLine.replaceFirst(internalUrl, proxiedUrl.trim());
        }
        rewrittenLines.add(newLine);
      } else {
        // Es una URL de segmento o de sub-playlist, la proxiamos usando el host actual
        final absoluteUri = baseUri.resolve(trimmedLine);
        final proxiedUrl = _buildProxiedUrl(absoluteUri.toString(), originalHeaders, host);
        rewrittenLines.add(proxiedUrl.trim());
      }
    }
    return '${rewrittenLines.join('\n')}\n';
  }

  String _buildProxiedUrl(String url, Map<String, String>? headers, String host) {
    final bUrl = base64Url.encode(utf8.encode(url));
    final bHeaders = headers != null ? base64Url.encode(utf8.encode(json.encode(headers))) : null;

    var proxyUrl = 'http://$host/proxy?url=$bUrl';
    if (bHeaders != null) {
      proxyUrl += '&headers=$bHeaders';
    }
    return proxyUrl;
  }

  String getProxiedUrl(String url, Map<String, String>? headers) {
    if (_localIp.isEmpty) return url; // Fallback si no hay proxy
    return _buildProxiedUrl(url, headers, '$_localIp:$_port');
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = 0;
    _localIp = '';
  }
}
