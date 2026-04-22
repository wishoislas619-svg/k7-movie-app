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

      print('🎬 [PROXY] Listo — Red: http://$_localIp:$_port  |  Local: http://127.0.0.1:$_port');
      print('💡 [ADB] Para VLC en Mac: adb forward tcp:$_port tcp:$_port → usa http://127.0.0.1:$_port/proxy?...');

      _server!.listen((HttpRequest request) async {
        try {
          if (request.uri.path == '/proxy') {
            await _handleProxyRequest(request);
          } else if (request.uri.path == '/ping') {
            request.response.statusCode = HttpStatus.ok;
            request.response.write('📡 [PROXY] Proxy is ALIVE and reachable at ${_localIp.isEmpty ? "localhost" : _localIp}:$_port');
            await request.response.close();
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
    final encodedHeaders = request.uri.queryParameters['h'] ?? request.uri.queryParameters['headers'];
    final algoParam = request.uri.queryParameters['a'];



    if (encodedUrl == null) {
      print('❌ [PROXY] Error: Falta el parámetro "url" en la petición.');
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('Error: Missing url parameter');
      await request.response.close();
      return;
    }

    // Restaurar padding de base64 si falta
    String normalizeBase64(String s) {
      int pad = 4 - (s.length % 4);
      if (pad < 4) s += '=' * pad;
      return s;
    }

    final url = utf8.decode(base64Url.decode(normalizeBase64(encodedUrl)));
    Map<String, String> headers = {};
    if (encodedHeaders != null) {
      final decoded = utf8.decode(base64Url.decode(normalizeBase64(encodedHeaders)));
      headers = Map<String, String>.from(json.decode(decoded));
    }

    final incomingHeaders = <String, String>{};
    request.headers.forEach((key, value) => incomingHeaders[key] = value.join(', '));

    // Aplicar cabeceras por defecto solo si no vienen en la petición original
    if (url.contains('videasy') || url.contains('embed.su') || url.contains('mdisk') || algoParam == '3') {
       headers['Referer'] ??= 'https://embed.su/';
       headers['Origin'] ??= 'https://embed.su';
    }

    // Los segmentos de TikTok CDN requieren el Referer del player original
    if (url.contains('tiktokcdn.com') || url.contains('muscdn.com') || url.contains('bytecdn')) {
      headers['Referer'] = 'https://player.videasy.net/';
      headers['Origin'] = 'https://player.videasy.net';

    }
    
    // SPOOFING: Prioridad al parámetro 'a' de la URL
    final isAlgo1 = algoParam == '1' || (algoParam == null && url.contains('m3u8') && !url.contains('embed.su') && !url.contains('videasy'));
    final isAlgo2Or3 = algoParam == '2' || algoParam == '3' || url.contains('videasy') || url.contains('embed.su');

    // 🎭 SUPER SPOOFING: 
    // Si es Algo 1, nos hacemos pasar por un celular (Android).
    if (isAlgo1) {
      headers['User-Agent'] = 'Dalvik/2.1.0 (Linux; U; Android 13; SM-S918B Build/TP1A.220624.014)';
    } 
    // Si es Algo 2 o 3, nos hacemos pasar por un navegador de escritorio (Chrome)
    // Esto es vital para VLC/TVs, porque si el servidor ve "VLC" o "Tizen", sirve anuncios de TikTok.
    else if (isAlgo2Or3) {
      headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
    }
    
    headers['Connection'] ??= 'Keep-Alive';
    headers['Accept-Encoding'] ??= 'gzip';
    
    // 🛡️ Filtro de cabeceras para el upstream
    if (url.contains('.m3u8')) {
      headers.remove('Range'); 
    } else if (incomingHeaders.containsKey('range')) {
      headers['Range'] = incomingHeaders['range']!;
    }

    if (isAlgo2Or3) {
      headers['Sec-Fetch-Dest'] ??= 'video';
      headers['Sec-Fetch-Mode'] ??= 'cors';
      headers['Sec-Fetch-Site'] ??= 'cross-site';
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


        final requestHost = request.headers.value(HttpHeaders.hostHeader) ?? '$_localIp:$_port';
        final body = response.body;
        
        final rewrittenBody = _rewriteM3u8(body, url, headers, requestHost, algorithm: algoParam != null ? int.tryParse(algoParam) : null);
        
        final bytes = utf8.encode(rewrittenBody);
        request.response.headers.contentType = ContentType.parse('application/vnd.apple.mpegurl');
        request.response.headers.contentLength = bytes.length;
        request.response.headers.set('Access-Control-Allow-Origin', '*');
        request.response.add(bytes);
        await request.response.close();
        print('♻️ [PROXY] M3U8 reescrita — ${bytes.length} bytes → $requestHost');
      } else {
        // Streaming directo para segmentos (.ts/.image/etc.)
        final client = http.Client();
        final proxyRequest = http.Request('GET', Uri.parse(url))
          ..headers.addAll(headers)
          ..followRedirects = true;

        final response = await client.send(proxyRequest);

        if (response.statusCode != 200 && response.statusCode != 206) {
          print('❌ [SEG] Error del CDN: ${response.statusCode} para ${url.split('?').first}');
          final errBytes = await response.stream.toBytes();
          final errPreview = errBytes.length > 200 ? errBytes.sublist(0, 200) : errBytes;
          print('❌ [SEG] Body: ${String.fromCharCodes(errPreview)}');
          request.response.statusCode = response.statusCode;
          await request.response.close();
          client.close();
          return;
        }
        
        request.response.statusCode = response.statusCode;
        response.headers.forEach((key, value) {
          final k = key.toLowerCase();
          if (k != 'transfer-encoding' && k != 'content-encoding' && k != 'content-type') {
            request.response.headers.set(key, value);
          }
        });

        // TikTok CDN disfraza los segmentos de video como 'image/png' para evitar hotlinking.
        // Forzamos el Content-Type correcto para que VLC y otros reproductores los procesen como video.
        final upstreamContentType = response.headers['content-type'] ?? '';
        if (upstreamContentType.contains('image') || url.contains('tiktokcdn') || url.contains('.image')) {
          request.response.headers.contentType = ContentType.parse('video/MP2T');
        } else {
          request.response.headers.set('content-type', upstreamContentType);
        }

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

  String _rewriteM3u8(String content, String baseUrl, Map<String, String> originalHeaders, String host, {int? algorithm}) {
    final lines = LineSplitter.split(content);
    final rewrittenLines = <String>[];
    final baseUri = Uri.parse(baseUrl);

    for (var line in lines) {
      final trimmedLine = line.trim();
      if (trimmedLine.isEmpty) continue;

      if (trimmedLine.startsWith('#')) {
        String newLine = trimmedLine;
        if (trimmedLine.startsWith('#EXT-X-KEY:')) {
           final uriMatch = RegExp(r'URI="([^"]+)"').firstMatch(trimmedLine);
           if (uriMatch != null) {
              final internalUrl = uriMatch.group(1)!;
              final absoluteUri = baseUri.resolve(internalUrl);
              final proxiedUrl = _buildProxiedUrl(absoluteUri.toString(), originalHeaders, host, algorithm: algorithm);
              newLine = trimmedLine.replaceFirst(internalUrl, proxiedUrl.trim());
           }
        }
        rewrittenLines.add(newLine);
      } else {
        // Es una URL de segmento o de sub-playlist, la proxiamos usando el host actual
        final absoluteUri = baseUri.resolve(trimmedLine);
        final proxiedUrl = _buildProxiedUrl(absoluteUri.toString(), originalHeaders, host, algorithm: algorithm);
        rewrittenLines.add(proxiedUrl.trim());
      }
    }
    return '${rewrittenLines.join('\n')}\n';
  }

  String _buildProxiedUrl(String url, Map<String, String>? headers, String host, {int? algorithm}) {
    // Usamos base64Url para evitar caracteres problemáticos (+ y /) y quitamos el padding (=) 
    final bUrl = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
    String? bHeaders;
    if (headers != null && headers.isNotEmpty) {
      bHeaders = base64Url.encode(utf8.encode(jsonEncode(headers))).replaceAll('=', '');
    }

    var proxyUrl = 'http://$host/proxy?url=$bUrl';
    if (bHeaders != null) {
      proxyUrl += '&h=$bHeaders';
    }
    if (algorithm != null) {
      proxyUrl += '&a=$algorithm';
    }
    return proxyUrl;
  }

  String getProxiedUrl(String url, Map<String, String>? headers, {bool useLocalhost = false, int? algorithm}) {
    final host = (useLocalhost || _localIp.isEmpty) ? '127.0.0.1:$_port' : '$_localIp:$_port';
    final proxied = _buildProxiedUrl(url, headers, host, algorithm: algorithm);
    print('🔗 [PROXY_GEN] URL Generada (Algo ${algorithm ?? "auto"}): $proxied');
    return proxied;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = 0;
    _localIp = '';
  }
}
