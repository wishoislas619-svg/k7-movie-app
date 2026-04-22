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
      print('🎬 [PROXY] También escuchando en http://127.0.0.1:$_port');

      _server!.listen((HttpRequest request) async {
        print('📥 [PROXY_IN] Petición detectada: ${request.method} ${request.uri.path}');
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

    // 🎭 SUPER SPOOFING: Solo forzamos Dalvik si es Algo 1. Para Algo 2/3 usamos el UA original del player.
    if (isAlgo1 || headers['User-Agent'] == null) {
      headers['User-Agent'] = 'Dalvik/2.1.0 (Linux; U; Android 13; SM-S918B Build/TP1A.220624.014)';
    }
    headers['Connection'] ??= 'Keep-Alive';
    headers['Accept-Encoding'] ??= 'gzip';
    
    // 🛡️ Filtro de cabeceras para el upstream
    if (url.contains('.m3u8')) {
      headers.remove('Range'); // El Range en un M3U8 puede ser detectado como bot
    } else if (incomingHeaders.containsKey('range')) {
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
    
    headers.remove('X-Proxy-Algorithm');

    final isM3u8 = url.toLowerCase().contains('.m3u8') || url.toLowerCase().contains('mpegurl');

    try {
      if (isM3u8) {
        // Usamos http.get para listas M3U8 para que maneje GZIP automáticamente
        final response = await http.get(Uri.parse(url), headers: headers);
        
        if (response.statusCode != 200) {
          print('❌ [PROXY] Error Upstream: ${response.statusCode}');
          request.response.statusCode = response.statusCode;
          await request.response.close();
          return;
        }

        print('📥 [PROXY] Upstream respondió: 200 (${response.headers['content-type']})');
        
        final requestHost = request.headers.value(HttpHeaders.hostHeader) ?? '$_localIp:$_port';
        final body = response.body;
        
        // Debug: Diagnóstico de contenido crudo
        final sample = body.length > 100 ? body.substring(0, 100).replaceAll('\n', ' ') : body;
        print('🔍 [DEBUG] M3U8 Recibido: $sample');

        final rewrittenBody = _rewriteM3u8(body, url, headers, requestHost);
        
        // Debug: Inspección de integridad
        final allLines = LineSplitter.split(rewrittenBody).toList();
        final firstLines = allLines.take(5).join('\n');
        final lastLines = allLines.length > 5 ? allLines.skip(allLines.length - 5).join('\n') : '';
        print('🔍 [DEBUG] M3U8 reescrito - Inicio:\n$firstLines');
        print('🔍 [DEBUG] M3U8 reescrito - Fin:\n$lastLines');

        final bytes = utf8.encode(rewrittenBody);
        request.response.headers.contentType = ContentType.parse('application/vnd.apple.mpegurl');
        request.response.headers.contentLength = bytes.length;
        request.response.headers.set('Access-Control-Allow-Origin', '*');
        request.response.add(bytes);
        await request.response.close();
        print('♻️ [PROXY] Lista M3U8 reescrita (${bytes.length} bytes)');
      } else {
        // Streaming directo para segmentos (.ts)
        final client = http.Client();
        final proxyRequest = http.Request('GET', Uri.parse(url))
          ..headers.addAll(headers)
          ..followRedirects = true;

        final response = await client.send(proxyRequest);
        
        request.response.statusCode = response.statusCode;
        response.headers.forEach((key, value) {
          final k = key.toLowerCase();
          if (k != 'transfer-encoding' && k != 'content-encoding') {
            request.response.headers.set(key, value);
          }
        });
        request.response.headers.set('Access-Control-Allow-Origin', '*');
        
        await request.response.addStream(response.stream);
        await request.response.close();
        client.close();
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

  String getProxiedUrl(String url, Map<String, String>? headers, {bool useLocalhost = false}) {
    if (_localIp.isEmpty && !useLocalhost) return url; // Fallback si no hay proxy ni localhost
    final host = useLocalhost ? '127.0.0.1:$_port' : '$_localIp:$_port';
    return _buildProxiedUrl(url, headers, host);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = 0;
    _localIp = '';
  }
}
