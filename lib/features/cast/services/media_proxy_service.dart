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
        print('🌐 [INCOMING] ${request.method} ${request.uri.toString()}');
        try {
          if (request.uri.path == '/proxy') {
            await _handleProxyRequest(request);
          } else if (request.uri.path == '/ping') {
            request.response.statusCode = HttpStatus.ok;
            request.response.write('📡 [PROXY] Proxy is ALIVE and reachable at ${_localIp.isEmpty ? "localhost" : _localIp}:$_port');
            await request.response.close();
          } else {
            print('⚠️ [NOT_FOUND] Ruta no reconocida: ${request.uri.path}');
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

    // 🛡️ LÓGICA POR ALGORITMO (Aislamiento total)
    
    // Algoritmo 1: TOTALMENTE INVISIBLE (No tocamos nada)
    final isAlgo1 = algoParam == '1' || (algoParam == null && url.contains('m3u8') && !url.contains('embed.su') && !url.contains('videasy'));
    if (isAlgo1) {
      // Usamos los headers originales sin añadir nada nuestro
    } else {
      // Algoritmo 3: Videasy / Embed.su
      if (algoParam == '3' || url.contains('videasy') || url.contains('embed.su')) {
        headers['Referer'] ??= 'https://embed.su/';
        headers['Origin'] ??= 'https://embed.su';
      }

      // Algoritmo 2: Cuevana / Otros
      if (algoParam == '2') {
        headers['User-Agent'] = 'Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36';
        headers['Sec-Fetch-Dest'] = 'video';
        headers['Sec-Fetch-Mode'] = 'cors';
        headers['Sec-Fetch-Site'] = 'cross-site';
        if (incomingHeaders.containsKey('cookie')) {
          headers['Cookie'] = incomingHeaders['cookie']!;
        }
      }

      // TikTok CDN: Solo para Algo 2
      if (url.contains('tiktokcdn.com') || url.contains('muscdn.com')) {
        if (algoParam == '2') {
          headers['Referer'] = 'https://player.videasy.net/';
          headers['Origin'] = 'https://player.videasy.net';
        }
      }
    }
    
    headers['Connection'] ??= 'Keep-Alive';
    headers['Accept-Encoding'] ??= 'gzip';
    
    // 🛡️ Filtro de cabeceras para el upstream
    if (url.contains('.m3u8') || url.contains('.txt')) {
      headers.remove('Range'); 
    } else if (incomingHeaders.containsKey('range')) {
      headers['Range'] = incomingHeaders['range']!;
    }
    
    // 📁 Soporte para archivos locales (Descargas) con soporte de Range
    if (!url.startsWith('http')) {
      final cleanPath = url.replaceFirst('file://', '');
      final file = File(cleanPath);
      if (await file.exists()) {
        final length = await file.length();
        final rangeHeader = request.headers.value('range');
        
        request.response.headers.set('Accept-Ranges', 'bytes');
        request.response.headers.set('Access-Control-Allow-Origin', '*');
        request.response.headers.contentType = ContentType.parse('video/mp4');

        if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
          final parts = rangeHeader.substring(6).split('-');
          final start = int.parse(parts[0]);
          final end = (parts.length > 1 && parts[1].isNotEmpty) 
              ? int.parse(parts[1]) 
              : length - 1;
          
          print('📂 [LOCAL] Rango: $start-$end / $length | $cleanPath');
          
          request.response.statusCode = HttpStatus.partialContent;
          request.response.headers.set('Content-Range', 'bytes $start-$end/$length');
          request.response.headers.contentLength = (end - start) + 1;
          
          await request.response.addStream(file.openRead(start, end + 1));
        } else {
          print('📂 [LOCAL] Completo: $length bytes | $cleanPath');
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentLength = length;
          await request.response.addStream(file.openRead());
        }
        await request.response.close();
        return;
      } else {
        print('⚠️ [LOCAL] Archivo no encontrado en: $cleanPath');
      }
    }

    final isM3u8Candidate = url.contains('.m3u8') || 
                            url.contains('.txt') || 
                            url.contains('master') || 
                            url.contains('playlist') || 
                            url.contains('mpegurl');

    try {
      if (isM3u8Candidate) {
        // Solo para candidatos a M3U8 descargamos el cuerpo para analizarlo
        final response = await http.get(Uri.parse(url), headers: headers);
        
        if (response.statusCode != 200) {
          print('❌ [PROXY] Error Upstream: ${response.statusCode} para ${url.split('?').first}');
          request.response.statusCode = response.statusCode;
          await request.response.close();
          return;
        }

        final contentType = response.headers['content-type']?.toLowerCase() ?? '';
        final body = response.body;

        // Verificamos si realmente es una lista HLS por su contenido
        if (body.contains('#EXTM3U')) {
          print('📥 [PROXY] Lista HLS reescrita: ${url.split('/').last}');
          final requestHost = request.headers.value(HttpHeaders.hostHeader) ?? '$_localIp:$_port';
          final rewrittenBody = _rewriteM3u8(body, url, headers, requestHost, algorithm: algoParam != null ? int.tryParse(algoParam) : null);
          
          final bytes = utf8.encode(rewrittenBody);
          request.response.headers.contentType = ContentType.parse('application/vnd.apple.mpegurl');
          request.response.headers.contentLength = bytes.length;
          request.response.headers.set('Access-Control-Allow-Origin', '*');
          request.response.add(bytes);
          await request.response.close();
          return;
        } else {
          // Si no es un M3U8 real, enviamos los bytes originales sin tocarlos
          request.response.statusCode = 200;
          request.response.headers.set('content-type', contentType);
          request.response.add(response.bodyBytes);
          await request.response.close();
          return;
        }
      } else {
        // STREAMING DIRECTO PARA SEGMENTOS (BINARIOS) - No tocamos los bytes
        final client = http.Client();
        final proxyRequest = http.Request('GET', Uri.parse(url))
          ..headers.addAll(headers)
          ..followRedirects = true;

        final response = await client.send(proxyRequest);
        final segName = url.split('/').last.split('?').first;

        if (response.statusCode != 200 && response.statusCode != 206) {
          print('❌ [SEG] Error ${response.statusCode} en: $segName');
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

        // Corrección de Content-Type para TikTok (disfrazado de imagen)
        final upstreamContentType = response.headers['content-type'] ?? '';
        final isTikTok = url.contains('tiktokcdn') || url.contains('muscdn') || url.contains('.image');
        
        if (isTikTok && upstreamContentType.contains('image')) {
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
        if (trimmedLine.startsWith('#EXT-X-KEY:') || trimmedLine.startsWith('#EXT-X-MAP:')) {
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
